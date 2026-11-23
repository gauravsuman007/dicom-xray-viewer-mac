// Lists every element of a DICOM file (tag, name, VR, value), including nested sequences.

import Foundation

struct TagRow {
    let depth: Int
    let tag: String        // "(0008,103E)"
    let name: String
    let vr: String
    let length: String
    let value: String
}

enum DicomDictionary {
    /// Common tags only (one per line: TTTTTTTT VR Name). Anything else is shown as Unknown / Private.
    static let table: [UInt32: (vr: String, name: String)] = {
        var t: [UInt32: (vr: String, name: String)] = [:]
        for line in source.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, let key = UInt32(parts[0], radix: 16) else { continue }
            t[key] = (parts[1], parts[2])
        }
        return t
    }()

    static let source = """
    00020000 UL File Meta Information Group Length
    00020001 OB File Meta Information Version
    00020002 UI Media Storage SOP Class UID
    00020003 UI Media Storage SOP Instance UID
    00020010 UI Transfer Syntax UID
    00020012 UI Implementation Class UID
    00020013 SH Implementation Version Name
    00020016 AE Source Application Entity Title
    00080005 CS Specific Character Set
    00080008 CS Image Type
    00080012 DA Instance Creation Date
    00080013 TM Instance Creation Time
    00080014 UI Instance Creator UID
    00080016 UI SOP Class UID
    00080018 UI SOP Instance UID
    00080020 DA Study Date
    00080021 DA Series Date
    00080022 DA Acquisition Date
    00080023 DA Content Date
    0008002A DT Acquisition DateTime
    00080030 TM Study Time
    00080031 TM Series Time
    00080032 TM Acquisition Time
    00080033 TM Content Time
    00080050 SH Accession Number
    00080060 CS Modality
    00080064 CS Conversion Type
    00080068 CS Presentation Intent Type
    00080070 LO Manufacturer
    00080080 LO Institution Name
    00080081 ST Institution Address
    00080090 PN Referring Physician's Name
    00080092 ST Referring Physician's Address
    00080100 SH Code Value
    00080102 SH Coding Scheme Designator
    00080104 LO Code Meaning
    00080201 SH Timezone Offset From UTC
    00081010 SH Station Name
    00081030 LO Study Description
    0008103E LO Series Description
    00081040 LO Institutional Department Name
    00081048 PN Physician(s) of Record
    00081050 PN Performing Physician's Name
    00081060 PN Name of Physician(s) Reading Study
    00081070 PN Operators' Name
    00081080 LO Admitting Diagnoses Description
    00081090 LO Manufacturer's Model Name
    00081110 SQ Referenced Study Sequence
    00081111 SQ Referenced Performed Procedure Step Sequence
    00081140 SQ Referenced Image Sequence
    00081150 UI Referenced SOP Class UID
    00081155 UI Referenced SOP Instance UID
    00082111 ST Derivation Description
    00082112 SQ Source Image Sequence
    00082218 SQ Anatomic Region Sequence
    00082228 SQ Primary Anatomic Structure Sequence
    00100010 PN Patient's Name
    00100020 LO Patient ID
    00100021 LO Issuer of Patient ID
    00100030 DA Patient's Birth Date
    00100040 CS Patient's Sex
    00101010 AS Patient's Age
    00101020 DS Patient's Size
    00101030 DS Patient's Weight
    00102000 LO Medical Alerts
    00102110 LO Allergies
    00104000 LT Patient Comments
    00120062 CS Patient Identity Removed
    00120063 LO De-identification Method
    00180010 LO Contrast/Bolus Agent
    00180015 CS Body Part Examined
    00180050 DS Slice Thickness
    00180060 DS KVP
    00181000 LO Device Serial Number
    00181004 LO Plate ID
    00181020 LO Software Version(s)
    00181030 LO Protocol Name
    00181110 DS Distance Source to Detector
    00181111 DS Distance Source to Patient
    00181114 DS Estimated Radiographic Magnification Factor
    00181120 DS Gantry/Detector Tilt
    00181150 IS Exposure Time
    00181151 IS X-Ray Tube Current
    00181152 IS Exposure
    00181153 IS Exposure in uAs
    00181160 SH Filter Type
    00181164 DS Imager Pixel Spacing
    00181166 CS Grid
    00181190 DS Focal Spot(s)
    00181200 DA Date of Last Calibration
    00181201 TM Time of Last Calibration
    00181400 LO Acquisition Device Processing Description
    00181401 LO Acquisition Device Processing Code
    00181402 CS Cassette Orientation
    00181403 CS Cassette Size
    00181404 US Exposures on Plate
    00181405 IS Relative X-Ray Exposure
    00181411 DS Exposure Index
    00181412 DS Target Exposure Index
    00181413 DS Deviation Index
    00181500 CS Positioner Motion
    00181508 CS Positioner Type
    00181510 DS Positioner Primary Angle
    00181511 DS Positioner Secondary Angle
    00181700 CS Collimator Shape
    00185100 CS Patient Position
    00185101 CS View Position
    00186000 DS Sensitivity
    00187004 CS Detector Type
    00187005 CS Detector Configuration
    00187006 LT Detector Description
    00187008 LT Detector Mode
    0018700A SH Detector ID
    0018700C DA Date of Last Detector Calibration
    0018A001 SQ Contributing Equipment Sequence
    0020000D UI Study Instance UID
    0020000E UI Series Instance UID
    00200010 SH Study ID
    00200011 IS Series Number
    00200012 IS Acquisition Number
    00200013 IS Instance Number
    00200020 CS Patient Orientation
    00200032 DS Image Position (Patient)
    00200037 DS Image Orientation (Patient)
    00200052 UI Frame of Reference UID
    00200060 CS Laterality
    00200062 CS Image Laterality
    00204000 LT Image Comments
    00280002 US Samples per Pixel
    00280004 CS Photometric Interpretation
    00280006 US Planar Configuration
    00280008 IS Number of Frames
    00280010 US Rows
    00280011 US Columns
    00280030 DS Pixel Spacing
    00280034 IS Pixel Aspect Ratio
    00280100 US Bits Allocated
    00280101 US Bits Stored
    00280102 US High Bit
    00280103 US Pixel Representation
    00280106 US Smallest Image Pixel Value
    00280107 US Largest Image Pixel Value
    00280300 CS Quality Control Image
    00280301 CS Burned In Annotation
    00280A02 CS Pixel Spacing Calibration Type
    00280A04 LO Pixel Spacing Calibration Description
    00281040 CS Pixel Intensity Relationship
    00281041 SS Pixel Intensity Relationship Sign
    00281050 DS Window Center
    00281051 DS Window Width
    00281052 DS Rescale Intercept
    00281053 DS Rescale Slope
    00281054 LO Rescale Type
    00281055 LO Window Center & Width Explanation
    00281056 CS VOI LUT Function
    00282110 CS Lossy Image Compression
    00282112 DS Lossy Image Compression Ratio
    00283010 SQ VOI LUT Sequence
    00321032 PN Requesting Physician
    00321033 LO Requesting Service
    00321060 LO Requested Procedure Description
    00400244 DA Performed Procedure Step Start Date
    00400245 TM Performed Procedure Step Start Time
    00400253 SH Performed Procedure Step ID
    00400254 LO Performed Procedure Step Description
    00400260 SQ Performed Protocol Code Sequence
    00400275 SQ Request Attributes Sequence
    00400280 ST Comments on the Performed Procedure Step
    00540400 SH Image ID
    00880200 SQ Icon Image Sequence
    7FE00010 OW Pixel Data
    """
}

final class DicomDumper {
    let parser: DicomParser
    var b: [UInt8] { parser.b }
    var rows: [TagRow] = []
    var explicitDS = false
    var charset = ""

    init(_ p: DicomParser) { parser = p }

    func run() -> [TagRow] {
        var p = 0
        if b.count > 132, b[128] == 0x44, b[129] == 0x49, b[130] == 0x43, b[131] == 0x4D { p = 132 }
        func upper(_ x: UInt8) -> Bool { x >= 0x41 && x <= 0x5A }
        explicitDS = p + 6 <= b.count && upper(b[p + 4]) && upper(b[p + 5])
        _ = walk(p, b.count, 0, untilDelimiter: false)
        return rows
    }

    private func hex4(_ v: Int) -> String { String(format: "%04X", v) }

    /// Walks the elements in [start, end); returns the position after the delimiter (or where it stopped).
    private func walk(_ start: Int, _ end: Int, _ depth: Int, untilDelimiter: Bool) -> Int {
        var p = start
        let limit = min(end, b.count)
        while p + 8 <= limit {
            let g = parser.u16(p)
            guard let h = parser.header(at: p, explicit: g == 2 || explicitDS) else { break }
            if h.group == 0xFFFE {
                if h.elem == 0xE0DD || h.elem == 0xE00D { return p + 8 }
                if h.elem == 0xE000 {
                    rows.append(TagRow(depth: depth, tag: "(FFFE,E000)", name: "Item", vr: "", length: h.len < 0 ? "undefined" : "\(h.len)", value: ""))
                    if h.len < 0 { p = walk(p + 8, end, depth + 1, untilDelimiter: true) }
                    else { _ = walk(p + 8, p + 8 + h.len, depth + 1, untilDelimiter: false); p += 8 + h.len }
                    continue
                }
                p += 8; continue
            }
            let key = UInt32(h.group) << 16 | UInt32(h.elem)
            let info = DicomDictionary.table[key]
            let vp = p + h.hdr
            let vr = explicitDS || h.group == 2 ? h.vr : (info?.vr ?? "UN")
            let name = info?.name ?? (h.group % 2 == 1 ? "Private" : "Unknown")
            let tag = "(\(hex4(h.group)),\(hex4(h.elem)))"
            let len = h.len < 0 ? "undefined" : "\(h.len)"
            guard vp <= b.count else { break }

            if key == 0x7FE0_0010 {
                if h.len < 0 {
                    let n = max(parser.fragments(from: vp).count - 1, 0)
                    rows.append(TagRow(depth: depth, tag: tag, name: name, vr: vr, length: len, value: "(compressed image data, \(n) fragment\(n == 1 ? "" : "s"))"))
                    p = parser.skipSequence(vp, explicit: false)
                } else {
                    rows.append(TagRow(depth: depth, tag: tag, name: name, vr: vr, length: len, value: "(\(h.len) bytes of pixels)"))
                    p = vp + h.len
                }
                continue
            }
            if vr == "SQ" || h.len < 0 {
                rows.append(TagRow(depth: depth, tag: tag, name: name, vr: "SQ", length: len, value: "(sequence)"))
                if h.len < 0 { p = walk(vp, end, depth + 1, untilDelimiter: true) }
                else { _ = walk(vp, min(vp + h.len, b.count), depth + 1, untilDelimiter: false); p = vp + h.len }
                continue
            }
            guard vp + h.len <= b.count else {
                rows.append(TagRow(depth: depth, tag: tag, name: name, vr: vr, length: len, value: "(truncated)"))
                break
            }
            let value = format(vr, b[vp..<(vp + h.len)])
            if key == 0x00080005 { charset = value }
            if key == 0x00020010 { explicitDS = value != TS.implicitLE }
            rows.append(TagRow(depth: depth, tag: tag, name: name, vr: vr, length: len, value: value))
            p = vp + h.len
        }
        return p
    }

    private func format(_ vr: String, _ d: ArraySlice<UInt8>) -> String {
        let s = d.startIndex
        func nums<T>(_ size: Int, _ f: (Int) -> T) -> String {
            let n = d.count / size
            var out = (0..<min(n, 24)).map { "\(f(s + $0 * size))" }.joined(separator: " \\ ")
            if n > 24 { out += " … (\(n) values)" }
            return out
        }
        func le(_ p: Int, _ n: Int) -> UInt64 { (0..<n).reduce(0) { $0 | UInt64(b[p + $1]) << UInt64(8 * $1) } }
        switch vr {
        case "US": return nums(2) { Int(le($0, 2)) }
        case "SS": return nums(2) { Int(Int16(truncatingIfNeeded: le($0, 2))) }
        case "UL": return nums(4) { Int(le($0, 4)) }
        case "SL": return nums(4) { Int(Int32(truncatingIfNeeded: le($0, 4))) }
        case "FL": return nums(4) { Float(bitPattern: UInt32(le($0, 4))) }
        case "FD": return nums(8) { Double(bitPattern: le($0, 8)) }
        case "AT": return nums(4) { String(format: "(%04X,%04X)", Int(le($0, 2)), Int(le($0 + 2, 2))) }
        case "OB", "OW", "OF", "OD", "OL", "OV", "UN":
            let printable = !d.isEmpty && d.count < 400 && d.allSatisfy { ($0 >= 0x20 && $0 < 0x7F) || $0 == 0 }
            if printable { return parser.clean(d, charset: charset) }
            if d.count <= 16 { return d.map { String(format: "%02X", $0) }.joined(separator: " ") }
            return "(\(d.count) bytes)"
        default:
            var text = parser.clean(d, charset: charset).replacingOccurrences(of: "\\", with: " \\ ")
            if text.count > 500 { text = String(text.prefix(500)) + "…" }
            return text
        }
    }
}

extension Loader {
    /// Reads up to the first 8 MB (all header elements) and lists every element.
    static func dump(_ url: URL) throws -> [TagRow] {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let head = try fh.read(upToCount: 8 << 20) ?? Data()
        guard head.count > 140 else { throw DicomError("File too small to be DICOM") }
        return DicomDumper(DicomParser([UInt8](head))).run()
    }
}
