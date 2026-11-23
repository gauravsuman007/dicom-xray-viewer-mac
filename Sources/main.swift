// X-ray Viewer — app wiring: window, menus, library <-> canvas.

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var splitVC: NSSplitViewController!
    let library = Library()
    let canvas = Canvas()
    let sidebar = SidebarViewController()

    var userInvert = false
    var showPatient = false
    var sortAscending = UserDefaults.standard.bool(forKey: "sortAscending")
    var currentPaths: [String] = []
    var generation = 0
    var truncatedNote: String?
    let maxCompare = 12
    var metaWindows: [MetadataWindow] = []
    var prefs: PreferencesWindow?
    let emptyMessage = "Select a scan in the sidebar, or open / drop DICOM files (⌘O)"

    // MARK: Launch

    func applicationWillFinishLaunching(_ n: Notification) {
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.minSize = NSSize(width: 760, height: 460)

        let canvasVC = NSViewController(); canvasVC.view = canvas
        splitVC = NSSplitViewController()
        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 230; side.maximumThickness = 420; side.canCollapse = true
        splitVC.addSplitViewItem(side)
        splitVC.addSplitViewItem(NSSplitViewItem(viewController: canvasVC))
        window.contentViewController = splitVC
        window.setContentSize(NSSize(width: 1240, height: 820))
        window.title = "X-ray Viewer"
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)

        canvas.message = emptyMessage
        canvas.onDrop = { [weak self] in self?.open($0) }
        canvas.onActiveChange = { [weak self] in self?.refreshOverlay() }
        canvas.onInfo = { [weak self] in self?.showMetadata() }
        canvas.onTileReset = { [weak self] t in
            t.wl = defaultWL(t.image); self?.refreshTile(t); self?.refreshOverlay()
        }
        canvas.onTileWindowDrag = { [weak self] t, dx, dy in
            guard let self, t.image.samples == 1 else { return }
            let k = max(1, t.wl.w / 300)
            t.wl.w = max(1, t.wl.w + Double(dx) * k)
            t.wl.c -= Double(dy) * k
            self.refreshTile(t); self.refreshOverlay()
        }

        _ = sidebar.view
        sidebar.onSelect = { [weak self] in self?.selectionChanged($0) }
        sidebar.onAdd = { [weak self] in self?.openPanel() }
        sidebar.onShowMetadata = { [weak self] in self?.showMetadata(path: $0) }
        sidebar.onRemove = { [weak self] paths in
            guard let self, !paths.isEmpty else { return }
            self.library.remove(paths); self.syncLibrary()
        }
        sidebar.onSortChanged = { [weak self] asc in
            self?.sortAscending = asc
            UserDefaults.standard.set(asc, forKey: "sortAscending")
        }
        sidebar.setSort(ascending: sortAscending)
        syncLibrary()
        library.refreshStale { [weak self] in self?.syncLibrary() }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if currentPaths.isEmpty {
            let args = CommandLine.arguments.dropFirst().filter { FileManager.default.fileExists(atPath: $0) }
            if !args.isEmpty { open(args.map { URL(fileURLWithPath: $0) }) }
        }
        NSApp.activate(ignoringOtherApps: true)
        devSnapshotIfRequested()
    }

    func application(_ app: NSApplication, open urls: [URL]) { open(urls) }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    /// Test hook: XRAY_SNAPSHOT=out.png [XRAY_SELECT_ALL=1] renders the window to a PNG and quits.
    func devSnapshotIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["XRAY_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if env["XRAY_SELECT_ALL"] != nil { self.sidebar.selectAllScans() }
            if env["XRAY_META"] != nil { self.showMetadata() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            let target = env["XRAY_META"] != nil ? (self.metaWindows.first?.window ?? self.window!) : self.window!
            p.arguments = ["-x", "-o", "-l", String(target.windowNumber), out]
            try? p.run(); p.waitUntilExit()
            NSApp.terminate(nil)
        }
    }

    // MARK: Menu

    func buildMenu() {
        let main = NSMenu()
        func add(_ menu: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            if sel != nil { it.target = target ?? self }
            menu.addItem(it)
        }
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); main.addItem(item)
            let m = NSMenu(title: title); item.submenu = m; return m
        }
        let arrowL = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), arrowR = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))

        let app = submenu("X-ray Viewer")
        add(app, "Settings…", #selector(openSettings), ",")
        app.addItem(.separator())
        add(app, "Quit X-ray Viewer", #selector(NSApplication.terminate(_:)), "q", target: NSApp)

        let file = submenu("File")
        add(file, "Open…", #selector(openPanel), "o")
        file.addItem(.separator())
        add(file, "Export Current View as PNG…", #selector(exportCurrent), "e")
        add(file, "Export Patient's Scans as PNG…", #selector(exportAll), "E", [.command, .shift])
        file.addItem(.separator())
        add(file, "Clear History…", #selector(clearHistory), "")
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w", target: nil)

        let edit = submenu("Edit")
        add(edit, "Copy", Selector(("copy:")), "c", target: nil)
        add(edit, "Select All", Selector(("selectAll:")), "a", target: nil)

        let view = submenu("View")
        add(view, "Show/Hide Library", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control], target: splitVC)
        add(view, "Collapse All", #selector(collapseAllAction), "")
        add(view, "Expand All", #selector(expandAllAction), "")
        view.addItem(.separator())
        add(view, "Sort Newest First", #selector(sortNewest), "")
        add(view, "Sort Oldest First", #selector(sortOldest), "")
        view.addItem(.separator())
        add(view, "Previous Scan", #selector(prev), arrowL, [])
        add(view, "Next Scan", #selector(next), arrowR, [])
        view.addItem(.separator())
        add(view, "Invert", #selector(toggleInvert), "i", [])
        add(view, "Reset Window/Level", #selector(resetWindowAction), "r", [])
        add(view, "Auto Window/Level", #selector(autoWindow), "a", [])
        add(view, "Show Patient Info", #selector(togglePatient), "i", .command)
        add(view, "Show All Metadata…", #selector(showMetadataAction), "i", [.command, .option])
        view.addItem(.separator())
        add(view, "Zoom In", #selector(zoomIn), "+")
        add(view, "Zoom Out", #selector(zoomOut), "-")
        add(view, "Fit to Window", #selector(fitAction), "0")
        add(view, "Actual Size", #selector(actualAction), "1")
        view.addItem(.separator())
        add(view, "Arrange Scans Side by Side", #selector(arrangeAction), "l")
        add(view, "Blend Overlapping Scans", #selector(toggleBlend), "b", [])
        NSApp.mainMenu = main
    }

    func validateMenuItem(_ m: NSMenuItem) -> Bool {
        switch m.action {
        case #selector(toggleInvert): m.state = userInvert ? .on : .off
        case #selector(togglePatient): m.state = showPatient ? .on : .off
        case #selector(toggleBlend): m.state = canvas.blend ? .on : .off; return canvas.compare
        case #selector(arrangeAction): return canvas.compare
        case #selector(sortNewest): m.state = sortAscending ? .off : .on
        case #selector(sortOldest): m.state = sortAscending ? .on : .off
        default: break
        }
        return true
    }

    @objc func collapseAllAction() { sidebar.collapseAll() }
    @objc func expandAllAction() { sidebar.expandAll() }

    @objc func openSettings() {
        if prefs == nil {
            let p = PreferencesWindow()
            p.onRestoreChanged = { [weak self] _ in self?.sidebar.persistExpandedState() }
            prefs = p
        }
        prefs?.show()
    }

    // Metadata viewer: right-click a scan, the info button on a single scan, or View menu.
    @objc func showMetadataAction() { showMetadata() }
    func showMetadata(path: String? = nil) {
        let target = path ?? canvas.active?.path ?? (canvas.tiles.count == 1 ? canvas.tiles[0].path : nil) ?? sidebar.selectedPaths.first
        guard let target else { NSSound.beep(); return }
        if let open = metaWindows.first(where: { $0.window.title.hasSuffix((target as NSString).lastPathComponent) }) { open.show(); return }
        do {
            let url = URL(fileURLWithPath: target)
            let w = MetadataWindow(url: url, rows: try Loader.dump(url))
            w.onClose = { [weak self] w in self?.metaWindows.removeAll { $0 === w } }
            metaWindows.append(w); w.show()
        } catch { alert("Cannot read metadata", "\(error)") }
    }

    @objc func prev() { sidebar.selectAdjacent(-1) }
    @objc func next() { sidebar.selectAdjacent(1) }
    @objc func sortNewest() { setSort(false) }
    @objc func sortOldest() { setSort(true) }
    func setSort(_ asc: Bool) {
        sortAscending = asc
        UserDefaults.standard.set(asc, forKey: "sortAscending")
        sidebar.setSort(ascending: asc)
    }
    @objc func toggleInvert() { userInvert.toggle(); canvas.tiles.forEach(refreshTile) }
    @objc func togglePatient() { showPatient.toggle(); canvas.tiles.forEach { $0.label = label(for: $0.path) }; refreshOverlay(); canvas.needsDisplay = true }
    @objc func toggleBlend() { canvas.blend.toggle() }
    @objc func arrangeAction() { canvas.arrangeAndFit() }
    @objc func fitAction() { canvas.fit() }
    @objc func actualAction() { canvas.actualSize() }
    @objc func zoomIn() { canvas.zoomCentered(1.25) }
    @objc func zoomOut() { canvas.zoomCentered(0.8) }

    var windowTargets: [Tile] { canvas.active.map { [$0] } ?? canvas.tiles }
    @objc func resetWindowAction() { windowTargets.forEach { $0.wl = defaultWL($0.image); refreshTile($0) }; refreshOverlay() }
    @objc func autoWindow() { windowTargets.forEach { $0.wl = autoWL($0.image); refreshTile($0) }; refreshOverlay() }

    // MARK: Library <-> sidebar

    func syncLibrary(select paths: [String]? = nil) {
        sidebar.reload(entries: Array(library.entries.values), keepSelection: paths)
        let sel = sidebar.selectedPaths
        if sel != currentPaths { selectionChanged(sel) }
    }

    @objc func openPanel() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.message = "Choose DICOM files or a folder containing them"
        p.beginSheetModal(for: window) { [weak self] r in if r == .OK { self?.open(p.urls) } }
    }

    func open(_ inputs: [URL]) {
        let files = Loader.collect(inputs)
        guard !files.isEmpty else { alert("No DICOM files found", "Nothing in the selection looked like a DICOM file."); return }
        canvas.message = "Reading \(files.count) file\(files.count == 1 ? "" : "s")…"
        library.add(files) { [weak self] paths in
            guard let self else { return }
            guard let first = paths.first else {
                self.canvas.message = self.emptyMessage
                self.alert("No readable images", "None of the \(files.count) file(s) contained a DICOM image this app can read.")
                return
            }
            if paths.count < files.count { NSLog("%d of %d files skipped (not readable DICOM images)", files.count - paths.count, files.count) }
            self.syncLibrary(select: [first])
            self.selectionChanged(self.sidebar.selectedPaths)
        }
    }

    // MARK: Showing scans

    func selectionChanged(_ paths: [String]) {
        guard paths != currentPaths else { return }
        currentPaths = paths
        generation += 1
        let gen = generation
        guard !paths.isEmpty else {
            canvas.tiles = []; canvas.active = nil; canvas.overlay = []; canvas.message = emptyMessage
            window.title = "X-ray Viewer"; return
        }
        // Compare view lines scans up by date (direction follows the sidebar sort), whatever the patient grouping.
        let ordered = paths.enumerated().sorted { a, b in
            let ka = library.entries[a.element]?.sortKey, kb = library.entries[b.element]?.sortKey
            switch (ka, kb) {
            case let (x?, y?): return x == y ? a.offset < b.offset : (sortAscending ? x < y : x > y)
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map { $0.element }
        let use = Array(ordered.prefix(maxCompare))
        truncatedNote = paths.count > maxCompare ? "Showing the first \(maxCompare) of \(paths.count) selected scans" : nil
        canvas.message = "Loading…"
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [(String, DicomImage?, String?)] = []
            for p in use {
                do { results.append((p, try Loader.load(URL(fileURLWithPath: p)), nil)) }
                catch { results.append((p, nil, "\((p as NSString).lastPathComponent): \(error)")) }
            }
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.display(results)
            }
        }
    }

    func display(_ results: [(String, DicomImage?, String?)]) {
        var tiles: [Tile] = [], errors: [String] = []
        for (i, r) in results.enumerated() {
            guard let im = r.1 else { errors.append(r.2 ?? "unreadable file"); continue }
            let t = Tile(path: r.0, image: im, wl: defaultWL(im), order: i)
            t.cg = render(im, wl: t.wl, invert: im.mono1 != userInvert)
            t.label = label(for: r.0)
            tiles.append(t)
        }
        canvas.tiles = tiles
        canvas.active = tiles.count == 1 ? tiles[0] : nil
        canvas.arrange()
        canvas.message = tiles.isEmpty ? errors.joined(separator: "\n") : nil
        canvas.fit()
        library.touch(tiles.map { $0.path })
        window.title = tiles.count == 1 ? (tiles[0].path as NSString).lastPathComponent : "\(tiles.count) scans"
        if tiles.count == 1, let e = library.entries[tiles[0].path] {
            if !e.name.isEmpty { window.title = e.name }
            if !e.patient.isEmpty { window.title += "  —  \(e.patient)" }
        }
        self.errorNote = errors.isEmpty ? nil : "\(errors.count) scan(s) could not be read"
        refreshOverlay()
    }
    var errorNote: String?

    func label(for path: String) -> String {
        let e = library.entries[path]
        var parts: [String] = []
        if let e, !e.name.isEmpty { parts.append(e.name) }
        if let e, e.sortKey != nil { parts.append(e.prettyDate) }
        if showPatient, let e, !e.patient.isEmpty { parts.append(e.patient) }
        if parts.isEmpty { parts.append((path as NSString).lastPathComponent) }
        return parts.joined(separator: " · ")
    }

    func refreshTile(_ t: Tile) {
        t.cg = render(t.image, wl: t.wl, invert: t.image.mono1 != userInvert)
        canvas.needsDisplay = true
    }

    func refreshOverlay() {
        var lines: [String] = []
        let t = canvas.active ?? (canvas.tiles.count == 1 ? canvas.tiles[0] : nil)
        if let t {
            if showPatient, let e = library.entries[t.path] {
                lines += [e.patient, [e.modality, e.prettyDate].filter { !$0.isEmpty }.joined(separator: "  ")].filter { !$0.isEmpty }
            }
            lines.append("\(t.image.cols) × \(t.image.rows)")
            if t.image.samples == 1 { lines.append(String(format: "W %.0f  L %.0f", t.wl.w, t.wl.c)) }
        } else if canvas.compare {
            lines.append("\(canvas.tiles.count) scans · drag a scan to move it · ⇧-drag adjusts contrast · scroll or pinch zooms all")
        }
        if let n = truncatedNote { lines.append(n) }
        if let n = errorNote { lines.append(n) }
        canvas.overlay = lines
    }

    // MARK: Export, history

    @objc func exportCurrent() {
        guard !canvas.tiles.isEmpty else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        var data: Data?
        if canvas.compare { data = canvas.snapshotPNG(); p.nameFieldStringValue = "comparison.png" }
        else if let t = canvas.tiles.first, let cg = t.cg {
            p.nameFieldStringValue = ((t.path as NSString).lastPathComponent as NSString).deletingPathExtension + ".png"
            let rep = NSBitmapImageRep(cgImage: cg); data = rep.representation(using: .png, properties: [:])
        }
        guard let data else { return }
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let u = p.url else { return }
            do { try data.write(to: u) } catch { self?.alert("Export failed", "\(error)") }
        }
    }

    @objc func exportAll() {
        var paths = Array(library.entries.keys)
        if let first = currentPaths.first, let e = library.entries[first] {
            paths = library.entries.values.filter { $0.patientKey == e.patientKey }.map { $0.path }
        }
        guard !paths.isEmpty else { return }
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.prompt = "Export Here"; p.message = "Choose a folder for the PNG files"
        let files = paths.map { URL(fileURLWithPath: $0) }, inv = userInvert
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let dir = p.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let (ok, fails) = convertAll(files, to: dir, invert: inv)
                DispatchQueue.main.async {
                    self?.alert("Exported \(ok) of \(files.count) image\(files.count == 1 ? "" : "s")",
                                fails.isEmpty ? dir.path : fails.prefix(8).joined(separator: "\n"))
                }
            }
        }
    }

    @objc func clearHistory() {
        let a = NSAlert()
        a.messageText = "Clear the scan history?"
        a.informativeText = "This only removes the list of scans and patient names stored by this app. Your DICOM files are not touched."
        a.addButton(withTitle: "Clear History"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            self.library.clear(); self.syncLibrary()
        }
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        a.beginSheetModal(for: window)
    }
}

// MARK: - Entry point

// Headless mode: XrayViewer --convert <file-or-folder>... <output-folder> [--invert]
let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--convert" {
    var rest = Array(args.dropFirst())
    let inv = rest.contains("--invert"); rest.removeAll { $0 == "--invert" }
    guard rest.count >= 2 else { print("usage: --convert <file-or-folder>... <output-folder> [--invert]"); exit(2) }
    let out = URL(fileURLWithPath: rest.removeLast())
    let (ok, fails) = convertAll(rest.map { URL(fileURLWithPath: $0) }, to: out, invert: inv)
    print("converted \(ok) file(s) → \(out.path)")
    fails.forEach { print("FAILED \($0)") }
    exit(fails.isEmpty && ok > 0 ? 0 : 1)
}

UserDefaults.standard.register(defaults: [SidebarViewController.restoreKey: true])   // "reopen tree as I left it": on by default
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
