// Persistent scan history: remembers every scan you open and groups them by patient.
// Stored as a small JSON file in ~/Library/Application Support/X-ray Viewer/library.json (local only).

import Foundation

struct ScanEntry: Codable, Hashable {
    var path: String
    var patient: String          // display name; "" when the file has none
    var patientID: String
    var date: String             // YYYYMMDD or ""
    var time: String             // HHMMSS or ""
    var modality: String
    var desc: String
    var title: String?          // scan name from metadata (nil = not read yet by this version)
    var view: String?           // laterality / view position
    var meta: Int?              // metadata reader version that produced this entry
    var rows: Int
    var cols: Int
    var added: Date
    var lastOpened: Date?

    var fileName: String { (path as NSString).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path) }
    /// Sortable key; nil when the scan has no date.
    var sortKey: String? { date.isEmpty ? nil : date + (time.isEmpty ? "000000" : time) }
    var prettyDate: String {
        guard date.count == 8 else { return "No date" }
        let d = "\(date.prefix(4))-\(date.dropFirst(4).prefix(2))-\(date.dropFirst(6).prefix(2))"
        return time.count == 6 ? d + "  \(time.prefix(2)):\(time.dropFirst(2).prefix(2))" : d
    }
    var name: String { title ?? "" }
    var patientKey: String { patient.isEmpty ? "Unknown patient" : patient }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

final class Library {
    static let metaVersion = 2
    private(set) var entries: [String: ScanEntry] = [:]
    let fileURL: URL

    init() {
        if let override = ProcessInfo.processInfo.environment["XRAY_LIBRARY"] {
            fileURL = URL(fileURLWithPath: override)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            fileURL = base.appendingPathComponent("X-ray Viewer/library.json")
        }
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([ScanEntry].self, from: data) {
            for e in list { entries[e.path] = e }
        }
    }

    func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(Array(entries.values)) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Reads only the DICOM header (first MB), so adding thousands of files is quick.
    static func entry(for url: URL) -> ScanEntry? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 1 << 20), head.count > 140,
              let im = try? DicomParser([UInt8](head)).parse(metadataOnly: true), im.rows > 0, im.cols > 0
        else { return nil }
        let path = url.standardizedFileURL.path
        return ScanEntry(path: path, patient: im.patient, patientID: im.patientID, date: im.date, time: im.time,
                         modality: im.modality, desc: im.desc, title: im.title, view: im.view, meta: Library.metaVersion, rows: im.rows, cols: im.cols, added: Date(), lastOpened: nil)
    }

    /// Adds files in the background; `done` runs on the main thread with the paths that were readable.
    func add(_ urls: [URL], done: @escaping ([String]) -> Void) {
        let known = Set(entries.keys)
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [ScanEntry] = [], paths: [String] = []
            for u in urls {
                let path = u.standardizedFileURL.path
                if known.contains(path) { paths.append(path); continue }
                if let e = Library.entry(for: u) { found.append(e); paths.append(path) }
            }
            DispatchQueue.main.async {
                for e in found { self.entries[e.path] = e }
                if !found.isEmpty { self.save() }
                done(paths)
            }
        }
    }

    /// Entries saved by an older version lack the scan name; re-read just their headers once.
    func refreshStale(done: @escaping () -> Void) {
        let stale = entries.values.filter { ($0.meta ?? 0) < Library.metaVersion && $0.exists }.map { $0.path }
        guard !stale.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let fresh = stale.compactMap { Library.entry(for: URL(fileURLWithPath: $0)) }
            DispatchQueue.main.async {
                for var e in fresh {
                    if let old = self.entries[e.path] { e.added = old.added; e.lastOpened = old.lastOpened }
                    self.entries[e.path] = e
                }
                self.save(); done()
            }
        }
    }

    func touch(_ paths: [String]) { for p in paths { entries[p]?.lastOpened = Date() }; save() }
    func remove(_ paths: [String]) { for p in paths { entries[p] = nil }; save() }
    func clear() { entries = [:]; save() }
}

// MARK: - Grouping for the sidebar: patient > day > scan

final class PatientNode: NSObject {
    let name: String
    var days: [DayNode] = []
    var scans: [ScanNode] { days.flatMap { $0.scans } }
    init(name: String) { self.name = name }
}

final class DayNode: NSObject {
    let date: String                 // YYYYMMDD or "" (no date)
    var scans: [ScanNode] = []
    unowned let parent: PatientNode
    var key: String { parent.name + "|" + date }
    init(date: String, parent: PatientNode) { self.date = date; self.parent = parent }
}

final class ScanNode: NSObject {
    let entry: ScanEntry
    unowned let parent: DayNode
    init(_ e: ScanEntry, parent: DayNode) { entry = e; self.parent = parent }
}

/// Patients A→Z (unknown last); days and the scans within a day by date/time, undated always last.
func buildGroups(_ entries: [ScanEntry], ascending: Bool) -> [PatientNode] {
    func before(_ a: String?, _ b: String?, tie: Bool) -> Bool {
        switch (a, b) {
        case let (x?, y?): return x == y ? tie : (ascending ? x < y : x > y)
        case (_?, nil): return true
        case (nil, _?): return false
        default: return tie
        }
    }
    var byPatient: [String: [ScanEntry]] = [:]
    for e in entries { byPatient[e.patientKey.lowercased(), default: []].append(e) }
    var nodes: [PatientNode] = []
    for (_, list) in byPatient {
        let patient = PatientNode(name: list[0].patientKey)
        let byDay = Dictionary(grouping: list, by: { $0.date })
        let days = byDay.keys.sorted { before($0.isEmpty ? nil : $0, $1.isEmpty ? nil : $1, tie: $0 < $1) }
        for d in days {
            let day = DayNode(date: d, parent: patient)
            let sorted = byDay[d]!.sorted { a, b in
                before(a.sortKey, b.sortKey, tie: a.path.localizedStandardCompare(b.path) == .orderedAscending)
            }
            day.scans = sorted.map { ScanNode($0, parent: day) }
            patient.days.append(day)
        }
        nodes.append(patient)
    }
    return nodes.sorted {
        if $0.name == "Unknown patient" { return false }
        if $1.name == "Unknown patient" { return true }
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
}
