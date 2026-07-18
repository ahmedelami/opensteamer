#if os(macOS)
import LiveKitWebRTC
import MacWebRTCAudioDeviceShim
import MacWebRTCAudioDeviceShimTestSupport
import XCTest

final class MacWebRTCAudioDeviceShimTests: XCTestCase {
    private static let channelCount = 2

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
            UInt64(480 * Self.channelCount)
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
            count: callbackFramePattern.max()! * Self.channelCount
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
            UInt64(totalFrameCount * Self.channelCount)
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

    private static func stereoSequence(frameRange: Range<Int>) -> [Int16] {
        frameRange.flatMap { frame -> [Int16] in
            let marker = Int16((frame % 30_000) + 1)
            return [marker, -marker]
        }
    }
}
#endif
