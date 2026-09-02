import CoreGraphics
import Foundation
import XCTest
@testable import Streaming

final class FocusedWindowResizeGeometryTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 600, height: 500)
    private let original = CGRect(x: 100, y: 100, width: 400, height: 300)
    private let minimumSize = CGSize(width: 160, height: 120)

    func testMinimumRetainedSizeIsAffineAndPositive() throws {
        let normalized = try XCTUnwrap(
            FocusedWindowResizeGeometry.minimumRetainedSize(
                for: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.4)
            )
        )
        let native = try XCTUnwrap(
            FocusedWindowResizeGeometry.minimumRetainedSize(
                for: CGRect(x: -1_200, y: 80, width: 600, height: 400)
            )
        )

        XCTAssertEqual(normalized.width, 0.15, accuracy: 0.000_001)
        XCTAssertEqual(normalized.height, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(native.width, 150, accuracy: 0.000_001)
        XCTAssertEqual(native.height, 100, accuracy: 0.000_001)
        XCTAssertNil(FocusedWindowResizeGeometry.minimumRetainedSize(for: .zero))
    }

    func testMidpointTiesChooseRightAndBottomDeterministically() {
        XCTAssertEqual(
            FocusedWindowResizeGeometry.corner(
                for: CGPoint(x: original.midX, y: original.midY),
                in: original
            ),
            .bottomRight
        )
        XCTAssertEqual(
            FocusedWindowResizeGeometry.corner(
                for: CGPoint(x: original.minX, y: original.midY),
                in: original
            ),
            .bottomLeft
        )
        XCTAssertEqual(
            FocusedWindowResizeGeometry.corner(
                for: CGPoint(x: original.midX, y: original.minY),
                in: original
            ),
            .topRight
        )
    }

    func testInsetStartAppliesDeltaWithoutSnappingEdgeToFinger() throws {
        let proposal = try XCTUnwrap(
            FocusedWindowResizeGeometry.proposedFrame(
                original: original,
                start: CGPoint(x: 150, y: 140),
                end: CGPoint(x: 130, y: 110),
                bounds: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                minimumSize: minimumSize
            )
        )

        XCTAssertEqual(proposal.corner, .topLeft)
        XCTAssertEqual(proposal.frame, CGRect(x: 80, y: 70, width: 420, height: 330))
        XCTAssertNotEqual(proposal.frame.origin, CGPoint(x: 130, y: 110))
    }

    func testAllCornersPreserveTheirOppositeCorner() throws {
        let cases: [(
            start: CGPoint,
            end: CGPoint,
            corner: FocusedWindowResizeCorner,
            frame: CGRect
        )] = [
            (
                CGPoint(x: 125, y: 125), CGPoint(x: 105, y: 105),
                .topLeft, CGRect(x: 80, y: 80, width: 420, height: 320)
            ),
            (
                CGPoint(x: 475, y: 125), CGPoint(x: 495, y: 105),
                .topRight, CGRect(x: 100, y: 80, width: 420, height: 320)
            ),
            (
                CGPoint(x: 125, y: 375), CGPoint(x: 105, y: 395),
                .bottomLeft, CGRect(x: 80, y: 100, width: 420, height: 320)
            ),
            (
                CGPoint(x: 475, y: 375), CGPoint(x: 495, y: 395),
                .bottomRight, CGRect(x: 100, y: 100, width: 420, height: 320)
            )
        ]

        for item in cases {
            let proposal = try XCTUnwrap(
                FocusedWindowResizeGeometry.proposedFrame(
                    original: original,
                    start: item.start,
                    end: item.end,
                    bounds: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                    minimumSize: minimumSize
                )
            )
            XCTAssertEqual(proposal.corner, item.corner)
            XCTAssertEqual(proposal.frame, item.frame)
        }
    }

    func testExtremeDragsClampToBoundsAndCanonicalMinimumFrame() throws {
        let outward = try XCTUnwrap(
            FocusedWindowResizeGeometry.proposedFrame(
                original: original,
                start: CGPoint(x: 120, y: 120),
                end: CGPoint(x: -1_000, y: -1_000),
                bounds: bounds,
                minimumSize: minimumSize
            )
        )
        XCTAssertEqual(outward.frame, CGRect(x: 0, y: 0, width: 500, height: 400))

        let crossed = try XCTUnwrap(
            FocusedWindowResizeGeometry.proposedFrame(
                original: original,
                start: CGPoint(x: 120, y: 120),
                end: CGPoint(x: 1_000, y: 1_000),
                bounds: bounds,
                minimumSize: minimumSize
            )
        )
        XCTAssertEqual(crossed.frame, CGRect(x: 340, y: 280, width: 160, height: 120))
        XCTAssertEqual(crossed.frame, crossed.frame.standardized)
        XCTAssertGreaterThan(crossed.frame.width, 0)
        XCTAssertGreaterThan(crossed.frame.height, 0)
    }

    func testMinimumLargerThanOriginalCanonicalizesToOriginalAxisSize() throws {
        let proposal = try XCTUnwrap(
            FocusedWindowResizeGeometry.proposedFrame(
                original: original,
                start: CGPoint(x: 480, y: 380),
                end: CGPoint(x: 0, y: 0),
                bounds: bounds,
                minimumSize: CGSize(width: 1_000, height: 1_000)
            )
        )

        XCTAssertEqual(proposal.corner, .bottomRight)
        XCTAssertEqual(proposal.frame, original)
    }

    func testMalformedOrUnboundGeometryFailsClosed() {
        let invalidProposals = [
            FocusedWindowResizeGeometry.proposedFrame(
                original: original,
                start: CGPoint(x: original.minX - 1, y: original.minY),
                end: .zero,
                bounds: bounds,
                minimumSize: minimumSize
            ),
            FocusedWindowResizeGeometry.proposedFrame(
                original: original,
                start: CGPoint(x: .nan, y: original.minY),
                end: .zero,
                bounds: bounds,
                minimumSize: minimumSize
            ),
            FocusedWindowResizeGeometry.proposedFrame(
                original: original,
                start: CGPoint(x: original.minX, y: original.minY),
                end: CGPoint(x: CGFloat.infinity, y: 0),
                bounds: bounds,
                minimumSize: minimumSize
            ),
            FocusedWindowResizeGeometry.proposedFrame(
                original: CGRect(x: 100, y: 100, width: -400, height: 300),
                start: CGPoint(x: 100, y: 100),
                end: .zero,
                bounds: bounds,
                minimumSize: minimumSize
            ),
            FocusedWindowResizeGeometry.proposedFrame(
                original: original,
                start: CGPoint(x: original.minX, y: original.minY),
                end: .zero,
                bounds: bounds,
                minimumSize: CGSize(width: -1, height: 120)
            )
        ]

        XCTAssertTrue(invalidProposals.allSatisfy { $0 == nil })
    }
}
