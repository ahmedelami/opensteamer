import Foundation
import XCTest
@testable import Streaming

final class FocusedWindowMoveGeometryTests: XCTestCase {
    func testOutsideWindowStartTranslatesWithoutSnappingOrResizing() throws {
        let moved = try XCTUnwrap(FocusedWindowMoveGeometry.proposedFrame(
            original: CGRect(x: 100, y: 80, width: 300, height: 200),
            start: CGPoint(x: 700, y: 450), end: CGPoint(x: 650, y: 400),
            displayBounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        ))
        XCTAssertEqual(moved, CGRect(x: 50, y: 30, width: 300, height: 200))
    }

    func testEveryBoundaryClampsPositionAndPreservesSizeWithNegativeDisplayOrigin() throws {
        let bounds = CGRect(x: -800, y: -600, width: 800, height: 600)
        let original = CGRect(x: -600, y: -450, width: 300, height: 200)
        for (end, expected) in [
            (CGPoint(x: -800, y: -600), CGPoint(x: -800, y: -600)),
            (CGPoint(x: 0, y: -600), CGPoint(x: -300, y: -600)),
            (CGPoint(x: -800, y: 0), CGPoint(x: -800, y: -200)),
            (CGPoint(x: 0, y: 0), CGPoint(x: -300, y: -200))
        ] {
            let moved = try XCTUnwrap(FocusedWindowMoveGeometry.proposedFrame(
                original: original, start: CGPoint(x: -400, y: -300), end: end,
                displayBounds: bounds
            ))
            XCTAssertEqual(moved.origin, expected)
            XCTAssertEqual(moved.size, original.size)
        }
    }

    func testNormalizedPreviewMatchesHostGeometry() throws {
        let normalized = try XCTUnwrap(FocusedWindowMoveGeometry.proposedFrame(
            original: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5),
            start: CGPoint(x: 0.05, y: 0.1), end: CGPoint(x: 0.35, y: 0.7),
            displayBounds: CGRect(x: 0, y: 0, width: 1, height: 1)
        ))
        let native = try XCTUnwrap(FocusedWindowMoveGeometry.proposedFrame(
            original: CGRect(x: -800, y: 150, width: 400, height: 250),
            start: CGPoint(x: -950, y: 50), end: CGPoint(x: -650, y: 350),
            displayBounds: CGRect(x: -1000, y: 0, width: 1000, height: 500)
        ))
        XCTAssertEqual(normalized.minX, (native.minX + 1000) / 1000, accuracy: 0.000_001)
        XCTAssertEqual(normalized.minY, native.minY / 500, accuracy: 0.000_001)
        XCTAssertEqual(normalized.width, native.width / 1000, accuracy: 0.000_001)
        XCTAssertEqual(normalized.height, native.height / 500, accuracy: 0.000_001)
    }

    func testNegotiatedMoveMayLeaveDisplayWhileRetainingTopBandAndHorizontalGrip() throws {
        let bounds = CGRect(x: -1_920, y: -1_080, width: 1_920, height: 1_080)
        let original = CGRect(x: -600, y: -400, width: 640, height: 400)
        let moved = try XCTUnwrap(FocusedWindowMoveGeometry.proposedFrame(
            original: original,
            start: CGPoint(x: -1_920, y: -1_080),
            end: CGPoint(x: 0, y: 0),
            displayBounds: bounds,
            allowsRecoverableOffscreen: true
        ))

        XCTAssertEqual(moved.size, original.size)
        XCTAssertEqual(
            moved.minX,
            bounds.maxX - bounds.width * FocusedWindowMoveGeometry.minimumVisibleHorizontalGripFraction,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            moved.minY,
            bounds.maxY - bounds.height * FocusedWindowMoveGeometry.minimumVisibleTopBandFraction,
            accuracy: 0.000_001
        )
        XCTAssertTrue(FocusedWindowMoveGeometry.isRecoverable(moved, in: bounds))
        XCTAssertFalse(bounds.contains(moved))
    }

    func testRecoverablePartialTargetCanMoveBackAndLegacyPathRejectsIt() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 600)
        let partial = CGRect(x: -450, y: 100, width: 500, height: 300)
        XCTAssertTrue(FocusedWindowMoveGeometry.isRecoverable(partial, in: bounds))
        XCTAssertNil(FocusedWindowMoveGeometry.proposedFrame(
            original: partial,
            start: CGPoint(x: 100, y: 100),
            end: CGPoint(x: 300, y: 100),
            displayBounds: bounds
        ))
        XCTAssertEqual(
            FocusedWindowMoveGeometry.proposedFrame(
                original: partial,
                start: CGPoint(x: 100, y: 100),
                end: CGPoint(x: 300, y: 100),
                displayBounds: bounds,
                allowsRecoverableOffscreen: true
            ),
            CGRect(x: -250, y: 100, width: 500, height: 300)
        )
    }

    func testOffscreenMoveRejectsLostTitleBandLostGripAndUnboundedWindow() {
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 600)
        for frame in [
            CGRect(x: -476, y: 100, width: 500, height: 300),
            CGRect(x: 100, y: -1, width: 500, height: 300),
            CGRect(x: 100, y: 583, width: 500, height: 300),
            CGRect(x: 0, y: 0, width: 65_000, height: 300)
        ] {
            XCTAssertFalse(FocusedWindowMoveGeometry.isRecoverable(frame, in: bounds))
        }
    }

    func testMalformedGeometryAndOutsideImageOriginsAreRejected() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let original = CGRect(x: 100, y: 100, width: 300, height: 200)
        for start in [CGPoint(x: -1, y: 100), CGPoint(x: 100, y: 601), CGPoint(x: CGFloat.nan, y: 100)] {
            XCTAssertNil(FocusedWindowMoveGeometry.proposedFrame(
                original: original, start: start, end: .zero, displayBounds: bounds
            ))
        }
        XCTAssertNil(FocusedWindowMoveGeometry.proposedFrame(
            original: original, start: .zero, end: CGPoint(x: CGFloat.infinity, y: 0), displayBounds: bounds
        ))
        XCTAssertNil(FocusedWindowMoveGeometry.proposedFrame(
            original: CGRect(x: 0, y: 0, width: 900, height: 200),
            start: .zero, end: .zero, displayBounds: bounds
        ))
        XCTAssertNil(FocusedWindowMoveGeometry.proposedFrame(
            original: CGRect(x: 400, y: 200, width: -100, height: 200),
            start: .zero, end: .zero, displayBounds: bounds
        ))
    }
}
