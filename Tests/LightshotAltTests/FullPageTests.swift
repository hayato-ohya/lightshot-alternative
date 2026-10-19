import XCTest
import AppKit
@testable import LightshotAlt

final class FullPageTests: XCTestCase {
    /// Solid image with a distinct gray value per row band so rows can be identified after stitching.
    private func image(width: Int, height: Int, gray: UInt8) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(gray: CGFloat(gray) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func gray(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        let data = image.dataProvider!.data! as Data
        return data[y * image.bytesPerRow + x * 4 + 1] // any color channel; BGRA little-endian
    }

    func testComposePlacesSlicesTopToBottomAndLaterSlicesWin() {
        let slices = [
            PageSlice(image: image(width: 10, height: 50, gray: 50), y: 0),
            PageSlice(image: image(width: 10, height: 40, gray: 150), y: 40), // overlaps rows 40..49 of the first
            PageSlice(image: image(width: 10, height: 20, gray: 250), y: 80),
        ]
        let out = FullPageTests.compose(slices, width: 10, height: 100)
        XCTAssertEqual(out.width, 10)
        XCTAssertEqual(out.height, 100)
        XCTAssertEqual(Int(gray(out, x: 5, y: 0)), 50, accuracy: 20)
        XCTAssertEqual(Int(gray(out, x: 5, y: 39)), 50, accuracy: 20)
        XCTAssertEqual(Int(gray(out, x: 5, y: 45)), 150, accuracy: 20, "later slice overwrites the overlap")
        XCTAssertEqual(Int(gray(out, x: 5, y: 79)), 150, accuracy: 20)
        XCTAssertEqual(Int(gray(out, x: 5, y: 99)), 250, accuracy: 20)
    }

    private static func compose(_ slices: [PageSlice], width: Int, height: Int) -> CGImage {
        FullPageCapturer.compose(slices, width: width, height: height)!
    }

    func testCropViewportTakesBottomOfWindowAndRemovesTopInset() {
        // Window image 100x120: toolbar on top (rows 0..19), viewport rows 20..119.
        let ctx = CGContext(data: nil, width: 100, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 120))
        ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 100, width: 100, height: 20)) // CG bottom-left origin → top 20 rows = toolbar
        let window = ctx.makeImage()!

        let full = FullPageCapturer.cropViewport(window, viewportW: 100, viewportH: 100, topInset: 0, rightAligned: false)!
        XCTAssertEqual(full.height, 100)
        XCTAssertLessThan(gray(full, x: 1, y: 0), 100, "first row of the crop is page content, not toolbar")

        let inset = FullPageCapturer.cropViewport(window, viewportW: 100, viewportH: 100, topInset: 30, rightAligned: false)!
        XCTAssertEqual(inset.height, 70)

        // Safari with a sidebar: viewport narrower than the window and right-aligned.
        let narrow = FullPageCapturer.cropViewport(window, viewportW: 60, viewportH: 100, topInset: 0, rightAligned: true)!
        XCTAssertEqual(narrow.width, 60)
    }

    func testAppleScriptEscapesQuotesAndBackslashes() {
        let script = FullPageCapturer.appleScript(kind: .safari, bundleID: "com.apple.Safari", windowTitle: "A \"quoted\" title",
                                                  js: "return \"x\\n\"")
        XCTAssertTrue(script.contains("first window whose name is \"A \\\"quoted\\\" title\""))
        XCTAssertTrue(script.contains("do JavaScript \"return \\\"x\\\\n\\\"\" in current tab"))
        let chrome = FullPageCapturer.appleScript(kind: .chromium, bundleID: "com.google.Chrome", windowTitle: "", js: "1")
        XCTAssertTrue(chrome.contains("execute active tab of theWindow javascript \"1\""))
        XCTAssertNotNil(BrowserKind(bundleID: "com.brave.Browser"))
        XCTAssertNil(BrowserKind(bundleID: "org.mozilla.firefox"))
    }
}
