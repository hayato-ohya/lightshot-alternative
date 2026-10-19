import AppKit

enum Tool: CaseIterable {
    case pen, marker, line, arrow, rect, text

    var symbolName: String {
        switch self {
        case .pen: return "pencil"
        case .marker: return "highlighter"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .text: return "textformat"
        }
    }

    var title: String {
        switch self {
        case .pen: return "Pen"
        case .marker: return "Marker"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rect: return "Rectangle"
        case .text: return "Text"
        }
    }
}

/// One drawn element. Coordinates are in overlay-view points (flipped, origin top-left of the screen).
final class Annotation {
    enum Shape {
        case path([CGPoint])
        case line(CGPoint, CGPoint)
        case arrow(CGPoint, CGPoint)
        case rect(CGRect)
        case text(String, CGPoint)
    }

    var shape: Shape
    let tool: Tool
    let color: NSColor
    let lineWidth: CGFloat
    let fontSize: CGFloat

    static let textSizes: [CGFloat] = [16, 22, 30, 40]
    static func textFont(size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }

    init(shape: Shape, tool: Tool, color: NSColor, lineWidth: CGFloat, fontSize: CGFloat = 22) {
        self.shape = shape
        self.tool = tool
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
    }

    var isDegenerate: Bool {
        switch shape {
        case .path(let pts): return pts.count < 2
        case .line(let a, let b), .arrow(let a, let b): return hypot(b.x - a.x, b.y - a.y) < 2
        case .rect(let r): return r.width < 2 || r.height < 2
        case .text(let s, _): return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func draw() {
        switch shape {
        case .path(let points):
            guard let first = points.first else { return }
            let path = NSBezierPath()
            // Flat ends for the marker so pauses and endpoints do not show up as round blobs.
            path.lineCapStyle = (tool == .marker) ? .butt : .round
            path.lineJoinStyle = .round
            path.move(to: first)
            for p in points.dropFirst() { path.line(to: p) }
            if tool == .marker {
                // Stroke opaquely inside a transparency layer, then composite the whole layer at 40%.
                // This keeps the opacity uniform even where the stroke overlaps itself.
                path.lineWidth = lineWidth * 5
                guard let ctx = NSGraphicsContext.current?.cgContext else { return }
                ctx.saveGState()
                ctx.setAlpha(0.4)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                color.setStroke()
                path.stroke()
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            } else {
                path.lineWidth = lineWidth
                color.setStroke()
                path.stroke()
            }

        case .line(let a, let b):
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineWidth = lineWidth
            path.move(to: a)
            path.line(to: b)
            color.setStroke()
            path.stroke()

        case .arrow(let a, let b):
            let dx = b.x - a.x, dy = b.y - a.y
            let len = hypot(dx, dy)
            guard len > 0.5 else { return }
            let ux = dx / len, uy = dy / len
            let headLength = max(14, lineWidth * 4.5)
            let headWidth = headLength * 0.55
            let base = CGPoint(x: b.x - ux * headLength, y: b.y - uy * headLength)
            let shaft = NSBezierPath()
            shaft.lineCapStyle = .round
            shaft.lineWidth = lineWidth
            shaft.move(to: a)
            shaft.line(to: base)
            color.setStroke()
            shaft.stroke()
            let head = NSBezierPath()
            head.move(to: b)
            head.line(to: CGPoint(x: base.x - uy * headWidth, y: base.y + ux * headWidth))
            head.line(to: CGPoint(x: base.x + uy * headWidth, y: base.y - ux * headWidth))
            head.close()
            color.setFill()
            head.fill()

        case .rect(let r):
            let path = NSBezierPath(rect: r)
            path.lineJoinStyle = .round
            path.lineWidth = lineWidth
            color.setStroke()
            path.stroke()

        case .text(let string, let origin):
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Annotation.textFont(size: fontSize),
                .foregroundColor: color,
                .shadow: shadow,
            ]
            NSAttributedString(string: string, attributes: attrs).draw(at: origin)
        }
    }
}
