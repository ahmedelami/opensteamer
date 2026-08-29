import CoreGraphics
import Foundation
import XCTest
@testable import CaptureCore

/// Specifies the security boundary between authenticated remote-control messages and macOS input.
///
/// The suite uses an in-memory accessibility/event backend so it can prove fail-closed behavior
/// without requesting TCC access or posting real input. Its central oracle is that a command is
/// injected only while permission, display, Show generation, input session, and exact nonsecure
/// focus all remain valid. Rejected commands must not leave reusable keyboard authority behind.
final class MacRemoteInputControllerTests: XCTestCase {
    // Stable synthetic identifiers make generation/session mismatches explicit in each fixture;
    // they are test values, not production device identifiers or credentials.
    private let displayID: UInt32 = 42
    private let showID: UInt64 = 73
    private let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    // MARK: - Capability activation and coordinate validation

    func testControllerIsFailClosedUntilExplicitlyEnabledAndArmed() {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        let controller = MacRemoteInputController(
            allowRemoteControl: false,
            system: system,
            clock: clock
        )

        XCTAssertEqual(
            controller.arm(displayID: displayID, screenRequestID: showID, inputSessionID: sessionID),
            .disabled
        )
        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: .init(x: 0.5, y: 0.5)
            ),
            .rejected(.disabled)
        )
        XCTAssertTrue(system.postedMousePoints.isEmpty)
    }

    func testArmRequiresBothTCCGrantsAndAnActiveDisplay() {
        let system = MockMacRemoteInputSystem()
        let controller = makeController(system: system)

        system.permissions = .init(accessibilityTrusted: true, postEventAllowed: false)
        XCTAssertEqual(
            controller.arm(displayID: displayID, screenRequestID: showID, inputSessionID: sessionID),
            .permissionRequired(system.permissions)
        )

        system.permissions = .init(accessibilityTrusted: true, postEventAllowed: true)
        system.bounds = nil
        XCTAssertEqual(
            controller.arm(displayID: displayID, screenRequestID: showID, inputSessionID: sessionID),
            .displayUnavailable
        )

        system.bounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        XCTAssertEqual(
            controller.arm(displayID: displayID, screenRequestID: showID, inputSessionID: sessionID),
            .armed
        )
    }

    func testTapMapsThroughNegativeGlobalDisplayOriginWithoutYFlip() {
        let system = MockMacRemoteInputSystem()
        system.bounds = CGRect(x: -1_920, y: -400, width: 1_920, height: 1_080)
        let controller = armedController(system: system)

        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: .init(x: 0.25, y: 0.75),
                viewerVideoSize: .init(width: 1_920, height: 1_080)
            ),
            .accepted(.none)
        )
        XCTAssertEqual(system.postedMousePoints.count, 1)
        XCTAssertEqual(system.postedMousePoints[0].x, -1_440, accuracy: 0.0001)
        XCTAssertEqual(system.postedMousePoints[0].y, 410, accuracy: 0.0001)
    }

    func testFreshCaptureBoundsOverrideStaleOwnerProcessBounds() throws {
        let system = MockMacRemoteInputSystem()
        // Reproduces the virtual-display owner's cached pre-transition Core Graphics mode.
        system.bounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let clock = MockMacRemoteInputClock()
        let controller = MacRemoteInputController(
            allowRemoteControl: true,
            system: system,
            clock: clock
        )
        XCTAssertEqual(
            controller.arm(
                displayID: displayID,
                screenRequestID: showID,
                inputSessionID: sessionID,
                authoritativeDisplayBounds: CGRect(x: 0, y: 0, width: 603, height: 1_311)
            ),
            .armed
        )
        let geometry = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_206,
                surfaceHeight: 2_622,
                contentRect: CGRect(x: 0, y: 0, width: 603, height: 1_311),
                contentScale: 1,
                scaleFactor: 2
            )
        )
        stabilize(geometry, on: controller, clock: clock)

        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: .init(x: 0.25, y: 0.75),
                viewerVideoSize: .init(width: 1_206, height: 2_622)
            ),
            .accepted(.none)
        )
        let posted = try XCTUnwrap(system.postedMousePoints.last)
        XCTAssertEqual(posted.x, 150.75, accuracy: 0.000_1)
        XCTAssertEqual(posted.y, 983.25, accuracy: 0.000_1)
    }

    func testFreshCaptureBoundsUpdateFencesAndThenMapsLiveModeChange() throws {
        let system = MockMacRemoteInputSystem()
        system.bounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let clock = MockMacRemoteInputClock()
        let controller = MacRemoteInputController(
            allowRemoteControl: true,
            system: system,
            clock: clock
        )
        XCTAssertEqual(
            controller.arm(
                displayID: displayID,
                screenRequestID: showID,
                inputSessionID: sessionID,
                authoritativeDisplayBounds: CGRect(x: 0, y: 0, width: 540, height: 1_170)
            ),
            .armed
        )
        let oldGeometry = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 2_340,
                contentRect: CGRect(x: 0, y: 0, width: 540, height: 1_170),
                contentScale: 1,
                scaleFactor: 2
            )
        )
        stabilize(oldGeometry, on: controller, clock: clock)
        XCTAssertEqual(
            tap(controller, viewerVideoSize: .init(width: 1_080, height: 2_340)),
            .accepted(.none)
        )

        controller.updateAuthoritativeDisplayBounds(
            CGRect(x: 0, y: 0, width: 603, height: 1_311),
            for: displayID
        )
        XCTAssertEqual(
            tap(controller, viewerVideoSize: .init(width: 1_206, height: 2_622)),
            .rejected(.screenFormatChanging)
        )

        let newGeometry = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_206,
                surfaceHeight: 2_622,
                contentRect: CGRect(x: 0, y: 0, width: 603, height: 1_311),
                contentScale: 1,
                scaleFactor: 2
            )
        )
        stabilize(newGeometry, on: controller, clock: clock)
        XCTAssertEqual(
            tap(controller, viewerVideoSize: .init(width: 1_206, height: 2_622)),
            .accepted(.none)
        )
        let posted = try XCTUnwrap(system.postedMousePoints.last)
        XCTAssertEqual(posted.x, 301.5, accuracy: 0.000_1)
        XCTAssertEqual(posted.y, 655.5, accuracy: 0.000_1)
    }

    func testArmRejectsMalformedAuthoritativeDisplayBounds() {
        let system = MockMacRemoteInputSystem()
        let controller = makeController(system: system)

        XCTAssertEqual(
            controller.arm(
                displayID: displayID,
                screenRequestID: showID,
                inputSessionID: sessionID,
                authoritativeDisplayBounds: CGRect(
                    x: 0,
                    y: 0,
                    width: CGFloat.nan,
                    height: 1_311
                )
            ),
            .displayUnavailable
        )
        XCTAssertEqual(
            tap(controller, viewerVideoSize: .init(width: 1_206, height: 2_622)),
            .rejected(.staleSession)
        )
    }

    func testBottomRightNormalizedEdgeStaysInsideCapturedDisplay() {
        let system = MockMacRemoteInputSystem()
        system.bounds = CGRect(x: 1_920, y: -200, width: 1_280, height: 720)
        let controller = armedController(system: system)

        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: .init(x: 1, y: 1),
                viewerVideoSize: .init(width: 1_280, height: 720)
            ),
            .accepted(.none)
        )
        let posted = try! XCTUnwrap(system.postedMousePoints.first)
        XCTAssertGreaterThanOrEqual(posted.x, system.bounds!.minX)
        XCTAssertGreaterThanOrEqual(posted.y, system.bounds!.minY)
        XCTAssertLessThan(posted.x, system.bounds!.maxX)
        XCTAssertLessThan(posted.y, system.bounds!.maxY)
    }

    func testTapRejectsNonFiniteAndOutOfRangePointsWithoutInjection() {
        let system = MockMacRemoteInputSystem()
        let controller = armedController(system: system)

        for point in [
            MacRemoteNormalizedPoint(x: -.infinity, y: 0),
            MacRemoteNormalizedPoint(x: .nan, y: 0),
            MacRemoteNormalizedPoint(x: -0.001, y: 0.5),
            MacRemoteNormalizedPoint(x: 0.5, y: 1.001)
        ] {
            XCTAssertEqual(
                controller.handleTap(
                    screenRequestID: showID,
                    inputSessionID: sessionID,
                    normalizedPoint: point
                ),
                .rejected(.invalidPoint)
            )
        }
        XCTAssertTrue(system.postedMousePoints.isEmpty)
    }

    func testTapMapsThroughLivePillarboxInsteadOfStartupCanvas() throws {
        let system = MockMacRemoteInputSystem()
        system.bounds = CGRect(x: 100, y: -50, width: 414, height: 896)
        let clock = MockMacRemoteInputClock()
        let controller = armedController(system: system, clock: clock)
        let geometry = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 48, y: 0, width: 444, height: 960),
                contentScale: 1,
                scaleFactor: 2
            )
        )
        stabilize(geometry, on: controller, clock: clock)

        let framePoint = MacRemoteNormalizedPoint(
            x: (96 + (888 * 0.25)) / 1_080,
            y: 0.75
        )
        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: framePoint,
                viewerVideoSize: .init(width: 1_080, height: 1_920)
            ),
            .accepted(.none)
        )
        let posted = try XCTUnwrap(system.postedMousePoints.last)
        XCTAssertEqual(posted.x, 203.5, accuracy: 0.000_1)
        XCTAssertEqual(posted.y, 622, accuracy: 0.000_1)

        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: .init(x: 0.05, y: 0.5),
                viewerVideoSize: .init(width: 1_080, height: 1_920)
            ),
            .rejected(.invalidPoint)
        )
        XCTAssertEqual(system.postedMousePoints.count, 1)
    }

    func testTapRejectsMissingOrStaleCrossAspectFrameGeometry() throws {
        let system = MockMacRemoteInputSystem()
        system.bounds = CGRect(x: 0, y: 0, width: 603, height: 1_311)
        let controller = armedController(system: system)

        controller.updateScreenVideoFrameGeometry(nil)
        XCTAssertEqual(
            tap(controller, viewerVideoSize: .init(width: 1_206, height: 2_622)),
            .rejected(.screenFormatChanging)
        )

        let stale = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 0, y: 0, width: 1_080, height: 1_920),
                contentScale: 1,
                scaleFactor: 1
            )
        )
        controller.updateScreenVideoFrameGeometry(stale)
        XCTAssertEqual(
            tap(controller, viewerVideoSize: .init(width: 1_080, height: 1_920)),
            .rejected(.screenFormatChanging)
        )
        XCTAssertTrue(system.postedMousePoints.isEmpty)
    }

    func testTapAcceptsAdaptedViewerFrameButRejectsDifferentPortraitAspect() throws {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        system.bounds = CGRect(x: 0, y: 0, width: 301, height: 655)
        let controller = armedController(system: system, clock: clock)
        let geometry = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 602,
                surfaceHeight: 1_310,
                contentRect: CGRect(x: 0, y: 0, width: 602, height: 1_310),
                contentScale: 1,
                scaleFactor: 1
            )
        )
        stabilize(geometry, on: controller, clock: clock)

        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: .init(x: 0.5, y: 0.5),
                // Still portrait, but this old 16:9 frame is materially different from the
                // current 602x1310 display shape.
                viewerVideoSize: .init(width: 1_080, height: 1_920)
            ),
            .rejected(.screenFormatChanging)
        )
        XCTAssertTrue(system.postedMousePoints.isEmpty)

        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: .init(x: 0.5, y: 0.5),
                // WebRTC's 3/4 adaptation aligns each edge independently, so this is a
                // legitimate portrait presentation without exact source-aspect equality.
                viewerVideoSize: .init(width: 450, height: 981)
            ),
            .accepted(.none)
        )
        XCTAssertEqual(system.postedMousePoints, [CGPoint(x: 150.5, y: 327.5)])
    }

    func testPointerActionsWithoutRenderedViewerSizeFailClosed() {
        let system = MockMacRemoteInputSystem()
        let controller = armedController(system: system)

        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: .init(x: 0.5, y: 0.5)
            ),
            .rejected(.screenFormatChanging)
        )
        XCTAssertEqual(
            controller.handlePrimaryDrag(
                screenRequestID: showID,
                inputSessionID: sessionID,
                start: .init(x: 0.25, y: 0.25),
                end: .init(x: 0.75, y: 0.75)
            ),
            .rejected(.screenFormatChanging)
        )
        XCTAssertTrue(system.postedMousePoints.isEmpty)
        XCTAssertTrue(system.postedDragEvents.isEmpty)
    }

    func testDiagnosedPointerResultIdentifiesExactFormatFence() throws {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        system.bounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let controller = armedController(system: system, clock: clock)

        var outcome = controller.handleTapWithDiagnostics(
            screenRequestID: showID,
            inputSessionID: sessionID,
            normalizedPoint: .init(x: 0.25, y: 0.75)
        )
        XCTAssertEqual(outcome.result, .rejected(.screenFormatChanging))
        XCTAssertEqual(outcome.screenFormatDiagnostic?.reason, .viewerSizeMissing)
        XCTAssertFalse(outcome.screenFormatDiagnostic?.stableGeometryAvailable == true)
        XCTAssertTrue(outcome.screenFormatDiagnostic?.candidateGeometryAvailable == true)
        XCTAssertEqual(outcome.screenFormatDiagnostic?.candidateAgeMilliseconds, 750)

        controller.updateScreenVideoFrameGeometry(nil)
        outcome = controller.handleTapWithDiagnostics(
            screenRequestID: showID,
            inputSessionID: sessionID,
            normalizedPoint: .init(x: 0.25, y: 0.75),
            viewerVideoSize: .init(width: 1_920, height: 1_080)
        )
        XCTAssertEqual(
            outcome.screenFormatDiagnostic?.reason,
            .frameGeometryUnavailableOrUnstable
        )
        XCTAssertFalse(outcome.screenFormatDiagnostic?.stableGeometryAvailable == true)

        let staleLandscape = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_920,
                surfaceHeight: 1_080,
                contentRect: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
                contentScale: 1,
                scaleFactor: 1
            )
        )
        stabilize(staleLandscape, on: controller, clock: clock)
        system.bounds = CGRect(x: 0, y: 0, width: 1_080, height: 1_920)
        outcome = controller.handleTapWithDiagnostics(
            screenRequestID: showID,
            inputSessionID: sessionID,
            normalizedPoint: .init(x: 0.25, y: 0.75),
            viewerVideoSize: .init(width: 1_920, height: 1_080)
        )
        XCTAssertEqual(
            outcome.screenFormatDiagnostic?.reason,
            .displayGeometryIncompatible
        )

        system.bounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        outcome = controller.handleTapWithDiagnostics(
            screenRequestID: showID,
            inputSessionID: sessionID,
            normalizedPoint: .init(x: 0.25, y: 0.75),
            viewerVideoSize: .init(width: 1_000, height: 1_000)
        )
        XCTAssertEqual(outcome.screenFormatDiagnostic?.reason, .viewerAspectMismatch)
        XCTAssertGreaterThan(
            outcome.screenFormatDiagnostic?.viewerAspectRelativeDifference ?? 0,
            0.4
        )
        XCTAssertTrue(system.postedMousePoints.isEmpty)
    }

    func testEveryAdvertisedModeMapsRelativeCoordinatesIntoItsLiveBounds() throws {
        let modes: [(logical: CGSize, pixels: CGSize)] = [
            (.init(width: 540, height: 960), .init(width: 540, height: 960)),
            (.init(width: 603, height: 1_312), .init(width: 602, height: 1_310)),
            (.init(width: 640, height: 480), .init(width: 640, height: 480)),
            (.init(width: 640, height: 1_392), .init(width: 640, height: 1_392)),
            (.init(width: 720, height: 1_280), .init(width: 720, height: 1_280)),
            (.init(width: 750, height: 1_334), .init(width: 750, height: 1_334)),
            (.init(width: 400, height: 300), .init(width: 800, height: 600)),
            (.init(width: 800, height: 600), .init(width: 800, height: 600)),
            (.init(width: 400, height: 870), .init(width: 800, height: 1_740)),
            (.init(width: 800, height: 1_740), .init(width: 800, height: 1_740)),
            (.init(width: 405, height: 720), .init(width: 810, height: 1_440)),
            (.init(width: 810, height: 1_440), .init(width: 810, height: 1_440)),
            (.init(width: 414, height: 896), .init(width: 828, height: 1_792)),
            (.init(width: 828, height: 1_792), .init(width: 828, height: 1_792)),
            (.init(width: 450, height: 800), .init(width: 900, height: 1_600)),
            (.init(width: 900, height: 1_600), .init(width: 900, height: 1_600)),
            (.init(width: 512, height: 384), .init(width: 1_024, height: 768)),
            (.init(width: 1_024, height: 768), .init(width: 1_024, height: 768)),
            (.init(width: 512, height: 1_113), .init(width: 1_024, height: 2_226)),
            (.init(width: 1_024, height: 2_226), .init(width: 1_024, height: 2_226)),
            (.init(width: 540, height: 960), .init(width: 1_080, height: 1_920)),
            (.init(width: 1_080, height: 1_920), .init(width: 1_080, height: 1_920)),
            (.init(width: 540, height: 1_170), .init(width: 1_080, height: 2_340)),
            (.init(width: 1_080, height: 2_340), .init(width: 1_080, height: 2_340)),
            (.init(width: 603, height: 1_311), .init(width: 1_206, height: 2_622)),
            (.init(width: 1_206, height: 2_622), .init(width: 1_206, height: 2_622)),
            (.init(width: 640, height: 480), .init(width: 1_280, height: 960)),
            (.init(width: 672, height: 504), .init(width: 1_344, height: 1_008)),
            (.init(width: 800, height: 600), .init(width: 1_600, height: 1_200))
        ]

        for mode in modes {
            let system = MockMacRemoteInputSystem()
            let clock = MockMacRemoteInputClock()
            system.bounds = CGRect(
                x: -mode.logical.width,
                y: 200,
                width: mode.logical.width,
                height: mode.logical.height
            )
            let controller = armedController(system: system, clock: clock)
            let geometry = try XCTUnwrap(
                ScreenVideoFrameGeometry(
                    surfaceWidth: Int(mode.pixels.width),
                    surfaceHeight: Int(mode.pixels.height),
                    contentRect: CGRect(origin: .zero, size: mode.pixels),
                    contentScale: 1,
                    scaleFactor: 1
                )
            )
            stabilize(geometry, on: controller, clock: clock)

            XCTAssertEqual(
                controller.handleTap(
                    screenRequestID: showID,
                    inputSessionID: sessionID,
                    normalizedPoint: .init(x: 0.25, y: 0.75),
                    viewerVideoSize: .init(
                        width: Int(mode.pixels.width),
                        height: Int(mode.pixels.height)
                    )
                ),
                .accepted(.none),
                "Rejected advertised mode \(mode)"
            )
            let posted = try XCTUnwrap(system.postedMousePoints.last)
            XCTAssertEqual(
                posted.x,
                system.bounds!.minX + (mode.logical.width * 0.25),
                accuracy: 0.000_1
            )
            XCTAssertEqual(
                posted.y,
                system.bounds!.minY + (mode.logical.height * 0.75),
                accuracy: 0.000_1
            )
        }
    }

    func testChangedFrameGeometryFailsClosedUntilTheNewTransformIsStable() throws {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        system.bounds = CGRect(x: 0, y: 0, width: 540, height: 960)
        let controller = armedController(system: system, clock: clock)
        XCTAssertEqual(
            tap(controller, viewerVideoSize: .init(width: 540, height: 960)),
            .accepted(.none)
        )
        XCTAssertEqual(system.postedMousePoints.count, 1)

        system.bounds = CGRect(x: 0, y: 0, width: 414, height: 896)
        let changedGeometry = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 48, y: 0, width: 444, height: 960),
                contentScale: 1,
                scaleFactor: 2
            )
        )
        controller.updateScreenVideoFrameGeometry(changedGeometry)
        XCTAssertEqual(
            tap(controller, viewerVideoSize: .init(width: 1_080, height: 1_920)),
            .rejected(.screenFormatChanging)
        )

        clock.advance(by: 0.749)
        controller.updateScreenVideoFrameGeometry(changedGeometry)
        XCTAssertEqual(
            tap(controller, viewerVideoSize: .init(width: 1_080, height: 1_920)),
            .rejected(.screenFormatChanging)
        )

        clock.advance(by: 0.001)
        controller.updateScreenVideoFrameGeometry(changedGeometry)
        let framePoint = MacRemoteNormalizedPoint(
            x: (96 + (888 * 0.5)) / 1_080,
            y: 0.5
        )
        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: framePoint,
                viewerVideoSize: .init(width: 1_080, height: 1_920)
            ),
            .accepted(.none)
        )
        XCTAssertEqual(system.postedMousePoints.count, 2)
        XCTAssertEqual(system.postedMousePoints.last, CGPoint(x: 207, y: 448))
    }

    func testPortraitToLandscapeReplacementRecoversNoncentralMapping() throws {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        system.bounds = CGRect(x: 100, y: -50, width: 540, height: 1_170)
        let controller = MacRemoteInputController(
            allowRemoteControl: true,
            system: system,
            clock: clock
        )
        XCTAssertEqual(
            controller.arm(
                displayID: displayID,
                screenRequestID: showID,
                inputSessionID: sessionID
            ),
            .armed
        )
        let portraitGeometry = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 2_340,
                contentRect: CGRect(x: 0, y: 0, width: 540, height: 1_170),
                contentScale: 1,
                scaleFactor: 2
            )
        )
        stabilize(portraitGeometry, on: controller, clock: clock)
        let noncentralPoint = MacRemoteNormalizedPoint(x: 0.25, y: 0.75)

        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: noncentralPoint,
                viewerVideoSize: .init(width: 1_080, height: 2_340)
            ),
            .accepted(.none)
        )
        let portraitPostedPoint = try XCTUnwrap(system.postedMousePoints.last)
        XCTAssertEqual(portraitPostedPoint.x, 235, accuracy: 0.000_1)
        XCTAssertEqual(portraitPostedPoint.y, 827.5, accuracy: 0.000_1)

        system.bounds = CGRect(x: -200, y: 75, width: 1_170, height: 540)
        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: noncentralPoint,
                viewerVideoSize: .init(width: 1_080, height: 2_340)
            ),
            .rejected(.screenFormatChanging)
        )
        XCTAssertEqual(system.postedMousePoints.count, 1)

        controller.updateScreenVideoFrameGeometry(nil)
        let landscapeGeometry = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 2_340,
                surfaceHeight: 1_080,
                contentRect: CGRect(x: 0, y: 0, width: 1_170, height: 540),
                contentScale: 1,
                scaleFactor: 2
            )
        )
        controller.updateScreenVideoFrameGeometry(landscapeGeometry)

        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: noncentralPoint,
                viewerVideoSize: .init(width: 2_340, height: 1_080)
            ),
            .rejected(.screenFormatChanging)
        )
        clock.advance(by: 0.749)
        controller.updateScreenVideoFrameGeometry(landscapeGeometry)
        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: noncentralPoint,
                viewerVideoSize: .init(width: 2_340, height: 1_080)
            ),
            .rejected(.screenFormatChanging)
        )
        clock.advance(by: 0.001)
        controller.updateScreenVideoFrameGeometry(landscapeGeometry)

        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: noncentralPoint,
                viewerVideoSize: .init(width: 1_080, height: 2_340)
            ),
            .rejected(.screenFormatChanging)
        )
        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: noncentralPoint,
                viewerVideoSize: .init(width: 2_340, height: 1_080)
            ),
            .accepted(.none)
        )
        XCTAssertEqual(system.postedMousePoints.count, 2)
        let landscapePostedPoint = try XCTUnwrap(system.postedMousePoints.last)
        XCTAssertEqual(landscapePostedPoint.x, 92.5, accuracy: 0.000_1)
        XCTAssertEqual(landscapePostedPoint.y, 480, accuracy: 0.000_1)
    }

    func testSingleFrameGeometryPromotesLazilyAfterStabilityInterval() throws {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        system.bounds = CGRect(x: 0, y: 0, width: 414, height: 896)
        let controller = armedController(system: system, clock: clock)
        let geometry = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 96, y: 0, width: 888, height: 1_920),
                contentScale: 1,
                scaleFactor: 1
            )
        )

        controller.updateScreenVideoFrameGeometry(geometry)
        clock.advance(by: 0.750)

        XCTAssertEqual(
            tap(controller, viewerVideoSize: .init(width: 1_080, height: 1_920)),
            .accepted(.none)
        )
        XCTAssertEqual(system.postedMousePoints.last, CGPoint(x: 207, y: 448))
    }

    func testDifferentTransformRestartsStabilityInterval() throws {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        system.bounds = CGRect(x: 0, y: 0, width: 414, height: 896)
        let controller = armedController(system: system, clock: clock)
        let firstGeometry = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 96, y: 0, width: 888, height: 1_920),
                contentScale: 1,
                scaleFactor: 1
            )
        )
        let secondGeometry = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 97, y: 0, width: 888, height: 1_920),
                contentScale: 1,
                scaleFactor: 1
            )
        )

        controller.updateScreenVideoFrameGeometry(firstGeometry)
        clock.advance(by: 0.749)
        controller.updateScreenVideoFrameGeometry(secondGeometry)
        clock.advance(by: 0.001)
        XCTAssertEqual(
            tap(controller, viewerVideoSize: .init(width: 1_080, height: 1_920)),
            .rejected(.screenFormatChanging)
        )

        clock.advance(by: 0.749)
        XCTAssertEqual(
            tap(controller, viewerVideoSize: .init(width: 1_080, height: 1_920)),
            .accepted(.none)
        )
    }

    func testClearingGeometryBeforePromotionKeepsInputClosed() throws {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        system.bounds = CGRect(x: 0, y: 0, width: 414, height: 896)
        let controller = armedController(system: system, clock: clock)
        let geometry = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 96, y: 0, width: 888, height: 1_920),
                contentScale: 1,
                scaleFactor: 1
            )
        )

        controller.updateScreenVideoFrameGeometry(geometry)
        clock.advance(by: 0.500)
        controller.updateScreenVideoFrameGeometry(nil)
        clock.advance(by: 1)

        XCTAssertEqual(
            tap(controller, viewerVideoSize: .init(width: 1_080, height: 1_920)),
            .rejected(.screenFormatChanging)
        )
        XCTAssertTrue(system.postedMousePoints.isEmpty)
    }

    func testSubpixelJitterCannotAccumulateAcrossTheStabilityBaseline() throws {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        system.bounds = CGRect(x: 0, y: 0, width: 414, height: 896)
        let controller = armedController(system: system, clock: clock)
        func geometry(x: CGFloat) throws -> ScreenVideoFrameGeometry {
            try XCTUnwrap(
                ScreenVideoFrameGeometry(
                    surfaceWidth: 1_080,
                    surfaceHeight: 1_920,
                    contentRect: CGRect(x: x, y: 0, width: 888, height: 1_920),
                    contentScale: 1,
                    scaleFactor: 1
                )
            )
        }

        controller.updateScreenVideoFrameGeometry(try geometry(x: 96))
        clock.advance(by: 0.400)
        controller.updateScreenVideoFrameGeometry(try geometry(x: 96.4))
        clock.advance(by: 0.400)
        controller.updateScreenVideoFrameGeometry(try geometry(x: 96.8))

        XCTAssertEqual(
            tap(controller, viewerVideoSize: .init(width: 1_080, height: 1_920)),
            .rejected(.screenFormatChanging)
        )
        clock.advance(by: 0.750)
        XCTAssertEqual(
            tap(controller, viewerVideoSize: .init(width: 1_080, height: 1_920)),
            .accepted(.none)
        )
    }

    // MARK: - Primary drag atomicity and authorization

    func testPrimaryDragMapsBothPointsAndPostsDownDragUpInOrder() {
        let system = MockMacRemoteInputSystem()
        system.bounds = CGRect(x: -1_920, y: -400, width: 1_920, height: 1_080)
        let controller = armedController(system: system)

        XCTAssertEqual(
            drag(
                controller,
                start: .init(x: 0.25, y: 0.75),
                end: .init(x: 0.75, y: 0.25)
            ),
            .accepted(.none)
        )

        XCTAssertEqual(system.postedDragEvents.count, 8)
        guard case .down(let down) = system.postedDragEvents[0],
              case .dragged(let firstDragged) = system.postedDragEvents[1],
              case .dragged(let finalDragged) = system.postedDragEvents[6],
              case .up(let up) = system.postedDragEvents[7] else {
            return XCTFail("Expected one complete down-dragged-path-up sequence")
        }
        XCTAssertEqual(down.x, -1_440, accuracy: 0.0001)
        XCTAssertEqual(down.y, 410, accuracy: 0.0001)
        XCTAssertEqual(firstDragged.x, -1_280, accuracy: 0.0001)
        XCTAssertEqual(firstDragged.y, 320, accuracy: 0.0001)
        XCTAssertEqual(finalDragged.x, -480, accuracy: 0.0001)
        XCTAssertEqual(finalDragged.y, -130, accuracy: 0.0001)
        XCTAssertEqual(up.x, finalDragged.x, accuracy: 0.0001)
        XCTAssertEqual(up.y, finalDragged.y, accuracy: 0.0001)
    }

    func testPrimaryDragRejectsStaleShowAndInputSession() {
        let system = MockMacRemoteInputSystem()
        let controller = armedController(system: system)

        XCTAssertEqual(
            controller.handlePrimaryDrag(
                screenRequestID: showID + 1,
                inputSessionID: sessionID,
                start: .init(x: 0.1, y: 0.2),
                end: .init(x: 0.8, y: 0.9)
            ),
            .rejected(.staleSession)
        )
        XCTAssertEqual(
            controller.handlePrimaryDrag(
                screenRequestID: showID,
                inputSessionID: UUID(),
                start: .init(x: 0.1, y: 0.2),
                end: .init(x: 0.8, y: 0.9)
            ),
            .rejected(.staleSession)
        )
        XCTAssertTrue(system.postedDragEvents.isEmpty)
    }

    func testPrimaryDragValidatesBothPointsBeforeInjection() {
        let system = MockMacRemoteInputSystem()
        let controller = armedController(system: system)
        let valid = MacRemoteNormalizedPoint(x: 0.5, y: 0.5)

        for (start, end) in [
            (MacRemoteNormalizedPoint(x: .nan, y: 0.2), valid),
            (MacRemoteNormalizedPoint(x: -0.001, y: 0.2), valid),
            (valid, MacRemoteNormalizedPoint(x: 0.2, y: .infinity)),
            (valid, MacRemoteNormalizedPoint(x: 0.2, y: 1.001))
        ] {
            XCTAssertEqual(
                drag(controller, start: start, end: end),
                .rejected(.invalidPoint)
            )
        }
        XCTAssertTrue(system.postedDragEvents.isEmpty)
    }

    func testPrimaryDragRechecksPermissionsAndDisplay() {
        let system = MockMacRemoteInputSystem()
        let controller = armedController(system: system)

        system.permissions = .init(accessibilityTrusted: false, postEventAllowed: true)
        XCTAssertEqual(drag(controller), .rejected(.permissionRequired))
        XCTAssertTrue(system.postedDragEvents.isEmpty)

        // Permission loss revokes the bound session.
        system.permissions = .init(accessibilityTrusted: true, postEventAllowed: true)
        XCTAssertEqual(drag(controller), .rejected(.staleSession))

        XCTAssertEqual(
            controller.arm(displayID: displayID, screenRequestID: showID, inputSessionID: sessionID),
            .armed
        )
        system.bounds = nil
        XCTAssertEqual(drag(controller), .rejected(.displayUnavailable))
        XCTAssertTrue(system.postedDragEvents.isEmpty)
    }

    func testPrimaryDragSharesTapRateLimitBudget() {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        let controller = armedController(system: system, clock: clock)

        for _ in 0..<11 {
            XCTAssertEqual(tap(controller), .accepted(.none))
        }
        XCTAssertEqual(drag(controller), .accepted(.none))
        XCTAssertEqual(drag(controller), .rejected(.rateLimited))
        XCTAssertEqual(system.postedMousePoints.count, 11)
        XCTAssertEqual(system.postedDragEvents.count, 8)

        clock.advance(by: 0.125)
        XCTAssertEqual(drag(controller), .accepted(.none))
    }

    func testPrimaryDragGrantsOnlySameNonsecureEditableFocus() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextArea", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system)

        XCTAssertEqual(
            drag(controller),
            .accepted(.editable(generation: 1, secure: false))
        )
        XCTAssertEqual(
            text(controller, generation: 1, value: "selected replacement"),
            .accepted(.editable(generation: 1, secure: false))
        )

        let secure = system.makeElement(
            role: "AXTextField",
            subrole: "AXSecureTextField",
            settable: true
        )
        system.hitElement = secure
        system.currentFocusedElement = secure
        XCTAssertEqual(drag(controller), .accepted(.none))
        XCTAssertEqual(
            text(controller, generation: 1, value: "must stay local"),
            .rejected(.focusChanged)
        )
        XCTAssertEqual(system.postedTexts, ["selected replacement"])
    }

    func testPrimaryDragRejectsWhilePhysicalPrimaryButtonIsHeld() {
        let system = MockMacRemoteInputSystem()
        system.physicalPrimaryButtonPressed = true
        let controller = armedController(system: system)

        XCTAssertEqual(drag(controller), .rejected(.primaryButtonInUse))
        XCTAssertTrue(system.postedDragEvents.isEmpty)

        system.physicalPrimaryButtonPressed = false
        XCTAssertEqual(drag(controller), .accepted(.none))
        XCTAssertEqual(system.postedDragEvents.count, 8)
    }

    func testEveryPrimaryDragClearsPriorKeyboardFocusEvenWhenInvalid() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system)
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        XCTAssertEqual(
            drag(controller, end: .init(x: 2, y: 0.5)),
            .rejected(.invalidPoint)
        )
        XCTAssertEqual(
            text(controller, generation: 1, value: "blocked"),
            .rejected(.focusChanged)
        )
        XCTAssertTrue(system.postedDragEvents.isEmpty)
    }

    func testPrimaryDragBackendFailureIsAllOrNoneAndGrantsNoFocus() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        system.dragPostSucceeds = false
        let controller = armedController(system: system)

        XCTAssertEqual(drag(controller), .rejected(.injectionFailed))
        XCTAssertTrue(system.postedDragEvents.isEmpty)
        XCTAssertEqual(
            text(controller, generation: 1, value: "blocked"),
            .rejected(.focusChanged)
        )

        system.dragPostSucceeds = true
        XCTAssertEqual(
            drag(controller),
            .accepted(.editable(generation: 1, secure: false))
        )
        XCTAssertEqual(system.postedDragEvents.count, 8)
    }

    // MARK: - Stateless scrolling

    func testScrollMapsAnchorAndPreservesExactViewerDeltasAtOneX() throws {
        let system = MockMacRemoteInputSystem()
        system.bounds = CGRect(x: -1_920, y: -400, width: 1_920, height: 1_080)
        let controller = armedController(system: system)

        XCTAssertEqual(
            scroll(
                controller,
                anchor: .init(x: 0.25, y: 0.75),
                deltaX: -17,
                deltaY: 29
            ),
            .accepted(.none)
        )
        XCTAssertEqual(system.postedScrollEvents.count, 1)
        let posted = try XCTUnwrap(system.postedScrollEvents.first)
        XCTAssertEqual(posted.point.x, -1_440, accuracy: 0.0001)
        XCTAssertEqual(posted.point.y, 410, accuracy: 0.0001)
        XCTAssertEqual(posted.deltaX, -17)
        XCTAssertEqual(posted.deltaY, 29)
        XCTAssertTrue(system.postedMousePoints.isEmpty)
        XCTAssertTrue(system.postedDragEvents.isEmpty)
    }

    func testScrollConvertsTwoXFramebufferPixelsWithCumulativeRemainders() throws {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        system.bounds = CGRect(x: 0, y: 0, width: 540, height: 1_170)
        let controller = MacRemoteInputController(
            allowRemoteControl: true,
            system: system,
            clock: clock
        )
        XCTAssertEqual(
            controller.arm(displayID: displayID, screenRequestID: showID, inputSessionID: sessionID),
            .armed
        )
        let geometry = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 2_340,
                contentRect: CGRect(x: 0, y: 0, width: 540, height: 1_170),
                contentScale: 1,
                scaleFactor: 2
            )
        )
        stabilize(geometry, on: controller, clock: clock)
        let viewerSize = MacRemoteInputVideoSize(width: 1_080, height: 2_340)

        XCTAssertEqual(
            scroll(controller, deltaX: 3, deltaY: -5, viewerVideoSize: viewerSize),
            .accepted(.none)
        )
        XCTAssertEqual(
            scroll(controller, deltaX: 3, deltaY: -5, viewerVideoSize: viewerSize),
            .accepted(.none)
        )

        XCTAssertEqual(system.postedScrollEvents.map(\.deltaX), [1, 2])
        XCTAssertEqual(system.postedScrollEvents.map(\.deltaY), [-2, -3])
        XCTAssertEqual(system.postedScrollEvents.reduce(0) { $0 + $1.deltaX }, 3)
        XCTAssertEqual(system.postedScrollEvents.reduce(0) { $0 + $1.deltaY }, -5)
    }

    func testScrollUsesAxisAwareScaleForAdaptedDecoderFrame() throws {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        system.bounds = CGRect(x: 0, y: 0, width: 603, height: 1_311)
        let controller = MacRemoteInputController(
            allowRemoteControl: true,
            system: system,
            clock: clock
        )
        XCTAssertEqual(
            controller.arm(displayID: displayID, screenRequestID: showID, inputSessionID: sessionID),
            .armed
        )
        let geometry = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_206,
                surfaceHeight: 2_622,
                contentRect: CGRect(x: 0, y: 0, width: 603, height: 1_311),
                contentScale: 1,
                scaleFactor: 2
            )
        )
        stabilize(geometry, on: controller, clock: clock)

        XCTAssertEqual(
            scroll(
                controller,
                deltaX: 602,
                deltaY: -1_310,
                viewerVideoSize: .init(width: 602, height: 1_310)
            ),
            .accepted(.none)
        )

        let posted = try XCTUnwrap(system.postedScrollEvents.first)
        XCTAssertEqual(posted.deltaX, 603)
        XCTAssertEqual(posted.deltaY, -1_311)
    }

    func testCoreGraphicsScrollUsesPixelUnitsAtAnchorWithoutMouseButtonEvents() throws {
        let implementation = try controllerSourceSlice(
            after: "    /// Posts one location-targeted smooth scroll without synthesizing mouse-button state.",
            before: "    /// Posts prevalidated UTF-16 text as a balanced keyboard event pair."
        )

        XCTAssertTrue(implementation.contains("scrollWheelEvent2Source: source"))
        XCTAssertTrue(implementation.contains("units: .pixel"))
        XCTAssertTrue(implementation.contains("wheel1: deltaY"))
        XCTAssertTrue(implementation.contains("wheel2: deltaX"))
        XCTAssertTrue(implementation.contains("event.location = point"))
        XCTAssertTrue(implementation.contains("event.post(tap: .cghidEventTap)"))
        XCTAssertFalse(implementation.contains("mouseEventSource:"))
        XCTAssertFalse(implementation.contains("leftMouseDown"))
        XCTAssertFalse(implementation.contains("leftMouseUp"))
    }

    func testScrollRequiresViewerSizeAndStableCompatibleFrameGeometry() throws {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        let controller = armedController(system: system, clock: clock)

        let missingSize = controller.handleScrollWithDiagnostics(
            screenRequestID: showID,
            inputSessionID: sessionID,
            anchor: .init(x: 0.5, y: 0.5),
            deltaX: 0,
            deltaY: 12
        )
        XCTAssertEqual(missingSize.result, .rejected(.screenFormatChanging))
        XCTAssertEqual(missingSize.screenFormatDiagnostic?.reason, .viewerSizeMissing)

        let replacement = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 1_920,
                contentRect: CGRect(x: 0, y: 0, width: 1_080, height: 1_920),
                contentScale: 1,
                scaleFactor: 1
            )
        )
        controller.updateScreenVideoFrameGeometry(replacement)
        XCTAssertEqual(scroll(controller), .rejected(.screenFormatChanging))
        clock.advance(by: 0.750)
        XCTAssertEqual(
            scroll(controller, viewerVideoSize: .init(width: 1_080, height: 1_920)),
            .rejected(.screenFormatChanging),
            "A frame shape incompatible with the captured display remains fenced"
        )
        XCTAssertTrue(system.postedScrollEvents.isEmpty)
    }

    func testScrollRejectsStaleSessionInvalidAnchorAndOutOfContractDeltas() {
        let system = MockMacRemoteInputSystem()
        let controller = armedController(system: system)

        XCTAssertEqual(
            controller.handleScroll(
                screenRequestID: showID + 1,
                inputSessionID: sessionID,
                anchor: .init(x: 0.5, y: 0.5),
                deltaX: 1,
                deltaY: 1,
                viewerVideoSize: .init(width: 1_920, height: 1_080)
            ),
            .rejected(.staleSession)
        )
        XCTAssertEqual(
            scroll(controller, anchor: .init(x: .nan, y: 0.5)),
            .rejected(.invalidPoint)
        )
        XCTAssertEqual(scroll(controller, deltaX: 0, deltaY: 0), .rejected(.invalidScrollDelta))
        XCTAssertEqual(
            scroll(controller, deltaX: 4_097, deltaY: 0),
            .rejected(.invalidScrollDelta)
        )
        XCTAssertEqual(
            scroll(controller, deltaX: 0, deltaY: -4_097),
            .rejected(.invalidScrollDelta)
        )
        XCTAssertEqual(
            scroll(
                controller,
                deltaX: 4_096,
                deltaY: 0,
                viewerVideoSize: .init(width: 32, height: 18)
            ),
            .rejected(.invalidScrollDelta),
            "An untrusted adapted-frame size cannot amplify a bounded wire delta"
        )
        XCTAssertTrue(system.postedScrollEvents.isEmpty)

        XCTAssertEqual(scroll(controller, deltaX: 4_096, deltaY: -4_096), .accepted(.none))
    }

    func testScrollRechecksPermissionsAndDisplayBeforePosting() {
        let system = MockMacRemoteInputSystem()
        let controller = armedController(system: system)

        system.permissions = .init(accessibilityTrusted: true, postEventAllowed: false)
        XCTAssertEqual(scroll(controller), .rejected(.permissionRequired))
        XCTAssertTrue(system.postedScrollEvents.isEmpty)

        system.permissions = .init(accessibilityTrusted: true, postEventAllowed: true)
        XCTAssertEqual(scroll(controller), .rejected(.staleSession))
        XCTAssertEqual(
            controller.arm(displayID: displayID, screenRequestID: showID, inputSessionID: sessionID),
            .armed
        )
        system.bounds = nil
        XCTAssertEqual(scroll(controller), .rejected(.displayUnavailable))
        XCTAssertTrue(system.postedScrollEvents.isEmpty)
    }

    func testScrollHasIndependentSixtyHertzBudgetWithBoundedBurstAndClearsKeyboardGrant() {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system, clock: clock)
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        for _ in 0..<8 {
            XCTAssertEqual(scroll(controller), .accepted(.none))
        }
        XCTAssertEqual(scroll(controller), .rejected(.rateLimited))
        XCTAssertEqual(system.postedScrollEvents.count, 8)
        XCTAssertEqual(
            text(controller, generation: 1, value: "blocked after scroll"),
            .rejected(.focusChanged)
        )

        // Scroll does not consume the tap/drag budget, and one token refills per display frame.
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 2, secure: false)))
        clock.advance(by: 0.017)
        XCTAssertEqual(scroll(controller), .accepted(.none))
    }

    func testScrollBackendFailurePostsNoOtherPointerActionAndGrantsNoFocus() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        system.scrollPostSucceeds = false
        let controller = armedController(system: system)

        XCTAssertEqual(scroll(controller), .rejected(.injectionFailed))
        XCTAssertTrue(system.postedScrollEvents.isEmpty)
        XCTAssertTrue(system.postedMousePoints.isEmpty)
        XCTAssertTrue(system.postedDragEvents.isEmpty)
        XCTAssertEqual(
            text(controller, generation: 1, value: "blocked"),
            .rejected(.focusChanged)
        )
    }

    // MARK: - Accessibility focus and keyboard capability

    func testSecureEditableAncestorNeverGrantsRemoteKeyboardFocus() {
        let system = MockMacRemoteInputSystem()
        let hitChild = system.makeElement(role: "AXStaticText", settable: false)
        let focusedFieldEditor = system.makeElement(role: "AXGroup", settable: false)
        let secureField = system.makeElement(
            role: "AXTextField",
            subrole: "AXSecureTextField",
            settable: true
        )
        let editableContainer = system.makeElement(role: "AXTextArea", settable: true)
        system.setParent(secureField, of: hitChild)
        system.setParent(secureField, of: focusedFieldEditor)
        system.setParent(editableContainer, of: secureField)
        system.hitElement = hitChild
        system.currentFocusedElement = focusedFieldEditor
        let controller = armedController(system: system)

        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID,
                inputSessionID: sessionID,
                normalizedPoint: .init(x: 0.4, y: 0.3),
                viewerVideoSize: .init(width: 1_920, height: 1_080)
            ),
            .accepted(.none)
        )
        XCTAssertEqual(
            text(controller, generation: 1, value: "canonical focus"),
            .rejected(.focusChanged)
        )
        XCTAssertEqual(system.postedMousePoints.count, 1)
        XCTAssertTrue(system.postedTexts.isEmpty)
    }

    func testAuthorizedFieldBecomingSecureRevokesTextAndKeyInjection() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system)

        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        system.setSubrole("AXSecureTextField", of: field)
        XCTAssertEqual(
            text(controller, generation: 1, value: "must stay local"),
            .rejected(.focusChanged)
        )
        XCTAssertEqual(
            controller.pressKey(
                screenRequestID: showID,
                inputSessionID: sessionID,
                focusGeneration: 1,
                key: .returnKey
            ),
            .rejected(.focusChanged)
        )
        XCTAssertTrue(system.postedTexts.isEmpty)
        XCTAssertTrue(system.postedKeys.isEmpty)
    }

    func testClickingAnotherElementClearsOldKeyboardGrant() {
        let system = MockMacRemoteInputSystem()
        let first = system.makeElement(role: "AXTextField", settable: true)
        let second = system.makeElement(role: "AXTextArea", settable: true)
        system.hitElement = first
        system.currentFocusedElement = first
        let controller = armedController(system: system)

        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        system.hitElement = second
        system.currentFocusedElement = first
        XCTAssertEqual(tap(controller), .accepted(.none))
        XCTAssertEqual(
            controller.insertText(
                screenRequestID: showID,
                inputSessionID: sessionID,
                focusGeneration: 1,
                text: "must not be injected"
            ),
            .rejected(.focusChanged)
        )
        XCTAssertTrue(system.postedTexts.isEmpty)
    }

    func testTextAndExplicitKeysAreInjectedOnlyWhileExactElementRemainsFocused() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system)
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        XCTAssertEqual(
            controller.insertText(
                screenRequestID: showID,
                inputSessionID: sessionID,
                focusGeneration: 1,
                text: "Hello 👋"
            ),
            .accepted(.editable(generation: 1, secure: false))
        )
        XCTAssertEqual(
            controller.pressKey(
                screenRequestID: showID,
                inputSessionID: sessionID,
                focusGeneration: 1,
                key: .backspace
            ),
            .accepted(.editable(generation: 1, secure: false))
        )
        XCTAssertEqual(
            controller.pressKey(
                screenRequestID: showID,
                inputSessionID: sessionID,
                focusGeneration: 1,
                key: .returnKey
            ),
            .accepted(.editable(generation: 1, secure: false))
        )
        XCTAssertEqual(system.postedTexts, ["Hello 👋"])
        XCTAssertEqual(system.postedKeys, [.backspace, .returnKey])

        let other = system.makeElement(role: "AXTextField", settable: true)
        system.currentFocusedElement = other
        XCTAssertEqual(
            controller.insertText(
                screenRequestID: showID,
                inputSessionID: sessionID,
                focusGeneration: 1,
                text: "blocked"
            ),
            .rejected(.focusChanged)
        )
        XCTAssertEqual(system.postedTexts, ["Hello 👋"])
    }

    func testStaleShowSessionGenerationAndRevocationCannotInject() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system)
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        XCTAssertEqual(
            controller.insertText(
                screenRequestID: showID + 1,
                inputSessionID: sessionID,
                focusGeneration: 1,
                text: "wrong show"
            ),
            .rejected(.staleSession)
        )
        XCTAssertTrue(system.postedTexts.isEmpty)

        // Retap because any rejected keyboard request fail-closes its focus grant.
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 2, secure: false)))
        XCTAssertEqual(
            controller.pressKey(
                screenRequestID: showID,
                inputSessionID: UUID(),
                focusGeneration: 2,
                key: .returnKey
            ),
            .rejected(.staleSession)
        )
        XCTAssertTrue(system.postedKeys.isEmpty)

        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 3, secure: false)))
        XCTAssertEqual(
            controller.pressKey(
                screenRequestID: showID,
                inputSessionID: sessionID,
                focusGeneration: 2,
                key: .returnKey
            ),
            .rejected(.focusChanged)
        )

        controller.revoke()
        XCTAssertEqual(tap(controller), .rejected(.staleSession))
        XCTAssertEqual(scroll(controller), .rejected(.staleSession))
        XCTAssertEqual(system.postedMousePoints.count, 3)
        XCTAssertTrue(system.postedScrollEvents.isEmpty)
    }

    func testPermissionsAreRecheckedForEveryAction() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system)
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        system.permissions = .init(accessibilityTrusted: false, postEventAllowed: true)
        XCTAssertEqual(
            controller.insertText(
                screenRequestID: showID,
                inputSessionID: sessionID,
                focusGeneration: 1,
                text: "blocked"
            ),
            .rejected(.permissionRequired)
        )
        XCTAssertTrue(system.postedTexts.isEmpty)

        // Losing either grant revokes the entire session, so restoring permission cannot
        // silently revive the old capability without a fresh acknowledged Show.
        system.permissions = .init(accessibilityTrusted: true, postEventAllowed: true)
        XCTAssertEqual(tap(controller), .rejected(.staleSession))
        XCTAssertEqual(system.postedMousePoints.count, 1)
    }

    // MARK: - Text validation and abuse limits

    func testExplicitlyEditableNonstandardAXRoleCanReceiveText() {
        let system = MockMacRemoteInputSystem()
        let contentEditable = system.makeElement(
            role: "AXWebArea",
            settable: false,
            editable: true
        )
        system.hitElement = contentEditable
        system.currentFocusedElement = contentEditable
        let controller = armedController(system: system)

        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))
        XCTAssertEqual(
            text(controller, generation: 1, value: "content editable"),
            .accepted(.editable(generation: 1, secure: false))
        )
    }

    func testSettableTextAreaMayOmitAXEnabledButExplicitlyDisabledFieldIsRejected() {
        let system = MockMacRemoteInputSystem()
        let textArea = system.makeElement(
            role: "AXTextArea",
            enabled: nil,
            settable: true
        )
        system.hitElement = textArea
        system.currentFocusedElement = textArea
        let controller = armedController(system: system)

        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))
        XCTAssertEqual(
            text(controller, generation: 1, value: "TextEdit compatible"),
            .accepted(.editable(generation: 1, secure: false))
        )

        let disabledField = system.makeElement(
            role: "AXTextField",
            enabled: false,
            settable: true
        )
        system.hitElement = disabledField
        system.currentFocusedElement = disabledField
        XCTAssertEqual(tap(controller), .accepted(.none))
    }

    func testTextValidationEnforcesEncodingCapsAndRejectsControlAndFunctionKeyRanges() {
        XCTAssertNil(MacRemoteInputController.validatedTextByteCount(""))
        XCTAssertNil(MacRemoteInputController.validatedTextByteCount("line\nbreak"))
        XCTAssertNil(MacRemoteInputController.validatedTextByteCount("tab\there"))
        XCTAssertNil(MacRemoteInputController.validatedTextByteCount("C1\u{0085}"))
        XCTAssertNil(MacRemoteInputController.validatedTextByteCount("function\u{F700}"))
        XCTAssertNil(MacRemoteInputController.validatedTextByteCount("function\u{F8FF}"))
        XCTAssertNil(MacRemoteInputController.validatedTextByteCount(String(repeating: "a", count: 513)))
        XCTAssertNil(MacRemoteInputController.validatedTextByteCount(String(repeating: "😀", count: 129)))

        XCTAssertNil(
            MacRemoteInputController.validatedTextByteCount(String(repeating: "a", count: 512))
        )
        XCTAssertEqual(
            MacRemoteInputController.validatedTextByteCount(String(repeating: "é", count: 256)),
            512
        )
        XCTAssertEqual(MacRemoteInputController.validatedTextByteCount("ordinary text"), 13)
    }

    func testTapBucketHasDocumentedBurstAndMonotonicRefill() {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        let controller = armedController(system: system, clock: clock)

        for _ in 0..<12 {
            XCTAssertEqual(tap(controller), .accepted(.none))
        }
        XCTAssertEqual(tap(controller), .rejected(.rateLimited))
        XCTAssertEqual(system.postedMousePoints.count, 12)

        clock.advance(by: 0.125)
        XCTAssertEqual(tap(controller), .accepted(.none))
        XCTAssertEqual(tap(controller), .rejected(.rateLimited))

        // A regressing clock must never mint tokens.
        clock.advance(by: -10)
        XCTAssertEqual(tap(controller), .rejected(.rateLimited))
    }

    func testKeyBucketHasDocumentedBurstAndRefill() {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system, clock: clock)
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        for _ in 0..<40 {
            XCTAssertEqual(key(controller, generation: 1), .accepted(.editable(generation: 1, secure: false)))
        }
        XCTAssertEqual(key(controller, generation: 1), .rejected(.rateLimited))
        XCTAssertEqual(system.postedKeys.count, 40)

        // Reauthorize focus, then one key token refills in 1/25 second.
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 2, secure: false)))
        clock.advance(by: 0.04)
        XCTAssertEqual(key(controller, generation: 2), .accepted(.editable(generation: 2, secure: false)))
    }

    func testTextBucketChargesUTF8BytesWithDocumentedBurstAndRefill() {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        let field = system.makeElement(role: "AXTextArea", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system, clock: clock)
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        let chunk = String(repeating: "é", count: 256)
        for _ in 0..<8 {
            XCTAssertEqual(
                text(controller, generation: 1, value: chunk),
                .accepted(.editable(generation: 1, secure: false))
            )
        }
        XCTAssertEqual(text(controller, generation: 1, value: "x"), .rejected(.rateLimited))
        XCTAssertEqual(system.postedTexts.count, 8)

        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 2, secure: false)))
        clock.advance(by: 1.0 / 2_048.0)
        XCTAssertEqual(
            text(controller, generation: 2, value: "x"),
            .accepted(.editable(generation: 2, secure: false))
        )
    }

    // MARK: - Focus timing, session renewal, and backend failure

    func testPostClickFocusPollingIsBoundedToFiftyMilliseconds() {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = nil
        let controller = armedController(system: system, clock: clock)

        XCTAssertEqual(tap(controller), .accepted(.none))
        XCTAssertLessThanOrEqual(clock.totalSlept, 0.050_001)
        XCTAssertGreaterThan(clock.totalSlept, 0)
        XCTAssertLessThanOrEqual(clock.sleepCalls, 10)
    }

    func testPollingCanObserveDelayedFocusButNeverAuthorizesDifferentEditableElement() {
        let system = MockMacRemoteInputSystem()
        let clock = MockMacRemoteInputClock()
        let target = system.makeElement(role: "AXTextField", settable: true)
        let other = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = target
        system.focusSequence = [nil, other, target]
        let controller = armedController(system: system, clock: clock)

        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))
        XCTAssertEqual(clock.sleepCalls, 2)

        system.hitElement = target
        system.focusSequence = Array(repeating: other, count: 11)
        XCTAssertEqual(tap(controller), .accepted(.none))
    }

    func testRearmingCreatesAFreshAuthorizationDomainAndResetsGeneration() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system)
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        let newSession = UUID()
        XCTAssertEqual(
            controller.arm(displayID: displayID, screenRequestID: showID + 1, inputSessionID: newSession),
            .armed
        )
        XCTAssertEqual(tap(controller), .rejected(.staleSession))
        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID + 1,
                inputSessionID: newSession,
                normalizedPoint: .init(x: 0.5, y: 0.5),
                viewerVideoSize: .init(width: 1_920, height: 1_080)
            ),
            .accepted(.editable(generation: 1, secure: false))
        )
    }

    func testInvalidatePermanentlyRevokesPointerAndKeyboardInjection() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        let controller = armedController(system: system)

        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))
        XCTAssertEqual(system.postedMousePoints.count, 1)

        controller.invalidate()

        XCTAssertEqual(tap(controller), .rejected(.disabled))
        XCTAssertEqual(drag(controller), .rejected(.disabled))
        XCTAssertEqual(scroll(controller), .rejected(.disabled))
        XCTAssertEqual(text(controller, generation: 1, value: "blocked"), .rejected(.disabled))
        XCTAssertEqual(key(controller, generation: 1), .rejected(.disabled))
        XCTAssertEqual(system.postedMousePoints.count, 1)
        XCTAssertTrue(system.postedDragEvents.isEmpty)
        XCTAssertTrue(system.postedScrollEvents.isEmpty)
        XCTAssertTrue(system.postedTexts.isEmpty)
        XCTAssertTrue(system.postedKeys.isEmpty)
    }

    func testInvalidateCannotBeUndoneByRevokeOrRearm() {
        let system = MockMacRemoteInputSystem()
        let controller = makeController(system: system)

        controller.invalidate()
        controller.revoke()
        controller.invalidate()

        let replacementSessionID = UUID()
        XCTAssertEqual(
            controller.arm(
                displayID: displayID,
                screenRequestID: showID + 1,
                inputSessionID: replacementSessionID
            ),
            .disabled
        )
        XCTAssertEqual(
            controller.handleTap(
                screenRequestID: showID + 1,
                inputSessionID: replacementSessionID,
                normalizedPoint: .init(x: 0.5, y: 0.5)
            ),
            .rejected(.disabled)
        )
        XCTAssertTrue(system.postedMousePoints.isEmpty)
    }

    func testBackendFailuresDoNotLeaveAKeyboardGrant() {
        let system = MockMacRemoteInputSystem()
        let field = system.makeElement(role: "AXTextField", settable: true)
        system.hitElement = field
        system.currentFocusedElement = field
        system.mousePostSucceeds = false
        let controller = armedController(system: system)

        XCTAssertEqual(tap(controller), .rejected(.injectionFailed))
        system.mousePostSucceeds = true
        XCTAssertEqual(tap(controller), .accepted(.editable(generation: 1, secure: false)))

        system.textPostSucceeds = false
        XCTAssertEqual(text(controller, generation: 1, value: "blocked"), .rejected(.injectionFailed))
        system.textPostSucceeds = true
        XCTAssertEqual(text(controller, generation: 1, value: "still blocked"), .rejected(.focusChanged))
        XCTAssertTrue(system.postedTexts.isEmpty)
    }

    private func makeController(
        system: MockMacRemoteInputSystem,
        clock: MockMacRemoteInputClock = .init()
    ) -> MacRemoteInputController {
        let controller = MacRemoteInputController(
            allowRemoteControl: true,
            system: system,
            clock: clock
        )
        if let bounds = system.bounds,
           let geometry = fullFrameGeometry(for: bounds) {
            stabilize(geometry, on: controller, clock: clock)
        }
        return controller
    }

    private func stabilize(
        _ geometry: ScreenVideoFrameGeometry,
        on controller: MacRemoteInputController,
        clock: MockMacRemoteInputClock
    ) {
        controller.updateScreenVideoFrameGeometry(geometry)
        clock.advance(by: 0.750)
    }

    private func fullFrameGeometry(for bounds: CGRect) -> ScreenVideoFrameGeometry? {
        let width = max(2, Int(bounds.width.rounded()))
        let height = max(2, Int(bounds.height.rounded()))
        return ScreenVideoFrameGeometry(
            surfaceWidth: width,
            surfaceHeight: height,
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            contentScale: 1,
            scaleFactor: 1
        )
    }

    private func armedController(
        system: MockMacRemoteInputSystem,
        clock: MockMacRemoteInputClock = .init()
    ) -> MacRemoteInputController {
        let controller = makeController(system: system, clock: clock)
        XCTAssertEqual(
            controller.arm(displayID: displayID, screenRequestID: showID, inputSessionID: sessionID),
            .armed
        )
        return controller
    }

    private func tap(
        _ controller: MacRemoteInputController,
        viewerVideoSize: MacRemoteInputVideoSize = .init(width: 1_920, height: 1_080)
    ) -> MacRemoteInputResult {
        controller.handleTap(
            screenRequestID: showID,
            inputSessionID: sessionID,
            normalizedPoint: .init(x: 0.5, y: 0.5),
            viewerVideoSize: viewerVideoSize
        )
    }

    private func drag(
        _ controller: MacRemoteInputController,
        start: MacRemoteNormalizedPoint = .init(x: 0.25, y: 0.25),
        end: MacRemoteNormalizedPoint = .init(x: 0.75, y: 0.75),
        viewerVideoSize: MacRemoteInputVideoSize = .init(width: 1_920, height: 1_080)
    ) -> MacRemoteInputResult {
        controller.handlePrimaryDrag(
            screenRequestID: showID,
            inputSessionID: sessionID,
            start: start,
            end: end,
            viewerVideoSize: viewerVideoSize
        )
    }

    private func scroll(
        _ controller: MacRemoteInputController,
        anchor: MacRemoteNormalizedPoint = .init(x: 0.5, y: 0.5),
        deltaX: Int32 = 0,
        deltaY: Int32 = 12,
        viewerVideoSize: MacRemoteInputVideoSize = .init(width: 1_920, height: 1_080)
    ) -> MacRemoteInputResult {
        controller.handleScroll(
            screenRequestID: showID,
            inputSessionID: sessionID,
            anchor: anchor,
            deltaX: deltaX,
            deltaY: deltaY,
            viewerVideoSize: viewerVideoSize
        )
    }

    private func key(
        _ controller: MacRemoteInputController,
        generation: UInt64
    ) -> MacRemoteInputResult {
        controller.pressKey(
            screenRequestID: showID,
            inputSessionID: sessionID,
            focusGeneration: generation,
            key: .backspace
        )
    }

    private func text(
        _ controller: MacRemoteInputController,
        generation: UInt64,
        value: String
    ) -> MacRemoteInputResult {
        controller.insertText(
            screenRequestID: showID,
            inputSessionID: sessionID,
            focusGeneration: generation,
            text: value
        )
    }

    private func controllerSourceSlice(
        after startMarker: String,
        before endMarker: String
    ) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureCore/MacRemoteInputController.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: startMarker)?.upperBound)
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound
        )
        return String(source[start..<end])
    }
}

/// Deterministic monotonic clock for token refill and bounded focus-polling assertions.
/// `sleep` advances virtual time immediately, keeping the suite fast and independent of load.
private final class MockMacRemoteInputClock: @unchecked Sendable, MacRemoteInputClock {
    private(set) var time: TimeInterval = 100
    private(set) var totalSlept: TimeInterval = 0
    private(set) var sleepCalls = 0

    func now() -> TimeInterval {
        time
    }

    func sleep(for interval: TimeInterval) {
        sleepCalls += 1
        totalSlept += interval
        time += interval
    }

    func advance(by interval: TimeInterval) {
        time += interval
    }
}

/// In-memory model of the TCC, display, Accessibility, and CoreGraphics operations used by the
/// controller. Posted events are recorded only after the corresponding injected backend succeeds,
/// allowing the tests to distinguish validation failures from partial input delivery.
private final class MockMacRemoteInputSystem: @unchecked Sendable, MacRemoteInputSystem {
    /// The complete mouse gesture protocol expected by a primary drag.
    enum PostedDragEvent: Equatable {
        case down(CGPoint)
        case dragged(CGPoint)
        case up(CGPoint)
    }

    struct PostedScrollEvent: Equatable {
        let point: CGPoint
        let deltaX: Int32
        let deltaY: Int32
    }

    struct Node {
        // Parent links model field editors and nested secure/editable accessibility containers.
        var parent: MacRemoteAccessibilityElement?
        var role: String?
        var subrole: String?
        var enabled: Bool?
        var settable: Bool
        var editable: Bool?
    }

    var permissions = MacRemoteInputPermissionStatus(
        accessibilityTrusted: true,
        postEventAllowed: true
    )
    var bounds: CGRect? = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
    var physicalPrimaryButtonPressed = false
    var hitElement: MacRemoteAccessibilityElement?
    var currentFocusedElement: MacRemoteAccessibilityElement?
    var focusSequence: [MacRemoteAccessibilityElement?] = []

    var mousePostSucceeds = true
    var dragPostSucceeds = true
    var scrollPostSucceeds = true
    var textPostSucceeds = true
    var keyPostSucceeds = true

    private(set) var postedMousePoints: [CGPoint] = []
    private(set) var postedDragEvents: [PostedDragEvent] = []
    private(set) var postedScrollEvents: [PostedScrollEvent] = []
    private(set) var postedTexts: [String] = []
    private(set) var postedKeys: [MacRemoteInputKey] = []
    private var nodes: [ObjectIdentifier: Node] = [:]

    func makeElement(
        role: String?,
        subrole: String? = nil,
        enabled: Bool? = true,
        settable: Bool,
        editable: Bool? = nil
    ) -> MacRemoteAccessibilityElement {
        let element = MacRemoteAccessibilityElement(rawValue: NSObject())
        nodes[ObjectIdentifier(element)] = Node(
            role: role,
            subrole: subrole,
            enabled: enabled,
            settable: settable,
            editable: editable
        )
        return element
    }

    func setParent(
        _ parent: MacRemoteAccessibilityElement,
        of child: MacRemoteAccessibilityElement
    ) {
        nodes[ObjectIdentifier(child)]?.parent = parent
    }

    func setSubrole(
        _ subrole: String?,
        of element: MacRemoteAccessibilityElement
    ) {
        nodes[ObjectIdentifier(element)]?.subrole = subrole
    }

    func permissionStatus(promptIfNeeded _: Bool) -> MacRemoteInputPermissionStatus {
        permissions
    }

    func displayBounds(for _: UInt32) -> CGRect? {
        bounds
    }

    func isPhysicalPrimaryButtonPressed() -> Bool {
        physicalPrimaryButtonPressed
    }

    func element(at _: CGPoint) -> MacRemoteAccessibilityElement? {
        hitElement
    }

    func parent(of element: MacRemoteAccessibilityElement) -> MacRemoteAccessibilityElement? {
        nodes[ObjectIdentifier(element)]?.parent
    }

    func role(of element: MacRemoteAccessibilityElement) -> String? {
        nodes[ObjectIdentifier(element)]?.role
    }

    func subrole(of element: MacRemoteAccessibilityElement) -> String? {
        nodes[ObjectIdentifier(element)]?.subrole
    }

    func isEnabled(_ element: MacRemoteAccessibilityElement) -> Bool? {
        nodes[ObjectIdentifier(element)]?.enabled
    }

    func isEditable(_ element: MacRemoteAccessibilityElement) -> Bool? {
        nodes[ObjectIdentifier(element)]?.editable
    }

    func isValueSettable(_ element: MacRemoteAccessibilityElement) -> Bool {
        nodes[ObjectIdentifier(element)]?.settable ?? false
    }

    func focusedElement() -> MacRemoteAccessibilityElement? {
        if !focusSequence.isEmpty {
            return focusSequence.removeFirst()
        }
        return currentFocusedElement
    }

    func elementsEqual(
        _ lhs: MacRemoteAccessibilityElement,
        _ rhs: MacRemoteAccessibilityElement
    ) -> Bool {
        lhs === rhs
    }

    func postMouseClick(at point: CGPoint) -> Bool {
        guard mousePostSucceeds else { return false }
        postedMousePoints.append(point)
        return true
    }

    func postPrimaryDrag(from start: CGPoint, to end: CGPoint) -> Bool {
        guard dragPostSucceeds else { return false }
        postedDragEvents.append(.down(start))
        postedDragEvents.append(
            contentsOf: MacRemoteInputDragPath.points(from: start, to: end).map {
                .dragged($0)
            }
        )
        postedDragEvents.append(.up(end))
        return true
    }

    func postScroll(at point: CGPoint, deltaX: Int32, deltaY: Int32) -> Bool {
        guard scrollPostSucceeds else { return false }
        postedScrollEvents.append(
            PostedScrollEvent(point: point, deltaX: deltaX, deltaY: deltaY)
        )
        return true
    }

    func postUnicodeText(_ text: String) -> Bool {
        guard textPostSucceeds else { return false }
        postedTexts.append(text)
        return true
    }

    func postKey(_ key: MacRemoteInputKey) -> Bool {
        guard keyPostSucceeds else { return false }
        postedKeys.append(key)
        return true
    }
}
