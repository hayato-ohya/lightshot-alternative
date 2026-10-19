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
    var color: NSColor
    var lineWidth: CGFloat
    var fontSize: CGFloat

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

// MARK: - Editing support

extension Annotation {
    func copy() -> Annotation {
        Annotation(shape: shape, tool: tool, color: color, lineWidth: lineWidth, fontSize: fontSize)
    }

    var textAttributes: [NSAttributedString.Key: Any] {
        [.font: Annotation.textFont(size: fontSize)]
    }

    /// Bounding box in view points.
    var bounds: CGRect {
        switch shape {
        case .path(let pts):
            guard let first = pts.first else { return .zero }
            var r = CGRect(origin: first, size: .zero)
            for p in pts { r = r.union(CGRect(origin: p, size: .zero)) }
            let pad = (tool == .marker ? lineWidth * 5 : lineWidth) / 2
            return r.insetBy(dx: -pad, dy: -pad)
        case .line(let a, let b), .arrow(let a, let b):
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            let pad = max(lineWidth, 14) / 2
            return r.insetBy(dx: -pad, dy: -pad)
        case .rect(let r):
            return r.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .text(let s, let origin):
            let size = (s as NSString).size(withAttributes: textAttributes)
            return CGRect(origin: origin, size: CGSize(width: max(size.width, 10), height: max(size.height, fontSize)))
        }
    }

    /// Points the user can drag to reshape the annotation (line/arrow endpoints, rectangle corners).
    var handlePoints: [CGPoint] {
        switch shape {
        case .line(let a, let b), .arrow(let a, let b):
            return [a, b]
        case .rect(let r):
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        case .path, .text:
            return []
        }
    }

    func setHandle(_ index: Int, to p: CGPoint) {
        switch shape {
        case .line(let a, let b):
            shape = index == 0 ? .line(p, b) : .line(a, p)
        case .arrow(let a, let b):
            shape = index == 0 ? .arrow(p, b) : .arrow(a, p)
        case .rect(let r):
            // Opposite corner stays fixed.
            let anchor: CGPoint
            switch index {
            case 0: anchor = CGPoint(x: r.maxX, y: r.maxY)
            case 1: anchor = CGPoint(x: r.minX, y: r.maxY)
            case 2: anchor = CGPoint(x: r.minX, y: r.minY)
            default: anchor = CGPoint(x: r.maxX, y: r.minY)
            }
            shape = .rect(CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                                 width: abs(anchor.x - p.x), height: abs(anchor.y - p.y)))
        case .path, .text:
            break
        }
    }

    func move(by d: CGPoint) {
        func t(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.x, y: p.y + d.y) }
        switch shape {
        case .path(let pts): shape = .path(pts.map(t))
        case .line(let a, let b): shape = .line(t(a), t(b))
        case .arrow(let a, let b): shape = .arrow(t(a), t(b))
        case .rect(let r): shape = .rect(r.offsetBy(dx: d.x, dy: d.y))
        case .text(let s, let o): shape = .text(s, t(o))
        }
    }

    /// True when `p` is on the drawn stroke (or inside the text box).
    func hitTest(_ p: CGPoint) -> Bool {
        let tolerance = max(lineWidth / 2, 5)
        switch shape {
        case .path(let pts):
            let tol = tool == .marker ? max(lineWidth * 2.5, 5) : tolerance
            guard pts.count > 1 else { return pts.first.map { hypot($0.x - p.x, $0.y - p.y) <= tol } ?? false }
            for i in 1..<pts.count where Annotation.distance(from: p, toSegment: pts[i - 1], pts[i]) <= tol { return true }
            return false
        case .line(let a, let b), .arrow(let a, let b):
            return Annotation.distance(from: p, toSegment: a, b) <= max(tolerance, 7)
        case .rect(let r):
            let outer = r.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = r.insetBy(dx: tolerance, dy: tolerance)
            return outer.contains(p) && !(inner.width > 0 && inner.height > 0 && inner.contains(p))
        case .text:
            return bounds.insetBy(dx: -3, dy: -3).contains(p)
        }
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
