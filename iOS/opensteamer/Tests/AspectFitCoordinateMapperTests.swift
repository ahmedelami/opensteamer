import CoreGraphics
import XCTest
@testable import opensteamer

/// Regression coverage for translating iPhone gestures through aspect-fit letterboxing.
/// The critical oracles are rejection outside visible video, finite normalized coordinates, and
/// edge clamping only after an accepted drag has begun.
final class AspectFitCoordinateMapperTests: XCTestCase {
    func testWideVideoMapsCenterAndRejectsTopLetterbox() throws {
        let container = CGSize(width: 390, height: 700)
        let video = CGSize(width: 1_920, height: 1_080)
        let visibleRect = try XCTUnwrap(
            AspectFitCoordinateMapper.visibleVideoRect(
                containerSize: container,
                videoSize: video
            )
        )

        let center = try XCTUnwrap(
            AspectFitCoordinateMapper.normalizedPoint(
                for: CGPoint(x: visibleRect.midX, y: visibleRect.midY),
                containerSize: container,
                videoSize: video
            )
        )
        XCTAssertEqual(center.x, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(center.y, 0.5, accuracy: 0.000_001)
        XCTAssertNil(
            AspectFitCoordinateMapper.normalizedPoint(
                for: CGPoint(x: container.width / 2, y: visibleRect.minY - 1),
                containerSize: container,
                videoSize: video
            )
        )
    }

    func testPortraitVideoRejectsSideLetterboxAndPreservesEdges() throws {
        let container = CGSize(width: 700, height: 390)
        let video = CGSize(width: 1_080, height: 1_920)
        let visibleRect = try XCTUnwrap(
            AspectFitCoordinateMapper.visibleVideoRect(
                containerSize: container,
                videoSize: video
            )
        )

        XCTAssertNil(
            AspectFitCoordinateMapper.normalizedPoint(
                for: CGPoint(x: visibleRect.minX - 1, y: visibleRect.midY),
                containerSize: container,
                videoSize: video
            )
        )
        for justOutside in [
            CGPoint(x: visibleRect.minX.nextDown, y: visibleRect.midY),
            CGPoint(x: visibleRect.maxX.nextUp, y: visibleRect.midY),
            CGPoint(x: visibleRect.midX, y: visibleRect.minY.nextDown),
            CGPoint(x: visibleRect.midX, y: visibleRect.maxY.nextUp),
        ] {
            XCTAssertNil(
                AspectFitCoordinateMapper.normalizedPoint(
                    for: justOutside,
                    containerSize: container,
                    videoSize: video
                )
            )
        }
        let minimum = try XCTUnwrap(
            AspectFitCoordinateMapper.normalizedPoint(
                for: CGPoint(x: visibleRect.minX, y: visibleRect.minY),
                containerSize: container,
                videoSize: video
            )
        )
        let maximum = try XCTUnwrap(
            AspectFitCoordinateMapper.normalizedPoint(
                for: CGPoint(x: visibleRect.maxX, y: visibleRect.maxY),
                containerSize: container,
                videoSize: video
            )
        )
        XCTAssertEqual(minimum, .zero)
        XCTAssertEqual(maximum.x, 1, accuracy: 0.000_001)
        XCTAssertEqual(maximum.y, 1, accuracy: 0.000_001)
    }

    func testInvalidGeometryAndNonfiniteLocationsFailClosed() {
        XCTAssertNil(
            AspectFitCoordinateMapper.visibleVideoRect(
                containerSize: .zero,
                videoSize: CGSize(width: 1_920, height: 1_080)
            )
        )
        XCTAssertNil(
            AspectFitCoordinateMapper.normalizedPoint(
                for: CGPoint(x: CGFloat.infinity, y: 20),
                containerSize: CGSize(width: 390, height: 700),
                videoSize: CGSize(width: 1_920, height: 1_080)
            )
        )
        XCTAssertNil(
            AspectFitCoordinateMapper.visibleVideoRect(
                containerSize: CGSize(width: 390, height: 700),
                videoSize: CGSize(width: CGFloat.nan, height: 1_080)
            )
        )
    }

    func testActiveDragClampsOutsideVideoToNearestEdge() throws {
        let container = CGSize(width: 390, height: 700)
        let video = CGSize(width: 1_920, height: 1_080)
        let visibleRect = try XCTUnwrap(
            AspectFitCoordinateMapper.visibleVideoRect(
                containerSize: container,
                videoSize: video
            )
        )

        let clamped = try XCTUnwrap(
            AspectFitCoordinateMapper.clampedNormalizedPoint(
                for: CGPoint(x: container.width + 200, y: visibleRect.minY - 100),
                containerSize: container,
                videoSize: video
            )
        )

        XCTAssertEqual(clamped.x, 1, accuracy: 0.000_001)
        XCTAssertEqual(clamped.y, 0, accuracy: 0.000_001)
    }

    func testPrimaryDragRequiresMovementAndAnOriginInsideVideo() throws {
        let container = CGSize(width: 390, height: 700)
        let video = CGSize(width: 1_920, height: 1_080)
        let visibleRect = try XCTUnwrap(
            AspectFitCoordinateMapper.visibleVideoRect(
                containerSize: container,
                videoSize: video
            )
        )
        let start = CGPoint(x: visibleRect.midX, y: visibleRect.midY)

        XCTAssertNil(
            RemotePrimaryDragGesturePolicy.normalizedEndpoints(
                startLocation: start,
                endLocation: CGPoint(x: start.x + 2, y: start.y),
                containerSize: container,
                videoSize: video
            )
        )
        XCTAssertNil(
            RemotePrimaryDragGesturePolicy.normalizedEndpoints(
                startLocation: CGPoint(x: start.x, y: visibleRect.minY - 1),
                endLocation: start,
                containerSize: container,
                videoSize: video
            )
        )

        let endpoints = try XCTUnwrap(
            RemotePrimaryDragGesturePolicy.normalizedEndpoints(
                startLocation: start,
                endLocation: CGPoint(x: container.width + 40, y: visibleRect.maxY + 40),
                containerSize: container,
                videoSize: video
            )
        )
        XCTAssertEqual(endpoints.start.x, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(endpoints.start.y, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(endpoints.end.x, 1, accuracy: 0.000_001)
        XCTAssertEqual(endpoints.end.y, 1, accuracy: 0.000_001)
    }

    func testEveryMacScaleChoiceUsesTheFullPortraitViewerWidth() throws {
        let portraitViewer = CGSize(width: 603, height: 1_311)
        let selectableFramebuffers = [
            CGSize(width: 1_206, height: 2_622),
            CGSize(width: 1_080, height: 2_340),
            CGSize(width: 1_080, height: 1_920),
            CGSize(width: 828, height: 1_792),
            CGSize(width: 750, height: 1_334),
        ]

        for framebuffer in selectableFramebuffers {
            let renderedRect = try XCTUnwrap(
                AspectFitCoordinateMapper.visibleVideoRect(
                    containerSize: portraitViewer,
                    videoSize: framebuffer
                )
            )
            XCTAssertEqual(renderedRect.minX, 0, accuracy: 0.001)
            XCTAssertEqual(renderedRect.maxX, portraitViewer.width, accuracy: 0.001)
        }
    }

    func testEverySelectableFramebufferPreservesTheNormalizedTouchGrid() throws {
        let viewerSizes = [
            CGSize(width: 603, height: 1_311),
            CGSize(width: 390, height: 844),
            CGSize(width: 844, height: 390),
        ]
        // Includes the fixed-size and synthesized mode families currently exposed by the
        // OpenSteamer display. The odd 603x1312 source is encoded as the nearest even 602x1310.
        let encodedFramebuffers = [
            CGSize(width: 540, height: 960),
            CGSize(width: 602, height: 1_310),
            CGSize(width: 640, height: 480),
            CGSize(width: 640, height: 1_392),
            CGSize(width: 720, height: 1_280),
            CGSize(width: 750, height: 1_334),
            CGSize(width: 800, height: 600),
            CGSize(width: 800, height: 1_740),
            CGSize(width: 810, height: 1_440),
            CGSize(width: 828, height: 1_792),
            CGSize(width: 900, height: 1_600),
            CGSize(width: 1_024, height: 768),
            CGSize(width: 1_024, height: 2_226),
            CGSize(width: 1_080, height: 1_920),
            CGSize(width: 1_080, height: 2_340),
            CGSize(width: 1_206, height: 2_622),
            CGSize(width: 1_280, height: 960),
            CGSize(width: 1_344, height: 1_008),
            CGSize(width: 1_600, height: 1_200),
        ]
        let normalizedValues: [CGFloat] = [0, 0.1, 0.25, 0.5, 0.75, 0.9, 1]

        for viewerSize in viewerSizes {
            for framebuffer in encodedFramebuffers {
                let visibleRect = try XCTUnwrap(
                    AspectFitCoordinateMapper.visibleVideoRect(
                        containerSize: viewerSize,
                        videoSize: framebuffer
                    )
                )
                for expectedX in normalizedValues {
                    for expectedY in normalizedValues {
                        let location = CGPoint(
                            x: visibleRect.minX + (visibleRect.width * expectedX),
                            y: visibleRect.minY + (visibleRect.height * expectedY)
                        )
                        let normalized = try XCTUnwrap(
                            AspectFitCoordinateMapper.normalizedPoint(
                                for: location,
                                containerSize: viewerSize,
                                videoSize: framebuffer
                            ),
                            "Rejected \(framebuffer) at \(expectedX),\(expectedY)"
                        )
                        XCTAssertEqual(normalized.x, expectedX, accuracy: 0.000_001)
                        XCTAssertEqual(normalized.y, expectedY, accuracy: 0.000_001)
                    }
                }
            }
        }
    }
}
