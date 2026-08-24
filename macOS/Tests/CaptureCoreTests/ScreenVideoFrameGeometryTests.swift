import CoreGraphics
import XCTest
@testable import CaptureCore

/// Proves that remote input follows the captured content inside a fixed ScreenCaptureKit surface.
final class ScreenVideoFrameGeometryTests: XCTestCase {
    func testPillarboxedContentMapsRelativePointsAndRejectsBars() throws {
        let geometry = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 48, y: 0, width: 444, height: 960),
                contentScale: 1,
                scaleFactor: 2
            )
        )

        XCTAssertEqual(geometry.contentRect, CGRect(x: 96, y: 0, width: 888, height: 1_920))

        let quarter = try XCTUnwrap(
            geometry.contentNormalizedPoint(
                for: CGPoint(
                    x: (96 + (888 * 0.25)) / 1_080,
                    y: 0.75
                )
            )
        )
        XCTAssertEqual(quarter.x, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(quarter.y, 0.75, accuracy: 0.000_001)
        XCTAssertNil(
            geometry.contentNormalizedPoint(for: CGPoint(x: 0.05, y: 0.5))
        )
        XCTAssertNil(
            geometry.contentNormalizedPoint(for: CGPoint(x: 0.95, y: 0.5))
        )
    }

    func testLetterboxedContentClampsOnlyAnActiveDragEndpoint() throws {
        let geometry = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 0, y: 300, width: 1_080, height: 1_320),
                contentScale: 1,
                scaleFactor: 1
            )
        )

        XCTAssertNil(
            geometry.contentNormalizedPoint(for: CGPoint(x: 0.5, y: 0.05))
        )
        let minimum = try XCTUnwrap(
            geometry.clampedContentNormalizedPoint(for: CGPoint(x: 0.5, y: 0.05))
        )
        let maximum = try XCTUnwrap(
            geometry.clampedContentNormalizedPoint(for: CGPoint(x: 0.5, y: 0.95))
        )
        XCTAssertEqual(minimum.x, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(minimum.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(maximum.x, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(maximum.y, 1, accuracy: 0.000_001)
    }

    func testAllAdvertisedModeMappingsHaveCompatibleLogicalAndPixelAspects() throws {
        let modes: [(logical: CGSize, pixels: CGSize)] = [
            (.init(width: 1_080, height: 1_920), .init(width: 1_080, height: 1_920)),
            (.init(width: 603, height: 1_311), .init(width: 1_206, height: 2_622)),
            (.init(width: 540, height: 1_170), .init(width: 1_080, height: 2_340)),
            (.init(width: 540, height: 960), .init(width: 1_080, height: 1_920)),
            (.init(width: 414, height: 896), .init(width: 828, height: 1_792)),
            (.init(width: 750, height: 1_334), .init(width: 750, height: 1_334))
        ]

        for mode in modes {
            let geometry = try XCTUnwrap(
                ScreenVideoFrameGeometry(
                    surfaceWidth: Int(mode.pixels.width),
                    surfaceHeight: Int(mode.pixels.height),
                    contentRect: CGRect(origin: .zero, size: mode.pixels),
                    contentScale: 1,
                    scaleFactor: 1
                )
            )
            XCTAssertTrue(
                geometry.hasCompatibleAspectRatio(
                    with: CGRect(origin: .zero, size: mode.logical)
                ),
                "Rejected advertised mode \(mode)"
            )
        }
    }

    func testStaleCrossAspectGeometryIsIncompatible() throws {
        let stale = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 0, y: 0, width: 1_080, height: 1_920),
                contentScale: 1,
                scaleFactor: 1
            )
        )

        XCTAssertFalse(
            stale.hasCompatibleAspectRatio(
                with: CGRect(x: 0, y: 0, width: 603, height: 1_311)
            )
        )
    }

    func testMalformedOrOutOfSurfaceGeometryFailsClosed() {
        let invalidContentRects = [
            CGRect(x: -1, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: 1_081, height: 1_920),
            CGRect(x: 0, y: 0, width: 0, height: 1_920),
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100)
        ]
        for contentRect in invalidContentRects {
            XCTAssertNil(
                ScreenVideoFrameGeometry(
                    surfaceWidth: 1_080,
                    surfaceHeight: 1_920,
                    contentRect: contentRect,
                    contentScale: 1,
                    scaleFactor: 1
                )
            )
        }

        XCTAssertNil(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 0, y: 0, width: 1_080, height: 1_920),
                contentScale: 0,
                scaleFactor: 1
            )
        )
        XCTAssertNil(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 0, y: 0, width: 1_080, height: 1_920),
                contentScale: 1,
                scaleFactor: 5
            )
        )
    }
}
