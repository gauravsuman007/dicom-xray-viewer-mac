// Secondary windows: full metadata list, and settings.

import Cocoa

final class MetaTable: NSTableView {
    var copyHandler: (() -> Void)?
    @objc func copy(_ sender: Any?) { copyHandler?() }
}

final class MetadataWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let window: NSWindow
    var onClose: ((MetadataWindow) -> Void)?
    private let all: [TagRow]
    private var shown: [TagRow]
    private let table = MetaTable()
    private let search = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    init(url: URL, rows: [TagRow]) {
        all = rows; shown = rows
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 660),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Metadata — \(url.lastPathComponent)"
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 560, height: 320)
        window.isReleasedWhenClosed = false
        window.delegate = self

        search.placeholderString = "Filter by tag, name or value (e.g. Unterschenkel, 0008, laterality)"
        search.sendsSearchStringImmediately = true
        search.target = self; search.action = #selector(filterChanged)
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyRows))
        copy.bezelStyle = .rounded; copy.toolTip = "Copy the selected rows, or all shown rows, as tab-separated text"
        let top = NSStackView(views: [search, copy]); top.orientation = .horizontal; top.spacing = 8
        top.translatesAutoresizingMaskIntoConstraints = false

        func col(_ id: String, _ title: String, _ w: CGFloat, _ min: CGFloat = 30) -> NSTableColumn {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); c.title = title; c.width = w; c.minWidth = min
            return c
        }
        table.addTableColumn(col("tag", "Tag", 110, 80))
        table.addTableColumn(col("name", "Name", 260, 80))
        table.addTableColumn(col("vr", "VR", 36))
        table.addTableColumn(col("len", "Length", 66))
        let value = col("value", "Value", 440, 100); value.resizingMask = .autoresizingMask
        table.addTableColumn(value)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 18
        table.dataSource = self; table.delegate = self
        table.copyHandler = { [weak self] in self?.copyRows() }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(top); root.addSubview(scroll); root.addSubview(status)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        window.contentView = root
        updateStatus()
        window.center()
    }

    func show() { window.makeKeyAndOrderFront(nil) }

    private func updateStatus() {
        status.stringValue = shown.count == all.count ? "\(all.count) elements" : "\(shown.count) of \(all.count) elements"
    }

    @objc private func filterChanged() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        shown = q.isEmpty ? all : all.filter { r in
            [r.tag, r.name, r.vr, r.value].contains { $0.range(of: q, options: opts) != nil }
        }
        table.reloadData(); updateStatus()
    }

    @objc private func copyRows() {
        let sel = table.selectedRowIndexes
        let rows = sel.isEmpty ? shown : sel.map { shown[$0] }
        let text = rows.map { "\($0.tag)\t\(String(repeating: "  ", count: $0.depth))\($0.name)\t\($0.vr)\t\($0.value)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard let col else { return nil }
        let r = shown[row], id = col.identifier
        let f = (tv.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: ""); f.identifier = id; f.lineBreakMode = .byTruncatingTail; return f
        }()
        f.toolTip = nil
        switch id.rawValue {
        case "tag": f.stringValue = r.tag; f.font = mono; f.textColor = .secondaryLabelColor
        case "name":
            f.stringValue = String(repeating: "      ", count: r.depth) + r.name
            f.font = .systemFont(ofSize: 12); f.textColor = (r.name == "Unknown" || r.name == "Private") ? .secondaryLabelColor : .labelColor
        case "vr": f.stringValue = r.vr; f.font = mono; f.textColor = .secondaryLabelColor
        case "len": f.stringValue = r.length; f.font = mono; f.textColor = .secondaryLabelColor
        default: f.stringValue = r.value; f.font = mono; f.textColor = .labelColor; f.toolTip = r.value
        }
        return f
    }

    func windowWillClose(_ n: Notification) { onClose?(self) }
}

final class PreferencesWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let restore = NSButton(checkboxWithTitle: "Reopen the library tree as I left it", target: nil, action: nil)
    var onRestoreChanged: ((Bool) -> Void)?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 150),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false

        restore.state = UserDefaults.standard.bool(forKey: SidebarViewController.restoreKey) ? .on : .off
        restore.target = self; restore.action = #selector(toggled)
        let note = NSTextField(wrappingLabelWithString: "When on, the patients and days you had expanded stay expanded the next time you start the app. When off, the library always starts fully collapsed.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [restore, note])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(); root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
        ])
        window.contentView = root
        window.center()
    }

    func show() { window.makeKeyAndOrderFront(nil) }

    @objc private func toggled() {
        let on = restore.state == .on
        UserDefaults.standard.set(on, forKey: SidebarViewController.restoreKey)
        onRestoreChanged?(on)
    }
}
