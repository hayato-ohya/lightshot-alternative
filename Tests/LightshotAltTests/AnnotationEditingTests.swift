import XCTest
import AppKit
@testable import LightshotAlt

final class AnnotationEditingTests: XCTestCase {
    func testLineHitTestMoveAndHandles() {
        let a = Annotation(shape: .line(CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 10)), tool: .line, color: .red, lineWidth: 3)
        XCTAssertTrue(a.hitTest(CGPoint(x: 60, y: 13)))
        XCTAssertFalse(a.hitTest(CGPoint(x: 60, y: 30)))
        XCTAssertFalse(a.hitTest(CGPoint(x: 130, y: 10)), "beyond the end point")
        a.move(by: CGPoint(x: 5, y: 20))
        XCTAssertEqual(a.handlePoints, [CGPoint(x: 15, y: 30), CGPoint(x: 115, y: 30)])
        a.setHandle(1, to: CGPoint(x: 50, y: 80))
        if case .line(let s, let e) = a.shape {
            XCTAssertEqual(s, CGPoint(x: 15, y: 30))
            XCTAssertEqual(e, CGPoint(x: 50, y: 80))
        } else { XCTFail() }
    }

    func testRectHitsEdgesOnlyAndCornerHandleKeepsOppositeCorner() {
        let a = Annotation(shape: .rect(CGRect(x: 20, y: 20, width: 100, height: 60)), tool: .rect, color: .blue, lineWidth: 4)
        XCTAssertTrue(a.hitTest(CGPoint(x: 70, y: 21)), "on the top edge")
        XCTAssertFalse(a.hitTest(CGPoint(x: 70, y: 50)), "inside the rectangle is not a hit")
        a.setHandle(0, to: CGPoint(x: 0, y: 0)) // drag top-left corner
        if case .rect(let r) = a.shape {
            XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 120, height: 80))
        } else { XCTFail() }
        a.setHandle(2, to: CGPoint(x: -10, y: -10)) // bottom-right dragged past top-left → normalized
        if case .rect(let r) = a.shape {
            XCTAssertEqual(r, CGRect(x: -10, y: -10, width: 10, height: 10))
        } else { XCTFail() }
    }

    func testTextHitUsesBoundsAndCopyIsIndependent() {
        let a = Annotation(shape: .text("Hello", CGPoint(x: 100, y: 100)), tool: .text, color: .white, lineWidth: 3, fontSize: 22)
        XCTAssertTrue(a.hitTest(CGPoint(x: 110, y: 110)))
        XCTAssertFalse(a.hitTest(CGPoint(x: 100, y: 200)))
        let c = a.copy()
        c.move(by: CGPoint(x: 50, y: 0))
        c.color = .black
        XCTAssertEqual(a.bounds.origin, CGPoint(x: 100, y: 100))
        XCTAssertEqual(c.bounds.origin, CGPoint(x: 150, y: 100))
        XCTAssertEqual(a.color, .white)
    }

    func testMarkerPathHitToleranceScalesWithWidth() {
        let a = Annotation(shape: .path([CGPoint(x: 0, y: 50), CGPoint(x: 100, y: 50)]), tool: .marker, color: .yellow, lineWidth: 3)
        XCTAssertTrue(a.hitTest(CGPoint(x: 50, y: 56)), "marker is 15pt wide")
        XCTAssertFalse(a.hitTest(CGPoint(x: 50, y: 70)))
    }
}
