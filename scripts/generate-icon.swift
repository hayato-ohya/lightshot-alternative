// Generates an .iconset directory for the app icon: a diagonal feather in pale blue,
// in the spirit of Lightshot's purple feather. Usage: swift generate-icon.swift <output.iconset>
import AppKit

let outDir = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Cubic Bézier helpers (design space is 256 x 256, origin bottom-left).
struct Cubic {
    let p0, c1, c2, p3: CGPoint
    func point(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let x = u*u*u*p0.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*p3.x
        let y = u*u*u*p0.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*p3.y
        return CGPoint(x: x, y: y)
    }
}

let tip = CGPoint(x: 230, y: 240)
let base = CGPoint(x: 30, y: 30)
let quillEnd = CGPoint(x: 14, y: 8)
// Shaft bows slightly below the straight tip–base line.
let shaft = Cubic(p0: base, c1: CGPoint(x: 72, y: 62), c2: CGPoint(x: 140, y: 150), p3: tip)
// Outer (upper-left) edge of the vane, from tip down to the base.
let outer = Cubic(p0: tip, c1: CGPoint(x: 150, y: 232), c2: CGPoint(x: 52, y: 178), p3: CGPoint(x: 34, y: 112))
let outerLower = Cubic(p0: CGPoint(x: 34, y: 112), c1: CGPoint(x: 22, y: 82), c2: CGPoint(x: 18, y: 42), p3: base)
// Inner (lower-right) edge, hugging the shaft with a small lobe below it.
let inner = Cubic(p0: base, c1: CGPoint(x: 96, y: 54), c2: CGPoint(x: 176, y: 150), p3: tip)

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let k = CGFloat(size) / 256
    let xf = NSAffineTransform()
    xf.scale(by: k)
    xf.concat()

    // Ground shadow.
    let shadowRect = NSRect(x: 36, y: 0, width: 170, height: 20)
    let shadowPath = NSBezierPath(ovalIn: shadowRect)
    NSGradient(colors: [NSColor.black.withAlphaComponent(0.22), NSColor.black.withAlphaComponent(0)])!
        .draw(in: shadowPath, relativeCenterPosition: NSPoint(x: -0.2, y: 0))

    // Vane outline.
    let vane = NSBezierPath()
    vane.move(to: tip)
    vane.curve(to: outer.p3, controlPoint1: outer.c1, controlPoint2: outer.c2)
    vane.curve(to: base, controlPoint1: outerLower.c1, controlPoint2: outerLower.c2)
    vane.curve(to: tip, controlPoint1: inner.c1, controlPoint2: inner.c2)
    vane.close()

    gc.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = NSColor(calibratedRed: 0.1, green: 0.3, blue: 0.6, alpha: 0.35)
    drop.shadowBlurRadius = 6 * k
    drop.shadowOffset = NSSize(width: 2 * k, height: -3 * k)
    drop.set()
    NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.12, green: 0.42, blue: 0.86, alpha: 1), 0.0),   // deep blue near base
        (NSColor(calibratedRed: 0.32, green: 0.62, blue: 0.95, alpha: 1), 0.45),
        (NSColor(calibratedRed: 0.64, green: 0.84, blue: 1.00, alpha: 1), 1.0))!  // lighter toward the tip
        .draw(in: vane, angle: 42)
    gc.restoreGraphicsState()

    // Notches cut into the outer edge (cleared to transparent).
    gc.saveGraphicsState()
    gc.compositingOperation = .destinationOut
    for t in [0.22, 0.42, 0.62] as [CGFloat] {
        let a = outer.point(t - 0.015), b = outer.point(t + 0.075)
        let e = outer.point(t - 0.05), s = shaft.point(1 - (t - 0.05))
        let depth = CGPoint(x: e.x + (s.x - e.x) * 0.55, y: e.y + (s.y - e.y) * 0.55)
        let notch = NSBezierPath()
        notch.move(to: a)
        notch.line(to: depth)
        notch.line(to: b)
        notch.close()
        NSColor.black.setFill()
        notch.fill()
    }
    gc.restoreGraphicsState()

    // Barb lines for texture.
    gc.saveGraphicsState()
    vane.addClip()
    NSColor(calibratedRed: 0.08, green: 0.3, blue: 0.7, alpha: 0.3).setStroke()
    for t in stride(from: 0.08, through: 0.92, by: 0.055) as StrideThrough<CGFloat> {
        let s = shaft.point(t), o = outer.point(1 - t)
        let barb = NSBezierPath()
        barb.lineWidth = 1.2
        barb.move(to: s)
        barb.curve(to: o,
                   controlPoint1: CGPoint(x: s.x + (o.x - s.x) * 0.3 + 10, y: s.y + (o.y - s.y) * 0.3 + 6),
                   controlPoint2: CGPoint(x: s.x + (o.x - s.x) * 0.7 + 6, y: s.y + (o.y - s.y) * 0.7 + 4))
        barb.stroke()
    }
    gc.restoreGraphicsState()

    // Thin outline.
    vane.lineWidth = 1.2
    NSColor(calibratedRed: 0.08, green: 0.3, blue: 0.68, alpha: 0.7).setStroke()
    vane.stroke()

    // Shaft: dark core with a light highlight.
    let shaftPath = NSBezierPath()
    shaftPath.move(to: quillEnd)
    shaftPath.line(to: shaft.p0)
    shaftPath.curve(to: shaft.p3, controlPoint1: shaft.c1, controlPoint2: shaft.c2)
    shaftPath.lineCapStyle = .round
    shaftPath.lineWidth = 5
    NSColor(calibratedRed: 0.05, green: 0.18, blue: 0.42, alpha: 1).setStroke()
    shaftPath.stroke()
    let highlight = NSBezierPath()
    highlight.move(to: CGPoint(x: shaft.p0.x - 1, y: shaft.p0.y + 2))
    highlight.curve(to: CGPoint(x: shaft.p3.x - 1, y: shaft.p3.y + 1),
                    controlPoint1: CGPoint(x: shaft.c1.x - 1, y: shaft.c1.y + 2),
                    controlPoint2: CGPoint(x: shaft.c2.x - 1, y: shaft.c2.y + 2))
    highlight.lineWidth = 1.2
    NSColor(calibratedRed: 0.75, green: 0.9, blue: 1, alpha: 0.7).setStroke()
    highlight.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base).png"))
    try render(base * 2).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base)@2x.png"))
}

// Menu bar template icon: a solid feather silhouette (black + alpha), like Lightshot's status item.
func renderMenuBar(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    // Fit the 256-space feather (bbox ~ 10...236) into the icon with a small margin.
    let k = CGFloat(size) / 256 * 1.02
    let xf = NSAffineTransform()
    xf.translateX(by: 0, yBy: CGFloat(size) * 0.01)
    xf.scale(by: k)
    xf.concat()

    let vane = NSBezierPath()
    vane.move(to: tip)
    vane.curve(to: outer.p3, controlPoint1: outer.c1, controlPoint2: outer.c2)
    vane.curve(to: base, controlPoint1: outerLower.c1, controlPoint2: outerLower.c2)
    vane.curve(to: tip, controlPoint1: inner.c1, controlPoint2: inner.c2)
    vane.close()
    NSColor.black.setFill()
    vane.fill()

    let shaftPath = NSBezierPath()
    shaftPath.move(to: quillEnd)
    shaftPath.line(to: shaft.p0)
    shaftPath.curve(to: shaft.p3, controlPoint1: shaft.c1, controlPoint2: shaft.c2)
    shaftPath.lineCapStyle = .round
    shaftPath.lineWidth = 14
    NSColor.black.setStroke()
    shaftPath.stroke()

    gc.compositingOperation = .destinationOut
    for t in [0.22, 0.42, 0.62] as [CGFloat] {
        let a = outer.point(t - 0.015), b = outer.point(t + 0.075)
        let e = outer.point(t - 0.05), s = shaft.point(1 - (t - 0.05))
        let depth = CGPoint(x: e.x + (s.x - e.x) * 0.5, y: e.y + (s.y - e.y) * 0.5)
        let notch = NSBezierPath()
        notch.move(to: a)
        notch.line(to: depth)
        notch.line(to: b)
        notch.close()
        notch.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if CommandLine.arguments.count > 2 {
    let menuDir = CommandLine.arguments[2]
    try FileManager.default.createDirectory(atPath: menuDir, withIntermediateDirectories: true)
    try renderMenuBar(18).write(to: URL(fileURLWithPath: "\(menuDir)/MenuBarIcon.png"))
    try renderMenuBar(36).write(to: URL(fileURLWithPath: "\(menuDir)/MenuBarIcon@2x.png"))
}
