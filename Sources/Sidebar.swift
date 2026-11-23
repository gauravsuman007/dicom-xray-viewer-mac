// Library sidebar: scans grouped by patient, sorted by date.

import Cocoa

final class LibraryOutline: NSOutlineView {
    var onDelete: (() -> Void)?
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 51 || e.keyCode == 117 { onDelete?() } else { super.keyDown(with: e) }   // delete / forward-delete
    }
}

final class ScanCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("ScanCell")
    private let title = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = ScanCell.id
        for l in [title, sub] { l.lineBreakMode = .byTruncatingTail; l.maximumNumberOfLines = 1 }
        title.font = .systemFont(ofSize: 12, weight: .medium)
        sub.font = .systemFont(ofSize: 10); sub.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, sub])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(patient p: PatientNode) {
        let s = NSMutableAttributedString(string: p.name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
        s.append(NSAttributedString(string: "   \(p.scans.count)", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        title.attributedStringValue = s
        sub.isHidden = true
    }

    func configure(day d: DayNode) {
        var text = "No date"
        if d.date.count == 8 {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
            if let date = f.date(from: d.date) {
                let o = DateFormatter(); o.dateStyle = .medium; o.timeStyle = .none
                let w = DateFormatter(); w.dateFormat = "EEE"
                text = "\(w.string(from: date)), \(o.string(from: date))"
            }
        }
        let s = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor.labelColor])
        s.append(NSAttributedString(string: "   \(d.scans.count)", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        title.attributedStringValue = s
        sub.isHidden = true
    }

    func configure(scan e: ScanEntry) {
        let exists = e.exists
        let time = e.time.count == 6 ? "\(e.time.prefix(2)):\(e.time.dropFirst(2).prefix(2))" : ""
        var primary = [time, e.name].filter { !$0.isEmpty }.joined(separator: "   ")
        if primary.isEmpty { primary = e.fileName }
        title.stringValue = primary + (exists ? "" : "  (missing)")
        title.textColor = exists ? .labelColor : .secondaryLabelColor
        let detail = [e.modality, e.view ?? "", "\(e.cols)×\(e.rows)"].filter { !$0.isEmpty }.joined(separator: " · ")
        sub.stringValue = detail + " — " + e.fileName
        sub.isHidden = false
    }
}

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onSelect: (([String]) -> Void)?
    var onRemove: (([String]) -> Void)?
    var onAdd: (() -> Void)?
    var onSortChanged: ((Bool) -> Void)?

    private(set) var ascending = false
    private var entries: [ScanEntry] = []
    private var patients: [PatientNode] = []
    private var expanded = Set<String>()       // patient names and "patient|date" day keys that are open
    var onShowMetadata: ((String) -> Void)?
    private var suppress = false

    private let outline = LibraryOutline()
    private let sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No scans yet.\n\nOpen or drop DICOM files or a folder (⌘O). Everything you open is remembered here, grouped by patient.")

    static let restoreKey = "restoreTreeState", expandedKey = "treeExpanded"
    private var restoreState: Bool { UserDefaults.standard.bool(forKey: SidebarViewController.restoreKey) }

    /// Called when the "remember tree state" setting changes.
    func persistExpandedState() {
        if restoreState { UserDefaults.standard.set(Array(expanded), forKey: SidebarViewController.expandedKey) }
        else { UserDefaults.standard.removeObject(forKey: SidebarViewController.expandedKey) }
    }
    func collapseAll() { outline.collapseItem(nil, collapseChildren: true) }
    func expandAll() { outline.expandItem(nil, expandChildren: true) }

    override func loadView() {
        if restoreState { expanded = Set(UserDefaults.standard.stringArray(forKey: SidebarViewController.expandedKey) ?? []) }
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 290, height: 700))
        root.material = .sidebar; root.blendingMode = .behindWindow; root.state = .followsWindowActiveState
        view = root

        sortPopup.addItems(withTitles: ["Newest first", "Oldest first"])
        sortPopup.controlSize = .small; sortPopup.font = .systemFont(ofSize: 11)
        sortPopup.target = self; sortPopup.action = #selector(sortChanged)
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add scans")!, target: self, action: #selector(addTapped))
        add.bezelStyle = .texturedRounded; add.controlSize = .small; add.toolTip = "Add DICOM files or a folder"
        let header = NSStackView(views: [sortPopup, add])
        header.orientation = .horizontal; header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col); outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.style = .sourceList
        outline.indentationPerLevel = 8
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.backgroundColor = .clear
        outline.dataSource = self; outline.delegate = self
        outline.target = self; outline.doubleAction = #selector(doubleClicked)
        outline.onDelete = { [weak self] in self.map { s in s.onRemove?(s.selectedPaths) } }
        let menu = NSMenu(); menu.delegate = self; outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center; emptyLabel.textColor = .secondaryLabelColor; emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header); root.addSubview(scroll); root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 38),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -40),
        ])
    }

    // MARK: API

    func setSort(ascending asc: Bool) {
        ascending = asc
        sortPopup.selectItem(at: asc ? 1 : 0)
        rebuild(keeping: selectedPaths)
    }

    func reload(entries list: [ScanEntry], keepSelection paths: [String]? = nil) {
        entries = list
        rebuild(keeping: paths ?? selectedPaths)
    }

    var selectedPaths: [String] {
        guard isViewLoaded else { return [] }
        return outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? ScanNode)?.entry.path }
    }

    func select(paths: [String], notify: Bool = false) {
        suppress = !notify
        defer { suppress = false }
        let set = Set(paths)
        for p in patients {                      // make sure the target scans are visible
            for d in p.days where d.scans.contains(where: { set.contains($0.entry.path) }) {
                outline.expandItem(p); outline.expandItem(d)
                expanded.insert(p.name); expanded.insert(d.key)
            }
        }
        var rows = IndexSet()
        for r in 0..<outline.numberOfRows {
            if let n = outline.item(atRow: r) as? ScanNode, set.contains(n.entry.path) { rows.insert(r) }
        }
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { outline.scrollRowToVisible(first) }
        persistExpandedState()
    }

    func selectAdjacent(_ d: Int) {
        let rows = (0..<outline.numberOfRows).filter { outline.item(atRow: $0) is ScanNode }
        guard !rows.isEmpty else { return }
        let cur = d > 0 ? outline.selectedRowIndexes.last : outline.selectedRowIndexes.first
        var target = rows[d > 0 ? 0 : rows.count - 1]
        if let cur, let i = rows.firstIndex(of: cur) { target = rows[(i + d + rows.count) % rows.count] }
        outline.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        outline.scrollRowToVisible(target)
    }

    func selectAllScans() {
        let rows = (0..<outline.numberOfRows).filter { outline.item(atRow: $0) is ScanNode }
        outline.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    private func rebuild(keeping paths: [String]) {
        guard isViewLoaded else { return }
        patients = buildGroups(entries, ascending: ascending)
        suppress = true
        outline.reloadData()
        for p in patients where expanded.contains(p.name) {           // only what was open stays open
            outline.expandItem(p)
            for d in p.days where expanded.contains(d.key) { outline.expandItem(d) }
        }
        suppress = false
        select(paths: paths)
        emptyLabel.isHidden = !entries.isEmpty
    }

    @objc private func sortChanged() {
        ascending = sortPopup.indexOfSelectedItem == 1
        rebuild(keeping: selectedPaths)
        onSortChanged?(ascending)
    }
    @objc private func addTapped() { onAdd?() }

    // MARK: Data source & delegate

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return patients.count }
        if let p = item as? PatientNode { return p.days.count }
        return (item as? DayNode)?.scans.count ?? 0
    }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool { item is PatientNode || item is DayNode }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let p = item as? PatientNode { return p.days[index] }
        if let d = item as? DayNode { return d.scans[index] }
        return patients[index]
    }
    func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        let cell = (ov.makeView(withIdentifier: ScanCell.id, owner: self) as? ScanCell) ?? ScanCell()
        if let p = item as? PatientNode { cell.configure(patient: p) }
        else if let d = item as? DayNode { cell.configure(day: d) }
        else if let s = item as? ScanNode { cell.configure(scan: s.entry) }
        return cell
    }
    func outlineView(_ ov: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { item is PatientNode ? 26 : (item is DayNode ? 24 : 40) }

    func outlineView(_ ov: NSOutlineView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        IndexSet(proposed.filter { ov.item(atRow: $0) is ScanNode })     // patient rows only expand/collapse
    }
    func outlineViewSelectionDidChange(_ n: Notification) {
        guard !suppress else { return }
        onSelect?(selectedPaths)
    }
    func outlineViewItemDidCollapse(_ n: Notification) {
        guard !suppress else { return }
        if let p = n.userInfo?["NSObject"] as? PatientNode { expanded.remove(p.name) }
        if let d = n.userInfo?["NSObject"] as? DayNode { expanded.remove(d.key) }
        persistExpandedState()
    }
    func outlineViewItemDidExpand(_ n: Notification) {
        guard !suppress else { return }
        if let p = n.userInfo?["NSObject"] as? PatientNode { expanded.insert(p.name) }
        if let d = n.userInfo?["NSObject"] as? DayNode { expanded.insert(d.key) }
        persistExpandedState()
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0 else { return }
        func add(_ title: String, _ sel: Selector, _ paths: [String]) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: ""); it.target = self; it.representedObject = paths
            menu.addItem(it)
        }
        if let p = outline.item(atRow: row) as? PatientNode {
            let paths = p.scans.map { $0.entry.path }
            add("Compare All Scans (\(paths.count))", #selector(menuCompare(_:)), paths)
            menu.addItem(.separator())
            add("Remove Patient from History", #selector(menuRemove(_:)), paths)
        } else if let d = outline.item(atRow: row) as? DayNode {
            let paths = d.scans.map { $0.entry.path }
            add("Compare This Day (\(paths.count))", #selector(menuCompare(_:)), paths)
            menu.addItem(.separator())
            add("Remove Day from History", #selector(menuRemove(_:)), paths)
        } else if outline.item(atRow: row) is ScanNode {
            var paths = selectedPaths
            if let n = outline.item(atRow: row) as? ScanNode, !paths.contains(n.entry.path) { paths = [n.entry.path] }
            if let n = outline.item(atRow: row) as? ScanNode { add("Show All Metadata…", #selector(menuMetadata(_:)), [n.entry.path]) }
            add("Show in Finder", #selector(menuReveal(_:)), paths)
            add(paths.count > 1 ? "Remove \(paths.count) Scans from History" : "Remove from History", #selector(menuRemove(_:)), paths)
        }
    }
    /// Double-click a patient or a day to compare all of its scans.
    @objc private func doubleClicked() {
        let row = outline.clickedRow
        guard row >= 0 else { return }
        let item = outline.item(atRow: row)
        let paths = (item as? PatientNode)?.scans.map { $0.entry.path } ?? (item as? DayNode)?.scans.map { $0.entry.path } ?? []
        if paths.count > 1 { select(paths: paths, notify: true) }
    }
    @objc private func menuCompare(_ s: NSMenuItem) { select(paths: s.representedObject as? [String] ?? [], notify: true) }
    @objc private func menuMetadata(_ s: NSMenuItem) {
        if let p = (s.representedObject as? [String])?.first { onShowMetadata?(p) }
    }
    @objc private func menuRemove(_ s: NSMenuItem) { onRemove?(s.representedObject as? [String] ?? []) }
    @objc private func menuReveal(_ s: NSMenuItem) {
        let urls = (s.representedObject as? [String] ?? []).map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
