import CoreGraphics
import XCTest
@testable import CaptureCore

/// Proves that remote input follows the captured content inside a fixed ScreenCaptureKit surface.
final class ScreenVideoFrameGeometryTests: XCTestCase {
    func testFullFrameDoesNotRequireCaptureFormatRenegotiation() throws {
        let geometry = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_206,
                surfaceHeight: 2_622,
                contentRect: CGRect(x: 0, y: 0, width: 603, height: 1_311),
                contentScale: 1,
                scaleFactor: 2
            )
        )

        XCTAssertFalse(geometry.requiresCaptureFormatRenegotiation)
    }

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
        XCTAssertTrue(geometry.requiresCaptureFormatRenegotiation)

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

        XCTAssertTrue(geometry.requiresCaptureFormatRenegotiation)

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

    func testHalfPixelEdgeDifferencesDoNotRequireCaptureFormatRenegotiation() throws {
        let tolerated = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 0.5, y: 0.5, width: 1_079, height: 1_919),
                contentScale: 1,
                scaleFactor: 1
            )
        )
        let insetBeyondTolerance = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(
                    x: 0.500_001,
                    y: 0,
                    width: 1_079.499_999,
                    height: 1_920
                ),
                contentScale: 1,
                scaleFactor: 1
            )
        )

        XCTAssertFalse(tolerated.requiresCaptureFormatRenegotiation)
        XCTAssertTrue(insetBeyondTolerance.requiresCaptureFormatRenegotiation)
    }

    func testFormatRenegotiationRequiresThreeConsecutiveInsetFrames() throws {
        let fullFrame = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 0, y: 0, width: 1_080, height: 1_920),
                contentScale: 1,
                scaleFactor: 1
            )
        )
        let insetFrame = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 96, y: 0, width: 888, height: 1_920),
                contentScale: 1,
                scaleFactor: 1
            )
        )
        var detector = ScreenVideoFormatRenegotiationDetector()

        XCTAssertEqual(detector.observe(insetFrame), .dropFrame)
        XCTAssertEqual(detector.observe(insetFrame), .dropFrame)
        XCTAssertEqual(detector.observe(fullFrame), .forwardFrame)
        XCTAssertEqual(detector.observe(insetFrame), .dropFrame)
        XCTAssertEqual(detector.observe(insetFrame), .dropFrame)
        XCTAssertEqual(detector.observe(insetFrame), .renegotiate)
        XCTAssertEqual(detector.observe(fullFrame), .dropFrame)

        detector.reset()
        XCTAssertEqual(detector.observe(fullFrame), .forwardFrame)
    }

    func testFormatRenegotiationDetectsSameAspectScaleChangeWithoutInsets() throws {
        let initial = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 0, y: 0, width: 540, height: 960),
                contentScale: 1,
                scaleFactor: 2
            )
        )
        let rescaled = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 0, y: 0, width: 540, height: 960),
                contentScale: 1.44,
                scaleFactor: 2
            )
        )
        var detector = ScreenVideoFormatRenegotiationDetector()

        XCTAssertEqual(detector.observe(initial), .forwardFrame)
        XCTAssertEqual(detector.observe(rescaled), .dropFrame)
        XCTAssertEqual(detector.observe(rescaled), .dropFrame)
        XCTAssertEqual(detector.observe(rescaled), .renegotiate)
    }

    func testMissingGeometryCannotClearAnInsetFormatChangeCandidate() throws {
        let insetFrame = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 96, y: 0, width: 888, height: 1_920),
                contentScale: 1,
                scaleFactor: 1
            )
        )
        let fullFrame = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 0, y: 0, width: 1_080, height: 1_920),
                contentScale: 1,
                scaleFactor: 1
            )
        )
        var detector = ScreenVideoFormatRenegotiationDetector()

        XCTAssertEqual(detector.observe(insetFrame), .dropFrame)
        XCTAssertEqual(detector.observe(nil), .dropFrame)
        XCTAssertEqual(detector.observe(insetFrame), .dropFrame)
        XCTAssertEqual(detector.observe(nil), .dropFrame)
        XCTAssertEqual(detector.observe(insetFrame), .renegotiate)
        XCTAssertEqual(detector.observe(nil), .dropFrame)
        XCTAssertEqual(detector.observe(fullFrame), .dropFrame)

        detector.reset()
        XCTAssertEqual(detector.observe(nil), .forwardFrame)
        XCTAssertEqual(detector.observe(fullFrame), .forwardFrame)
    }

    func testInvalidGeometryIsDroppedAndTriggersBoundedRenegotiation() {
        var detector = ScreenVideoFormatRenegotiationDetector()

        XCTAssertEqual(detector.observe(.invalid), .dropFrame)
        XCTAssertTrue(detector.hasPendingFormatChange)
        XCTAssertEqual(detector.observe(.absent), .dropFrame)
        XCTAssertEqual(detector.observe(.invalid), .dropFrame)
        XCTAssertEqual(detector.observe(.invalid), .renegotiate)
        XCTAssertFalse(detector.hasPendingFormatChange)
        XCTAssertEqual(detector.observe(.absent), .dropFrame)
    }

    func testFallbackDeadlineLatchesPendingFormatChangeWithoutAnotherFrame() throws {
        let insetFrame = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 96, y: 0, width: 888, height: 1_920),
                contentScale: 1,
                scaleFactor: 1
            )
        )
        var detector = ScreenVideoFormatRenegotiationDetector()

        XCTAssertEqual(detector.observe(insetFrame), .dropFrame)
        XCTAssertTrue(detector.hasPendingFormatChange)
        XCTAssertTrue(detector.requestRenegotiationAfterFallbackDeadline())
        XCTAssertFalse(detector.hasPendingFormatChange)
        XCTAssertFalse(detector.requestRenegotiationAfterFallbackDeadline())
        XCTAssertEqual(detector.observe(insetFrame), .dropFrame)
    }

    func testCompatibleGeometryClearsPendingFallbackCandidate() throws {
        let fullFrame = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 0, y: 0, width: 1_080, height: 1_920),
                contentScale: 1,
                scaleFactor: 1
            )
        )
        let insetFrame = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 96, y: 0, width: 888, height: 1_920),
                contentScale: 1,
                scaleFactor: 1
            )
        )
        var detector = ScreenVideoFormatRenegotiationDetector()

        XCTAssertEqual(detector.observe(fullFrame), .forwardFrame)
        XCTAssertEqual(detector.observe(insetFrame), .dropFrame)
        XCTAssertTrue(detector.hasPendingFormatChange)
        XCTAssertEqual(detector.observe(fullFrame), .forwardFrame)
        XCTAssertFalse(detector.hasPendingFormatChange)
        XCTAssertFalse(detector.requestRenegotiationAfterFallbackDeadline())
    }

    func testFormatRenegotiationIgnoresSmallContentScaleJitter() throws {
        let baseline = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 0, y: 0, width: 540, height: 960),
                contentScale: 1,
                scaleFactor: 2
            )
        )
        let jittered = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 0, y: 0, width: 540, height: 960),
                contentScale: 1.004,
                scaleFactor: 2
            )
        )
        var detector = ScreenVideoFormatRenegotiationDetector()

        XCTAssertEqual(detector.observe(baseline), .forwardFrame)
        for _ in 0..<6 {
            XCTAssertEqual(detector.observe(jittered), .forwardFrame)
        }
    }

    func testAllAdvertisedFullFrameModesRemainCompatibleAndDoNotRequireRenegotiation() throws {
        let modes: [(logical: CGSize, pixels: CGSize)] = [
            (.init(width: 1_080, height: 1_920), .init(width: 1_080, height: 1_920)),
            (.init(width: 603, height: 1_311), .init(width: 1_206, height: 2_622)),
            (.init(width: 540, height: 1_170), .init(width: 1_080, height: 2_340)),
            (.init(width: 540, height: 960), .init(width: 1_080, height: 1_920)),
            (.init(width: 414, height: 896), .init(width: 828, height: 1_792)),
            (.init(width: 750, height: 1_334), .init(width: 750, height: 1_334)),
            (.init(width: 1_024, height: 768), .init(width: 1_024, height: 768))
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
            XCTAssertFalse(
                geometry.requiresCaptureFormatRenegotiation,
                "Requested renegotiation for full-frame advertised mode \(mode)"
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
