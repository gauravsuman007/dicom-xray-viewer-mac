// The image canvas: one scan, or several scans on a shared, zoomable "light table".

import Cocoa

final class Tile {
    let path: String
    var image: DicomImage
    var wl: WL
    var cg: CGImage?
    var origin = CGPoint.zero       // world position (image pixels) of the bottom-left corner
    var label = ""
    let order: Int                  // left-to-right order used by "arrange"
    var size: CGSize { CGSize(width: image.cols, height: image.rows) }
    init(path: String, image: DicomImage, wl: WL, order: Int) {
        self.path = path; self.image = image; self.wl = wl; self.order = order
    }
}

final class Canvas: NSView {
    var tiles: [Tile] = [] { didSet { updateControls(); needsDisplay = true } }
    var active: Tile? { didSet { needsDisplay = true } }
    var overlay: [String] = [] { didSet { needsDisplay = true } }
    var message: String? { didSet { needsDisplay = true } }
    var blend = false { didSet { blendButton.state = blend ? .on : .off; needsDisplay = true } }
    var gapFraction: CGFloat = 0.06

    /// View transform shared by every tile: screen = off + world * k  (k = screen points per image pixel).
    private(set) var k: CGFloat = 1
    private(set) var off = CGPoint.zero
    private var fitted = true

    var onTileWindowDrag: ((Tile, CGFloat, CGFloat) -> Void)?
    var onTileReset: ((Tile) -> Void)?
    var onActiveChange: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    var compare: Bool { tiles.count > 1 }
    private let bottomInset: CGFloat = 54

    // Controls
    private let bar = NSVisualEffectView()
    private let zoomSlider = NSSlider(value: 0, minValue: -5.6, maxValue: 6, target: nil, action: nil)
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let gapSlider = NSSlider(value: 6, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let blendButton = NSButton(checkboxWithTitle: "Blend", target: nil, action: nil)
    private var compareControls: [NSView] = []

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        buildControls()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Geometry

    func worldBounds() -> CGRect {
        tiles.reduce(CGRect.null) { $0.union(CGRect(origin: $1.origin, size: $1.size)) }
    }
    func screenRect(_ t: Tile) -> NSRect {
        NSRect(x: off.x + t.origin.x * k, y: off.y + t.origin.y * k, width: t.size.width * k, height: t.size.height * k)
    }
    func tile(at p: NSPoint) -> Tile? { tiles.last { screenRect($0).contains(p) } }
    private var viewportCenter: NSPoint { NSPoint(x: bounds.midX, y: (bounds.height + bottomInset) / 2) }

    func fit() {
        let r = worldBounds(), areaH = bounds.height - bottomInset
        guard !r.isNull, r.width > 0, r.height > 0, bounds.width > 0, areaH > 0 else { return }
        k = min(bounds.width * 0.96 / r.width, areaH * 0.96 / r.height)
        off = CGPoint(x: bounds.midX - r.midX * k, y: bottomInset + areaH / 2 - r.midY * k)
        fitted = true
        syncControls(); needsDisplay = true
    }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        if fitted { fit() }
    }

    func zoom(by f: CGFloat, about p: NSPoint) { setK(k * f, about: p) }
    func zoomCentered(_ f: CGFloat) { zoom(by: f, about: viewportCenter) }
    func actualSize() { setK(1, about: viewportCenter) }
    func setK(_ newK: CGFloat, about p: NSPoint) {
        let nk = min(max(newK, 0.02), 64), f = nk / k
        off = CGPoint(x: p.x - (p.x - off.x) * f, y: p.y - (p.y - off.y) * f)
        k = nk; fitted = false
        syncControls(); needsDisplay = true
    }

    /// Lay the scans out left-to-right with the current spacing, centred vertically.
    func arrange() {
        let sorted = tiles.sorted { $0.order < $1.order }
        guard !sorted.isEmpty else { return }
        let maxH = sorted.map { $0.size.height }.max()!
        let gap = gapFraction * sorted.map { $0.size.width }.reduce(0, +) / CGFloat(sorted.count)
        var x: CGFloat = 0
        for t in sorted { t.origin = CGPoint(x: x, y: (maxH - t.size.height) / 2); x += t.size.width + gap }
    }
    func arrangeAndFit() { arrange(); fit() }

    private func arrangeKeepingView() {
        let before = worldBounds()
        let centre = CGPoint(x: off.x + before.midX * k, y: off.y + before.midY * k)
        arrange()
        if fitted { fit() } else {
            let after = worldBounds()
            off = CGPoint(x: centre.x - after.midX * k, y: centre.y - after.midY * k)
            needsDisplay = true
        }
    }

    // MARK: Drawing

    override func draw(_ dirty: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        let ctx = NSGraphicsContext.current!.cgContext
        for (i, t) in tiles.enumerated() {
            guard let cg = t.cg else { continue }
            let r = screenRect(t)
            guard r.intersects(dirty) else { continue }
            ctx.saveGState()
            if blend && i > 0 { ctx.setBlendMode(.screen) }
            ctx.interpolationQuality = k >= 2 ? .none : .high
            ctx.draw(cg, in: r)
            ctx.restoreGState()
            if compare {
                (t === active ? NSColor.controlAccentColor : NSColor(white: 1, alpha: 0.28)).setStroke()
                let path = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)); path.lineWidth = t === active ? 2 : 1; path.stroke()
            }
        }
        let shadow = NSShadow(); shadow.shadowColor = .black; shadow.shadowBlurRadius = 2; shadow.shadowOffset = .zero
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(white: 0.88, alpha: 1), .shadow: shadow,
        ]
        if compare {
            for t in tiles where !t.label.isEmpty {
                let r = screenRect(t)
                if r.width > 80 { (t.label as NSString).draw(at: NSPoint(x: r.minX + 6, y: r.maxY - 17), withAttributes: attrs) }
            }
        }
        for (i, line) in overlay.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 10, y: bounds.height - 22 - CGFloat(i) * 15), withAttributes: attrs)
        }
        if let message {
            let big: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(white: 0.7, alpha: 1)]
            let sz = (message as NSString).size(withAttributes: big)
            (message as NSString).draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2), withAttributes: big)
        }
    }

    // MARK: Mouse & gestures

    private enum Drag { case none, move(Tile), pan, level(Tile) }
    private var drag = Drag.none

    private func setActive(_ t: Tile?) {
        guard active !== t else { return }
        active = t; onActiveChange?()
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        let hit = tile(at: p)
        if let hit {
            setActive(hit)
            if compare, let i = tiles.firstIndex(where: { $0 === hit }) { tiles.append(tiles.remove(at: i)) }   // bring to front
        }
        if e.clickCount == 2, let t = hit ?? active { onTileReset?(t); return }
        let panKey = e.modifierFlags.contains(.option) || e.modifierFlags.contains(.control)
        if panKey { drag = .pan }
        else if compare && !e.modifierFlags.contains(.shift) { drag = hit.map { .move($0) } ?? .pan }
        else if let t = hit ?? active ?? tiles.first { setActive(t); drag = .level(t) }
        else { drag = .none }
    }
    override func mouseDragged(with e: NSEvent) {
        switch drag {
        case .move(let t):
            t.origin.x += e.deltaX / k; t.origin.y -= e.deltaY / k; fitted = false; needsDisplay = true
        case .pan:
            off.x += e.deltaX; off.y -= e.deltaY; fitted = false; needsDisplay = true
        case .level(let t): onTileWindowDrag?(t, e.deltaX, e.deltaY)
        case .none: break
        }
    }
    override func mouseUp(with e: NSEvent) { drag = .none }
    override func rightMouseDragged(with e: NSEvent) { off.x += e.deltaX; off.y -= e.deltaY; fitted = false; needsDisplay = true }
    override func otherMouseDragged(with e: NSEvent) { rightMouseDragged(with: e) }

    override func scrollWheel(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if e.modifierFlags.contains(.command) { zoom(by: exp(e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.01 : 0.05)), about: p) }
        else if e.hasPreciseScrollingDeltas { off.x += e.scrollingDeltaX; off.y += e.scrollingDeltaY; fitted = false; needsDisplay = true }
        else { zoom(by: 1 + 0.05 * e.scrollingDeltaY, about: p) }
    }
    override func magnify(with e: NSEvent) { zoom(by: 1 + e.magnification, about: convert(e.locationInWindow, from: nil)) }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls); return true
    }

    // MARK: Controls

    private func button(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded; b.controlSize = .small
        return b
    }
    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor; return l
    }
    private func divider() -> NSView {
        let v = NSBox(); v.boxType = .separator
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return v
    }

    private func buildControls() {
        bar.material = .hudWindow; bar.blendingMode = .withinWindow; bar.state = .active
        bar.wantsLayer = true; bar.layer?.cornerRadius = 10
        bar.translatesAutoresizingMaskIntoConstraints = false

        zoomSlider.target = self; zoomSlider.action = #selector(zoomSliderChanged); zoomSlider.controlSize = .small
        zoomSlider.widthAnchor.constraint(equalToConstant: 130).isActive = true
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.alignment = .right
        zoomLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        gapSlider.target = self; gapSlider.action = #selector(gapChanged); gapSlider.controlSize = .small
        gapSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        blendButton.target = self; blendButton.action = #selector(blendToggled); blendButton.controlSize = .small
        blendButton.toolTip = "Blend overlapping scans (screen blend) so both stay visible"

        let out = button("−", #selector(zoomOutTapped)), inn = button("+", #selector(zoomInTapped))
        let fitB = button("Fit", #selector(fitTapped)), one = button("1:1", #selector(actualTapped))
        out.toolTip = "Zoom out all scans"; inn.toolTip = "Zoom in on all scans"
        let arrangeB = button("Arrange", #selector(arrangeTapped)); arrangeB.toolTip = "Line the scans up side by side again"
        let gapLabel = label("Spacing")
        compareControls = [divider(), gapLabel, gapSlider, blendButton, arrangeB]

        let stack = NSStackView(views: [out, zoomSlider, inn, zoomLabel, fitB, one] + compareControls)
        stack.orientation = .horizontal; stack.spacing = 8; stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        addSubview(bar)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor), stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.centerXAnchor.constraint(equalTo: centerXAnchor), bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        updateControls()
    }

    private func updateControls() {
        for v in compareControls { v.isHidden = !compare }
        bar.isHidden = tiles.isEmpty
    }
    private func syncControls() {
        zoomSlider.doubleValue = log2(Double(k))
        zoomLabel.stringValue = "\(Int((k * 100).rounded()))%"
    }

    @objc private func zoomSliderChanged() { setK(CGFloat(pow(2, zoomSlider.doubleValue)), about: viewportCenter) }
    @objc private func zoomInTapped() { zoomCentered(1.25) }
    @objc private func zoomOutTapped() { zoomCentered(0.8) }
    @objc private func fitTapped() { fit() }
    @objc private func actualTapped() { actualSize() }
    @objc private func arrangeTapped() { arrangeAndFit() }
    @objc private func gapChanged() { gapFraction = CGFloat(gapSlider.doubleValue) / 100; arrangeKeepingView() }
    @objc private func blendToggled() { blend = blendButton.state == .on }

    /// PNG of exactly what is on screen (without the control bar).
    func snapshotPNG() -> Data? {
        bar.isHidden = true; defer { updateControls() }
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
