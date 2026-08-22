#if os(macOS)
import Foundation
import LiveKitWebRTC
import MacWebRTCAudioDeviceShim
import MacWebRTCAudioDeviceShimTestSupport
import XCTest

private final class SendableMacAudioDeviceBox: @unchecked Sendable {
    let device: ASMacStereoAudioDevice

    init(_ device: ASMacStereoAudioDevice) {
        self.device = device
    }
}

private final class SendablePCMContentRefBox: @unchecked Sendable {
    let reference: ASMacAudioQueuePCMContentRef

    init(_ reference: ASMacAudioQueuePCMContentRef) {
        self.reference = reference
    }
}

private final class SendableValueBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    func store(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    func load() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

/// Proves the pinned Objective-C ABI preserves every stereo sample, rejects inactive delivery,
/// and maintains a monotonic source clock across arbitrary callback sizes and restarts.
final class MacWebRTCAudioDeviceShimTests: XCTestCase {
    private static let inputChannelCount = 2
    private static let outputChannelCount = 1

    func testPinnedRuntimePreflightAndSwiftImporter() throws {
        var error: NSError?
        XCTAssertTrue(ASMacWebRTCAudioDevicePreflight(&error), "\(String(describing: error))")
        XCTAssertNil(error)

        let device = try XCTUnwrap(ASMacStereoAudioDevice())
        let diagnostics = device.diagnostics
        XCTAssertFalse(diagnostics.initialized)
        XCTAssertFalse(diagnostics.recordingInitialized)
        XCTAssertFalse(diagnostics.recording)
        XCTAssertFalse(diagnostics.playoutInitialized)
        XCTAssertFalse(diagnostics.playing)
        XCTAssertEqual(diagnostics.receivedFrameCount, 0)
        XCTAssertEqual(diagnostics.deliveredFrameCount, 0)
    }

    func testAudioQueueRuntimeFailureLatchPublishesFirstStatusAndConsumesOnce() throws {
        let latch = try XCTUnwrap(
            ASMacAudioQueueRuntimeFailureLatchCreate()
        )
        defer {
            ASMacAudioQueueRuntimeFailureLatchDestroy(latch)
        }

        let firstStatus = Int32(-66_101)
        let repeatedStatus = Int32(-66_102)
        ASMacAudioQueueRuntimeFailureLatchPublish(
            latch,
            firstStatus
        )
        ASMacAudioQueueRuntimeFailureLatchPublish(
            latch,
            repeatedStatus
        )

        var observedStatus: Int32 = 0
        XCTAssertTrue(
            ASMacAudioQueueRuntimeFailureLatchTake(
                latch,
                &observedStatus
            )
        )
        XCTAssertEqual(observedStatus, firstStatus)
        XCTAssertFalse(
            ASMacAudioQueueRuntimeFailureLatchTake(
                latch,
                &observedStatus
            )
        )

        ASMacAudioQueueRuntimeFailureLatchReset(latch)
        ASMacAudioQueueRuntimeFailureLatchPublish(
            latch,
            repeatedStatus
        )
        XCTAssertTrue(
            ASMacAudioQueueRuntimeFailureLatchTake(
                latch,
                &observedStatus
            )
        )
        XCTAssertEqual(observedStatus, repeatedStatus)
    }

    func testAudioQueueProgressExcludesPrimingAndPublishesPostStartOutcomes()
        throws {
        let progress = try XCTUnwrap(
            ASMacAudioQueueProgressCreate()
        )
        defer {
            ASMacAudioQueueProgressDestroy(progress)
        }

        ASMacAudioQueueProgressReset(progress)
        ASMacAudioQueueProgressPublish(
            progress,
            480,
            true,
            noErr
        )
        var snapshot = ASMacAudioQueueProgressRead(progress)
        XCTAssertFalse(snapshot.queueRunning)
        XCTAssertEqual(snapshot.postStartCallbackCount, 0)
        XCTAssertEqual(snapshot.successfulFrameCount, 0)

        ASMacAudioQueueProgressSetQueueRunning(
            progress,
            true
        )
        ASMacAudioQueueProgressPublish(
            progress,
            480,
            true,
            noErr
        )
        ASMacAudioQueueProgressPublish(
            progress,
            480,
            false,
            noErr
        )
        let failure = Int32(-66_103)
        ASMacAudioQueueProgressPublish(
            progress,
            480,
            false,
            failure
        )

        snapshot = ASMacAudioQueueProgressRead(progress)
        XCTAssertTrue(snapshot.queueRunning)
        XCTAssertEqual(snapshot.postStartCallbackCount, 3)
        XCTAssertEqual(snapshot.requestedFrameCount, 1_440)
        XCTAssertEqual(snapshot.successfulPullCount, 1)
        XCTAssertEqual(snapshot.successfulFrameCount, 480)
        XCTAssertEqual(snapshot.silenceFallbackCount, 2)
        XCTAssertEqual(snapshot.silenceFrameCount, 960)
        XCTAssertEqual(snapshot.enqueueFailureCount, 1)
        XCTAssertEqual(snapshot.lastEnqueueStatus, failure)

        ASMacAudioQueueProgressSetQueueRunning(
            progress,
            false
        )
        ASMacAudioQueueProgressPublish(
            progress,
            480,
            true,
            noErr
        )
        let stopped = ASMacAudioQueueProgressRead(progress)
        XCTAssertFalse(stopped.queueRunning)
        XCTAssertEqual(stopped.postStartCallbackCount, 3)
        XCTAssertEqual(stopped.successfulFrameCount, 480)
    }

    #if DEBUG
    func testAudioQueuePCMContentConcurrentResetReadCannotABA() throws {
        let reference = try XCTUnwrap(
            ASMacAudioQueuePCMContentCreate()
        )
        defer {
            ASMacAudioQueuePCMContentDestroy(reference)
        }

        var firstWindow = ASMacAudioQueuePCMContentRawWindow()
        firstWindow.sourceStartFrame = 0
        firstWindow.sourceEndFrame = 48_000
        firstWindow.windowFingerprint = 0x1111_2222_3333_4444
        firstWindow.frameCount = 48_000
        firstWindow.sampleSum = 17
        ASMacAudioQueuePCMContentPublish(reference, firstWindow)
        let first = ASMacAudioQueuePCMContentRead(reference)
        XCTAssertTrue(first.hasCompletedWindow)
        XCTAssertEqual(first.lifecycleGeneration, 1)
        XCTAssertEqual(first.windowSequence, 1)

        let referenceBox = SendablePCMContentRefBox(reference)
        let racedResult =
            SendableValueBox<ASMacAudioQueuePCMContentSnapshot>()
        let readReturned = DispatchSemaphore(value: 0)
        ASMacAudioQueuePCMContentHoldReadForTesting(reference)
        DispatchQueue.global(qos: .userInitiated).async {
            racedResult.store(
                ASMacAudioQueuePCMContentRead(referenceBox.reference)
            )
            readReturned.signal()
        }

        let heldDeadline = Date().addingTimeInterval(1)
        while !ASMacAudioQueuePCMContentReadIsHeldForTesting(reference),
              Date() < heldDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertTrue(
            ASMacAudioQueuePCMContentReadIsHeldForTesting(reference)
        )

        ASMacAudioQueuePCMContentReset(reference)
        var secondWindow = ASMacAudioQueuePCMContentRawWindow()
        secondWindow.sourceStartFrame = 48_000
        secondWindow.sourceEndFrame = 96_000
        secondWindow.windowFingerprint = 0xaaaa_bbbb_cccc_dddd
        secondWindow.frameCount = 48_000
        secondWindow.sampleSum = -23
        ASMacAudioQueuePCMContentPublish(reference, secondWindow)
        ASMacAudioQueuePCMContentReleaseReadForTesting(reference)

        XCTAssertEqual(
            readReturned.wait(timeout: .now() + .seconds(1)),
            .success
        )
        let raced = try XCTUnwrap(racedResult.load())
        XCTAssertTrue(raced.hasCompletedWindow)
        XCTAssertEqual(raced.lifecycleGeneration, 2)
        XCTAssertEqual(raced.windowSequence, 2)
        XCTAssertEqual(raced.completedFrameCount, 48_000)
        XCTAssertEqual(raced.window.sourceStartFrame, 48_000)
        XCTAssertEqual(raced.window.sourceEndFrame, 96_000)
        XCTAssertEqual(
            raced.window.windowFingerprint,
            0xaaaa_bbbb_cccc_dddd
        )
        XCTAssertEqual(raced.window.sampleSum, -23)
    }
    #endif

    func testInactiveDirectDeliveryFailsClosedAndCountsRejectedPCM() throws {
        let device = try XCTUnwrap(ASMacStereoAudioDevice())
        let samples = Self.stereoSequence(frameRange: 0..<480)

        XCTAssertFalse(deliver(samples, frameCount: 480, into: device))

        let diagnostics = device.diagnostics
        XCTAssertEqual(diagnostics.receivedFrameCount, 480)
        XCTAssertEqual(diagnostics.deliveredFrameCount, 0)
        XCTAssertEqual(diagnostics.rejectedFrameCount, 480)
        XCTAssertEqual(diagnostics.deliveryCallbackCount, 0)
        XCTAssertEqual(diagnostics.deliveryFailureCount, 0)
    }

    func testStereoDeliveryUsesNativeRenderPathForEveryInterleavedSample() throws {
        let device = try XCTUnwrap(ASMacStereoAudioDevice())
        let harness = ASMacStereoAudioDeviceTestHarness(device: device)
        XCTAssertTrue(harness.startRecording())

        XCTAssertTrue(deliver(frameRange: 0..<480, into: device))

        let diagnostics = harness.diagnostics
        XCTAssertEqual(
            diagnostics.directInputDataCallbackCount,
            0,
            "The pinned native direct-input path truncates stereo to frameCount elements."
        )
        XCTAssertEqual(diagnostics.renderBlockCallbackCount, 1)
        XCTAssertEqual(
            diagnostics.renderedSampleElementCount,
            UInt64(480 * Self.inputChannelCount)
        )
        XCTAssertEqual(diagnostics.frameCount, 480)
        XCTAssertEqual(diagnostics.invalidBufferListCount, 0)
        XCTAssertEqual(diagnostics.samplePatternMismatchCount, 0)

        let deviceDiagnostics = device.diagnostics
        XCTAssertEqual(deviceDiagnostics.deliveredFrameCount, 480)
        XCTAssertEqual(deviceDiagnostics.deliveryFailureCount, 0)
        XCTAssertEqual(deviceDiagnostics.nativeDeliveryErrorCount, 0)
        XCTAssertEqual(deviceDiagnostics.renderInvocationCount, 1)
        XCTAssertEqual(deviceDiagnostics.renderCopiedFrameCount, 480)
        XCTAssertEqual(deviceDiagnostics.renderCopiedSampleElementCount, 960)
        XCTAssertEqual(deviceDiagnostics.renderNotInvokedCount, 0)
        XCTAssertEqual(deviceDiagnostics.renderMultipleInvocationCount, 0)
        XCTAssertEqual(deviceDiagnostics.renderValidationFailureCount, 0)
        XCTAssertEqual(deviceDiagnostics.prefilledInputDataDeliveryCount, 0)
    }

    func testDelegateNoErrWithoutRenderInvocationFailsClosed() throws {
        let device = try XCTUnwrap(ASMacStereoAudioDevice())
        let harness = ASMacStereoAudioDeviceTestHarness(device: device)
        XCTAssertTrue(harness.startRecording())
        harness.deliveryBehavior = .returnSuccessWithoutRender

        XCTAssertFalse(deliver(frameRange: 0..<480, into: device))

        let diagnostics = device.diagnostics
        XCTAssertEqual(diagnostics.receivedFrameCount, 480)
        XCTAssertEqual(diagnostics.deliveredFrameCount, 0)
        XCTAssertEqual(diagnostics.rejectedFrameCount, 480)
        XCTAssertEqual(diagnostics.deliveryCallbackCount, 1)
        XCTAssertEqual(diagnostics.deliveryFailureCount, 1)
        XCTAssertEqual(diagnostics.nativeDeliveryErrorCount, 0)
        XCTAssertEqual(diagnostics.renderInvocationCount, 0)
        XCTAssertEqual(diagnostics.renderCopiedFrameCount, 0)
        XCTAssertEqual(diagnostics.renderCopiedSampleElementCount, 0)
        XCTAssertEqual(diagnostics.renderNotInvokedCount, 1)
        XCTAssertEqual(diagnostics.renderMultipleInvocationCount, 0)
        XCTAssertEqual(diagnostics.renderValidationFailureCount, 0)
        XCTAssertEqual(diagnostics.prefilledInputDataDeliveryCount, 0)
        XCTAssertEqual(harness.diagnostics.renderBlockCallbackCount, 0)
    }

    func testMultipleOrInvalidRenderInvocationsFailClosedWithExactDiagnostics() throws {
        do {
            let device = try XCTUnwrap(ASMacStereoAudioDevice())
            let harness = ASMacStereoAudioDeviceTestHarness(device: device)
            XCTAssertTrue(harness.startRecording())
            harness.deliveryBehavior = .invokeRenderTwice

            XCTAssertFalse(deliver(frameRange: 0..<480, into: device))

            let diagnostics = device.diagnostics
            XCTAssertEqual(diagnostics.deliveredFrameCount, 0)
            XCTAssertEqual(diagnostics.rejectedFrameCount, 480)
            XCTAssertEqual(diagnostics.deliveryFailureCount, 1)
            XCTAssertEqual(diagnostics.nativeDeliveryErrorCount, 0)
            XCTAssertEqual(diagnostics.renderInvocationCount, 2)
            XCTAssertEqual(diagnostics.renderCopiedFrameCount, 960)
            XCTAssertEqual(diagnostics.renderCopiedSampleElementCount, 1_920)
            XCTAssertEqual(diagnostics.renderNotInvokedCount, 0)
            XCTAssertEqual(diagnostics.renderMultipleInvocationCount, 1)
            XCTAssertEqual(diagnostics.renderValidationFailureCount, 0)
            XCTAssertEqual(diagnostics.prefilledInputDataDeliveryCount, 0)
        }

        do {
            let device = try XCTUnwrap(ASMacStereoAudioDevice())
            let harness = ASMacStereoAudioDeviceTestHarness(device: device)
            XCTAssertTrue(harness.startRecording())
            harness.deliveryBehavior = .returnSuccessAfterInvalidRender

            XCTAssertFalse(deliver(frameRange: 0..<480, into: device))

            let diagnostics = device.diagnostics
            XCTAssertEqual(diagnostics.deliveredFrameCount, 0)
            XCTAssertEqual(diagnostics.rejectedFrameCount, 480)
            XCTAssertEqual(diagnostics.deliveryFailureCount, 1)
            XCTAssertEqual(diagnostics.nativeDeliveryErrorCount, 0)
            XCTAssertEqual(diagnostics.renderInvocationCount, 1)
            XCTAssertEqual(diagnostics.renderCopiedFrameCount, 0)
            XCTAssertEqual(diagnostics.renderCopiedSampleElementCount, 0)
            XCTAssertEqual(diagnostics.renderNotInvokedCount, 0)
            XCTAssertEqual(diagnostics.renderMultipleInvocationCount, 0)
            XCTAssertEqual(diagnostics.renderValidationFailureCount, 1)
            XCTAssertEqual(diagnostics.prefilledInputDataDeliveryCount, 0)
        }
    }

    func testRealNativeInactiveADMNoErrWithoutRenderInvocationFailsClosed() throws {
        XCTAssertTrue(LKRTCInitializeSSL())
        let device = try XCTUnwrap(ASMacStereoAudioDevice())
        var error: NSError?
        var factory: LKRTCPeerConnectionFactory? = ASCreateMacStereoPeerConnectionFactory(
            nil,
            nil,
            device,
            &error
        )
        XCTAssertNotNil(factory, "\(String(describing: error))")
        let configuration = LKRTCConfiguration()
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        var peer = factory?.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: nil
        )
        XCTAssertNotNil(peer)
        XCTAssertTrue(device.diagnostics.initialized)
        XCTAssertFalse(device.diagnostics.recording)

        XCTAssertTrue(ASStartMacStereoDeviceRecordingWithoutStartingNativeADM(device))
        XCTAssertFalse(deliver(frameRange: 0..<480, into: device))

        let diagnostics = device.diagnostics
        XCTAssertEqual(diagnostics.receivedFrameCount, 480)
        XCTAssertEqual(diagnostics.deliveredFrameCount, 0)
        XCTAssertEqual(diagnostics.rejectedFrameCount, 480)
        XCTAssertEqual(diagnostics.deliveryCallbackCount, 1)
        XCTAssertEqual(diagnostics.deliveryFailureCount, 1)
        XCTAssertEqual(
            diagnostics.nativeDeliveryErrorCount,
            0,
            "Pinned native ADM returned noErr despite consuming no PCM."
        )
        XCTAssertEqual(diagnostics.renderInvocationCount, 0)
        XCTAssertEqual(diagnostics.renderNotInvokedCount, 1)
        XCTAssertEqual(diagnostics.renderValidationFailureCount, 0)
        XCTAssertEqual(diagnostics.prefilledInputDataDeliveryCount, 0)

        peer?.close()
        peer = nil
        factory = nil
    }

    func testRepeatedNativeStartsAreIdempotentAndPreserveTimestampsAndAdmission() throws {
        let device = try XCTUnwrap(ASMacStereoAudioDevice())
        let harness = ASMacStereoAudioDeviceTestHarness(device: device)
        XCTAssertTrue(harness.startRecording())
        XCTAssertTrue(harness.startPlayout())

        XCTAssertTrue(deliver(frameRange: 0..<480, into: device))
        XCTAssertTrue(device.pullHeadlessPlayoutFrames(256))
        let before = device.diagnostics
        XCTAssertEqual(before.recordingGeneration, 1)
        XCTAssertEqual(before.approvedRecordingGeneration, 1)
        XCTAssertEqual(before.timestampResetCount, 1)

        // WebRTC is permitted to issue duplicate Start calls. They are protocol no-ops while the
        // same stream is active, not a new recording generation or a timestamp discontinuity.
        XCTAssertTrue(harness.repeatStartRecording())
        XCTAssertTrue(harness.repeatStartPlayout())
        let afterRepeatedStarts = device.diagnostics
        XCTAssertEqual(afterRepeatedStarts.recordingGeneration, before.recordingGeneration)
        XCTAssertEqual(
            afterRepeatedStarts.approvedRecordingGeneration,
            before.approvedRecordingGeneration
        )
        XCTAssertEqual(afterRepeatedStarts.timestampResetCount, before.timestampResetCount)

        XCTAssertTrue(deliver(frameRange: 480..<960, into: device))
        XCTAssertTrue(device.pullHeadlessPlayoutFrames(512))

        let deviceDiagnostics = device.diagnostics
        let harnessDiagnostics = harness.diagnostics
        XCTAssertEqual(deviceDiagnostics.deliveredFrameCount, 960)
        XCTAssertEqual(deviceDiagnostics.lastDeliverySampleTime, 480)
        XCTAssertEqual(deviceDiagnostics.playoutFrameCount, 768)
        XCTAssertEqual(harnessDiagnostics.sampleTimeDiscontinuityCount, 0)
        XCTAssertEqual(harnessDiagnostics.hostTimeDiscontinuityCount, 0)
        XCTAssertEqual(harnessDiagnostics.playoutSampleTimeDiscontinuityCount, 0)
        XCTAssertEqual(harnessDiagnostics.playoutHostTimeDiscontinuityCount, 0)
        XCTAssertEqual(harnessDiagnostics.samplePatternMismatchCount, 0)
    }

    func testCallerOwnedPlayoutPullWritesExactFrameCountWithoutFailure() throws {
        let device = try XCTUnwrap(ASMacStereoAudioDevice())
        let harness = ASMacStereoAudioDeviceTestHarness(device: device)
        XCTAssertEqual(
            ASMacStereoDeviceInputChannelCountForTesting(device),
            2
        )
        XCTAssertEqual(
            ASMacStereoDeviceOutputChannelCountForTesting(device),
            1
        )
        XCTAssertTrue(harness.startPlayout())

        var samples = Array(repeating: Int16.max, count: 480)
        let rendered = samples.withUnsafeMutableBufferPointer { buffer in
            device.renderPlayoutMonoInt16(
                buffer.baseAddress!,
                frameCount: 480
            )
        }

        XCTAssertTrue(rendered)
        XCTAssertTrue(samples.allSatisfy { $0 == 0 })
        let native = device.diagnostics
        let delegate = harness.diagnostics
        XCTAssertEqual(native.playoutCallbackCount, 1)
        XCTAssertEqual(native.playoutFrameCount, 480)
        XCTAssertEqual(native.playoutFailureCount, 0)
        XCTAssertEqual(delegate.playoutCallbackCount, 1)
        XCTAssertEqual(delegate.lastPlayoutFrameCount, 480)
        let telemetry = device.decodedPlayoutTelemetry
        XCTAssertEqual(telemetry.latestRequestedFrameCount, 480)
        XCTAssertEqual(telemetry.latestRequestedByteCount, 960)
        XCTAssertEqual(telemetry.latestReturnedByteCount, 960)
        XCTAssertEqual(
            delegate.playoutSampleTimeDiscontinuityCount,
            0
        )
        XCTAssertEqual(
            delegate.playoutHostTimeDiscontinuityCount,
            0
        )
    }

    func testCallerOwnedPlayoutPullRejectsNativeSuccessWithShortBufferContract()
        throws {
        let device = try XCTUnwrap(ASMacStereoAudioDevice())
        let harness = ASMacStereoAudioDeviceTestHarness(device: device)
        harness.playoutPattern = .alternating
        harness.playoutContractBehavior = .returnSuccessWithShortBuffer
        XCTAssertTrue(harness.startPlayout())

        var samples = Array(repeating: Int16.max, count: 480)
        let rendered = samples.withUnsafeMutableBufferPointer { buffer in
            device.renderPlayoutMonoInt16(
                buffer.baseAddress!,
                frameCount: 480
            )
        }

        XCTAssertFalse(rendered)
        XCTAssertTrue(samples.allSatisfy { $0 == 0 })
        let diagnostics = device.diagnostics
        XCTAssertEqual(diagnostics.playoutCallbackCount, 1)
        XCTAssertEqual(diagnostics.playoutFrameCount, 0)
        XCTAssertEqual(diagnostics.playoutFailureCount, 1)

        let telemetry = device.decodedPlayoutTelemetry
        XCTAssertEqual(telemetry.renderCallCount, 1)
        XCTAssertEqual(telemetry.nativeSuccessRenderCallCount, 1)
        XCTAssertEqual(telemetry.bufferContractMismatchCount, 1)
        XCTAssertEqual(telemetry.exactBufferContractCount, 0)
        XCTAssertEqual(telemetry.analyzedRenderCallCount, 0)
        XCTAssertEqual(telemetry.analyzedFrameCount, 0)
        XCTAssertFalse(telemetry.latestBufferContractWasExact)
        XCTAssertFalse(telemetry.hasCompletedWindow)
    }

    func testCallerOwnedPlayoutPullRejectsMalformedNativeChannelContract()
        throws {
        let device = try XCTUnwrap(ASMacStereoAudioDevice())
        let harness = ASMacStereoAudioDeviceTestHarness(device: device)
        harness.playoutPattern = .alternating
        harness.playoutContractBehavior =
            .returnSuccessWithWrongChannelCount
        XCTAssertTrue(harness.startPlayout())

        var samples = Array(repeating: Int16.max, count: 480)
        let rendered = samples.withUnsafeMutableBufferPointer { buffer in
            device.renderPlayoutMonoInt16(
                buffer.baseAddress!,
                frameCount: 480
            )
        }

        XCTAssertFalse(rendered)
        XCTAssertTrue(samples.allSatisfy { $0 == 0 })
        let telemetry = device.decodedPlayoutTelemetry
        XCTAssertEqual(telemetry.latestRequestedFrameCount, 480)
        XCTAssertEqual(telemetry.latestRequestedByteCount, 960)
        XCTAssertEqual(telemetry.latestReturnedByteCount, 960)
        XCTAssertFalse(telemetry.latestBufferContractWasExact)
        XCTAssertEqual(telemetry.bufferContractMismatchCount, 1)
        XCTAssertEqual(telemetry.analyzedFrameCount, 0)
    }

    func testDecodedPlayoutTelemetryPublishesExactOneSecondMonoWindow() throws {
        let device = try XCTUnwrap(ASMacStereoAudioDevice())
        let harness = ASMacStereoAudioDeviceTestHarness(device: device)
        harness.playoutPattern = .alternating
        XCTAssertTrue(harness.startPlayout())

        var samples = Array(repeating: Int16.zero, count: 480)
        for _ in 0..<100 {
            XCTAssertTrue(samples.withUnsafeMutableBufferPointer { buffer in
                device.renderPlayoutMonoInt16(
                    buffer.baseAddress!,
                    frameCount: 480
                )
            })
        }

        let telemetry = device.decodedPlayoutTelemetry
        XCTAssertEqual(telemetry.playoutGeneration, 1)
        XCTAssertEqual(telemetry.renderCallCount, 100)
        XCTAssertEqual(telemetry.requestedFrameCount, 48_000)
        XCTAssertEqual(telemetry.requestedByteCount, 96_000)
        XCTAssertEqual(telemetry.returnedByteCount, 96_000)
        XCTAssertEqual(telemetry.nativeSuccessRenderCallCount, 100)
        XCTAssertEqual(telemetry.nativeFailureRenderCallCount, 0)
        XCTAssertEqual(telemetry.exactBufferContractCount, 100)
        XCTAssertEqual(telemetry.bufferContractMismatchCount, 0)
        XCTAssertEqual(telemetry.analyzedRenderCallCount, 100)
        XCTAssertEqual(telemetry.analyzedFrameCount, 48_000)
        XCTAssertEqual(telemetry.analyzedByteCount, 96_000)
        XCTAssertEqual(telemetry.droppedTelemetryRenderCallCount, 0)
        XCTAssertEqual(telemetry.pendingWindowFrameCount, 0)
        XCTAssertEqual(telemetry.latestRenderCall, 100)
        XCTAssertEqual(telemetry.latestRenderStatus, noErr)
        XCTAssertEqual(telemetry.latestRequestedFrameCount, 480)
        XCTAssertEqual(telemetry.latestRequestedByteCount, 960)
        XCTAssertEqual(telemetry.latestReturnedByteCount, 960)
        XCTAssertTrue(telemetry.latestBufferContractWasExact)

        XCTAssertTrue(telemetry.hasCompletedWindow)
        XCTAssertEqual(telemetry.completedWindowSequence, 1)
        XCTAssertEqual(telemetry.completedWindowGeneration, 1)
        XCTAssertEqual(telemetry.completedWindowFirstRenderCall, 1)
        XCTAssertEqual(telemetry.completedWindowLastRenderCall, 100)
        XCTAssertEqual(telemetry.completedWindowRenderCallCount, 100)
        XCTAssertEqual(telemetry.completedWindowFrameCount, 48_000)
        XCTAssertEqual(telemetry.completedWindowByteCount, 96_000)
        XCTAssertEqual(telemetry.completedWindowDurationSeconds, 1, accuracy: 0.000_001)
        XCTAssertEqual(telemetry.rms, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(telemetry.peak, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(telemetry.dc, 0, accuracy: 0.000_001)
        XCTAssertEqual(telemetry.zeroSampleCount, 0)
        XCTAssertEqual(telemetry.clippedSampleCount, 0)
        XCTAssertEqual(telemetry.frozenBlockCount, 99)
        XCTAssertEqual(telemetry.longestFrozenBlockRun, 99)
    }

    func testDecodedPlayoutTelemetryReportsMonoSilenceClippingAndDC() throws {
        let clipped = try completedTelemetry(pattern: .clippedDC)
        XCTAssertEqual(clipped.clippingFraction, 1, accuracy: 0.000_001)
        XCTAssertEqual(clipped.peak, 1, accuracy: 0.000_001)
        XCTAssertEqual(clipped.dc, -1, accuracy: 0.000_001)

        let silence = try completedTelemetry(pattern: .silence)
        XCTAssertTrue(silence.windowIsAllZero)
        XCTAssertEqual(silence.zeroSampleCount, 48_000)
        XCTAssertEqual(silence.zeroFraction, 1, accuracy: 0.000_001)
        XCTAssertEqual(silence.allZeroBlockCount, 1)

        let dcNoise = try completedTelemetry(pattern: .dcOffsetNoise)
        XCTAssertEqual(dcNoise.dc, 12_000.0 / 32_768.0, accuracy: 0.000_001)

        let nearClipping = try completedTelemetry(pattern: .nearClipping)
        XCTAssertEqual(
            nearClipping.clippingFraction,
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            nearClipping.peak,
            32_760.0 / 32_768.0,
            accuracy: 0.000_001
        )
    }

    func testDecodedPlayoutTelemetrySplitsArbitraryCallbacksIntoExactWindows() throws {
        let device = try XCTUnwrap(ASMacStereoAudioDevice())
        let harness = ASMacStereoAudioDeviceTestHarness(device: device)
        harness.playoutPattern = .dcOffsetNoise
        XCTAssertTrue(harness.startPlayout())

        let callbackPattern = [1_024, 441, 1_536, 480, 2_048, 735, 1_000, 256]
        var samples = Array(
            repeating: Int16.zero,
            count: callbackPattern.max()! * Self.outputChannelCount
        )
        var requestedFrameCount = 0
        var callbackIndex = 0
        while requestedFrameCount <= 48_000 {
            let frameCount = callbackPattern[
                callbackIndex % callbackPattern.count
            ]
            XCTAssertTrue(samples.withUnsafeMutableBufferPointer { buffer in
                device.renderPlayoutMonoInt16(
                    buffer.baseAddress!,
                    frameCount: UInt(frameCount)
                )
            })
            requestedFrameCount += frameCount
            callbackIndex += 1
        }

        let telemetry = device.decodedPlayoutTelemetry
        XCTAssertTrue(telemetry.hasCompletedWindow)
        XCTAssertEqual(telemetry.completedWindowSequence, 1)
        XCTAssertEqual(telemetry.completedWindowFrameCount, 48_000)
        XCTAssertEqual(telemetry.completedWindowByteCount, 96_000)
        XCTAssertEqual(telemetry.completedWindowSourceStartFrame, 0)
        XCTAssertEqual(telemetry.completedWindowSourceEndFrame, 48_000)
        XCTAssertEqual(
            telemetry.pendingWindowFrameCount,
            UInt64(requestedFrameCount - 48_000)
        )
        XCTAssertEqual(
            telemetry.completedWindowFingerprint,
            Self.fnv1aFingerprint(frameCount: 48_000) { frame in
                let noise: Int16 = frame.isMultiple(of: 2) ? 512 : -512
                return 12_000 + noise
            }
        )
    }

    #if DEBUG
    func testDecodedCompletedWindowReadSpanningResetCannotABA() throws {
        let device = try XCTUnwrap(ASMacStereoAudioDevice())
        let harness = ASMacStereoAudioDeviceTestHarness(device: device)
        harness.playoutPattern = .alternating
        XCTAssertTrue(harness.startPlayout())
        var samples = Array(repeating: Int16.zero, count: 48_000)
        XCTAssertTrue(samples.withUnsafeMutableBufferPointer { buffer in
            device.renderPlayoutMonoInt16(
                buffer.baseAddress!,
                frameCount: 48_000
            )
        })
        XCTAssertEqual(device.decodedPlayoutTelemetry.completedWindowSequence, 1)

        let deviceBox = SendableMacAudioDeviceBox(device)
        let racedResult =
            SendableValueBox<ASMacDecodedPlayoutTelemetrySnapshot>()
        let readReturned = DispatchSemaphore(value: 0)
        device.holdDecodedTelemetryReadsForTesting()
        DispatchQueue.global(qos: .userInitiated).async {
            racedResult.store(deviceBox.device.decodedPlayoutTelemetry)
            readReturned.signal()
        }

        let heldDeadline = Date().addingTimeInterval(1)
        while !device.decodedTelemetryReadIsHeldForTesting,
              Date() < heldDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertTrue(device.decodedTelemetryReadIsHeldForTesting)

        XCTAssertTrue(harness.stopPlayout())
        harness.playoutPattern = .clippedDC
        XCTAssertTrue(harness.startPlayout())
        XCTAssertTrue(samples.withUnsafeMutableBufferPointer { buffer in
            device.renderPlayoutMonoInt16(
                buffer.baseAddress!,
                frameCount: 48_000
            )
        })
        device.releaseDecodedTelemetryReadsForTesting()

        XCTAssertEqual(
            readReturned.wait(timeout: .now() + .seconds(1)),
            .success
        )
        let raced = try XCTUnwrap(racedResult.load())
        XCTAssertFalse(
            raced.hasCompletedWindow,
            "A read linearized before reset must not accept the new payload under the old generation."
        )

        let fresh = device.decodedPlayoutTelemetry
        XCTAssertTrue(fresh.hasCompletedWindow)
        XCTAssertEqual(fresh.playoutGeneration, 2)
        XCTAssertEqual(fresh.completedWindowGeneration, 2)
        XCTAssertEqual(fresh.completedWindowSequence, 2)
        XCTAssertEqual(fresh.completedWindowSourceStartFrame, 0)
        XCTAssertEqual(fresh.completedWindowSourceEndFrame, 48_000)
        XCTAssertEqual(fresh.dc, -1, accuracy: 0.000_001)
    }
    #endif

    #if DEBUG
    func testStopPlayoutFencesHeldInFlightPullBeforeReturning() throws {
        let device = try XCTUnwrap(ASMacStereoAudioDevice())
        let harness = ASMacStereoAudioDeviceTestHarness(device: device)
        XCTAssertTrue(harness.startPlayout())
        let box = SendableMacAudioDeviceBox(device)
        let pullReturned = DispatchSemaphore(value: 0)
        let stopReturned = DispatchSemaphore(value: 0)

        device.holdPlayoutPullsForTesting()
        DispatchQueue.global(qos: .userInitiated).async {
            var samples = Array(repeating: Int16.max, count: 480)
            _ = samples.withUnsafeMutableBufferPointer { buffer in
                box.device.renderPlayoutMonoInt16(
                    buffer.baseAddress!,
                    frameCount: 480
                )
            }
            pullReturned.signal()
        }

        let heldDeadline = Date().addingTimeInterval(1)
        while !device.playoutPullIsHeldForTesting,
              Date() < heldDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertTrue(device.playoutPullIsHeldForTesting)
        XCTAssertEqual(device.diagnostics.playoutPullsInFlight, 1)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = box.device.stopPlayoutAndFenceForTesting()
            stopReturned.signal()
        }

        let fenceDeadline = Date().addingTimeInterval(1)
        while device.diagnostics.playoutFenceWaitCount == 0,
              Date() < fenceDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(device.diagnostics.playoutFenceWaitCount, 1)
        XCTAssertEqual(device.diagnostics.playoutPullsInFlight, 1)
        XCTAssertEqual(
            stopReturned.wait(timeout: .now() + .milliseconds(20)),
            .timedOut
        )

        device.releasePlayoutPullsForTesting()
        XCTAssertEqual(
            pullReturned.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(
            stopReturned.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(device.diagnostics.playoutPullsInFlight, 0)
        XCTAssertFalse(device.diagnostics.playing)
    }
    #endif

    func testRestartRequiresFreshGenerationApprovalAndResetsTimestampsExactlyOnce() throws {
        let device = try XCTUnwrap(ASMacStereoAudioDevice())
        let harness = ASMacStereoAudioDeviceTestHarness(device: device)
        XCTAssertTrue(harness.startRecording())
        XCTAssertTrue(deliver(frameRange: 0..<333, into: device))

        let firstGeneration = device.diagnostics.recordingGeneration
        XCTAssertTrue(harness.restartRecordingWithoutApproval())
        var diagnostics = device.diagnostics
        XCTAssertEqual(diagnostics.recordingGeneration, firstGeneration + 1)
        XCTAssertEqual(diagnostics.approvedRecordingGeneration, 0)
        XCTAssertEqual(diagnostics.timestampResetCount, 2)

        // A native restart invalidates the previous APM proof. No source PCM may cross the ADM
        // boundary until the peer re-verifies raw processing and approves this exact generation.
        XCTAssertFalse(deliver(frameRange: 0..<257, into: device))
        diagnostics = device.diagnostics
        XCTAssertEqual(diagnostics.admissionBlockedFrameCount, 257)
        XCTAssertEqual(diagnostics.rejectedFrameCount, 257)

        XCTAssertTrue(harness.approveCurrentRecordingGeneration())
        XCTAssertTrue(deliver(frameRange: 0..<257, into: device))
        diagnostics = device.diagnostics
        XCTAssertEqual(
            diagnostics.approvedRecordingGeneration,
            diagnostics.recordingGeneration
        )
        XCTAssertEqual(diagnostics.lastDeliverySampleTime, 0)
        XCTAssertEqual(diagnostics.deliveredFrameCount, 590)

        let harnessDiagnostics = harness.diagnostics
        XCTAssertEqual(harnessDiagnostics.sampleTimeDiscontinuityCount, 0)
        XCTAssertEqual(harnessDiagnostics.hostTimeDiscontinuityCount, 0)
        XCTAssertEqual(harnessDiagnostics.samplePatternMismatchCount, 0)
    }

    func testArbitrarySourceCadencePreservesThirtyMinutesOfExactStereoPCM() throws {
        // This is 30 minutes of source-clock callbacks without sleeping. The callback-size pattern
        // deliberately contains non-10-ms sizes. Native FineAudioBuffer—not an app ring/timer—owns
        // the required splitting and accumulation after this exact production boundary.
        let totalFrameCount = 48_000 * 60 * 30
        let callbackFramePattern = [960, 1_024, 441, 1_536, 480, 2_048, 735, 1_000, 256]
        let device = try XCTUnwrap(ASMacStereoAudioDevice())
        let harness = ASMacStereoAudioDeviceTestHarness(device: device)
        XCTAssertTrue(harness.startRecording())

        var samples = [Int16](
            repeating: 0,
            count: callbackFramePattern.max()! * Self.inputChannelCount
        )
        var sourceFrame = 0
        var callbackIndex = 0
        while sourceFrame < totalFrameCount {
            let frameCount = min(
                callbackFramePattern[callbackIndex % callbackFramePattern.count],
                totalFrameCount - sourceFrame
            )
            for localFrame in 0..<frameCount {
                let marker = Int16(((sourceFrame + localFrame) % 30_000) + 1)
                samples[localFrame * 2] = marker
                samples[localFrame * 2 + 1] = -marker
            }
            let accepted = samples.withUnsafeBufferPointer { buffer in
                device.deliverInterleavedStereoInt16(
                    buffer.baseAddress!,
                    frameCount: UInt(frameCount)
                )
            }
            guard accepted else {
                XCTFail("Source callback \(callbackIndex) was rejected at frame \(sourceFrame)")
                return
            }
            sourceFrame += frameCount
            callbackIndex += 1
        }

        let deviceDiagnostics = device.diagnostics
        let harnessDiagnostics = harness.diagnostics
        XCTAssertEqual(deviceDiagnostics.receivedFrameCount, UInt64(totalFrameCount))
        XCTAssertEqual(deviceDiagnostics.deliveredFrameCount, UInt64(totalFrameCount))
        XCTAssertEqual(deviceDiagnostics.rejectedFrameCount, 0)
        XCTAssertEqual(deviceDiagnostics.deliveryFailureCount, 0)
        XCTAssertEqual(deviceDiagnostics.admissionBlockedFrameCount, 0)
        XCTAssertEqual(deviceDiagnostics.deliveryCallbackCount, UInt64(callbackIndex))
        XCTAssertEqual(deviceDiagnostics.nativeDeliveryErrorCount, 0)
        XCTAssertEqual(deviceDiagnostics.renderInvocationCount, UInt64(callbackIndex))
        XCTAssertEqual(deviceDiagnostics.renderCopiedFrameCount, UInt64(totalFrameCount))
        XCTAssertEqual(
            deviceDiagnostics.renderCopiedSampleElementCount,
            UInt64(totalFrameCount * Self.inputChannelCount)
        )
        XCTAssertEqual(deviceDiagnostics.renderNotInvokedCount, 0)
        XCTAssertEqual(deviceDiagnostics.renderMultipleInvocationCount, 0)
        XCTAssertEqual(deviceDiagnostics.renderValidationFailureCount, 0)
        XCTAssertEqual(deviceDiagnostics.prefilledInputDataDeliveryCount, 0)
        XCTAssertEqual(deviceDiagnostics.timestampResetCount, 1)
        XCTAssertEqual(deviceDiagnostics.recordingGeneration, 1)
        XCTAssertEqual(deviceDiagnostics.approvedRecordingGeneration, 1)
        XCTAssertEqual(harnessDiagnostics.callbackCount, UInt64(callbackIndex))
        XCTAssertEqual(harnessDiagnostics.frameCount, UInt64(totalFrameCount))
        XCTAssertEqual(harnessDiagnostics.invalidBufferListCount, 0)
        XCTAssertEqual(harnessDiagnostics.samplePatternMismatchCount, 0)
        XCTAssertEqual(harnessDiagnostics.sampleTimeDiscontinuityCount, 0)
        XCTAssertEqual(harnessDiagnostics.hostTimeDiscontinuityCount, 0)
    }

    func testDeliveryThreadChangeNotifiesBeforeContinuingPCM() throws {
        let device = try XCTUnwrap(ASMacStereoAudioDevice())
        let harness = ASMacStereoAudioDeviceTestHarness(device: device)
        XCTAssertTrue(harness.startRecording())
        XCTAssertTrue(deliver(frameRange: 0..<480, into: device))

        XCTAssertTrue(
            harness.deliverStereoSequenceOnNewThread(
                startingAtFrame: 480,
                frameCount: 480
            )
        )

        let deviceDiagnostics = device.diagnostics
        let harnessDiagnostics = harness.diagnostics
        XCTAssertEqual(deviceDiagnostics.deliveryThreadChangeCount, 1)
        XCTAssertEqual(deviceDiagnostics.inputInterruptionCount, 1)
        XCTAssertEqual(harnessDiagnostics.inputInterruptionNotificationCount, 1)
        XCTAssertEqual(harnessDiagnostics.sampleTimeDiscontinuityCount, 0)
        XCTAssertEqual(harnessDiagnostics.samplePatternMismatchCount, 0)
    }

    func testFactoryInitializesAndTerminatesCustomDevice() throws {
        XCTAssertTrue(LKRTCInitializeSSL())
        let device = try XCTUnwrap(ASMacStereoAudioDevice())
        var error: NSError?
        var factory: LKRTCPeerConnectionFactory? = ASCreateMacStereoPeerConnectionFactory(
            nil,
            nil,
            device,
            &error
        )
        XCTAssertNotNil(factory, "\(String(describing: error))")
        XCTAssertNil(error)

        let configuration = LKRTCConfiguration()
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        var peer = factory?.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: nil
        )
        XCTAssertNotNil(peer)
        XCTAssertTrue(device.diagnostics.initialized)

        peer?.close()
        peer = nil
        factory = nil

        let deadline = Date().addingTimeInterval(1)
        while device.diagnostics.initialized, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(device.diagnostics.initialized)
    }

    private func deliver(
        frameRange: Range<Int>,
        into device: ASMacStereoAudioDevice
    ) -> Bool {
        let samples = Self.stereoSequence(frameRange: frameRange)
        return deliver(samples, frameCount: frameRange.count, into: device)
    }

    private func deliver(
        _ samples: [Int16],
        frameCount: Int,
        into device: ASMacStereoAudioDevice
    ) -> Bool {
        samples.withUnsafeBufferPointer { buffer in
            device.deliverInterleavedStereoInt16(
                buffer.baseAddress!,
                frameCount: UInt(frameCount)
            )
        }
    }

    private func completedTelemetry(
        pattern: ASMacStereoAudioDeviceHarnessPlayoutPattern
    ) throws -> ASMacDecodedPlayoutTelemetrySnapshot {
        let device = try XCTUnwrap(ASMacStereoAudioDevice())
        let harness = ASMacStereoAudioDeviceTestHarness(device: device)
        harness.playoutPattern = pattern
        XCTAssertTrue(harness.startPlayout())
        var samples = Array(repeating: Int16.zero, count: 48_000)
        XCTAssertTrue(samples.withUnsafeMutableBufferPointer { buffer in
            device.renderPlayoutMonoInt16(
                buffer.baseAddress!,
                frameCount: 48_000
            )
        })
        return device.decodedPlayoutTelemetry
    }

    private static func stereoSequence(frameRange: Range<Int>) -> [Int16] {
        frameRange.flatMap { frame -> [Int16] in
            let marker = Int16((frame % 30_000) + 1)
            return [marker, -marker]
        }
    }

    private static func fnv1aFingerprint(
        frameCount: Int,
        samples: (Int) -> Int16
    ) -> UInt64 {
        var fingerprint: UInt64 = 14_695_981_039_346_656_037
        for frame in 0..<frameCount {
            let value = UInt16(bitPattern: samples(frame))
            fingerprint ^= UInt64(value & 0x00ff)
            fingerprint &*= 1_099_511_628_211
            fingerprint ^= UInt64(value >> 8)
            fingerprint &*= 1_099_511_628_211
        }
        return fingerprint
    }
}
#endif
