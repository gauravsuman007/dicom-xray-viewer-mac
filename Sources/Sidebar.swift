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

    func configure(scan e: ScanEntry) {
        let exists = e.exists
        title.stringValue = e.prettyDate + (exists ? "" : "  (missing)")
        title.textColor = exists ? .labelColor : .secondaryLabelColor
        let detail = [e.modality, e.desc, "\(e.cols)×\(e.rows)"].filter { !$0.isEmpty }.joined(separator: " · ")
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
    private var collapsed = Set<String>()
    private var suppress = false

    private let outline = LibraryOutline()
    private let sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No scans yet.\n\nOpen or drop DICOM files or a folder (⌘O). Everything you open is remembered here, grouped by patient.")

    override func loadView() {
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
        var rows = IndexSet()
        for r in 0..<outline.numberOfRows {
            if let n = outline.item(atRow: r) as? ScanNode, set.contains(n.entry.path) { rows.insert(r) }
        }
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { outline.scrollRowToVisible(first) }
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
        for p in patients where !collapsed.contains(p.name) { outline.expandItem(p) }
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
        return (item as? PatientNode)?.scans.count ?? 0
    }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool { item is PatientNode }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let p = item as? PatientNode { return p.scans[index] }
        return patients[index]
    }
    func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        let cell = (ov.makeView(withIdentifier: ScanCell.id, owner: self) as? ScanCell) ?? ScanCell()
        if let p = item as? PatientNode { cell.configure(patient: p) }
        else if let s = item as? ScanNode { cell.configure(scan: s.entry) }
        return cell
    }
    func outlineView(_ ov: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { item is PatientNode ? 26 : 40 }

    func outlineView(_ ov: NSOutlineView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        IndexSet(proposed.filter { ov.item(atRow: $0) is ScanNode })     // patient rows only expand/collapse
    }
    func outlineViewSelectionDidChange(_ n: Notification) {
        guard !suppress else { return }
        onSelect?(selectedPaths)
    }
    func outlineViewItemDidCollapse(_ n: Notification) {
        if !suppress, let p = n.userInfo?["NSObject"] as? PatientNode { collapsed.insert(p.name) }
    }
    func outlineViewItemDidExpand(_ n: Notification) {
        if !suppress, let p = n.userInfo?["NSObject"] as? PatientNode { collapsed.remove(p.name) }
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
        } else if outline.item(atRow: row) is ScanNode {
            var paths = selectedPaths
            if let n = outline.item(atRow: row) as? ScanNode, !paths.contains(n.entry.path) { paths = [n.entry.path] }
            add("Show in Finder", #selector(menuReveal(_:)), paths)
            add(paths.count > 1 ? "Remove \(paths.count) Scans from History" : "Remove from History", #selector(menuRemove(_:)), paths)
        }
    }
    @objc private func menuCompare(_ s: NSMenuItem) { select(paths: s.representedObject as? [String] ?? [], notify: true) }
    @objc private func menuRemove(_ s: NSMenuItem) { onRemove?(s.representedObject as? [String] ?? []) }
    @objc private func menuReveal(_ s: NSMenuItem) {
        let urls = (s.representedObject as? [String] ?? []).map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
