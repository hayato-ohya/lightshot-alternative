import AppKit

@MainActor
protocol OverlayViewDelegate: AnyObject {
    func overlayViewDidBeginSelection(_ view: OverlayView)
    func overlayView(_ view: OverlayView, copy image: CGImage)
    func overlayView(_ view: OverlayView, save image: CGImage)
    func overlayViewDidRequestCancel(_ view: OverlayView)
    func overlayView(_ view: OverlayView, startRecording rect: CGRect)
}

/// Full-screen selection + annotation layer. Coordinates are flipped (origin top-left) points.
final class OverlayView: NSView, NSTextFieldDelegate {
    enum Mode { case screenshot, recording }

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var affectsLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
        var affectsRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
        var affectsTop: Bool { [.topLeft, .top, .topRight].contains(self) }
        var affectsBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }

        func center(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: r.minX, y: r.minY)
            case .top: return CGPoint(x: r.midX, y: r.minY)
            case .topRight: return CGPoint(x: r.maxX, y: r.minY)
            case .right: return CGPoint(x: r.maxX, y: r.midY)
            case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
            case .bottom: return CGPoint(x: r.midX, y: r.maxY)
            case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
            case .left: return CGPoint(x: r.minX, y: r.midY)
            }
        }
    }

    private enum Drag {
        case none
        case creating(CGPoint)
        case moving(CGPoint)          // offset of selection origin from mouse
        case resizing(Handle, CGRect) // original rect
        case drawing(Annotation)
        case movingAnnotation(Annotation, CGPoint)   // last mouse point
        case editingHandle(Annotation, Int)
    }

    let screenshot: CGImage
    let scale: CGFloat
    let mode: Mode
    private let windowFrames: [CGRect] // local flipped coords
    weak var delegate: OverlayViewDelegate?

    var selection: CGRect? { didSet { sizeLabel.isHidden = selection == nil } }
    var annotations: [Annotation] = []
    private var tool: Tool?
    private var color: NSColor = .systemRed
    private var lineWidth: CGFloat = 3
    private var textSize: CGFloat = 22
    private var hoveredWindow: CGRect?
    private var drag: Drag = .none
    private var textField: NSTextField?
    private var textCommitted = false
    private var editingTextAnnotation: Annotation?   // text being re-edited (removed from `annotations` meanwhile)
    private var textEntryFontSize: CGFloat = 22
    private(set) var selectedAnnotation: Annotation?
    private var undoStack: [[Annotation]] = []

    private let toolsBar = PaletteView(orientation: .vertical)
    private let actionsBar = PaletteView(orientation: .horizontal)
    private let sizeLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "Drag to select an area  ·  Click a window  ·  Esc to cancel")
    private var toolButtons: [Tool: NSButton] = [:]
    private var colorButton: NSButton?
    private var colorPopover: NSPopover?

    static let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .white, .black,
    ]

    init(frame: CGRect, screenshot: CGImage, scale: CGFloat, windowFrames: [CGRect], mode: Mode = .screenshot) {
        self.screenshot = screenshot
        self.scale = scale
        self.mode = mode
        self.windowFrames = windowFrames
        super.init(frame: frame)
        wantsLayer = true
        buildChrome()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Chrome

    private func buildChrome() {
        if mode == .recording {
            hintLabel.stringValue = "Drag to select the area to record  ·  Click a window  ·  ↩ to start  ·  Esc to cancel"
            actionsBar.addButton(symbol: "record.circle", tooltip: "Start recording (↩)", target: self, action: #selector(recordAction(_:)))
                .contentTintColor = .systemRed
            actionsBar.addButton(symbol: "xmark", tooltip: "Cancel (Esc)", target: self, action: #selector(cancelAction(_:)))
            actionsBar.fit()
            actionsBar.isHidden = true
            addSubview(actionsBar)
            toolsBar.isHidden = true
            for label in [sizeLabel, hintLabel] {
                label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                label.textColor = .white
                label.wantsLayer = true
                label.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
                label.layer?.cornerRadius = 4
                label.alignment = .center
                addSubview(label)
            }
            hintLabel.font = .systemFont(ofSize: 13, weight: .medium)
            sizeLabel.isHidden = true
            layoutHint()
            return
        }
        for t in Tool.allCases {
            let b = toolsBar.addButton(symbol: t.symbolName, tooltip: t.title, target: self, action: #selector(toolButtonClicked(_:)))
            b.tag = Tool.allCases.firstIndex(of: t)!
            toolButtons[t] = b
        }
        let colorButton = NSButton(image: swatchImage(color: color), target: self, action: #selector(colorButtonClicked(_:)))
        toolsBar.configure(colorButton, tooltip: "Color & line width")
        toolsBar.addView(colorButton)
        self.colorButton = colorButton
        toolsBar.addButton(symbol: "arrow.uturn.backward", tooltip: "Undo (⌘Z)", target: self, action: #selector(undo(_:)))
        toolsBar.fit()
        toolsBar.isHidden = true
        addSubview(toolsBar)

        actionsBar.addButton(symbol: "doc.on.doc", tooltip: "Copy to clipboard (⌘C / ↩)", target: self, action: #selector(copyAction(_:)))
        actionsBar.addButton(symbol: "square.and.arrow.down", tooltip: "Save… (⌘S)", target: self, action: #selector(saveAction(_:)))
        actionsBar.addButton(symbol: "xmark", tooltip: "Cancel (Esc)", target: self, action: #selector(cancelAction(_:)))
        actionsBar.fit()
        actionsBar.isHidden = true
        addSubview(actionsBar)

        for label in [sizeLabel, hintLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .white
            label.wantsLayer = true
            label.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
            label.layer?.cornerRadius = 4
            label.alignment = .center
            addSubview(label)
        }
        hintLabel.font = .systemFont(ofSize: 13, weight: .medium)
        sizeLabel.isHidden = true
        layoutHint()
    }

    private func layoutHint() {
        hintLabel.sizeToFit()
        var f = hintLabel.frame
        f.size.width += 20
        f.size.height += 8
        f.origin = CGPoint(x: (bounds.width - f.width) / 2, y: 60)
        hintLabel.frame = f
    }

    override func layout() {
        super.layout()
        layoutHint()
    }

    private func layoutChrome() {
        guard let sel = selection else {
            toolsBar.isHidden = true
            actionsBar.isHidden = true
            return
        }
        let idle: Bool
        if case .none = drag { idle = true } else { idle = false }
        toolsBar.isHidden = !idle || mode == .recording
        actionsBar.isHidden = !idle
        hintLabel.isHidden = true

        let gap: CGFloat = 6
        // Tools: right of the selection, else left, else inside.
        var tx = sel.maxX + gap
        if tx + toolsBar.frame.width > bounds.maxX {
            tx = sel.minX - gap - toolsBar.frame.width
            if tx < 0 { tx = max(0, sel.maxX - gap - toolsBar.frame.width) }
        }
        var ty = sel.minY
        ty = min(ty, bounds.maxY - toolsBar.frame.height)
        ty = max(0, ty)
        toolsBar.setFrameOrigin(CGPoint(x: tx, y: ty))

        // Actions: below the selection, else above, else inside.
        var ay = sel.maxY + gap
        if ay + actionsBar.frame.height > bounds.maxY {
            ay = sel.minY - gap - actionsBar.frame.height
            if ay < 0 { ay = max(0, sel.maxY - gap - actionsBar.frame.height) }
        }
        var ax = sel.maxX - actionsBar.frame.width
        ax = max(0, min(ax, bounds.maxX - actionsBar.frame.width))
        actionsBar.setFrameOrigin(CGPoint(x: ax, y: ay))

        // Size label: above-left of the selection.
        let px = Int((sel.width * scale).rounded()), py = Int((sel.height * scale).rounded())
        sizeLabel.stringValue = "\(px) × \(py)"
        sizeLabel.sizeToFit()
        var lf = sizeLabel.frame
        lf.size.width += 10
        lf.size.height += 4
        var ly = sel.minY - lf.height - 4
        if ly < 0 { ly = sel.minY + 4 }
        lf.origin = CGPoint(x: max(0, min(sel.minX, bounds.maxX - lf.width)), y: ly)
        sizeLabel.frame = lf
    }

    private func refreshToolButtons() {
        for (t, b) in toolButtons { PaletteView.setActive(b, t == tool) }
        colorButton?.image = swatchImage(color: color)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Annotations (only inside the selection).
        if let sel = selection {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: sel).addClip()
            for a in annotations { a.draw() }
            if case .drawing(let a) = drag { a.draw() }
            NSGraphicsContext.restoreGraphicsState()
            if let a = selectedAnnotation { drawAnnotationHandles(a) }
        }

        // Dim everything outside the selection.
        let dim = NSBezierPath(rect: bounds)
        if let sel = selection { dim.appendRect(sel) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()

        // Window hover highlight.
        if selection == nil, case .none = drag, let hw = hoveredWindow {
            NSColor.white.withAlphaComponent(0.12).setFill()
            hw.fill()
            let p = NSBezierPath(rect: hw.insetBy(dx: 1, dy: 1))
            p.lineWidth = 2
            NSColor.white.withAlphaComponent(0.9).setStroke()
            p.stroke()
        }

        guard let sel = selection else { return }
        // Selection border.
        let border = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.white.setStroke()
        border.stroke()
        let dashed = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
        dashed.lineWidth = 1
        dashed.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.black.withAlphaComponent(0.6).setStroke()
        dashed.stroke()

        // Handles.
        if case .none = drag {
            for h in Handle.allCases {
                let c = h.center(in: sel)
                let r = CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)
                NSColor.white.setFill()
                r.fill()
                let p = NSBezierPath(rect: r)
                NSColor.black.withAlphaComponent(0.7).setStroke()
                p.lineWidth = 1
                p.stroke()
            }
        }
    }

    private func drawAnnotationHandles(_ a: Annotation) {
        let handles = a.handlePoints
        if handles.isEmpty {
            let box = NSBezierPath(rect: a.bounds.insetBy(dx: -3, dy: -3))
            box.lineWidth = 1
            box.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.white.setStroke()
            box.stroke()
            let shadow = NSBezierPath(rect: a.bounds.insetBy(dx: -3, dy: -3))
            shadow.lineWidth = 1
            shadow.setLineDash([4, 3], count: 2, phase: 4)
            NSColor.black.withAlphaComponent(0.6).setStroke()
            shadow.stroke()
            return
        }
        for p in handles {
            let r = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            let path = NSBezierPath(ovalIn: r)
            NSColor.white.setFill()
            path.fill()
            path.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    private func annotationHandle(at p: CGPoint) -> (Annotation, Int)? {
        guard let a = selectedAnnotation else { return nil }
        for (i, h) in a.handlePoints.enumerated() where hypot(h.x - p.x, h.y - p.y) <= 8 { return (a, i) }
        return nil
    }

    private func annotation(at p: CGPoint) -> Annotation? {
        annotations.last { $0.hitTest(p) }
    }

    private func pushUndo() {
        undoStack.append(annotations.map { $0.copy() })
        if undoStack.count > 100 { undoStack.removeFirst() }
    }

    private func select(_ a: Annotation?) {
        selectedAnnotation = a
        if let a {
            // Reflect the selected annotation's style in the palette.
            color = a.color
            if a.tool == .text { textSize = a.fontSize } else if a.tool != .marker { lineWidth = a.lineWidth } else { lineWidth = a.lineWidth }
            refreshToolButtons()
        }
        needsDisplay = true
    }

    // MARK: - Geometry helpers

    private func snapped(_ r: CGRect) -> CGRect {
        var s = r.standardized
        s.origin.x = s.origin.x.rounded()
        s.origin.y = s.origin.y.rounded()
        s.size.width = s.size.width.rounded()
        s.size.height = s.size.height.rounded()
        return s.intersection(bounds)
    }

    private func handle(at p: CGPoint) -> Handle? {
        guard let sel = selection else { return nil }
        for h in Handle.allCases {
            let c = h.center(in: sel)
            if abs(c.x - p.x) <= 6 && abs(c.y - p.y) <= 6 { return h }
        }
        return nil
    }

    private func windowFrame(at p: CGPoint) -> CGRect? {
        windowFrames.first { $0.contains(p) }?.intersection(bounds)
    }

    private func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at p: CGPoint) {
        if let sel = selection, case .none = drag {
            if let h = handle(at: p) {
                    let pos: NSCursor.FrameResizePosition = {
                        switch h {
                        case .topLeft: return .topLeft
                        case .top: return .top
                        case .topRight: return .topRight
                        case .right: return .right
                        case .bottomRight: return .bottomRight
                        case .bottom: return .bottom
                        case .bottomLeft: return .bottomLeft
                        case .left: return .left
                        }
                    }()
                    NSCursor.frameResize(position: pos, directions: [.inward, .outward]).set()
                return
            }
            if annotationHandle(at: p) != nil {
                NSCursor.crosshair.set()
                return
            }
            if sel.contains(p), annotation(at: p) != nil {
                NSCursor.openHand.set()
                return
            }
            if tool == nil, sel.contains(p) {
                NSCursor.openHand.set()
                return
            }
            if tool == .text, sel.contains(p) {
                NSCursor.iBeam.set()
                return
            }
        }
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if selection == nil {
            let hw = windowFrame(at: p)
            if hw != hoveredWindow {
                hoveredWindow = hw
                needsDisplay = true
            }
        }
        updateCursor(at: p)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if window?.isKeyWindow == false {
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(self)
        }
        let p = convert(event.locationInWindow, from: nil)
        if textField != nil {
            // Clicking inside the active text field is handled by the field itself.
            if let tf = textField, tf.frame.contains(p) { super.mouseDown(with: event); return }
            commitText()
        }

        if let sel = selection {
            if let (a, index) = annotationHandle(at: p) {
                pushUndo()
                drag = .editingHandle(a, index)
            } else if sel.contains(p), let hit = annotation(at: p) {
                if event.clickCount == 2, case .text = hit.shape {
                    beginTextReedit(hit)
                    return
                }
                select(hit)
                pushUndo()
                drag = .movingAnnotation(hit, p)
                NSCursor.closedHand.set()
            } else if let h = handle(at: p) {
                select(nil)
                drag = .resizing(h, sel)
            } else if let tool, sel.contains(p) {
                select(nil)
                switch tool {
                case .text:
                    beginTextEntry(at: p)
                    return
                case .pen, .marker:
                    drag = .drawing(Annotation(shape: .path([p]), tool: tool, color: color, lineWidth: lineWidth))
                case .line:
                    drag = .drawing(Annotation(shape: .line(p, p), tool: tool, color: color, lineWidth: lineWidth))
                case .arrow:
                    drag = .drawing(Annotation(shape: .arrow(p, p), tool: tool, color: color, lineWidth: lineWidth))
                case .rect:
                    drag = .drawing(Annotation(shape: .rect(CGRect(origin: p, size: .zero)), tool: tool, color: color, lineWidth: lineWidth))
                }
            } else if sel.contains(p) {
                select(nil)
                drag = .moving(CGPoint(x: sel.minX - p.x, y: sel.minY - p.y))
                NSCursor.closedHand.set()
            } else {
                startNewSelection(at: p)
            }
        } else {
            startNewSelection(at: p)
        }
        layoutChrome()
        needsDisplay = true
    }

    private func startNewSelection(at p: CGPoint) {
        delegate?.overlayViewDidBeginSelection(self)
        annotations.removeAll()
        undoStack.removeAll()
        selectedAnnotation = nil
        tool = nil
        refreshToolButtons()
        selection = nil
        drag = .creating(p)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clamp(convert(event.locationInWindow, from: nil), to: bounds)
        switch drag {
        case .none:
            return
        case .creating(let start):
            selection = snapped(CGRect(x: start.x, y: start.y, width: p.x - start.x, height: p.y - start.y))
        case .moving(let offset):
            guard let sel = selection else { return }
            var o = CGPoint(x: p.x + offset.x, y: p.y + offset.y)
            o.x = min(max(0, o.x), bounds.width - sel.width)
            o.y = min(max(0, o.y), bounds.height - sel.height)
            selection = snapped(CGRect(origin: o, size: sel.size))
        case .resizing(let h, let orig):
            var minX = orig.minX, maxX = orig.maxX, minY = orig.minY, maxY = orig.maxY
            if h.affectsLeft { minX = p.x }
            if h.affectsRight { maxX = p.x }
            if h.affectsTop { minY = p.y }
            if h.affectsBottom { maxY = p.y }
            selection = snapped(CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY)))
        case .drawing(let a):
            switch a.shape {
            case .path(var pts):
                if let last = pts.last, hypot(p.x - last.x, p.y - last.y) < 1.5 { return }
                pts.append(p)
                a.shape = .path(pts)
            case .line(let s, _):
                a.shape = .line(s, p)
            case .arrow(let s, _):
                a.shape = .arrow(s, p)
            case .rect(let r):
                a.shape = .rect(CGRect(x: r.minX, y: r.minY, width: p.x - r.minX, height: p.y - r.minY))
            case .text:
                break
            }
        case .movingAnnotation(let a, let last):
            a.move(by: CGPoint(x: p.x - last.x, y: p.y - last.y))
            drag = .movingAnnotation(a, p)
        case .editingHandle(let a, let index):
            a.setHandle(index, to: p)
        }
        layoutChrome()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            break
        case .creating(let start):
            if hypot(p.x - start.x, p.y - start.y) < 3 {
                selection = windowFrame(at: p).map(snapped)
            } else if let sel = selection, sel.width < 2 || sel.height < 2 {
                selection = nil
            }
            hoveredWindow = nil
        case .moving, .resizing:
            break
        case .drawing(let a):
            if case .rect(let r) = a.shape { a.shape = .rect(r.standardized) }
            if !a.isDegenerate {
                pushUndo()
                annotations.append(a)
                selectedAnnotation = a
            }
        case .movingAnnotation, .editingHandle:
            if let a = selectedAnnotation, a.isDegenerate {
                annotations.removeAll { $0 === a }
                selectedAnnotation = nil
            }
        }
        drag = .none
        if let sel = selection, sel.width < 1 || sel.height < 1 { selection = nil }
        layoutChrome()
        updateCursor(at: p)
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.keyCode {
        case 53: // Esc
            if selectedAnnotation != nil { select(nil) } else { delegate?.overlayViewDidRequestCancel(self) }
        case 51, 117: // Delete / Forward delete
            deleteSelectedAnnotation()
        case 36, 76: // Return / Enter
            if mode == .recording { recordAction(nil) } else { copyAction(nil) }
        case 123, 124, 125, 126: // arrows
            nudge(keyCode: event.keyCode, resize: flags.contains(.shift))
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == [.command], let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch chars {
        case "c" where mode == .screenshot: copyAction(nil); return true
        case "s" where mode == .screenshot: saveAction(nil); return true
        case "z" where mode == .screenshot: undo(nil); return true
        case "a": selectAll(nil); return true
        case "q", "w": delegate?.overlayViewDidRequestCancel(self); return true
        default: return false
        }
    }

    override func selectAll(_ sender: Any?) {
        delegate?.overlayViewDidBeginSelection(self)
        selection = bounds
        layoutChrome()
        needsDisplay = true
    }

    private func deleteSelectedAnnotation() {
        guard let a = selectedAnnotation else { return }
        pushUndo()
        annotations.removeAll { $0 === a }
        selectedAnnotation = nil
        needsDisplay = true
    }

    private func nudge(keyCode: UInt16, resize: Bool) {
        let d: CGFloat = 1
        if let a = selectedAnnotation, !resize {
            pushUndo()
            switch keyCode {
            case 123: a.move(by: CGPoint(x: -d, y: 0))
            case 124: a.move(by: CGPoint(x: d, y: 0))
            case 125: a.move(by: CGPoint(x: 0, y: d))
            case 126: a.move(by: CGPoint(x: 0, y: -d))
            default: break
            }
            needsDisplay = true
            return
        }
        guard var sel = selection else { return }
        if resize {
            switch keyCode {
            case 123: sel.size.width -= d
            case 124: sel.size.width += d
            case 125: sel.size.height += d
            case 126: sel.size.height -= d
            default: break
            }
        } else {
            switch keyCode {
            case 123: sel.origin.x -= d
            case 124: sel.origin.x += d
            case 125: sel.origin.y += d
            case 126: sel.origin.y -= d
            default: break
            }
        }
        if sel.width >= 1 && sel.height >= 1 { selection = snapped(sel) }
        layoutChrome()
        needsDisplay = true
    }

    // MARK: - Tool actions

    @objc private func toolButtonClicked(_ sender: NSButton) {
        if textField != nil { commitText() }
        let t = Tool.allCases[sender.tag]
        tool = (tool == t) ? nil : t
        select(nil)
        refreshToolButtons()
    }

    @objc private func colorButtonClicked(_ sender: NSButton) {
        if let pop = colorPopover, pop.isShown {
            pop.close()
            return
        }
        let pop = NSPopover()
        pop.behavior = .transient
        let vc = NSViewController()
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        let colors = NSStackView()
        colors.spacing = 4
        for (i, c) in OverlayView.palette.enumerated() {
            let b = NSButton(image: swatchImage(color: c, size: 24), target: self, action: #selector(paletteColorClicked(_:)))
            b.isBordered = false
            b.tag = i
            colors.addArrangedSubview(b)
        }
        root.addArrangedSubview(colors)

        let widths = NSStackView()
        widths.spacing = 6
        for (i, w) in [2.0, 3.0, 5.0, 8.0].enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(widthClicked(_:)))
            b.image = NSImage(size: NSSize(width: 36, height: 16), flipped: false) { r in
                let p = NSBezierPath()
                p.lineCapStyle = .round
                p.lineWidth = w
                p.move(to: CGPoint(x: 4, y: r.midY))
                p.line(to: CGPoint(x: r.maxX - 4, y: r.midY))
                NSColor.labelColor.setStroke()
                p.stroke()
                return true
            }
            b.imagePosition = .imageOnly
            b.bezelStyle = .texturedRounded
            b.tag = i
            b.state = (w == lineWidth) ? .on : .off
            b.setButtonType(.pushOnPushOff)
            widths.addArrangedSubview(b)
        }
        root.addArrangedSubview(widths)

        let sizes = NSStackView()
        sizes.spacing = 6
        for (i, size) in Annotation.textSizes.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(textSizeClicked(_:)))
            b.attributedTitle = NSAttributedString(string: "A", attributes: [
                .font: NSFont.systemFont(ofSize: 11 + CGFloat(i) * 4, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ])
            b.bezelStyle = .texturedRounded
            b.toolTip = "Text size \(Int(size)) pt"
            b.tag = i
            b.state = (size == textSize) ? .on : .off
            b.setButtonType(.pushOnPushOff)
            b.widthAnchor.constraint(equalToConstant: 40).isActive = true
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            sizes.addArrangedSubview(b)
        }
        func caption(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            return l
        }
        root.insertArrangedSubview(caption("Color"), at: 0)
        root.insertArrangedSubview(caption("Line width"), at: 2)
        root.addArrangedSubview(caption("Text size"))
        root.addArrangedSubview(sizes)
        vc.view = root
        pop.contentViewController = vc
        colorPopover = pop
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minX)
    }

    @objc private func paletteColorClicked(_ sender: NSButton) {
        color = OverlayView.palette[sender.tag]
        if let a = selectedAnnotation { pushUndo(); a.color = color }
        textField?.textColor = color
        refreshToolButtons()
        colorPopover?.close()
        needsDisplay = true
    }

    @objc private func widthClicked(_ sender: NSButton) {
        lineWidth = [2.0, 3.0, 5.0, 8.0][sender.tag]
        if let a = selectedAnnotation, a.tool != .text { pushUndo(); a.lineWidth = lineWidth }
        colorPopover?.close()
        needsDisplay = true
    }

    @objc private func textSizeClicked(_ sender: NSButton) {
        textSize = Annotation.textSizes[sender.tag]
        if let a = selectedAnnotation, a.tool == .text { pushUndo(); a.fontSize = textSize }
        if let tf = textField {
            textEntryFontSize = textSize
            tf.font = Annotation.textFont(size: textSize)
            tf.setFrameSize(NSSize(width: tf.frame.width, height: textSize * 1.5))
        }
        colorPopover?.close()
        needsDisplay = true
    }

    @objc private func undo(_ sender: Any?) {
        if textField != nil { cancelText(); return }
        guard let previous = undoStack.popLast() else { return }
        annotations = previous
        selectedAnnotation = nil
        needsDisplay = true
    }

    @objc private func copyAction(_ sender: Any?) {
        if textField != nil { commitText() }
        guard let image = renderImage() else { return }
        delegate?.overlayView(self, copy: image)
    }

    @objc private func saveAction(_ sender: Any?) {
        if textField != nil { commitText() }
        guard let image = renderImage() else { return }
        delegate?.overlayView(self, save: image)
    }

    @objc private func cancelAction(_ sender: Any?) {
        delegate?.overlayViewDidRequestCancel(self)
    }

    @objc private func recordAction(_ sender: Any?) {
        guard mode == .recording, let sel = selection, sel.width >= 2, sel.height >= 2 else { return }
        delegate?.overlayView(self, startRecording: sel)
    }

    // MARK: - Text entry

    private func beginTextReedit(_ a: Annotation) {
        guard case .text(let string, let origin) = a.shape else { return }
        pushUndo()
        annotations.removeAll { $0 === a }
        selectedAnnotation = nil
        editingTextAnnotation = a
        color = a.color
        textSize = a.fontSize
        refreshToolButtons()
        beginTextEntry(at: CGPoint(x: origin.x, y: origin.y), initialText: string)
        needsDisplay = true
    }

    private func beginTextEntry(at p: CGPoint, initialText: String = "") {
        guard let sel = selection else { return }
        textEntryFontSize = textSize
        let tf = NSTextField(frame: CGRect(x: p.x - 2, y: p.y - 4, width: max(80, sel.maxX - p.x + 2), height: textSize * 1.5))
        tf.stringValue = initialText
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = Annotation.textFont(size: textSize)
        tf.textColor = color
        tf.placeholderAttributedString = NSAttributedString(string: "Text", attributes: [
            .font: Annotation.textFont(size: textSize), .foregroundColor: color.withAlphaComponent(0.5),
        ])
        tf.delegate = self
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        textCommitted = false
        textField = tf
        addSubview(tf)
        window?.makeFirstResponder(tf)
    }

    private func commitText() {
        guard let tf = textField, !textCommitted else { return }
        textCommitted = true
        let string = tf.stringValue
        let origin = CGPoint(x: tf.frame.minX + 2, y: tf.frame.minY + 4)
        tf.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
        let a = Annotation(shape: .text(string, origin), tool: .text, color: color, lineWidth: lineWidth, fontSize: textEntryFontSize)
        editingTextAnnotation = nil
        if !a.isDegenerate {
            annotations.append(a)
            selectedAnnotation = a
        }
        needsDisplay = true
    }

    private func cancelText() {
        guard let tf = textField else { return }
        textCommitted = true
        tf.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
        if let a = editingTextAnnotation {
            annotations.append(a) // restore the original text when re-editing is cancelled
            editingTextAnnotation = nil
            _ = undoStack.popLast()
        }
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            commitText()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelText()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitText()
    }

    // MARK: - Export

    /// Renders the selected region (with annotations) at native pixel resolution.
    func renderImage() -> CGImage? {
        guard let sel = selection else { return nil }
        let px = CGRect(x: (sel.minX * scale).rounded(), y: (sel.minY * scale).rounded(),
                        width: (sel.width * scale).rounded(), height: (sel.height * scale).rounded())
            .intersection(CGRect(x: 0, y: 0, width: screenshot.width, height: screenshot.height))
        guard px.width >= 1, px.height >= 1 else { return nil }
        let w = Int(px.width), h = Int(px.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        if let crop = screenshot.cropping(to: px) {
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        // Switch to flipped point coordinates whose origin is the selection's top-left.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -px.minX / scale, y: -px.minY / scale)
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        for a in annotations { a.draw() }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Called by the session when another screen's overlay starts a selection.
    func clearSelection() {
        if textField != nil { cancelText() }
        selection = nil
        annotations.removeAll()
        undoStack.removeAll()
        selectedAnnotation = nil
        drag = .none
        tool = nil
        refreshToolButtons()
        hintLabel.isHidden = false
        layoutChrome()
        needsDisplay = true
    }
}
