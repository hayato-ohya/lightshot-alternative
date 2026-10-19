import AppKit

/// A click-through window that darkens everything on a screen except the region being recorded.
/// Our own windows are excluded from the capture filter, so it never appears in the recording.
final class RecordingDimWindow: NSWindow {
    /// `rect` is in points relative to the top-left corner of `screen`.
    init(screen: NSScreen, rect: CGRect) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = DimView(frame: CGRect(origin: .zero, size: screen.frame.size), hole: rect)
    }

    private final class DimView: NSView {
        let hole: CGRect

        init(frame: CGRect, hole: CGRect) {
            self.hole = hole
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let dim = NSBezierPath(rect: bounds)
            dim.appendRect(hole)
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.45).setFill()
            dim.fill()
            let border = NSBezierPath(rect: hole.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            NSColor.systemRed.withAlphaComponent(0.9).setStroke()
            border.stroke()
        }
    }
}
