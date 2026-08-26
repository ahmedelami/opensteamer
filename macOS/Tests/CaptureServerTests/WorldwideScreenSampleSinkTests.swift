import CoreMedia
import CoreVideo
import CaptureCore
import XCTest
@testable import CaptureServer

final class WorldwideScreenSampleSinkTests: XCTestCase {
    func testExpectedStartupSurfaceMustBeRenderedBeforeForwardingCanCommit() throws {
        let capturer = RecordingScreenFrameCapturer()
        let sink = WorldwideScreenSampleSink(
            capturer: capturer,
            remoteInputController: MacRemoteInputController(allowRemoteControl: false),
            didRequireCaptureFormatRenegotiation: { _ in },
            didStop: { _, _ in }
        )
        let authorization = try XCTUnwrap(
            sink.beginForwarding(
                expectedFrameDimensions: .init(width: 1_080, height: 2_340),
                expectedScaleFactor: 2,
                expectedContentScale: 1
            )
        )

        XCTAssertEqual(
            sink.forwardingStartupProofState(authorizedBy: authorization),
            .waiting
        )
        XCTAssertFalse(sink.commitForwardingStartup(authorizedBy: authorization))
        XCTAssertEqual(capturer.captureCount, 0)

        let exactFrame = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 2_340,
                contentRect: CGRect(x: 0, y: 0, width: 540, height: 1_170),
                contentScale: 1,
                scaleFactor: 2
            )
        )
        sink.consumeScreenVideoSample(try makeImageSample(), frameGeometry: exactFrame)

        XCTAssertEqual(
            sink.forwardingStartupProofState(authorizedBy: authorization),
            .proven
        )
        XCTAssertEqual(capturer.captureCount, 1)
        XCTAssertTrue(sink.commitForwardingStartup(authorizedBy: authorization))
        XCTAssertTrue(sink.allowsActiveUse(authorizedBy: authorization))
    }

    func testUpscaledStaleStartupSourceCannotProveSelectedFramebuffer() throws {
        let capturer = RecordingScreenFrameCapturer()
        let sink = WorldwideScreenSampleSink(
            capturer: capturer,
            remoteInputController: MacRemoteInputController(allowRemoteControl: false),
            didRequireCaptureFormatRenegotiation: { _ in },
            didStop: { _, _ in }
        )
        let authorization = try XCTUnwrap(
            sink.beginForwarding(
                expectedFrameDimensions: .init(width: 1_080, height: 2_340),
                expectedScaleFactor: 2,
                expectedContentScale: 1
            )
        )
        let upscaledStaleSource = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 1_080,
                surfaceHeight: 2_340,
                contentRect: CGRect(x: 0, y: 0, width: 1_080, height: 2_340),
                contentScale: 2,
                scaleFactor: 1
            )
        )

        sink.consumeScreenVideoSample(
            try makeImageSample(),
            frameGeometry: upscaledStaleSource
        )

        XCTAssertEqual(capturer.captureCount, 0)
        XCTAssertFalse(authorization.isValid)
        XCTAssertTrue(sink.requiresForwardingStartupRetry)
        XCTAssertEqual(
            sink.forwardingStartupProofState(authorizedBy: authorization),
            .rejected
        )
    }

    func testUnexpectedStartupSurfaceIsNeverForwardedAndRequestsTypedRetry() throws {
        let renegotiations = LockedCount()
        let capturer = RecordingScreenFrameCapturer()
        let sink = WorldwideScreenSampleSink(
            capturer: capturer,
            remoteInputController: MacRemoteInputController(allowRemoteControl: false),
            didRequireCaptureFormatRenegotiation: { _ in
                renegotiations.increment()
            },
            didStop: { _, _ in }
        )
        let authorization = try XCTUnwrap(
            sink.beginForwarding(
                expectedFrameDimensions: .init(width: 1_080, height: 2_340)
            )
        )
        let staleSurface = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 540,
                surfaceHeight: 1_170,
                contentRect: CGRect(x: 0, y: 0, width: 540, height: 1_170),
                contentScale: 1,
                scaleFactor: 1
            )
        )

        sink.consumeScreenVideoSample(try makeImageSample(), frameGeometry: staleSurface)

        XCTAssertEqual(capturer.captureCount, 0)
        XCTAssertEqual(renegotiations.value, 0)
        XCTAssertFalse(authorization.isValid)
        XCTAssertTrue(sink.requiresForwardingStartupRetry)
        XCTAssertEqual(
            sink.forwardingStartupProofState(authorizedBy: authorization),
            .rejected
        )
        XCTAssertFalse(sink.commitForwardingStartup(authorizedBy: authorization))
    }

    func testMissingStartupGeometryCannotProveTheSelectedSurface() throws {
        let capturer = RecordingScreenFrameCapturer()
        let sink = WorldwideScreenSampleSink(
            capturer: capturer,
            remoteInputController: MacRemoteInputController(allowRemoteControl: false),
            didRequireCaptureFormatRenegotiation: { _ in },
            didStop: { _, _ in }
        )
        let authorization = try XCTUnwrap(
            sink.beginForwarding(
                expectedFrameDimensions: .init(width: 640, height: 360)
            )
        )

        sink.consumeScreenVideoSample(try makeImageSample(), frameGeometry: nil)

        XCTAssertEqual(capturer.captureCount, 0)
        XCTAssertFalse(authorization.isValid)
        XCTAssertTrue(sink.requiresForwardingStartupRetry)
    }

    func testDisplayModeChangeBeforeForwardingRejectsStaleStartup() {
        let renegotiations = LockedCount()
        let sink = WorldwideScreenSampleSink(
            capturer: RecordingScreenFrameCapturer(),
            remoteInputController: MacRemoteInputController(allowRemoteControl: false),
            didRequireCaptureFormatRenegotiation: { _ in
                renegotiations.increment()
            },
            didStop: { _, _ in }
        )

        sink.displayModeDidChange()
        sink.displayModeDidChange()

        XCTAssertEqual(renegotiations.value, 0)
        XCTAssertTrue(sink.requiresForwardingStartupRetry)
        XCTAssertNil(sink.beginForwarding())
    }

    func testDisplayModeChangeDuringForwardingStartupBecomesTypedRetry() throws {
        let renegotiations = LockedCount()
        let sink = WorldwideScreenSampleSink(
            capturer: RecordingScreenFrameCapturer(),
            remoteInputController: MacRemoteInputController(allowRemoteControl: false),
            didRequireCaptureFormatRenegotiation: { _ in
                renegotiations.increment()
            },
            didStop: { _, _ in }
        )

        let authorization = try XCTUnwrap(sink.beginForwarding())
        sink.displayModeDidChange()

        XCTAssertTrue(sink.requiresForwardingStartupRetry)
        XCTAssertFalse(sink.commitForwardingStartup(authorizedBy: authorization))
        XCTAssertFalse(authorization.isValid)
        XCTAssertEqual(renegotiations.value, 0)
    }

    func testDisplayModeChangeRevokesExactControlGenerationOnce() throws {
        let renegotiations = LockedCount()
        let sink = WorldwideScreenSampleSink(
            capturer: RecordingScreenFrameCapturer(),
            remoteInputController: MacRemoteInputController(allowRemoteControl: false),
            didRequireCaptureFormatRenegotiation: { _ in
                renegotiations.increment()
            },
            didStop: { _, _ in }
        )

        let first = try XCTUnwrap(sink.beginForwarding())
        XCTAssertTrue(sink.commitForwardingStartup(authorizedBy: first))
        XCTAssertTrue(first.isValid)
        XCTAssertTrue(sink.allowsActiveUse(authorizedBy: first))

        sink.displayModeDidChange()

        XCTAssertFalse(first.isValid)
        XCTAssertFalse(sink.allowsActiveUse(authorizedBy: first))
        XCTAssertEqual(renegotiations.value, 1)

        sink.displayModeDidChange()
        XCTAssertEqual(renegotiations.value, 1)

        sink.stopForwarding()
        XCTAssertFalse(first.isValid)

        let replacementSink = WorldwideScreenSampleSink(
            capturer: RecordingScreenFrameCapturer(),
            remoteInputController: MacRemoteInputController(allowRemoteControl: false),
            didRequireCaptureFormatRenegotiation: { _ in
                renegotiations.increment()
            },
            didStop: { _, _ in }
        )
        let second = try XCTUnwrap(replacementSink.beginForwarding())
        XCTAssertTrue(replacementSink.commitForwardingStartup(authorizedBy: second))
        XCTAssertFalse(first === second)
        XCTAssertTrue(second.isValid)
        XCTAssertTrue(replacementSink.allowsActiveUse(authorizedBy: second))
        XCTAssertFalse(replacementSink.allowsActiveUse(authorizedBy: first))

        replacementSink.stopForwarding()
        XCTAssertFalse(second.isValid)
        XCTAssertFalse(replacementSink.allowsActiveUse(authorizedBy: second))
    }

    func testChangedGeometryDebouncesBeforeRevokingTheForwardingGeneration() throws {
        let renegotiations = LockedCount()
        let capturer = RecordingScreenFrameCapturer()
        let scheduler = ManualFormatRenegotiationFallbackScheduler()
        let sink = WorldwideScreenSampleSink(
            capturer: capturer,
            remoteInputController: MacRemoteInputController(allowRemoteControl: false),
            didRequireCaptureFormatRenegotiation: { _ in
                renegotiations.increment()
            },
            scheduleFormatRenegotiationFallback: { delay, action in
                scheduler.schedule(delay, action)
            },
            didStop: { _, _ in }
        )
        let sample = try makeImageSample()
        let fullFrame = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 640,
                surfaceHeight: 360,
                contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
                contentScale: 1,
                scaleFactor: 2
            )
        )
        let authorization = try XCTUnwrap(
            sink.beginForwarding(
                expectedFrameDimensions: .init(width: 640, height: 360)
            )
        )
        let insetFrame = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 640,
                surfaceHeight: 360,
                contentRect: CGRect(x: 10, y: 5, width: 300, height: 170),
                contentScale: 0.8,
                scaleFactor: 2
            )
        )
        sink.consumeScreenVideoSample(sample, frameGeometry: fullFrame)
        XCTAssertEqual(capturer.captureCount, 1)
        XCTAssertTrue(sink.commitForwardingStartup(authorizedBy: authorization))

        sink.consumeScreenVideoSample(sample, frameGeometry: insetFrame)
        XCTAssertTrue(sink.isDebouncingFormatRenegotiation)
        XCTAssertFalse(sink.allowsActiveUse(authorizedBy: authorization))
        XCTAssertTrue(authorization.isValid)
        XCTAssertEqual(renegotiations.value, 0)
        XCTAssertEqual(capturer.captureCount, 1)

        sink.consumeScreenVideoSample(sample, frameGeometry: insetFrame)
        XCTAssertTrue(sink.isDebouncingFormatRenegotiation)
        XCTAssertEqual(renegotiations.value, 0)
        XCTAssertEqual(capturer.captureCount, 1)

        sink.consumeScreenVideoSample(sample, frameGeometry: insetFrame)
        XCTAssertFalse(sink.isDebouncingFormatRenegotiation)
        XCTAssertTrue(sink.isAwaitingFormatRenegotiation)
        XCTAssertFalse(authorization.isValid)
        XCTAssertEqual(renegotiations.value, 1)
        XCTAssertEqual(capturer.captureCount, 1)

        scheduler.runNext()
        XCTAssertEqual(renegotiations.value, 1)
    }

    func testFullFrameClearsTransientGeometryDebounce() throws {
        let capturer = RecordingScreenFrameCapturer()
        let sink = WorldwideScreenSampleSink(
            capturer: capturer,
            remoteInputController: MacRemoteInputController(allowRemoteControl: false),
            didRequireCaptureFormatRenegotiation: { _ in },
            didStop: { _, _ in }
        )
        let authorization = try XCTUnwrap(sink.beginForwarding())
        XCTAssertTrue(sink.commitForwardingStartup(authorizedBy: authorization))
        let sample = try makeImageSample()
        let fullFrame = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 640,
                surfaceHeight: 360,
                contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
                contentScale: 1,
                scaleFactor: 2
            )
        )
        let insetFrame = try XCTUnwrap(
            ScreenVideoFrameGeometry(
                surfaceWidth: 640,
                surfaceHeight: 360,
                contentRect: CGRect(x: 10, y: 5, width: 300, height: 170),
                contentScale: 0.8,
                scaleFactor: 2
            )
        )
        sink.consumeScreenVideoSample(sample, frameGeometry: fullFrame)
        sink.consumeScreenVideoSample(sample, frameGeometry: insetFrame)
        XCTAssertTrue(sink.isDebouncingFormatRenegotiation)
        XCTAssertEqual(capturer.captureCount, 1)

        sink.consumeScreenVideoSample(sample, frameGeometry: fullFrame)

        XCTAssertFalse(sink.isDebouncingFormatRenegotiation)
        XCTAssertTrue(sink.allowsActiveUse(authorizedBy: authorization))
        XCTAssertTrue(authorization.isValid)
        XCTAssertEqual(capturer.captureCount, 2)
    }

    func testFallbackDeadlineRenegotiatesWhenChangedFrameIsFollowedByIdleStream()
        throws {
        let renegotiations = LockedCount()
        let capturer = RecordingScreenFrameCapturer()
        let scheduler = ManualFormatRenegotiationFallbackScheduler()
        let sink = WorldwideScreenSampleSink(
            capturer: capturer,
            remoteInputController: MacRemoteInputController(allowRemoteControl: false),
            didRequireCaptureFormatRenegotiation: { _ in
                renegotiations.increment()
            },
            scheduleFormatRenegotiationFallback: { delay, action in
                scheduler.schedule(delay, action)
            },
            didStop: { _, _ in }
        )
        let authorization = try XCTUnwrap(sink.beginForwarding())
        XCTAssertTrue(sink.commitForwardingStartup(authorizedBy: authorization))
        let sample = try makeImageSample()
        let fullFrame = try makeFullFrameGeometry()
        let insetFrame = try makeInsetFrameGeometry()

        sink.consumeScreenVideoSample(sample, frameGeometry: fullFrame)
        sink.consumeScreenVideoSample(sample, frameGeometry: insetFrame)

        XCTAssertTrue(sink.isDebouncingFormatRenegotiation)
        XCTAssertTrue(authorization.isValid)
        XCTAssertEqual(capturer.captureCount, 1)
        XCTAssertEqual(
            scheduler.scheduledDelays,
            [WorldwideScreenSampleSink.formatRenegotiationFallbackDelay]
        )

        // ScreenCaptureKit can now emit only idle samples, which never reach this sink. Firing
        // the wall-clock deadline without another complete frame must still make progress.
        scheduler.runNext()

        XCTAssertFalse(sink.isDebouncingFormatRenegotiation)
        XCTAssertTrue(sink.isAwaitingFormatRenegotiation)
        XCTAssertFalse(authorization.isValid)
        XCTAssertEqual(renegotiations.value, 1)
        XCTAssertEqual(capturer.captureCount, 1)
    }

    func testRecoveredGeometryInvalidatesPendingFallbackDeadline() throws {
        let renegotiations = LockedCount()
        let capturer = RecordingScreenFrameCapturer()
        let scheduler = ManualFormatRenegotiationFallbackScheduler()
        let sink = WorldwideScreenSampleSink(
            capturer: capturer,
            remoteInputController: MacRemoteInputController(allowRemoteControl: false),
            didRequireCaptureFormatRenegotiation: { _ in
                renegotiations.increment()
            },
            scheduleFormatRenegotiationFallback: { delay, action in
                scheduler.schedule(delay, action)
            },
            didStop: { _, _ in }
        )
        let authorization = try XCTUnwrap(sink.beginForwarding())
        XCTAssertTrue(sink.commitForwardingStartup(authorizedBy: authorization))
        let sample = try makeImageSample()
        let fullFrame = try makeFullFrameGeometry()
        let insetFrame = try makeInsetFrameGeometry()

        sink.consumeScreenVideoSample(sample, frameGeometry: fullFrame)
        sink.consumeScreenVideoSample(sample, frameGeometry: insetFrame)
        XCTAssertTrue(sink.isDebouncingFormatRenegotiation)
        XCTAssertEqual(scheduler.scheduledDelays.count, 1)

        sink.consumeScreenVideoSample(sample, frameGeometry: fullFrame)
        XCTAssertFalse(sink.isDebouncingFormatRenegotiation)
        XCTAssertTrue(sink.allowsActiveUse(authorizedBy: authorization))
        XCTAssertEqual(capturer.captureCount, 2)

        // Work already enqueued on a dispatch queue cannot be unscheduled reliably. Its token
        // must be stale after recovery, so firing it cannot revoke the live generation.
        scheduler.runNext()

        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(sink.allowsActiveUse(authorizedBy: authorization))
        XCTAssertFalse(sink.isAwaitingFormatRenegotiation)
        XCTAssertEqual(renegotiations.value, 0)
        XCTAssertEqual(capturer.captureCount, 2)
    }
}

final class ScreenFormatRenegotiationCoordinatorTests: XCTestCase {
    func testReplacementRemainsQueuedUntilItsTaskAtomicallyClaimsIt() {
        let oldSink = CoordinatorSink()
        let replacementSink = CoordinatorSink()
        var coordinator = ScreenFormatRenegotiationCoordinator<CoordinatorSink>()

        XCTAssertEqual(
            coordinator.admit(
                oldSink,
                isCurrent: true,
                isAwaitingRenegotiation: true
            ),
            .begin
        )
        XCTAssertEqual(
            coordinator.admit(
                replacementSink,
                isCurrent: true,
                isAwaitingRenegotiation: true
            ),
            .coalesced
        )

        XCTAssertTrue(coordinator.finish(owner: oldSink) === replacementSink)
        XCTAssertEqual(coordinator.phase, .queued)
        XCTAssertTrue(coordinator.pending === replacementSink)

        XCTAssertEqual(
            coordinator.admit(
                replacementSink,
                isCurrent: true,
                isAwaitingRenegotiation: true
            ),
            .begin
        )
        XCTAssertEqual(coordinator.phase, .rebuilding)
        XCTAssertTrue(coordinator.owner === replacementSink)
        XCTAssertNil(coordinator.pending)
    }

    func testFailedOwnerDropsItsQueuedReplacement() {
        let oldSink = CoordinatorSink()
        let replacementSink = CoordinatorSink()
        var coordinator = ScreenFormatRenegotiationCoordinator<CoordinatorSink>()
        XCTAssertEqual(
            coordinator.admit(
                oldSink,
                isCurrent: true,
                isAwaitingRenegotiation: true
            ),
            .begin
        )
        XCTAssertEqual(
            coordinator.admit(
                replacementSink,
                isCurrent: true,
                isAwaitingRenegotiation: true
            ),
            .coalesced
        )

        coordinator.fail(owner: oldSink)

        XCTAssertNil(coordinator.finish(owner: oldSink))
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertNil(coordinator.owner)
        XCTAssertNil(coordinator.pending)
    }

    func testDuplicateOwnerRequestDoesNotQueueAnExtraRebuild() {
        let sink = CoordinatorSink()
        var coordinator = ScreenFormatRenegotiationCoordinator<CoordinatorSink>()
        XCTAssertEqual(
            coordinator.admit(
                sink,
                isCurrent: true,
                isAwaitingRenegotiation: true
            ),
            .begin
        )

        XCTAssertEqual(
            coordinator.admit(
                sink,
                isCurrent: true,
                isAwaitingRenegotiation: true
            ),
            .coalesced
        )
        XCTAssertNil(coordinator.pending)
        XCTAssertNil(coordinator.finish(owner: sink))
        XCTAssertEqual(coordinator.phase, .idle)
    }
}

private final class CoordinatorSink {}

private enum ImageSampleFixtureError: Error {
    case pixelBuffer(OSStatus)
    case formatDescription(OSStatus)
    case sampleBuffer(OSStatus)
}

private func makeFullFrameGeometry() throws -> ScreenVideoFrameGeometry {
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

private func makeInsetFrameGeometry() throws -> ScreenVideoFrameGeometry {
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

private func makeImageSample() throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    var status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        640,
        360,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw ImageSampleFixtureError.pixelBuffer(status)
    }

    var formatDescription: CMVideoFormatDescription?
    status = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
    )
    guard status == noErr, let formatDescription else {
        throw ImageSampleFixtureError.formatDescription(status)
    }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 60),
        presentationTimeStamp: CMTime(value: 1, timescale: 60),
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    status = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: formatDescription,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else {
        throw ImageSampleFixtureError.sampleBuffer(status)
    }
    return sampleBuffer
}

private final class RecordingScreenFrameCapturer:
    WorldwideScreenFrameCapturing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var captures = 0

    var captureCount: Int {
        lock.withLock { captures }
    }

    func captureScreenFrame(pixelBuffer _: CVPixelBuffer, timestamp _: CMTime) {
        lock.withLock { captures += 1 }
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class ManualFormatRenegotiationFallbackScheduler:
    @unchecked Sendable
{
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
