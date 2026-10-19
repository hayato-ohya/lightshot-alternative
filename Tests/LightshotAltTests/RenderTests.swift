import XCTest
import AppKit
@testable import LightshotAlt

@MainActor
final class RenderTests: XCTestCase {
    /// A 2x "screen" of 100x80 points whose top-left quadrant is red, rest blue.
    private func makeScreenshot(scale: CGFloat) -> CGImage {
        let w = Int(100 * scale), h = Int(80 * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        // CG origin is bottom-left, so the top-left quadrant is at y in [h/2, h).
        ctx.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
        return ctx.makeImage()!
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let data = image.dataProvider!.data! as Data
        let bpr = image.bytesPerRow
        let i = y * bpr + x * 4
        // Context is BGRA little-endian (premultipliedFirst | byteOrder32Little).
        return (data[i + 2], data[i + 1], data[i])
    }

    func testCropMatchesSelectionAtRetinaScale() {
        let scale: CGFloat = 2
        let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 100, height: 80),
                               screenshot: makeScreenshot(scale: scale), scale: scale, windowFrames: [])
        // Selection straddling the quadrant boundary: 40..60 x 30..50 points.
        view.selection = CGRect(x: 40, y: 30, width: 20, height: 20)
        let image = view.renderImage()!
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 40)
        // Top-left pixel of the crop is inside the red quadrant; bottom-right is blue.
        let tl = pixel(image, x: 1, y: 1)
        XCTAssertGreaterThan(tl.r, 200); XCTAssertLessThan(tl.b, 60)
        let br = pixel(image, x: 38, y: 38)
        XCTAssertLessThan(br.r, 60); XCTAssertGreaterThan(br.b, 200)
    }

    func testAnnotationIsDrawnAtCorrectPositionAndScale() {
        let scale: CGFloat = 2
        let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 100, height: 80),
                               screenshot: makeScreenshot(scale: scale), scale: scale, windowFrames: [])
        view.selection = CGRect(x: 50, y: 40, width: 50, height: 40) // bottom-right quadrant, blue
        // Green filled-ish rectangle stroke at view points (60,45)-(70,55) → crop points (10,5)-(20,15).
        view.annotations = [Annotation(shape: .rect(CGRect(x: 60, y: 45, width: 10, height: 10)),
                                       tool: .rect, color: .green, lineWidth: 4)]
        let image = view.renderImage()!
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 80)
        // Top edge of the rect in pixels: y = 5*2 = 10, x from 20 to 40.
        let onEdge = pixel(image, x: 30, y: 10)
        XCTAssertGreaterThan(onEdge.g, 200, "stroke should be green")
        // Well outside the rect is still blue.
        let outside = pixel(image, x: 80, y: 60)
        XCTAssertGreaterThan(outside.b, 200); XCTAssertLessThan(outside.g, 100)
        // Inside the rect (not on stroke) stays blue — unfilled.
        let inside = pixel(image, x: 30, y: 20)
        XCTAssertGreaterThan(inside.b, 200)
    }

    func testMarkerOpacityIsUniformWhereStrokeOverlapsItself() {
        let scale: CGFloat = 1
        let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 100, height: 80),
                               screenshot: makeScreenshot(scale: scale), scale: scale, windowFrames: [])
        view.selection = CGRect(x: 50, y: 40, width: 50, height: 40) // blue area
        // Marker stroke that goes right, then doubles back over itself with a jitter.
        let pts = [CGPoint(x: 55, y: 60), CGPoint(x: 90, y: 60), CGPoint(x: 70, y: 61), CGPoint(x: 72, y: 59), CGPoint(x: 60, y: 60)]
        view.annotations = [Annotation(shape: .path(pts), tool: .marker, color: .black, lineWidth: 3)]
        let image = view.renderImage()!
        let overlapped = pixel(image, x: 65 - 50, y: 60 - 40)   // covered twice
        let single = pixel(image, x: 85 - 50, y: 60 - 40)       // covered once
        XCTAssertEqual(Int(overlapped.b), Int(single.b), accuracy: 3, "overlapping marker must not get darker")
        XCTAssertLessThan(single.b, 200, "marker should visibly darken the blue")
    }

    func testRecordingModeOverlaySurvivesSelectionReset() {
        let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 100, height: 80),
                               screenshot: makeScreenshot(scale: 1), scale: 1, windowFrames: [], mode: .recording)
        view.selection = CGRect(x: 10, y: 10, width: 20, height: 20)
        view.clearSelection() // used to crash: no color button exists in recording mode
        XCTAssertNil(view.selection)
    }

    func testHotKeyDisplayString() {
        XCTAssertEqual(HotKey.default.displayString, "⇧⌘9")
        XCTAssertEqual(HotKey(keyCode: 122, modifiers: []).displayString, "F1")
    }
}
