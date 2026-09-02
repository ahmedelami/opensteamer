import CoreGraphics
import Streaming
import UIKit
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

    func testScrollAccumulatorScalesToFramebufferAndPreservesFractionalRemainder() throws {
        var accumulator = try XCTUnwrap(
            RemoteScrollDeltaAccumulator(
                containerSize: CGSize(width: 100, height: 100),
                videoSize: CGSize(width: 1_000, height: 1_000)
            )
        )

        XCTAssertTrue(accumulator.append(viewDelta: CGSize(width: 0.04, height: 0.06)))
        XCTAssertNil(accumulator.takeNextPacket(finalizing: false))
        XCTAssertEqual(accumulator.pendingPixelDelta.width, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(accumulator.pendingPixelDelta.height, 0.6, accuracy: 0.000_001)

        XCTAssertTrue(accumulator.append(viewDelta: CGSize(width: 0.04, height: 0.06)))
        XCTAssertEqual(
            accumulator.takeNextPacket(finalizing: false),
            RemoteScrollPixelDelta(x: 0, y: 1)
        )
        XCTAssertTrue(accumulator.append(viewDelta: CGSize(width: 0.04, height: 0.06)))
        XCTAssertEqual(
            accumulator.takeNextPacket(finalizing: true),
            RemoteScrollPixelDelta(x: 1, y: 1)
        )
        XCTAssertFalse(accumulator.hasPacket(finalizing: true))
    }

    func testScrollAccumulatorBoundsPacketsWithoutLosingOverflow() throws {
        var accumulator = try XCTUnwrap(
            RemoteScrollDeltaAccumulator(
                containerSize: CGSize(width: 100, height: 100),
                videoSize: CGSize(width: 100, height: 100)
            )
        )
        XCTAssertTrue(
            accumulator.append(viewDelta: CGSize(width: 9_000.25, height: -5_000.75))
        )

        XCTAssertEqual(
            accumulator.takeNextPacket(finalizing: false),
            RemoteScrollPixelDelta(x: 4_096, y: -4_096)
        )
        XCTAssertEqual(
            accumulator.takeNextPacket(finalizing: false),
            RemoteScrollPixelDelta(x: 4_096, y: -904)
        )
        XCTAssertEqual(
            accumulator.takeNextPacket(finalizing: true),
            RemoteScrollPixelDelta(x: 808, y: -1)
        )
    }

    func testUpwardFingerMovementStaysNegativeAtTheProtocolBoundary() throws {
        var accumulator = try XCTUnwrap(
            RemoteScrollDeltaAccumulator(
                containerSize: CGSize(width: 100, height: 100),
                videoSize: CGSize(width: 1_000, height: 1_000)
            )
        )
        XCTAssertTrue(accumulator.append(viewDelta: CGSize(width: -4, height: -3)))

        XCTAssertEqual(
            accumulator.takeNextPacket(finalizing: false),
            RemoteScrollPixelDelta(x: -40, y: -30),
            "The Mac maps protocol deltas directly to CG wheel2/wheel1 pixel units."
        )
    }

    func testScrollAccumulatorRejectsInvalidGeometryAndNonfiniteMovement() throws {
        XCTAssertNil(
            RemoteScrollDeltaAccumulator(
                containerSize: .zero,
                videoSize: CGSize(width: 1_000, height: 1_000)
            )
        )
        var accumulator = try XCTUnwrap(
            RemoteScrollDeltaAccumulator(
                containerSize: CGSize(width: 100, height: 100),
                videoSize: CGSize(width: 1_000, height: 1_000)
            )
        )
        XCTAssertFalse(
            accumulator.append(
                viewDelta: CGSize(width: CGFloat.infinity, height: 1)
            )
        )
        XCTAssertEqual(accumulator.pendingPixelDelta, .zero)
    }

    func testNormalizedResizeRectMapsIntoAspectFitVideoAndRejectsClipping() {
        XCTAssertEqual(
            AspectFitCoordinateMapper.viewRect(
                forNormalizedRect: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25),
                containerSize: CGSize(width: 400, height: 400),
                videoSize: CGSize(width: 200, height: 100)
            ),
            CGRect(x: 100, y: 200, width: 200, height: 50)
        )
        XCTAssertNil(
            AspectFitCoordinateMapper.viewRect(
                forNormalizedRect: CGRect(x: 0.8, y: 0.1, width: 0.3, height: 0.5),
                containerSize: CGSize(width: 400, height: 400),
                videoSize: CGSize(width: 200, height: 100)
            )
        )
    }

    func testResizeCrossoverRetainsSharedMinimumAndAffinePreviewParity() throws {
        let containerSize = CGSize(width: 390, height: 844)
        let videoSize = CGSize(width: 1_920, height: 1_080)
        let normalizedBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let normalizedOriginal = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
        let normalizedStart = CGPoint(x: 0.15, y: 0.25)
        let normalizedEnd = CGPoint(x: 0.95, y: 0.95)
        let normalizedMinimum = try XCTUnwrap(
            FocusedWindowResizeGeometry.minimumRetainedSize(
                for: normalizedOriginal
            )
        )
        let normalizedProposal = try XCTUnwrap(
            FocusedWindowResizeGeometry.proposedFrame(
                original: normalizedOriginal,
                start: normalizedStart,
                end: normalizedEnd,
                bounds: normalizedBounds,
                minimumSize: normalizedMinimum,
                containmentTolerance: 0
            )
        )

        XCTAssertEqual(
            normalizedProposal.frame.width,
            normalizedOriginal.width
                * FocusedWindowResizeGeometry.minimumRetainedFraction,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            normalizedProposal.frame.height,
            normalizedOriginal.height
                * FocusedWindowResizeGeometry.minimumRetainedFraction,
            accuracy: 0.000_001
        )

        let viewBounds = try XCTUnwrap(
            AspectFitCoordinateMapper.visibleVideoRect(
                containerSize: containerSize,
                videoSize: videoSize
            )
        )
        let viewOriginal = try XCTUnwrap(
            AspectFitCoordinateMapper.viewRect(
                forNormalizedRect: normalizedOriginal,
                containerSize: containerSize,
                videoSize: videoSize
            )
        )
        func viewPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: viewBounds.minX + point.x * viewBounds.width,
                y: viewBounds.minY + point.y * viewBounds.height
            )
        }
        let viewProposal = try XCTUnwrap(
            FocusedWindowResizeGeometry.proposedFrame(
                original: viewOriginal,
                start: viewPoint(normalizedStart),
                end: viewPoint(normalizedEnd),
                bounds: viewBounds,
                minimumSize: try XCTUnwrap(
                    FocusedWindowResizeGeometry.minimumRetainedSize(
                        for: viewOriginal
                    )
                ),
                containmentTolerance: 0
            )
        )
        let mappedNormalizedProposal = try XCTUnwrap(
            AspectFitCoordinateMapper.viewRect(
                forNormalizedRect: normalizedProposal.frame,
                containerSize: containerSize,
                videoSize: videoSize
            )
        )

        XCTAssertEqual(
            viewProposal.frame.minX,
            mappedNormalizedProposal.minX,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            viewProposal.frame.minY,
            mappedNormalizedProposal.minY,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            viewProposal.frame.width,
            mappedNormalizedProposal.width,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            viewProposal.frame.height,
            mappedNormalizedProposal.height,
            accuracy: 0.000_001
        )
    }

    @MainActor
    func testNativeGestureSurfaceInstallsOneAuthoritativeRecognizer() {
        let trackIdentity = NSObject()
        var invalidationCount = 0
        let configuration = RemotePointerGestureConfiguration(
            presentationID: UUID(),
            inputSessionID: UUID(),
            trackIdentity: ObjectIdentifier(trackIdentity),
            containerSize: CGSize(width: 390, height: 844),
            videoSize: CGSize(width: 1_080, height: 2_340),
            allowsPrimaryDrag: true,
            allowsScroll: false
        )
        let surface = RemotePointerGestureSurface(
            configuration: configuration,
            onTap: { _ in },
            onScrollBegan: { _ in nil },
            onScrollChanged: { _, _ in },
            onScrollEnded: { _ in },
            onScrollCancelled: { _ in },
            onPrimaryDrag: { _, _ in },
            onConfigurationInvalidated: { invalidationCount += 1 }
        )
        let coordinator = surface.makeCoordinator()
        let view = UIView(frame: .zero)
        coordinator.install(on: view)

        XCTAssertEqual(view.gestureRecognizers?.count, 1)
        XCTAssertEqual(
            coordinator.debugRecognizerConfiguration,
            RemotePointerGestureRecognizerDebugSnapshot(
                recognizerCount: 1,
                movementThreshold: 12,
                holdDuration: 0.35,
                allowsScroll: false,
                allowsPrimaryDrag: true
            )
        )

        coordinator.update(
            from: RemotePointerGestureSurface(
                configuration: RemotePointerGestureConfiguration(
                    presentationID: configuration.presentationID,
                    inputSessionID: configuration.inputSessionID,
                    trackIdentity: configuration.trackIdentity,
                    containerSize: configuration.containerSize,
                    videoSize: configuration.videoSize,
                    allowsPrimaryDrag: configuration.allowsPrimaryDrag,
                    allowsScroll: true
                ),
                onTap: surface.onTap,
                onScrollBegan: surface.onScrollBegan,
                onScrollChanged: surface.onScrollChanged,
                onScrollEnded: surface.onScrollEnded,
                onScrollCancelled: surface.onScrollCancelled,
                onPrimaryDrag: surface.onPrimaryDrag,
                onConfigurationInvalidated: surface.onConfigurationInvalidated
            )
        )

        XCTAssertEqual(invalidationCount, 1)
        XCTAssertEqual(view.gestureRecognizers?.count, 1)
        XCTAssertTrue(coordinator.debugRecognizerConfiguration.allowsScroll)
        XCTAssertTrue(coordinator.debugRecognizerConfiguration.allowsPrimaryDrag)
    }

    func testUnifiedGestureReleaseBelowThresholdIsTapBeforeDeadline() {
        var machine = RemotePointerGestureStateMachine(
            allowsScroll: true,
            allowsPrimaryDrag: true
        )

        XCTAssertEqual(machine.begin(at: .zero, timestamp: 0), [])
        XCTAssertEqual(
            machine.move(to: CGPoint(x: 11.99, y: 0), timestamp: 0.349),
            []
        )
        XCTAssertEqual(
            machine.end(at: CGPoint(x: 11.99, y: 0), timestamp: 0.349),
            [.tap(CGPoint(x: 11.99, y: 0))]
        )
    }

    func testUnifiedGestureExactThresholdStartsScrollBeforeDeadline() {
        var machine = RemotePointerGestureStateMachine(
            allowsScroll: true,
            allowsPrimaryDrag: true
        )

        XCTAssertEqual(machine.begin(at: .zero, timestamp: 0), [])
        XCTAssertEqual(
            machine.move(to: CGPoint(x: 12, y: 0), timestamp: 0.349),
            [
                .scrollBegan(.zero),
                .scrollChanged(CGSize(width: 12, height: 0)),
            ]
        )
        XCTAssertEqual(
            machine.end(at: CGPoint(x: 12, y: 0), timestamp: 0.349),
            [.scrollEnded]
        )
    }

    func testUnifiedGestureExactMovementAndHoldBoundaryLetsMovementWin() {
        var machine = RemotePointerGestureStateMachine(
            allowsScroll: true,
            allowsPrimaryDrag: true
        )

        XCTAssertEqual(machine.begin(at: .zero, timestamp: 0), [])
        XCTAssertEqual(
            machine.move(to: CGPoint(x: 12, y: 0), timestamp: 0.35),
            [
                .scrollBegan(.zero),
                .scrollChanged(CGSize(width: 12, height: 0)),
            ]
        )
        XCTAssertEqual(machine.phase, .scrolling)
    }

    func testUnifiedGestureEndOnlyThresholdCrossingDeliversCompleteScroll() {
        var machine = RemotePointerGestureStateMachine(
            allowsScroll: true,
            allowsPrimaryDrag: true
        )

        XCTAssertEqual(machine.begin(at: .zero, timestamp: 0), [])
        XCTAssertEqual(
            machine.end(at: CGPoint(x: 13, y: 0), timestamp: 0.2),
            [
                .scrollBegan(.zero),
                .scrollChanged(CGSize(width: 13, height: 0)),
                .scrollEnded,
            ]
        )
    }

    func testUnifiedGestureBothCapabilitiesScrollBeforeDeadlineAndDragAfterIt() {
        var scrollMachine = RemotePointerGestureStateMachine(
            allowsScroll: true,
            allowsPrimaryDrag: true
        )
        XCTAssertEqual(scrollMachine.begin(at: .zero, timestamp: 0), [])
        XCTAssertTrue(scrollMachine.shouldScheduleHoldDeadline)
        XCTAssertEqual(
            scrollMachine.move(to: CGPoint(x: 12.01, y: 0), timestamp: 0.349),
            [
                .scrollBegan(.zero),
                .scrollChanged(CGSize(width: 12.01, height: 0)),
            ]
        )
        XCTAssertFalse(scrollMachine.shouldScheduleHoldDeadline)

        var dragMachine = RemotePointerGestureStateMachine(
            allowsScroll: true,
            allowsPrimaryDrag: true
        )
        XCTAssertEqual(dragMachine.begin(at: .zero, timestamp: 0), [])
        XCTAssertEqual(
            dragMachine.move(to: CGPoint(x: 4, y: 0), timestamp: 0.35),
            [.primaryDragArmed(.zero)]
        )
        XCTAssertEqual(
            dragMachine.move(to: CGPoint(x: 40, y: 0), timestamp: 0.4),
            []
        )
        XCTAssertEqual(
            dragMachine.end(at: CGPoint(x: 80, y: 0), timestamp: 0.5),
            [.primaryDrag(start: .zero, end: CGPoint(x: 80, y: 0))]
        )
    }

    func testUnifiedGestureScrollOnlyNeverArmsHoldAndCanScrollLater() {
        var machine = RemotePointerGestureStateMachine(
            allowsScroll: true,
            allowsPrimaryDrag: false
        )

        XCTAssertEqual(machine.begin(at: .zero, timestamp: 0), [])
        XCTAssertFalse(machine.shouldScheduleHoldDeadline)
        XCTAssertEqual(
            machine.move(to: CGPoint(x: 5, y: 0), timestamp: 1),
            []
        )
        XCTAssertEqual(
            machine.move(to: CGPoint(x: 13, y: 0), timestamp: 2),
            [
                .scrollBegan(.zero),
                .scrollChanged(CGSize(width: 13, height: 0)),
            ]
        )
    }

    func testUnifiedGestureDragOnlyMovementBeforeHoldProducesNoAction() {
        var machine = RemotePointerGestureStateMachine(
            allowsScroll: false,
            allowsPrimaryDrag: true
        )

        XCTAssertEqual(machine.begin(at: .zero, timestamp: 0), [])
        XCTAssertTrue(machine.shouldScheduleHoldDeadline)
        XCTAssertEqual(
            machine.move(to: CGPoint(x: 13, y: 0), timestamp: 0.2),
            []
        )
        XCTAssertEqual(machine.phase, .suppressed)
        XCTAssertFalse(machine.shouldScheduleHoldDeadline)
        XCTAssertEqual(
            machine.end(at: CGPoint(x: 20, y: 0), timestamp: 0.4),
            []
        )
    }

    func testUnifiedGestureNeitherCapabilityStillPermitsStationaryTap() {
        var machine = RemotePointerGestureStateMachine(
            allowsScroll: false,
            allowsPrimaryDrag: false
        )

        XCTAssertEqual(machine.begin(at: CGPoint(x: 7, y: 9), timestamp: 0), [])
        XCTAssertFalse(machine.shouldScheduleHoldDeadline)
        XCTAssertEqual(
            machine.end(at: CGPoint(x: 7, y: 9), timestamp: 2),
            [.tap(CGPoint(x: 7, y: 9))]
        )
    }

    func testUnifiedGestureCancellationTerminatesActiveScroll() {
        var machine = RemotePointerGestureStateMachine(
            allowsScroll: true,
            allowsPrimaryDrag: true
        )

        XCTAssertEqual(machine.begin(at: .zero, timestamp: 0), [])
        XCTAssertFalse(
            machine.move(to: CGPoint(x: 13, y: 0), timestamp: 0.2).isEmpty
        )
        XCTAssertEqual(machine.cancel(), [.scrollCancelled])
        XCTAssertEqual(machine.phase, .cancelled)
        XCTAssertEqual(
            machine.end(at: CGPoint(x: 20, y: 0), timestamp: 0.3),
            []
        )
    }

    func testResizeModeTapSelectsWindowWithoutHoldOrOrdinaryTap() {
        var machine = RemotePointerGestureStateMachine(
            allowsScroll: true,
            allowsPrimaryDrag: true,
            interactionMode: .focusedWindowResize(target: nil)
        )

        XCTAssertEqual(machine.begin(at: CGPoint(x: 40, y: 50), timestamp: 0), [])
        XCTAssertFalse(machine.shouldScheduleHoldDeadline)
        XCTAssertEqual(machine.holdDeadlineReached(), [])
        XCTAssertEqual(
            machine.end(at: CGPoint(x: 45, y: 52), timestamp: 1),
            [.focusedWindowSelection(CGPoint(x: 45, y: 52))]
        )
    }

    func testResizeModeEndOnlyThresholdCrossingPreviewsThenCommitsExactlyOnce() {
        let generation = UUID()
        let target = RemotePointerResizeTarget(
            generation: generation,
            viewFrame: CGRect(x: 20, y: 20, width: 100, height: 100)
        )
        var machine = RemotePointerGestureStateMachine(
            allowsScroll: true,
            allowsPrimaryDrag: true,
            interactionMode: .focusedWindowResize(target: target)
        )
        let start = CGPoint(x: 30, y: 30)
        let end = CGPoint(x: 42, y: 30)

        XCTAssertEqual(machine.begin(at: start, timestamp: 0), [])
        XCTAssertEqual(
            machine.end(at: end, timestamp: 0.1),
            [
                .focusedWindowResizePreview(
                    targetGeneration: generation,
                    start: start,
                    end: end
                ),
                .focusedWindowResizeCommit(
                    targetGeneration: generation,
                    start: start,
                    end: end
                ),
            ]
        )
        XCTAssertEqual(machine.end(at: end, timestamp: 0.2), [])
    }

    func testResizeModeDragOutsideTargetSuppressesSelectionScrollAndCommit() {
        let target = RemotePointerResizeTarget(
            generation: UUID(),
            viewFrame: CGRect(x: 20, y: 20, width: 100, height: 100)
        )
        var machine = RemotePointerGestureStateMachine(
            allowsScroll: true,
            allowsPrimaryDrag: true,
            interactionMode: .focusedWindowResize(target: target)
        )

        XCTAssertEqual(machine.begin(at: .zero, timestamp: 0), [])
        XCTAssertEqual(machine.move(to: CGPoint(x: 12, y: 0), timestamp: 0.1), [])
        XCTAssertEqual(machine.phase, .suppressed)
        XCTAssertEqual(machine.end(at: CGPoint(x: 20, y: 0), timestamp: 0.2), [])
    }

    func testResizeModeCancellationAfterPreviewCannotCommit() {
        let generation = UUID()
        let start = CGPoint(x: 30, y: 30)
        let target = RemotePointerResizeTarget(
            generation: generation,
            viewFrame: CGRect(x: 20, y: 20, width: 100, height: 100)
        )
        var machine = RemotePointerGestureStateMachine(
            allowsScroll: true,
            allowsPrimaryDrag: true,
            interactionMode: .focusedWindowResize(target: target)
        )

        XCTAssertEqual(machine.begin(at: start, timestamp: 0), [])
        XCTAssertEqual(
            machine.move(to: CGPoint(x: 43, y: 30), timestamp: 0.1),
            [
                .focusedWindowResizePreview(
                    targetGeneration: generation,
                    start: start,
                    end: CGPoint(x: 43, y: 30)
                ),
            ]
        )
        XCTAssertEqual(machine.cancel(), [.focusedWindowResizeCancelled])
        XCTAssertEqual(machine.end(at: CGPoint(x: 60, y: 30), timestamp: 0.2), [])
    }

    @MainActor
    func testResizeTargetUpdateKeepsOneRecognizerWithoutOwnershipInvalidation() {
        let trackIdentity = NSObject()
        var invalidationCount = 0
        let base = RemotePointerGestureConfiguration(
            presentationID: UUID(),
            inputSessionID: UUID(),
            trackIdentity: ObjectIdentifier(trackIdentity),
            containerSize: CGSize(width: 390, height: 844),
            videoSize: CGSize(width: 1_080, height: 2_340),
            allowsPrimaryDrag: true,
            allowsScroll: true,
            interactionMode: .focusedWindowResize(target: nil)
        )
        let surface = RemotePointerGestureSurface(
            configuration: base,
            onTap: { _ in },
            onScrollBegan: { _ in nil },
            onScrollChanged: { _, _ in },
            onScrollEnded: { _ in },
            onScrollCancelled: { _ in },
            onPrimaryDrag: { _, _ in },
            onConfigurationInvalidated: { invalidationCount += 1 }
        )
        let coordinator = surface.makeCoordinator()
        let view = UIView(frame: .zero)
        coordinator.install(on: view)
        let target = RemotePointerResizeTarget(
            generation: UUID(),
            viewFrame: CGRect(x: 20, y: 20, width: 100, height: 100)
        )

        coordinator.update(
            from: RemotePointerGestureSurface(
                configuration: RemotePointerGestureConfiguration(
                    presentationID: base.presentationID,
                    inputSessionID: base.inputSessionID,
                    trackIdentity: base.trackIdentity,
                    containerSize: base.containerSize,
                    videoSize: base.videoSize,
                    allowsPrimaryDrag: base.allowsPrimaryDrag,
                    allowsScroll: base.allowsScroll,
                    interactionMode: .focusedWindowResize(target: target)
                ),
                onTap: surface.onTap,
                onScrollBegan: surface.onScrollBegan,
                onScrollChanged: surface.onScrollChanged,
                onScrollEnded: surface.onScrollEnded,
                onScrollCancelled: surface.onScrollCancelled,
                onPrimaryDrag: surface.onPrimaryDrag,
                onConfigurationInvalidated: surface.onConfigurationInvalidated
            )
        )

        XCTAssertEqual(invalidationCount, 0)
        XCTAssertEqual(view.gestureRecognizers?.count, 1)
    }
}
