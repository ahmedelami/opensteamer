import CaptureCore
import Foundation
import XCTest
@testable import CaptureServer

final class ScreenVideoServiceFormatRenegotiationTests: XCTestCase {
    func testChangedFrameFollowedByIdleStreamReachesFallbackDeadline() throws {
        let scheduler = LANManualFormatFallbackScheduler()
        let harness = LANFormatRenegotiationHarness(
            scheduleFallback: { delay, action in
                scheduler.schedule(delay, action)
            }
        )
        let fullFrame = try makeLANFullFrameGeometry()
        let insetFrame = try makeLANInsetFrameGeometry()

        XCTAssertEqual(harness.observe(fullFrame), .forwardFrame)
        XCTAssertEqual(harness.observe(insetFrame), .dropFrame)
        XCTAssertEqual(harness.restartCount, 0)
        XCTAssertEqual(
            scheduler.scheduledDelays,
            [ScreenVideoService.formatRenegotiationFallbackDelay]
        )

        // Idle ScreenCaptureKit samples do not reach ScreenVideoService. The injected clock
        // advances independently, so no third complete frame is needed to request a restart.
        scheduler.runNext()

        XCTAssertEqual(harness.restartCount, 1)
    }

    func testConcreteRecoveryInvalidatesQueuedFallbackAndCanArmANewCandidate() throws {
        let scheduler = LANManualFormatFallbackScheduler()
        let harness = LANFormatRenegotiationHarness(
            scheduleFallback: { delay, action in
                scheduler.schedule(delay, action)
            }
        )
        let fullFrame = try makeLANFullFrameGeometry()
        let insetFrame = try makeLANInsetFrameGeometry()

        XCTAssertEqual(harness.observe(fullFrame), .forwardFrame)
        XCTAssertEqual(harness.observe(insetFrame), .dropFrame)
        XCTAssertEqual(harness.observe(fullFrame), .forwardFrame)

        scheduler.runNext()

        XCTAssertEqual(harness.restartCount, 0)
        XCTAssertEqual(harness.observe(insetFrame), .dropFrame)
        XCTAssertEqual(scheduler.scheduledDelays.count, 1)

        scheduler.runNext()

        XCTAssertEqual(harness.restartCount, 1)
    }

    func testThreeChangedFramesInvalidateTheirQueuedFallbackDeadline() throws {
        let scheduler = LANManualFormatFallbackScheduler()
        let harness = LANFormatRenegotiationHarness(
            scheduleFallback: { delay, action in
                scheduler.schedule(delay, action)
            }
        )
        let fullFrame = try makeLANFullFrameGeometry()
        let insetFrame = try makeLANInsetFrameGeometry()

        XCTAssertEqual(harness.observe(fullFrame), .forwardFrame)
        XCTAssertEqual(harness.observe(insetFrame), .dropFrame)
        XCTAssertEqual(harness.observe(insetFrame), .dropFrame)
        XCTAssertEqual(harness.observe(insetFrame), .renegotiate)

        scheduler.runNext()

        XCTAssertEqual(harness.restartCount, 0)
    }
}

private final class LANFormatRenegotiationHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let scheduleFallback:
        ScreenVideoService.FormatRenegotiationFallbackScheduler
    private var state = ScreenVideoServiceFormatRenegotiationState()
    private var restarts = 0

    init(
        scheduleFallback:
            @escaping ScreenVideoService.FormatRenegotiationFallbackScheduler
    ) {
        self.scheduleFallback = scheduleFallback
    }

    var restartCount: Int {
        lock.withLock { restarts }
    }

    func observe(
        _ geometry: ScreenVideoFrameGeometry
    ) -> ScreenVideoFormatRenegotiationDetector.Action {
        let observation = lock.withLock {
            state.observe(geometry)
        }
        if let fallbackToken = observation.fallbackToken {
            scheduleFallback(
                ScreenVideoService.formatRenegotiationFallbackDelay
            ) { [weak self] in
                self?.fallbackDeadlineDidFire(fallbackToken)
            }
        }
        return observation.action
    }

    private func fallbackDeadlineDidFire(_ token: UInt64) {
        lock.withLock {
            if state.fallbackDeadlineDidFire(token) {
                restarts += 1
            }
        }
    }
}

private final class LANManualFormatFallbackScheduler: @unchecked Sendable {
    private struct ScheduledAction: @unchecked Sendable {
        let delay: TimeInterval
        let action: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var actions: [ScheduledAction] = []

    var scheduledDelays: [TimeInterval] {
        lock.withLock { actions.map(\.delay) }
    }

    func schedule(
        _ delay: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) {
        lock.withLock {
            actions.append(ScheduledAction(delay: delay, action: action))
        }
    }

    func runNext() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !actions.isEmpty else { return nil }
            return actions.removeFirst().action
        }
        action?()
    }
}

private func makeLANFullFrameGeometry() throws -> ScreenVideoFrameGeometry {
    try XCTUnwrap(
        ScreenVideoFrameGeometry(
            surfaceWidth: 640,
            surfaceHeight: 360,
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            contentScale: 1,
            scaleFactor: 2
        )
    )
}

private func makeLANInsetFrameGeometry() throws -> ScreenVideoFrameGeometry {
    try XCTUnwrap(
        ScreenVideoFrameGeometry(
            surfaceWidth: 640,
            surfaceHeight: 360,
            contentRect: CGRect(x: 10, y: 5, width: 300, height: 170),
            contentScale: 0.8,
            scaleFactor: 2
        )
    )
}
