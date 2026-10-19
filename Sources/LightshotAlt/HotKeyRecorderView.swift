import AppKit

/// Click, then press a key combination to record a new global shortcut.
final class HotKeyRecorderView: NSView {
    var hotKey: HotKey { didSet { needsDisplay = true } }
    var onChange: ((HotKey) -> Void)?
    private var recording = false

    init(hotKey: HotKey) {
        self.hotKey = hotKey
        super.init(frame: NSRect(x: 0, y: 0, width: 160, height: 26))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 160).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        recording = true
        HotKeyManager.shared.pause()
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        HotKeyManager.shared.resume()
        needsDisplay = true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(recording ? nil : self)
    }

    // Make sure the global hot key comes back even if the window closes mid-recording.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, recording { recording = false; HotKeyManager.shared.resume() }
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { // Esc cancels
            window?.makeFirstResponder(nil)
            return
        }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !mods.isEmpty || HotKey.functionKeyCodes.contains(event.keyCode) else {
            NSSound.beep()
            return
        }
        hotKey = HotKey(keyCode: event.keyCode, modifiers: mods)
        onChange?(hotKey)
        window?.makeFirstResponder(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        keyDown(with: event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()
        let text = recording ? "Press shortcut…" : hotKey.displayString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}
