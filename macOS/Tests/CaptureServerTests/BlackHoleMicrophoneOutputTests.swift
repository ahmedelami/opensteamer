#if os(macOS) && DEBUG
import AudioToolbox
import CaptureCore
import Darwin
import Foundation
import MacWebRTCAudioDeviceShim
import XCTest
@testable import CaptureServer

@MainActor
final class BlackHoleMicrophoneOutputTests: XCTestCase {
    private static let primingFailure = OSStatus(-66_201)
    private static let allocationFailure = OSStatus(-66_202)
    private static let firstRuntimeFailure = OSStatus(-66_203)
    private static let repeatedRuntimeFailure = OSStatus(-66_204)
    private static let callbackStopFailure = OSStatus(-66_205)
    private static let disposeFailure = OSStatus(-66_206)
    private static let progressStallGraceNanoseconds: UInt64 = 100

    private static func deviceTimestamp(
        sampleTime: Double,
        hostTime: UInt64,
        flags: AudioTimeStampFlags =
            BlackHoleFaceTimeClockPolicy.requiredTimestampFlags
    ) -> AudioTimeStamp {
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mHostTime = hostTime
        timestamp.mFlags = flags
        return timestamp
    }

    func testVisibleEndpointIsRejectedBeforeAnyAudioQueueOperation() {
        let operations = FakeBlackHoleAudioQueueOperations()

        XCTAssertNil(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                expectedHiddenEndpoint: .init(
                    deviceID: 79,
                    deviceUID:
                        WorldwideVirtualMicrophoneEndpointContract
                            .visibleDefaultInputDeviceUID
                ),
                runtimeFailureHandler: { _, _ in }
            )
        )
        XCTAssertEqual(operations.selectedDeviceUIDs, [])
        XCTAssertEqual(operations.allocateCallCount, 0)
        XCTAssertEqual(operations.startCallCount, 0)
    }

    func testWriterAuthorizationGateStartsClosedAndOutputFailsBeforeQueueCreation()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let gate = try XCTUnwrap(
            BlackHoleMicrophoneOutputAuthorizationGate()
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                authorizationGate: gate,
                runtimeFailureHandler: { _, _ in }
            )
        )

        XCTAssertFalse(gate.isOpen)
        XCTAssertThrowsError(try output.start()) { error in
            XCTAssertEqual(
                error as? BlackHoleMicrophoneOutputError,
                .operation(
                    "authorize hidden BlackHole microphone writer",
                    kAudio_ParamError
                )
            )
        }
        XCTAssertEqual(operations.createCallCount, 0)
        XCTAssertEqual(operations.allocateCallCount, 0)
        XCTAssertEqual(operations.enqueueCallCount, 0)
        XCTAssertEqual(operations.startCallCount, 0)
    }

    func testWriterAuthorizationOpenIsIdempotentForSameHealthyGenerationAndRejectsStalePreparation()
        throws {
        let gate = try XCTUnwrap(
            BlackHoleMicrophoneOutputAuthorizationGate()
        )
        let firstPreparation = gate.prepareToOpen()

        XCTAssertTrue(
            gate.openForTesting(preparation: firstPreparation)
        )
        XCTAssertTrue(
            gate.openForTesting(preparation: firstPreparation),
            "Repeated healthy admission must remain idempotent."
        )

        gate.close()
        XCTAssertFalse(gate.isOpen)
        XCTAssertFalse(
            gate.openForTesting(preparation: firstPreparation),
            "A close must fence a preparation from the prior generation."
        )

        let secondPreparation = gate.prepareToOpen()
        XCTAssertTrue(
            gate.openForTesting(preparation: secondPreparation)
        )
        XCTAssertTrue(gate.isOpen)
    }

    func testOutputFormatPolicyAcceptsOnlyExactRequestedFormatAndDeviceState()
        throws {
        let observation = try BlackHoleMicrophoneOutputFormatPolicy()
            .evaluate(
                BlackHoleMicrophoneOutputFormatPolicy.validEvidence
            )
            .get()

        XCTAssertEqual(observation.sampleRate, 48_000)
        XCTAssertEqual(observation.formatID, kAudioFormatLinearPCM)
        XCTAssertEqual(
            observation.formatFlags,
            kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked
        )
        XCTAssertEqual(observation.bytesPerPacket, 2)
        XCTAssertEqual(observation.framesPerPacket, 1)
        XCTAssertEqual(observation.bytesPerFrame, 2)
        XCTAssertEqual(observation.channelsPerFrame, 1)
        XCTAssertEqual(observation.bitsPerChannel, 16)
        XCTAssertEqual(observation.reserved, 0)
        XCTAssertEqual(observation.deviceSampleRate, 48_000)
        XCTAssertEqual(observation.deviceChannelCount, 1)
        XCTAssertEqual(observation.converterError, 0)
    }

    func testOutputFormatPolicyRejectsEveryMutatedASBDField() {
        typealias Rejection =
            BlackHoleMicrophoneOutputFormatRejection
        let mutations: [(
            name: String,
            mutate: (inout AudioStreamBasicDescription) -> Void,
            expected: Rejection
        )] = [
            (
                "sample rate",
                { $0.mSampleRate = 44_100 },
                .unexpectedStreamSampleRate(actual: 44_100)
            ),
            (
                "format ID",
                { $0.mFormatID = kAudioFormatMPEG4AAC },
                .unexpectedStreamFormatID(
                    actual: kAudioFormatMPEG4AAC
                )
            ),
            (
                "format flags",
                {
                    $0.mFormatFlags |=
                        kAudioFormatFlagIsNonInterleaved
                },
                .unexpectedStreamFormatFlags(
                    actual:
                        BlackHoleMicrophoneOutputFormatPolicy
                            .requiredFormatFlags
                        | kAudioFormatFlagIsNonInterleaved
                )
            ),
            (
                "bytes per packet",
                { $0.mBytesPerPacket = 8 },
                .unexpectedStreamBytesPerPacket(actual: 8)
            ),
            (
                "frames per packet",
                { $0.mFramesPerPacket = 2 },
                .unexpectedStreamFramesPerPacket(actual: 2)
            ),
            (
                "bytes per frame",
                { $0.mBytesPerFrame = 8 },
                .unexpectedStreamBytesPerFrame(actual: 8)
            ),
            (
                "channels per frame",
                { $0.mChannelsPerFrame = 4 },
                .unexpectedStreamChannelsPerFrame(actual: 4)
            ),
            (
                "bits per channel",
                { $0.mBitsPerChannel = 32 },
                .unexpectedStreamBitsPerChannel(actual: 32)
            ),
            (
                "reserved",
                { $0.mReserved = 1 },
                .unexpectedStreamReserved(actual: 1)
            ),
        ]
        let policy = BlackHoleMicrophoneOutputFormatPolicy()

        for mutation in mutations {
            var evidence =
                BlackHoleMicrophoneOutputFormatPolicy.validEvidence
            mutation.mutate(&evidence.streamDescription)
            XCTAssertEqual(
                policy.evaluate(evidence),
                .failure(mutation.expected),
                mutation.name
            )
        }
    }

    func testOutputFormatPolicyRejectsEveryReadFailureAndDeviceMutation() {
        let failure = OSStatus(-66_207)
        let policy = BlackHoleMicrophoneOutputFormatPolicy()
        let mutations: [(
            name: String,
            mutate: (inout BlackHoleMicrophoneOutputFormatEvidence) -> Void,
            expected: BlackHoleMicrophoneOutputFormatRejection
        )] = [
            (
                "stream read",
                { $0.streamDescriptionStatus = failure },
                .streamDescriptionCoreAudioStatus(failure)
            ),
            (
                "device-rate read",
                { $0.deviceSampleRateStatus = failure },
                .deviceSampleRateCoreAudioStatus(failure)
            ),
            (
                "device-channel read",
                { $0.deviceChannelCountStatus = failure },
                .deviceChannelCountCoreAudioStatus(failure)
            ),
            (
                "converter read",
                { $0.converterErrorReadStatus = failure },
                .converterErrorCoreAudioStatus(failure)
            ),
            (
                "44.1 kHz device",
                { $0.deviceSampleRate = 44_100 },
                .unexpectedDeviceSampleRate(actual: 44_100)
            ),
            (
                "four-channel device",
                { $0.deviceChannelCount = 4 },
                .unexpectedDeviceChannelCount(actual: 4)
            ),
            (
                "converter error",
                { $0.converterError = 1 },
                .converterError(actual: 1)
            ),
        ]

        for mutation in mutations {
            var evidence =
                BlackHoleMicrophoneOutputFormatPolicy.validEvidence
            mutation.mutate(&evidence)
            XCTAssertEqual(
                policy.evaluate(evidence),
                .failure(mutation.expected),
                mutation.name
            )
        }
    }

    func testOutputQueueReceivesExactRequestedASBDAndProvesItTwice()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureHandler: { _, _ in }
            )
        )

        try output.start()

        XCTAssertEqual(operations.requestedFormats.count, 1)
        let format = try XCTUnwrap(operations.requestedFormats.first)
        XCTAssertEqual(format.mSampleRate, 48_000)
        XCTAssertEqual(format.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(
            format.mFormatFlags,
            kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked
        )
        XCTAssertEqual(format.mBytesPerPacket, 2)
        XCTAssertEqual(format.mFramesPerPacket, 1)
        XCTAssertEqual(format.mBytesPerFrame, 2)
        XCTAssertEqual(format.mChannelsPerFrame, 1)
        XCTAssertEqual(format.mBitsPerChannel, 16)
        XCTAssertEqual(format.mReserved, 0)
        XCTAssertEqual(
            operations.allocatedBuffers.map {
                $0.pointee.mAudioDataBytesCapacity
            },
            [960, 960, 960]
        )
        XCTAssertEqual(operations.streamDescriptionReadCount, 2)
        XCTAssertEqual(operations.deviceSampleRateReadCount, 2)
        XCTAssertEqual(operations.deviceChannelCountReadCount, 2)
        XCTAssertEqual(operations.converterErrorReadCount, 2)
        output.stop()
    }

    func testFourChannelDeviceClosesGateAndDisposesBeforeStart()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            deviceChannelCountValues: [4]
        )
        let gate = try XCTUnwrap(
            BlackHoleMicrophoneOutputAuthorizationGate()
        )
        XCTAssertTrue(
            gate.openForTesting(preparation: gate.prepareToOpen())
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                authorizationGate: gate,
                runtimeFailureHandler: { _, _ in }
            )
        )

        XCTAssertThrowsError(try output.start()) { error in
            XCTAssertEqual(
                error as? BlackHoleMicrophoneOutputError,
                .formatUnsafe(
                    .unexpectedDeviceChannelCount(actual: 4)
                )
            )
        }
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(operations.allocateCallCount, 0)
        XCTAssertEqual(operations.startCallCount, 0)
        XCTAssertEqual(operations.stopCallCount, 0)
        XCTAssertEqual(operations.disposeCallCount, 1)
    }

    func test44100DeviceReadbackClosesGateAndDisposesBeforeStart()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            deviceSampleRateValues: [44_100]
        )
        let gate = try XCTUnwrap(
            BlackHoleMicrophoneOutputAuthorizationGate()
        )
        XCTAssertTrue(
            gate.openForTesting(preparation: gate.prepareToOpen())
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                authorizationGate: gate,
                runtimeFailureHandler: { _, _ in }
            )
        )

        XCTAssertThrowsError(try output.start())
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(operations.allocateCallCount, 0)
        XCTAssertEqual(operations.startCallCount, 0)
        XCTAssertEqual(operations.disposeCallCount, 1)
    }

    func testStreamReadbackDriftAfterStartClosesGateStopsAndDisposes()
        throws {
        var drifted = BlackHoleMicrophoneOutputFormatPolicy
            .requiredStreamDescription
        drifted.mChannelsPerFrame = 4
        let operations = FakeBlackHoleAudioQueueOperations(
            streamDescriptionValues: [
                BlackHoleMicrophoneOutputFormatPolicy
                    .requiredStreamDescription,
                drifted,
            ]
        )
        let gate = try XCTUnwrap(
            BlackHoleMicrophoneOutputAuthorizationGate()
        )
        XCTAssertTrue(
            gate.openForTesting(preparation: gate.prepareToOpen())
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                authorizationGate: gate,
                runtimeFailureHandler: { _, _ in }
            )
        )

        XCTAssertThrowsError(try output.start())
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(operations.streamDescriptionReadCount, 2)
        XCTAssertEqual(operations.allocateCallCount, 3)
        XCTAssertEqual(operations.startCallCount, 1)
        XCTAssertEqual(operations.deviceTimeReadCount, 0)
        XCTAssertEqual(operations.stopCallCount, 1)
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertFalse(output.forwardingProgressSnapshot.queueRunning)
    }

    func testConverterErrorAfterStartClosesGateStopsAndDisposes()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            converterErrorValues: [0, 1]
        )
        let gate = try XCTUnwrap(
            BlackHoleMicrophoneOutputAuthorizationGate()
        )
        XCTAssertTrue(
            gate.openForTesting(preparation: gate.prepareToOpen())
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                authorizationGate: gate,
                runtimeFailureHandler: { _, _ in }
            )
        )

        XCTAssertThrowsError(try output.start())
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(operations.converterErrorReadCount, 2)
        XCTAssertEqual(operations.startCallCount, 1)
        XCTAssertEqual(operations.stopCallCount, 1)
        XCTAssertEqual(operations.disposeCallCount, 1)
    }

    func testPreProofCallbackIsSilentWhenPostStartFormatIsUnsafe()
        throws {
        var drifted = BlackHoleMicrophoneOutputFormatPolicy
            .requiredStreamDescription
        drifted.mChannelsPerFrame = 4
        let startInterlock = BlackHoleAudioQueueStartInterlock()
        let operations = FakeBlackHoleAudioQueueOperations(
            streamDescriptionValues: [
                BlackHoleMicrophoneOutputFormatPolicy
                    .requiredStreamDescription,
                drifted,
            ],
            startQueueInterlock: startInterlock
        )

        try assertPreProofCallbackIsSilentAndStartFails(
            operations: operations,
            startInterlock: startInterlock
        )
    }

    func testPreProofCallbackIsSilentWhenStartupClockIsUnsafe()
        throws {
        let startInterlock = BlackHoleAudioQueueStartInterlock()
        let operations = FakeBlackHoleAudioQueueOperations(
            deviceTimeResults: [
                .success(
                    sampleTime: 6_687_779_444,
                    hostTime: AudioConvertNanosToHostTime(
                        10_000_000_000
                    )
                ),
            ],
            startQueueInterlock: startInterlock
        )

        try assertPreProofCallbackIsSilentAndStartFails(
            operations: operations,
            startInterlock: startInterlock
        )
    }

    private func assertPreProofCallbackIsSilentAndStartFails(
        operations: FakeBlackHoleAudioQueueOperations,
        startInterlock: BlackHoleAudioQueueStartInterlock
    ) throws {
        let gate = try XCTUnwrap(
            BlackHoleMicrophoneOutputAuthorizationGate()
        )
        XCTAssertTrue(
            gate.openForTesting(preparation: gate.prepareToOpen())
        )
        let renderProbe = BlackHoleRenderProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                authorizationGate: gate,
                renderForTesting: { samples, frameCount in
                    renderProbe.record(frameCount: frameCount)
                    for index in 0..<frameCount {
                        samples[index] = 12_345
                    }
                    return true
                },
                runtimeFailureHandler: { _, _ in }
            )
        )
        let outcome = BlackHoleOutputStartOutcomeProbe()
        let startReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { startReturned.signal() }
            do {
                try output.start()
                outcome.recordSuccess()
            } catch {
                outcome.record(error)
            }
        }
        defer { startInterlock.releaseFirstStart() }

        XCTAssertEqual(
            startInterlock.waitUntilFirstStartEntered(
                timeout: .now() + .seconds(1)
            ),
            .success
        )
        XCTAssertEqual(renderProbe.count, 0)
        XCTAssertEqual(operations.enqueueCallCount, 3)
        let callbackContext = try XCTUnwrap(
            operations.callbackContexts.first
        )
        let buffer = try XCTUnwrap(operations.allocatedBuffers.first)
        memset(
            buffer.pointee.mAudioData,
            0x7f,
            Int(buffer.pointee.mAudioDataBytesCapacity)
        )

        BlackHoleMicrophoneOutput
            .debugInvokeRealtimeCallbackWithContextForTesting(
                context: callbackContext,
                queue: operations.queue,
                buffer: buffer
            )

        XCTAssertEqual(
            renderProbe.count,
            0,
            "Decoded PCM must not be pulled before startup proof."
        )
        XCTAssertEqual(
            operations.enqueueCallCount,
            4,
            "The pre-proof callback should enqueue one silence buffer."
        )
        let bytes = UnsafeBufferPointer(
            start: buffer.pointee.mAudioData
                .assumingMemoryBound(to: UInt8.self),
            count: Int(buffer.pointee.mAudioDataByteSize)
        )
        XCTAssertTrue(bytes.allSatisfy { $0 == 0 })

        startInterlock.releaseFirstStart()
        XCTAssertEqual(
            startReturned.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertFalse(outcome.didSucceed)
        XCTAssertNotNil(outcome.error)
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(operations.stopCallCount, 1)
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertFalse(output.forwardingProgressSnapshot.queueRunning)
    }

    func testExternalCloseAfterPCMAdmissionOpenPreventsRunningCommit()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let gate = try XCTUnwrap(
            BlackHoleMicrophoneOutputAuthorizationGate()
        )
        XCTAssertTrue(
            gate.openForTesting(preparation: gate.prepareToOpen())
        )
        let renderProbe = BlackHoleRenderProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                authorizationGate: gate,
                renderForTesting: { _, frameCount in
                    renderProbe.record(frameCount: frameCount)
                    return true
                },
                pcmAdmissionDidOpenForTesting: {
                    gate.close()
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        XCTAssertThrowsError(try output.start()) { error in
            XCTAssertEqual(
                error as? BlackHoleMicrophoneOutputError,
                .operation(
                    "authorize hidden BlackHole microphone writer",
                    kAudio_ParamError
                )
            )
        }
        XCTAssertFalse(gate.isOpen)
        XCTAssertFalse(output.debugPCMAdmissionIsOpenForTesting)
        XCTAssertFalse(output.forwardingProgressSnapshot.queueRunning)
        XCTAssertEqual(renderProbe.count, 0)
        XCTAssertEqual(operations.stopCallCount, 1)
        XCTAssertEqual(operations.disposeCallCount, 1)
    }

    func testFaceTimeClockPolicyProjectsCaptured48KClockIntoProven24KFailureDomain()
        throws {
        let capturedDeviceSampleTime = 6_687_779_444.0
        let capturedFaceTimeSampleTime = UInt64(3_343_889_722)

        let projected = try BlackHoleFaceTimeClockPolicy
            .projectedFaceTimeSampleTime(
                sampleTime: capturedDeviceSampleTime,
                sampleRate: 48_000
            )
            .get()
        XCTAssertEqual(projected, capturedFaceTimeSampleTime)

        let result = BlackHoleFaceTimeClockPolicy().evaluate(
            status: noErr,
            timestamp: Self.deviceTimestamp(
                sampleTime: capturedDeviceSampleTime,
                hostTime: 1_000
            )
        )
        guard case .failure(
            .insufficientSigned32Headroom(
                let observation,
                let maximumProjectedSampleTime
            )
        ) = result else {
            return XCTFail("The captured clock must fail closed.")
        }
        XCTAssertEqual(
            observation.projectedFaceTimeSampleTime,
            capturedFaceTimeSampleTime
        )
        XCTAssertEqual(
            maximumProjectedSampleTime,
            2_146_043_647
        )
    }

    func testFaceTimeClockProjectionDoesNotScaleAnAlready24KValueTwice()
        throws {
        let capturedFaceTimeSampleTime = 3_343_889_722.0

        XCTAssertEqual(
            try BlackHoleFaceTimeClockPolicy
                .projectedFaceTimeSampleTime(
                    sampleTime: capturedFaceTimeSampleTime,
                    sampleRate: 24_000
                )
                .get(),
            UInt64(capturedFaceTimeSampleTime)
        )
        XCTAssertNotEqual(
            UInt64(capturedFaceTimeSampleTime),
            1_671_944_861,
            "The captured AUIO value is already in the 24 kHz domain."
        )
    }

    func testFaceTimeClockPolicyUsesUpwardProjectionAtExactHeadroomBoundary()
        throws {
        let maximumProjected =
            BlackHoleFaceTimeClockPolicy
                .maximumProjectedSampleTime
        let maximumDeviceSampleTime =
            Double(maximumProjected * 2)
        let policy = BlackHoleFaceTimeClockPolicy()

        let boundary = try policy.evaluate(
            status: noErr,
            timestamp: Self.deviceTimestamp(
                sampleTime: maximumDeviceSampleTime,
                hostTime: 100
            )
        ).get()
        XCTAssertEqual(
            boundary.projectedFaceTimeSampleTime,
            maximumProjected
        )

        let firstUnsafeResult = policy.evaluate(
            status: noErr,
            timestamp: Self.deviceTimestamp(
                sampleTime: maximumDeviceSampleTime + 1,
                hostTime: 101
            )
        )
        guard case .failure(
            .insufficientSigned32Headroom(
                let firstUnsafe,
                let reportedMaximum
            )
        ) = firstUnsafeResult else {
            return XCTFail("The first odd 48 kHz frame must round upward.")
        }
        XCTAssertEqual(
            firstUnsafe.projectedFaceTimeSampleTime,
            maximumProjected + 1
        )
        XCTAssertEqual(reportedMaximum, maximumProjected)
    }

    func testFaceTimeClockPolicyRejectsStatusFlagsNonfiniteNegativeAndRateMismatch()
        throws {
        let policy = BlackHoleFaceTimeClockPolicy()
        let valid = Self.deviceTimestamp(
            sampleTime: 1_000,
            hostTime: 2_000
        )

        XCTAssertEqual(
            policy.evaluate(
                status: Self.firstRuntimeFailure,
                timestamp: valid
            ),
            .failure(.coreAudioStatus(Self.firstRuntimeFailure))
        )
        XCTAssertEqual(
            policy.evaluate(
                status: noErr,
                timestamp: Self.deviceTimestamp(
                    sampleTime: 1_000,
                    hostTime: 2_000,
                    flags: .hostTimeValid
                )
            ),
            .failure(
                .missingRequiredTimestampFlags(
                    actual: .hostTimeValid
                )
            )
        )
        XCTAssertEqual(
            policy.evaluate(
                status: noErr,
                timestamp: Self.deviceTimestamp(
                    sampleTime: .nan,
                    hostTime: 2_000
                )
            ),
            .failure(.nonFiniteDeviceSampleTime)
        )
        XCTAssertEqual(
            policy.evaluate(
                status: noErr,
                timestamp: Self.deviceTimestamp(
                    sampleTime: -1,
                    hostTime: 2_000
                )
            ),
            .failure(.negativeDeviceSampleTime)
        )
        XCTAssertEqual(
            policy.evaluate(
                status: noErr,
                timestamp: Self.deviceTimestamp(
                    sampleTime: 1_000.5,
                    hostTime: 2_000
                )
            ),
            .failure(.nonIntegralDeviceSampleTime)
        )
        XCTAssertEqual(
            policy.evaluate(
                status: noErr,
                timestamp: Self.deviceTimestamp(
                    sampleTime: 1_000,
                    hostTime: 0
                )
            ),
            .failure(.zeroDeviceHostTime)
        )
        XCTAssertEqual(
            policy.evaluate(
                status: noErr,
                timestamp: valid,
                deviceSampleRate: 44_100
            ),
            .failure(.unexpectedDeviceSampleRate)
        )
    }

    func testFaceTimeClockPolicyRejectsSampleAndHostTimeRegression()
        throws {
        let policy = BlackHoleFaceTimeClockPolicy()
        let previous = try policy.evaluate(
            status: noErr,
            timestamp: Self.deviceTimestamp(
                sampleTime: 10_000,
                hostTime: 20_000
            )
        ).get()

        XCTAssertEqual(
            policy.evaluate(
                status: noErr,
                timestamp: Self.deviceTimestamp(
                    sampleTime: 9_999,
                    hostTime: 20_001
                ),
                previous: previous
            ),
            .failure(
                .deviceSampleTimeDidNotAdvance(
                    previous: 10_000,
                    current: 9_999
                )
            )
        )
        XCTAssertEqual(
            policy.evaluate(
                status: noErr,
                timestamp: Self.deviceTimestamp(
                    sampleTime: 10_001,
                    hostTime: 19_999
                ),
                previous: previous
            ),
            .failure(
                .deviceHostTimeDidNotAdvance(
                    previous: 20_000,
                    current: 19_999
                )
            )
        )
        XCTAssertEqual(
            policy.evaluate(
                status: noErr,
                timestamp: Self.deviceTimestamp(
                    sampleTime: 10_000,
                    hostTime: 20_001
                ),
                previous: previous
            ),
            .failure(
                .deviceSampleTimeDidNotAdvance(
                    previous: 10_000,
                    current: 10_000
                )
            )
        )
        XCTAssertEqual(
            policy.evaluate(
                status: noErr,
                timestamp: Self.deviceTimestamp(
                    sampleTime: 10_001,
                    hostTime: 20_000
                ),
                previous: previous
            ),
            .failure(
                .deviceHostTimeDidNotAdvance(
                    previous: 20_000,
                    current: 20_000
                )
            )
        )
    }

    func testFaceTimeClockPolicyRejectsAcceleratedRateAndOneShotJump()
        throws {
        let policy = BlackHoleFaceTimeClockPolicy()
        let initialHostTime = AudioConvertNanosToHostTime(
            10_000_000_000
        )
        let oneSecondHostDelta = AudioConvertNanosToHostTime(
            1_000_000_000
        )
        let previous = try policy.evaluate(
            status: noErr,
            timestamp: Self.deviceTimestamp(
                sampleTime: 1_000,
                hostTime: initialHostTime
            )
        ).get()

        XCTAssertNoThrow(
            try policy.evaluate(
                status: noErr,
                timestamp: Self.deviceTimestamp(
                    sampleTime: 49_000,
                    hostTime: initialHostTime
                        + oneSecondHostDelta
                ),
                previous: previous
            ).get()
        )

        for (name, sampleTime) in [
            ("accelerated", 73_000.0),
            ("one-shot jump", 1_001_000.0),
        ] {
            let result = policy.evaluate(
                status: noErr,
                timestamp: Self.deviceTimestamp(
                    sampleTime: sampleTime,
                    hostTime: initialHostTime
                        + oneSecondHostDelta
                ),
                previous: previous
            )
            guard case .failure(
                .deviceClockRateMismatch(
                    let actualFrameDelta,
                    let expectedFrameDelta,
                    let toleranceFrames,
                    let elapsedHostNanoseconds
                )
            ) = result else {
                XCTFail("\(name) clock mutation must fail closed.")
                continue
            }
            XCTAssertGreaterThan(
                abs(actualFrameDelta - expectedFrameDelta),
                toleranceFrames,
                name
            )
            XCTAssertEqual(
                elapsedHostNanoseconds,
                AudioConvertHostTimeToNanos(oneSecondHostDelta),
                name
            )
        }
    }

    func testUnsafeStartupClockClosesGateAndCleansStartedQueueBeforeCommit()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            deviceTimeResults: [
                .success(
                    sampleTime: 6_687_779_444,
                    hostTime: 1_000
                ),
            ]
        )
        let gate = try XCTUnwrap(
            BlackHoleMicrophoneOutputAuthorizationGate()
        )
        XCTAssertTrue(
            gate.openForTesting(
                preparation: gate.prepareToOpen()
            )
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                authorizationGate: gate,
                runtimeFailureHandler: { _, _ in }
            )
        )

        XCTAssertThrowsError(try output.start()) { error in
            guard case .sharedClockUnsafe(
                .insufficientSigned32Headroom(
                    let observation,
                    _
                )
            ) = error as? BlackHoleMicrophoneOutputError else {
                return XCTFail("Expected a typed shared-clock rejection.")
            }
            XCTAssertEqual(
                observation.projectedFaceTimeSampleTime,
                3_343_889_722
            )
        }
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(
            operations.operationTrace,
            ["start", "nominal-sample-rate", "device-current-time"]
        )
        XCTAssertEqual(operations.stopCallCount, 1)
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertFalse(
            output.forwardingProgressSnapshot.queueRunning
        )
    }

    func testStartupClockProofRetriesDocumentedHostOnlyTimestamp()
        throws {
        let initialHostTime = AudioConvertNanosToHostTime(
            10_000_000_000
        )
        let oneSecondHostDelta = AudioConvertNanosToHostTime(
            1_000_000_000
        )
        let operations = FakeBlackHoleAudioQueueOperations(
            deviceTimeResults: [
                .success(
                    sampleTime: 0,
                    hostTime: initialHostTime,
                    flags: .hostTimeValid
                ),
                .success(
                    sampleTime: 1_000,
                    hostTime: initialHostTime
                ),
                .success(
                    sampleTime: 49_000,
                    hostTime: initialHostTime
                        + oneSecondHostDelta
                ),
            ]
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureHandler: { _, _ in }
            )
        )

        try output.start()

        XCTAssertEqual(operations.deviceTimeReadCount, 3)
        XCTAssertTrue(output.forwardingProgressSnapshot.queueRunning)
        output.stop()
    }

    func testRuntimeClockFailureClosesGateBeforeSingleFailureReport()
        throws {
        let initialHostTime = AudioConvertNanosToHostTime(
            10_000_000_000
        )
        let oneSecondHostDelta = AudioConvertNanosToHostTime(
            1_000_000_000
        )
        let operations = FakeBlackHoleAudioQueueOperations(
            deviceTimeResults: [
                .success(
                    sampleTime: 1_000,
                    hostTime: initialHostTime
                ),
                .success(
                    sampleTime: 49_000,
                    hostTime: initialHostTime
                        + oneSecondHostDelta
                ),
                .success(
                    sampleTime: 6_687_779_444,
                    hostTime: initialHostTime
                        + oneSecondHostDelta * 2
                ),
            ]
        )
        let clock = BlackHoleManualMonotonicClock()
        let failures = BlackHoleRuntimeFailureProbe()
        let gate = try XCTUnwrap(
            BlackHoleMicrophoneOutputAuthorizationGate()
        )
        XCTAssertTrue(
            gate.openForTesting(
                preparation: gate.prepareToOpen()
            )
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                authorizationGate: gate,
                runtimeFailureHandler: { _, error in
                    failures.record(
                        error,
                        gateIsOpen: gate.isOpen
                    )
                }
            )
        )

        try output.start()
        let generation = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        clock.advance(by: 999_999_999)
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        XCTAssertEqual(operations.deviceTimeReadCount, 2)

        clock.advance(by: 1)
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(failures.gateWasOpen, [false])
        XCTAssertEqual(failures.errors.count, 1)
        guard case .sharedClockUnsafe(
            .insufficientSigned32Headroom(
                let observation,
                _
            )
        ) = failures.errors.first else {
            output.stop()
            return XCTFail("Expected one runtime clock rejection.")
        }
        XCTAssertEqual(
            observation.projectedFaceTimeSampleTime,
            3_343_889_722
        )
        XCTAssertEqual(operations.deviceTimeReadCount, 3)
        output.stop()
    }

    func testRuntimeClockFailureKeepsPCMClosedIfHandlerReopensWriterGate()
        throws {
        let initialHostTime = AudioConvertNanosToHostTime(
            10_000_000_000
        )
        let oneSecondHostDelta = AudioConvertNanosToHostTime(
            1_000_000_000
        )
        let operations = FakeBlackHoleAudioQueueOperations(
            deviceTimeResults: [
                .success(
                    sampleTime: 1_000,
                    hostTime: initialHostTime
                ),
                .success(
                    sampleTime: 49_000,
                    hostTime: initialHostTime
                        + oneSecondHostDelta
                ),
                .success(
                    sampleTime: 6_687_779_444,
                    hostTime: initialHostTime
                        + oneSecondHostDelta * 2
                ),
            ]
        )
        let clock = BlackHoleManualMonotonicClock()
        let failures = BlackHoleRuntimeFailureProbe()
        let renderProbe = BlackHoleRenderProbe()
        let gate = try XCTUnwrap(
            BlackHoleMicrophoneOutputAuthorizationGate()
        )
        XCTAssertTrue(
            gate.openForTesting(
                preparation: gate.prepareToOpen()
            )
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                authorizationGate: gate,
                renderForTesting: { samples, frameCount in
                    renderProbe.record(frameCount: frameCount)
                    for index in 0..<frameCount {
                        samples[index] = 3_456
                    }
                    return true
                },
                runtimeFailureHandler: { failedOutput, error in
                    let writerGateWasOpen = gate.isOpen
                    let pcmAdmissionWasOpen =
                        failedOutput
                            .debugPCMAdmissionIsOpenForTesting
                    let preparation = gate.prepareToOpen()
                    let didReopenWriterGate =
                        gate.openForTesting(
                            preparation: preparation
                        )
                    failures.record(
                        error,
                        gateIsOpen: writerGateWasOpen,
                        pcmAdmissionIsOpen:
                            pcmAdmissionWasOpen,
                        writerGateReopenSucceeded:
                            didReopenWriterGate
                    )
                }
            )
        )

        try output.start()
        XCTAssertTrue(output.debugPCMAdmissionIsOpenForTesting)
        XCTAssertEqual(renderProbe.count, 0)
        let generation = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        let buffer = try XCTUnwrap(
            operations.allocatedBuffers.first
        )

        clock.advance(by: 1_000_000_000)
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        XCTAssertEqual(failures.errors.count, 1)
        XCTAssertEqual(failures.gateWasOpen, [false])
        XCTAssertEqual(failures.pcmAdmissionWasOpen, [false])
        XCTAssertEqual(
            failures.writerGateReopenSucceeded,
            [true]
        )
        XCTAssertTrue(gate.isOpen)
        XCTAssertFalse(output.debugPCMAdmissionIsOpenForTesting)

        let renderCountBeforeCallback = renderProbe.count
        let enqueueCountBeforeCallback = operations.enqueueCallCount
        memset(
            buffer.pointee.mAudioData,
            0x7f,
            Int(buffer.pointee.mAudioDataBytesCapacity)
        )
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )

        XCTAssertEqual(renderProbe.count, renderCountBeforeCallback)
        XCTAssertEqual(
            operations.enqueueCallCount,
            enqueueCountBeforeCallback + 1,
            "The reopened writer may enqueue only gated silence."
        )
        let enqueuedBytes = UnsafeBufferPointer(
            start: buffer.pointee.mAudioData
                .assumingMemoryBound(to: UInt8.self),
            count: Int(buffer.pointee.mAudioDataByteSize)
        )
        XCTAssertTrue(
            enqueuedBytes.allSatisfy { $0 == 0 },
            "PCM admission must stay closed after clock rejection."
        )

        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        XCTAssertEqual(
            failures.errors.count,
            1,
            "The stale watchdog generation must report only once."
        )
        XCTAssertEqual(operations.deviceTimeReadCount, 3)
        output.stop()
    }

    func testRuntimeAcceleratedClockClosesGateOnNextRead()
        throws {
        let initialHostTime = AudioConvertNanosToHostTime(
            10_000_000_000
        )
        let oneSecondHostDelta = AudioConvertNanosToHostTime(
            1_000_000_000
        )
        let operations = FakeBlackHoleAudioQueueOperations(
            deviceTimeResults: [
                .success(
                    sampleTime: 1_000,
                    hostTime: initialHostTime
                ),
                .success(
                    sampleTime: 49_000,
                    hostTime: initialHostTime
                        + oneSecondHostDelta
                ),
                .success(
                    sampleTime: 73_000,
                    hostTime: initialHostTime
                        + oneSecondHostDelta * 2
                ),
            ]
        )
        let clock = BlackHoleManualMonotonicClock()
        let failures = BlackHoleRuntimeFailureProbe()
        let gate = try XCTUnwrap(
            BlackHoleMicrophoneOutputAuthorizationGate()
        )
        XCTAssertTrue(
            gate.openForTesting(preparation: gate.prepareToOpen())
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                authorizationGate: gate,
                runtimeFailureHandler: { _, error in
                    failures.record(
                        error,
                        gateIsOpen: gate.isOpen
                    )
                }
            )
        )

        try output.start()
        let generation = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        clock.advance(by: 1_000_000_000)
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(operations.deviceTimeReadCount, 3)
        XCTAssertEqual(failures.gateWasOpen, [false])
        XCTAssertEqual(failures.errors.count, 1)
        guard case .sharedClockUnsafe(
            .deviceClockRateMismatch
        ) = failures.errors.first else {
            output.stop()
            return XCTFail("Expected the next read to reject acceleration.")
        }
        output.stop()
    }

    func testStaleRuntimeClockGenerationCannotReadOrFailRestartedQueue()
        throws {
        let initialHostTime = AudioConvertNanosToHostTime(
            10_000_000_000
        )
        let oneSecondHostDelta = AudioConvertNanosToHostTime(
            1_000_000_000
        )
        let operations = FakeBlackHoleAudioQueueOperations(
            deviceTimeResults: [
                .success(
                    sampleTime: 1_000,
                    hostTime: initialHostTime
                ),
                .success(
                    sampleTime: 49_000,
                    hostTime: initialHostTime
                        + oneSecondHostDelta
                ),
                .success(
                    sampleTime: 2_000,
                    hostTime: initialHostTime
                ),
                .success(
                    sampleTime: 50_000,
                    hostTime: initialHostTime
                        + oneSecondHostDelta
                ),
                .success(
                    sampleTime: 6_687_779_444,
                    hostTime: initialHostTime
                        + oneSecondHostDelta * 2
                ),
            ]
        )
        let clock = BlackHoleManualMonotonicClock()
        let failures = BlackHoleRuntimeFailureProbe()
        let gate = try XCTUnwrap(
            BlackHoleMicrophoneOutputAuthorizationGate()
        )
        XCTAssertTrue(
            gate.openForTesting(
                preparation: gate.prepareToOpen()
            )
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                authorizationGate: gate,
                runtimeFailureHandler: { _, error in
                    failures.record(error)
                }
            )
        )

        try output.start()
        let firstGeneration = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        output.stop()
        try output.start()
        let secondGeneration = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        XCTAssertNotEqual(firstGeneration, secondGeneration)
        XCTAssertEqual(operations.deviceTimeReadCount, 4)

        clock.advance(by: 1_000_000_000)
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: firstGeneration
        )
        XCTAssertEqual(operations.deviceTimeReadCount, 4)
        XCTAssertTrue(gate.isOpen)
        XCTAssertTrue(failures.errors.isEmpty)

        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: secondGeneration
        )
        XCTAssertEqual(operations.deviceTimeReadCount, 5)
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(failures.errors.count, 1)
        output.stop()
    }

    func testClosedWriterGateSkipsPullScrubsBufferAndRetiresItWithoutEnqueue()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let renderProbe = BlackHoleRenderProbe()
        let gate = try XCTUnwrap(
            BlackHoleMicrophoneOutputAuthorizationGate()
        )
        let preparation = gate.prepareToOpen()
        XCTAssertTrue(
            gate.openForTesting(preparation: preparation)
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                authorizationGate: gate,
                renderForTesting: { samples, frameCount in
                    renderProbe.record(frameCount: frameCount)
                    for index in 0..<frameCount {
                        samples[index] = 1_234
                    }
                    return true
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try output.start()
        let renderCountAfterPriming = renderProbe.count
        let enqueueCountAfterPriming = operations.enqueueCallCount
        let buffer = try XCTUnwrap(operations.allocatedBuffers.first)
        memset(
            buffer.pointee.mAudioData,
            0x7f,
            Int(buffer.pointee.mAudioDataBytesCapacity)
        )
        gate.close()

        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )

        XCTAssertEqual(renderProbe.count, renderCountAfterPriming)
        XCTAssertEqual(
            operations.enqueueCallCount,
            enqueueCountAfterPriming,
            "A closed gate must retire the callback buffer."
        )
        XCTAssertEqual(
            buffer.pointee.mAudioDataByteSize,
            buffer.pointee.mAudioDataBytesCapacity
        )
        let samples = UnsafeBufferPointer(
            start: buffer.pointee.mAudioData
                .assumingMemoryBound(to: UInt8.self),
            count: Int(buffer.pointee.mAudioDataByteSize)
        )
        XCTAssertTrue(samples.allSatisfy { $0 == 0 })
        XCTAssertEqual(
            output.forwardingProgressSnapshot.successfulPullCount,
            0
        )
        output.stop()
    }

    func testCloseAfterPullScrubsBufferAndPreventsEnqueue()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let renderProbe = BlackHoleRenderProbe()
        let gate = try XCTUnwrap(
            BlackHoleMicrophoneOutputAuthorizationGate()
        )
        let preparation = gate.prepareToOpen()
        XCTAssertTrue(
            gate.openForTesting(preparation: preparation)
        )
        let interlock =
            BlackHoleMicrophoneOutputWriterAuthorizationInterlock()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                authorizationGate: gate,
                writerAuthorizationInterlockForTesting: interlock,
                renderForTesting: { samples, frameCount in
                    renderProbe.record(frameCount: frameCount)
                    for index in 0..<frameCount {
                        samples[index] = 2_345
                    }
                    return true
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try output.start()
        let renderCountAfterPriming = renderProbe.count
        let enqueueCountAfterPriming = operations.enqueueCallCount
        let context = try XCTUnwrap(
            output.debugRealtimeCallbackContextForTesting()
        )
        let buffer = try XCTUnwrap(operations.allocatedBuffers.first)
        let invocation = BlackHoleCallbackInvocationBox(
            context: context,
            queue: operations.queue,
            buffer: buffer
        )
        let callbackCompleted = DispatchGroup()
        interlock.armNextCallback()
        callbackCompleted.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { callbackCompleted.leave() }
            BlackHoleMicrophoneOutput
                .debugInvokeRealtimeCallbackWithContextForTesting(
                    context: invocation.context,
                    queue: invocation.queue,
                    buffer: invocation.buffer
                )
        }
        defer {
            interlock.releaseCallback()
            callbackCompleted.wait()
            output.stop()
        }

        guard interlock.waitUntilCallbackPaused(
            timeout: .now() + .seconds(1)
        ) == .success else {
            XCTFail(
                "The callback did not reach the final authorization check."
            )
            return
        }
        XCTAssertEqual(renderProbe.count, renderCountAfterPriming + 1)
        gate.close()
        interlock.releaseCallback()
        callbackCompleted.wait()

        XCTAssertEqual(
            operations.enqueueCallCount,
            enqueueCountAfterPriming,
            "Revoked PCM must never be returned to Core Audio."
        )
        let bytes = UnsafeBufferPointer(
            start: buffer.pointee.mAudioData
                .assumingMemoryBound(to: UInt8.self),
            count: Int(buffer.pointee.mAudioDataByteSize)
        )
        XCTAssertTrue(bytes.allSatisfy { $0 == 0 })
        XCTAssertEqual(
            output.forwardingProgressSnapshot.successfulPullCount,
            0
        )
    }

    func testHiddenMirrorSinkIsSelectedAndReadBackBeforeStartup()
        throws {
        let hiddenUID = WorldwideVirtualMicrophoneEndpointContract
            .hiddenMirrorSinkDeviceUID
        let operations = FakeBlackHoleAudioQueueOperations(
            deviceUID: hiddenUID
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                expectedHiddenEndpoint: .init(
                    deviceID: 89,
                    deviceUID: hiddenUID
                ),
                runtimeFailureHandler: { _, _ in }
            )
        )

        try output.start()

        XCTAssertEqual(
            operations.translatedDeviceUIDs,
            [hiddenUID, hiddenUID]
        )
        XCTAssertEqual(operations.selectedDeviceUIDs, [hiddenUID])
        XCTAssertEqual(operations.allocateCallCount, 3)
        XCTAssertEqual(operations.startCallCount, 1)
        output.stop()
    }

    func testSelectedSinkReadbackMismatchFailsClosedBeforeBuffers()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            currentDeviceUIDOverride:
                WorldwideVirtualMicrophoneEndpointContract
                    .visibleDefaultInputDeviceUID
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                expectedHiddenEndpoint: .init(
                    deviceID: 89,
                    deviceUID:
                        WorldwideVirtualMicrophoneEndpointContract
                            .hiddenMirrorSinkDeviceUID
                ),
                runtimeFailureHandler: { _, _ in }
            )
        )

        XCTAssertThrowsError(try output.start()) { error in
            XCTAssertEqual(
                error as? BlackHoleMicrophoneOutputError,
                .operation(
                    "verify selected BlackHole sink by UID",
                    kAudio_ParamError
                )
            )
        }
        XCTAssertEqual(operations.allocateCallCount, 0)
        XCTAssertEqual(operations.startCallCount, 0)
        XCTAssertEqual(operations.disposeCallCount, 1)
    }

    func testSelectedSinkDriftAfterStartStopsAndDisposesQueue()
        throws {
        let hiddenUID = WorldwideVirtualMicrophoneEndpointContract
            .hiddenMirrorSinkDeviceUID
        let operations = FakeBlackHoleAudioQueueOperations(
            currentDeviceUIDSequence: [
                hiddenUID,
                WorldwideVirtualMicrophoneEndpointContract
                    .visibleDefaultInputDeviceUID,
            ]
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                expectedHiddenEndpoint: .init(
                    deviceID: 89,
                    deviceUID: hiddenUID
                ),
                runtimeFailureHandler: { _, _ in }
            )
        )

        XCTAssertThrowsError(try output.start()) { error in
            XCTAssertEqual(
                error as? BlackHoleMicrophoneOutputError,
                .operation(
                    "verify selected BlackHole sink by UID",
                    kAudio_ParamError
                )
            )
        }
        XCTAssertEqual(operations.allocateCallCount, 3)
        XCTAssertEqual(operations.startCallCount, 1)
        XCTAssertEqual(operations.stopCallCount, 1)
        XCTAssertEqual(operations.disposeCallCount, 1)
    }

    func testSameUIDReplacementBeforeSelectionFailsBeforeCurrentDeviceMutation()
        throws {
        let hiddenUID = WorldwideVirtualMicrophoneEndpointContract
            .hiddenMirrorSinkDeviceUID
        let operations = FakeBlackHoleAudioQueueOperations(
            translatedDeviceIDSequence: [90]
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                expectedHiddenEndpoint: .init(
                    deviceID: 89,
                    deviceUID: hiddenUID
                ),
                runtimeFailureHandler: { _, _ in }
            )
        )

        XCTAssertThrowsError(try output.start()) { error in
            XCTAssertEqual(
                error as? BlackHoleMicrophoneOutputError,
                .operation(
                    "verify hidden BlackHole sink AudioDeviceID",
                    kAudio_ParamError
                )
            )
        }
        XCTAssertEqual(operations.translatedDeviceUIDs, [hiddenUID])
        XCTAssertEqual(operations.selectedDeviceUIDs, [])
        XCTAssertEqual(operations.allocateCallCount, 0)
        XCTAssertEqual(operations.startCallCount, 0)
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertFalse(output.forwardingProgressSnapshot.queueRunning)
    }

    func testSameUIDReplacementAfterStartFailsAndNeverCommitsSelection()
        throws {
        let hiddenUID = WorldwideVirtualMicrophoneEndpointContract
            .hiddenMirrorSinkDeviceUID
        let operations = FakeBlackHoleAudioQueueOperations(
            translatedDeviceIDSequence: [89, 90]
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                expectedHiddenEndpoint: .init(
                    deviceID: 89,
                    deviceUID: hiddenUID
                ),
                runtimeFailureHandler: { _, _ in }
            )
        )

        XCTAssertThrowsError(try output.start()) { error in
            XCTAssertEqual(
                error as? BlackHoleMicrophoneOutputError,
                .operation(
                    "verify hidden BlackHole sink AudioDeviceID",
                    kAudio_ParamError
                )
            )
        }
        XCTAssertEqual(
            operations.translatedDeviceUIDs,
            [hiddenUID, hiddenUID]
        )
        XCTAssertEqual(operations.selectedDeviceUIDs, [hiddenUID])
        XCTAssertEqual(operations.allocateCallCount, 3)
        XCTAssertEqual(operations.startCallCount, 1)
        XCTAssertEqual(operations.stopCallCount, 1)
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertFalse(output.forwardingProgressSnapshot.queueRunning)
    }

    func testPrimingFailurePreventsStartCleansExactPartialQueueAndThrowsStatus() throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            enqueueStatuses: [
                noErr,
                Self.primingFailure,
            ]
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureHandler: { _, _ in }
            )
        )

        XCTAssertThrowsError(try output.start()) { error in
            XCTAssertEqual(
                error as? BlackHoleMicrophoneOutputError,
                .operation(
                    "prime BlackHole output buffer",
                    Self.primingFailure
                )
            )
        }

        XCTAssertEqual(
            operations.selectedDeviceUIDs,
            [
                WorldwideVirtualMicrophoneEndpointContract
                    .hiddenMirrorSinkDeviceUID,
            ]
        )
        XCTAssertEqual(operations.allocateCallCount, 2)
        XCTAssertEqual(operations.enqueueCallCount, 2)
        XCTAssertEqual(
            operations.startCallCount,
            0,
            "A failed priming enqueue must abort before AudioQueueStart."
        )
        XCTAssertEqual(
            operations.stopCallCount,
            0,
            "An unstarted queue does not require AudioQueueStop during cleanup."
        )
        XCTAssertEqual(operations.freeBufferCallCount, 0)
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(operations.activeAllocationCount, 0)

        output.stop()
        XCTAssertEqual(operations.freeBufferCallCount, 0)
        XCTAssertEqual(operations.disposeCallCount, 1)
    }

    func testStopDuringStartWaitsForLocalQueueCleanupAndLeavesNoActiveQueue()
        throws {
        let startInterlock = BlackHoleAudioQueueStartInterlock()
        let operations = FakeBlackHoleAudioQueueOperations(
            startQueueInterlock: startInterlock
        )
        let startOutcome = BlackHoleOutputStartOutcomeProbe()
        let startReturned = DispatchSemaphore(value: 0)
        let stopReturned = DispatchSemaphore(value: 0)
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureHandler: { _, _ in }
            )
        )

        DispatchQueue.global(qos: .userInitiated).async {
            defer { startReturned.signal() }
            do {
                try output.start()
                startOutcome.recordSuccess()
            } catch {
                startOutcome.record(error)
            }
        }
        defer { startInterlock.releaseFirstStart() }

        XCTAssertEqual(
            startInterlock.waitUntilFirstStartEntered(
                timeout: .now() + .seconds(1)
            ),
            .success
        )
        DispatchQueue.global(qos: .userInitiated).async {
            output.stop()
            stopReturned.signal()
        }
        XCTAssertTrue(
            output.debugWaitForStopRequestDuringStartForTesting(
                timeout: 1
            ),
            "The concurrent stop never fenced the in-progress local queue."
        )
        XCTAssertEqual(
            stopReturned.wait(timeout: .now()),
            .timedOut,
            "stop() returned before the started local queue was cleaned up."
        )

        startInterlock.releaseFirstStart()
        XCTAssertEqual(
            startReturned.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(
            stopReturned.wait(timeout: .now() + .seconds(1)),
            .success
        )

        XCTAssertFalse(startOutcome.didSucceed)
        XCTAssertEqual(
            startOutcome.error,
            .operation(
                "authorize hidden BlackHole microphone writer",
                kAudio_ParamError
            )
        )
        XCTAssertEqual(operations.startCallCount, 1)
        XCTAssertEqual(operations.stopCallCount, 1)
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(operations.activeAllocationCount, 0)
        XCTAssertNil(output.debugRealtimeCallbackContextForTesting())
        XCTAssertFalse(output.forwardingProgressSnapshot.queueRunning)

        try output.start()
        XCTAssertTrue(output.forwardingProgressSnapshot.queueRunning)
        XCTAssertEqual(operations.startCallCount, 2)
        output.stop()
        XCTAssertEqual(operations.stopCallCount, 2)
        XCTAssertEqual(operations.disposeCallCount, 2)
        XCTAssertEqual(operations.activeAllocationCount, 0)
    }

    func testAllocationFailureChecksStatusAndCleansOnlyAllocatedBuffers() throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            allocateStatuses: [
                noErr,
                Self.allocationFailure,
            ]
        )
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureHandler: { _, _ in }
            )
        )

        XCTAssertThrowsError(try output.start()) { error in
            XCTAssertEqual(
                error as? BlackHoleMicrophoneOutputError,
                .operation(
                    "allocate BlackHole output buffer",
                    Self.allocationFailure
                )
            )
        }

        XCTAssertEqual(operations.allocateCallCount, 2)
        XCTAssertEqual(operations.enqueueCallCount, 1)
        XCTAssertEqual(operations.startCallCount, 0)
        XCTAssertEqual(operations.freeBufferCallCount, 0)
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(operations.activeAllocationCount, 0)
    }

    func testDisposeFailureTerminalizesQueueReleasesContextAndAllowsReplacementStart()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            disposeStatuses: [
                Self.disposeFailure,
                noErr,
            ]
        )
        let callbackContextDeinit =
            BlackHoleCallbackContextDeinitProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                callbackContextDeinitForTesting: {
                    callbackContextDeinit.record()
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try output.start()
        let originalQueue = operations.queue
        let originalBuffer = try XCTUnwrap(
            operations.allocatedBuffers.first
        )
        let enqueueCount = operations.enqueueCallCount

        output.stop()

        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(operations.activeAllocationCount, 0)
        XCTAssertEqual(
            output.debugLastDisposeStatusForTesting,
            Self.disposeFailure
        )
        XCTAssertEqual(callbackContextDeinit.count, 1)
        XCTAssertEqual(
            callbackContextDeinit.completed.wait(
                timeout: .now() + .seconds(1)
            ),
            .success,
            "The retained AudioQueue callback context must be released exactly once after AudioQueueDispose returns, even when it returns an error."
        )

        XCTAssertEqual(
            operations.enqueueBuffer(
                originalBuffer,
                on: originalQueue
            ),
            kAudio_ParamError,
            "The fake terminalizes a queue immediately after AudioQueueDispose returns so a retry-after-error mutant cannot pass."
        )
        XCTAssertEqual(operations.enqueueCallCount, enqueueCount)
        output.stop()
        XCTAssertEqual(
            operations.disposeCallCount,
            1,
            "A terminal AudioQueueRef must never be disposed a second time."
        )

        try output.start()
        XCTAssertEqual(
            operations.createCallCount,
            2,
            "A nonzero dispose status is diagnostic only and must not globally poison replacement queue creation."
        )
        XCTAssertNotEqual(operations.queue, originalQueue)
        output.stop()
        XCTAssertEqual(operations.disposeCallCount, 2)
        XCTAssertEqual(callbackContextDeinit.count, 2)
        XCTAssertEqual(operations.activeAllocationCount, 0)
    }

    func testFailedStartDisposeFailureReleasesContextAndAllowsLaterStart()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            enqueueStatuses: [
                noErr,
                Self.primingFailure,
            ],
            disposeStatuses: [
                Self.disposeFailure,
                noErr,
            ]
        )
        let callbackContextDeinit =
            BlackHoleCallbackContextDeinitProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                callbackContextDeinitForTesting: {
                    callbackContextDeinit.record()
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        XCTAssertThrowsError(try output.start()) { error in
            XCTAssertEqual(
                error as? BlackHoleMicrophoneOutputError,
                .operation(
                    "prime BlackHole output buffer",
                    Self.primingFailure
                )
            )
        }

        XCTAssertEqual(operations.createCallCount, 1)
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(operations.activeAllocationCount, 0)
        XCTAssertEqual(callbackContextDeinit.count, 1)

        try output.start()
        XCTAssertEqual(
            operations.createCallCount,
            2,
            "Failed-start cleanup must not retain a poisoned global disposal gate."
        )
        output.stop()
        XCTAssertEqual(operations.disposeCallCount, 2)
        XCTAssertEqual(callbackContextDeinit.count, 2)
        XCTAssertEqual(operations.activeAllocationCount, 0)
    }

    func testRepeatedStopAndDeinitNeverRedisposeTerminalQueue()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            disposeStatuses: [Self.disposeFailure]
        )
        let deinitProbe = BlackHoleDeinitProbe()
        let callbackContextDeinit =
            BlackHoleCallbackContextDeinitProbe()
        var output: BlackHoleMicrophoneOutput? = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                callbackContextDeinitForTesting: {
                    callbackContextDeinit.record()
                },
                deinitForTesting: {
                    deinitProbe.record()
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try output!.start()
        output!.stop()
        output!.stop()
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(callbackContextDeinit.count, 1)

        output = nil
        XCTAssertEqual(
            deinitProbe.completed.wait(
                timeout: .now() + .seconds(1)
            ),
            .success
        )
        XCTAssertEqual(
            operations.disposeCallCount,
            1,
            "Deinit after explicit stop must not retry the terminal AudioQueueRef."
        )
        XCTAssertEqual(operations.activeAllocationCount, 0)
    }

    func testMultipleIndependentOutputsDoNotPoisonReplacementStarts()
        throws {
        let firstCallbackContextDeinit =
            BlackHoleCallbackContextDeinitProbe()
        let secondCallbackContextDeinit =
            BlackHoleCallbackContextDeinitProbe()
        let operations = FakeBlackHoleAudioQueueOperations(
            disposeStatuses: [
                Self.disposeFailure,
                noErr,
            ]
        )
        let first = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                callbackContextDeinitForTesting: {
                    firstCallbackContextDeinit.record()
                },
                runtimeFailureHandler: { _, _ in }
            )
        )
        let second = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                callbackContextDeinitForTesting: {
                    secondCallbackContextDeinit.record()
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try first.start()
        first.stop()
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(firstCallbackContextDeinit.count, 1)

        try second.start()
        XCTAssertEqual(
            operations.createCallCount,
            2,
            "A failed dispose from one output must not block an independent replacement output."
        )
        second.stop()
        XCTAssertEqual(operations.disposeCallCount, 2)
        XCTAssertEqual(secondCallbackContextDeinit.count, 1)
        XCTAssertEqual(operations.activeAllocationCount, 0)
    }

    func testDisposeWaitsForEnteredCallbackBeforeReleasingContext() throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            disposeStatuses: [Self.disposeFailure]
        )
        let callbackProbe = BlackHoleCallbackHoldProbe()
        let contextDeinit = BlackHoleCallbackContextDeinitProbe()
        let stopReturned = DispatchSemaphore(value: 0)
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                renderForTesting: { _, frameCount in
                    callbackProbe.render(frameCount: frameCount)
                },
                callbackContextDeinitForTesting: {
                    contextDeinit.record()
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try output.start()
        let renderCountAfterPriming = callbackProbe.count
        callbackProbe.holdNextRender()
        let context = try XCTUnwrap(
            output.debugRealtimeCallbackContextForTesting()
        )
        let buffer = try XCTUnwrap(
            operations.allocatedBuffers.first
        )
        let callbackInvocation = BlackHoleCallbackInvocationBox(
            context: context,
            queue: operations.queue,
            buffer: buffer
        )
        DispatchQueue.global(qos: .userInitiated).async {
            BlackHoleMicrophoneOutput
                .debugInvokeRealtimeCallbackWithContextForTesting(
                    context: callbackInvocation.context,
                    queue: callbackInvocation.queue,
                    buffer: callbackInvocation.buffer
                )
        }
        XCTAssertEqual(
            callbackProbe.entered.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(callbackProbe.count, renderCountAfterPriming + 1)

        DispatchQueue.global(qos: .userInitiated).async {
            output.stop()
            stopReturned.signal()
        }

        let stopDeadline = Date().addingTimeInterval(1)
        while operations.stopCallCount == 0, Date() < stopDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(operations.stopCallCount, 1)
        XCTAssertEqual(operations.disposeCallCount, 0)
        XCTAssertEqual(
            stopReturned.wait(timeout: .now() + .milliseconds(20)),
            .timedOut
        )
        XCTAssertEqual(contextDeinit.count, 0)

        callbackProbe.releaseHeldRender()
        XCTAssertEqual(
            stopReturned.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(contextDeinit.count, 1)
        XCTAssertEqual(operations.activeAllocationCount, 0)
    }

    func testCallbackFailuresLatchFirstStatusReportOffCallbackOnceAndNeverTeardownInsideCallback() throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            enqueueStatuses: [
                noErr,
                noErr,
                noErr,
                Self.firstRuntimeFailure,
                Self.repeatedRuntimeFailure,
            ],
            reportedBufferCapacities: [
                2: 0,
            ]
        )
        let renderProbe = BlackHoleRenderProbe()
        let failureProbe = BlackHoleRuntimeFailureProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                renderForTesting: { _, frameCount in
                    renderProbe.record(frameCount: frameCount)
                    return false
                },
                runtimeFailureHandler: { output, error in
                    failureProbe.record(error)
                    output.stop()
                }
            )
        )

        try output.start()
        try output.start()
        let primedProgress = output.forwardingProgressSnapshot
        XCTAssertTrue(primedProgress.queueRunning)
        XCTAssertEqual(
            primedProgress.postStartCallbackCount,
            0,
            "Three priming fills must never appear as post-start progress."
        )
        XCTAssertEqual(
            operations.startCallCount,
            1,
            "Repeated start must remain idempotent."
        )
        XCTAssertEqual(operations.enqueueCallCount, 3)

        let allocatedBuffers = operations.allocatedBuffers
        XCTAssertEqual(allocatedBuffers.count, 3)
        let normalBuffer = try XCTUnwrap(allocatedBuffers.first)
        let zeroFrameBuffer = allocatedBuffers[2]
        let renderCountAfterPriming = renderProbe.count

        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: normalBuffer
        )
        XCTAssertEqual(
            normalBuffer.pointee.mAudioDataByteSize,
            normalBuffer.pointee.mAudioDataBytesCapacity
        )
        XCTAssertEqual(renderProbe.count, renderCountAfterPriming + 1)

        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: zeroFrameBuffer
        )
        XCTAssertEqual(zeroFrameBuffer.pointee.mAudioDataByteSize, 0)
        XCTAssertEqual(
            renderProbe.count,
            renderCountAfterPriming + 1,
            "The zero-frame branch must enqueue without invoking the native pull."
        )

        XCTAssertEqual(operations.enqueueCallCount, 5)
        XCTAssertEqual(
            failureProbe.errors.count,
            0,
            "The realtime callback may only publish to the atomic latch."
        )
        XCTAssertEqual(
            operations.stopCallCount,
            0,
            "AudioQueueStop must never run inside the realtime callback."
        )
        XCTAssertEqual(
            operations.freeBufferCallCount,
            0,
            "AudioQueueFreeBuffer must never run inside the realtime callback."
        )
        XCTAssertEqual(
            operations.disposeCallCount,
            0,
            "AudioQueueDispose must never run inside the realtime callback."
        )

        let callbackProgress = output.forwardingProgressSnapshot
        XCTAssertEqual(callbackProgress.postStartCallbackCount, 2)
        XCTAssertEqual(callbackProgress.requestedFrameCount, 480)
        XCTAssertEqual(callbackProgress.successfulPullCount, 0)
        XCTAssertEqual(callbackProgress.successfulFrameCount, 0)
        XCTAssertEqual(callbackProgress.silenceFallbackCount, 2)
        XCTAssertEqual(callbackProgress.silenceFrameCount, 480)
        XCTAssertEqual(callbackProgress.enqueueFailureCount, 2)
        XCTAssertEqual(
            callbackProgress.lastEnqueueStatus,
            Self.repeatedRuntimeFailure
        )

        output.debugReportLatchedRuntimeFailureForTesting()
        XCTAssertEqual(
            failureProbe.errors,
            [
                .operation(
                    "re-enqueue BlackHole output buffer",
                    Self.firstRuntimeFailure
                ),
            ],
            "The first callback failure must win and report off-callback exactly once."
        )
        XCTAssertEqual(operations.stopCallCount, 1)
        XCTAssertEqual(operations.freeBufferCallCount, 0)
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(operations.activeAllocationCount, 0)

        output.debugReportLatchedRuntimeFailureForTesting()
        output.stop()
        XCTAssertEqual(failureProbe.errors.count, 1)
        XCTAssertEqual(
            operations.stopCallCount,
            1,
            "Repeated reports and stop calls must remain idempotent."
        )
        XCTAssertEqual(operations.freeBufferCallCount, 0)
        XCTAssertEqual(operations.disposeCallCount, 1)
    }

    func testFailedDecodedPullRezerosFullCapacityAndEnqueuesFullSilence()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                renderForTesting: { samples, frameCount in
                    for index in 0..<frameCount {
                        samples[index] = Int16((index % 2_000) + 1)
                    }
                    return false
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try output.start()
        XCTAssertEqual(
            output.forwardingProgressSnapshot
                .postStartCallbackCount,
            0
        )

        let buffer = try XCTUnwrap(
            operations.allocatedBuffers.first
        )
        let enqueueCount = operations.enqueueCallCount
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )

        XCTAssertEqual(
            operations.enqueueCallCount,
            enqueueCount + 1
        )
        XCTAssertEqual(
            buffer.pointee.mAudioDataByteSize,
            buffer.pointee.mAudioDataBytesCapacity
        )
        let sampleCount =
            Int(buffer.pointee.mAudioDataByteSize)
            / MemoryLayout<Int16>.size
        let samples = UnsafeBufferPointer(
            start: buffer.pointee.mAudioData
                .assumingMemoryBound(to: Int16.self),
            count: sampleCount
        )
        XCTAssertTrue(samples.allSatisfy { $0 == 0 })

        let progress = output.forwardingProgressSnapshot
        XCTAssertEqual(progress.postStartCallbackCount, 1)
        XCTAssertEqual(progress.requestedFrameCount, 480)
        XCTAssertEqual(progress.successfulPullCount, 0)
        XCTAssertEqual(progress.successfulFrameCount, 0)
        XCTAssertEqual(progress.silenceFallbackCount, 1)
        XCTAssertEqual(progress.silenceFrameCount, 480)
        XCTAssertEqual(progress.enqueueFailureCount, 0)
        output.stop()
    }

    func testSuccessfulDecodedPullPreservesPatternAndAdvancesExactFrames()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                renderForTesting: { samples, frameCount in
                    for frame in 0..<frameCount {
                        let marker = Int16(frame + 1)
                        samples[frame] = marker
                    }
                    return true
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try output.start()
        XCTAssertEqual(
            output.forwardingProgressSnapshot
                .postStartCallbackCount,
            0
        )

        let buffer = try XCTUnwrap(
            operations.allocatedBuffers.first
        )
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        var progress = output.forwardingProgressSnapshot
        XCTAssertEqual(progress.postStartCallbackCount, 1)
        XCTAssertEqual(progress.successfulPullCount, 1)
        XCTAssertEqual(progress.successfulFrameCount, 480)
        XCTAssertEqual(progress.silenceFallbackCount, 0)

        let samples = buffer.pointee.mAudioData
            .assumingMemoryBound(to: Int16.self)
        XCTAssertEqual(samples[0], 1)
        XCTAssertEqual(samples[479], 480)
        XCTAssertEqual(buffer.pointee.mAudioDataByteSize, 960)

        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        progress = output.forwardingProgressSnapshot
        XCTAssertEqual(progress.postStartCallbackCount, 2)
        XCTAssertEqual(progress.requestedFrameCount, 960)
        XCTAssertEqual(progress.successfulPullCount, 2)
        XCTAssertEqual(progress.successfulFrameCount, 960)
        XCTAssertEqual(progress.enqueueFailureCount, 0)
        output.stop()
        XCTAssertFalse(
            output.forwardingProgressSnapshot.queueRunning
        )
    }

    func testPCMContentPublishesOnlyCompletedLatestWindowWithoutLifetimeSmearing()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        var renderedBufferCount = 0
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                renderForTesting: { samples, frameCount in
                    if renderedBufferCount < 100 {
                        for frame in 0..<frameCount {
                            let sample: Int16 = frame.isMultiple(of: 2)
                                ? 16_384
                                : -16_384
                            samples[frame] = sample
                        }
                    } else {
                        for frame in 0..<frameCount {
                            let sample: Int16
                            switch frame % 4 {
                            case 0:
                                sample = .max
                            case 1:
                                sample = .min
                            default:
                                sample = 0
                            }
                            samples[frame] = sample
                        }
                    }
                    renderedBufferCount += 1
                    return true
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try output.start()
        XCTAssertEqual(
            renderedBufferCount,
            0,
            "Startup priming must not pull decoded PCM."
        )
        XCTAssertEqual(
            output.forwardingProgressSnapshot.pcmContent,
            .zero,
            "A partial content window must not be published."
        )

        let buffer = try XCTUnwrap(operations.allocatedBuffers.first)
        for _ in 0..<100 {
            output.debugInvokeRealtimeCallbackForTesting(
                queue: operations.queue,
                buffer: buffer
            )
        }

        let first = output.forwardingProgressSnapshot.pcmContent
        XCTAssertGreaterThan(first.lifecycleGeneration, 0)
        XCTAssertEqual(first.windowSequence, 1)
        XCTAssertEqual(first.completedWindowCount, 1)
        XCTAssertEqual(first.completedFrameCount, 48_000)
        XCTAssertEqual(first.sourceStartFrame, 0)
        XCTAssertEqual(first.sourceEndFrame, 48_000)
        XCTAssertEqual(first.windowFrameCount, 48_000)
        XCTAssertNotEqual(first.windowFingerprint, 0)
        XCTAssertEqual(first.metrics.rms, 0.5, accuracy: 0.000_000_001)
        XCTAssertEqual(
            first.metrics.rmsDBFS,
            20 * log10(0.5),
            accuracy: 0.000_000_001
        )
        XCTAssertEqual(first.metrics.peak, 0.5, accuracy: 0.000_000_001)
        XCTAssertEqual(
            first.metrics.peakDBFS,
            20 * log10(0.5),
            accuracy: 0.000_000_001
        )
        XCTAssertEqual(first.metrics.dc, 0, accuracy: 0.000_000_001)
        XCTAssertEqual(first.metrics.zeroFraction, 0)
        XCTAssertEqual(first.metrics.clippingFraction, 0)

        for _ in 0..<99 {
            output.debugInvokeRealtimeCallbackForTesting(
                queue: operations.queue,
                buffer: buffer
            )
        }
        XCTAssertEqual(
            output.forwardingProgressSnapshot.pcmContent,
            first,
            "An incomplete next window must leave the latest completed " +
                "window visible."
        )

        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        let second = output.forwardingProgressSnapshot.pcmContent
        XCTAssertEqual(second.windowSequence, 2)
        XCTAssertEqual(second.completedWindowCount, 2)
        XCTAssertEqual(second.completedFrameCount, 96_000)
        XCTAssertEqual(second.lifecycleGeneration, first.lifecycleGeneration)
        XCTAssertEqual(second.sourceStartFrame, 48_000)
        XCTAssertEqual(second.sourceEndFrame, 96_000)
        XCTAssertEqual(second.windowFrameCount, 48_000)
        XCTAssertNotEqual(second.windowFingerprint, first.windowFingerprint)

        let fullScale = 32_768.0
        let endpointSquareSum =
            Double(Int64(Int16.max) * Int64(Int16.max))
            + Double(Int64(Int16.min) * Int64(Int16.min))
        let expectedRMS = sqrt(endpointSquareSum / 4) / fullScale
        let expectedDC = -1 / (4 * fullScale)
        XCTAssertEqual(
            second.metrics.rms,
            expectedRMS,
            accuracy: 0.000_000_001
        )
        XCTAssertEqual(second.metrics.peak, 1, accuracy: 0.000_000_001)
        XCTAssertEqual(
            second.metrics.dc,
            expectedDC,
            accuracy: 0.000_000_001
        )
        XCTAssertEqual(second.metrics.zeroFraction, 0.5)
        XCTAssertEqual(second.metrics.clippingFraction, 0.5)

        output.stop()
        XCTAssertEqual(
            output.forwardingProgressSnapshot.pcmContent,
            .zero,
            "A stopped lifecycle must not expose its prior PCM window."
        )

        try output.start()
        XCTAssertEqual(
            output.forwardingProgressSnapshot.pcmContent,
            .zero,
            "A replacement queue must not expose the retired lifecycle."
        )
        let replacementBuffer = try XCTUnwrap(
            operations.allocatedBuffers.last
        )
        for _ in 0..<100 {
            output.debugInvokeRealtimeCallbackForTesting(
                queue: operations.queue,
                buffer: replacementBuffer
            )
        }
        let replacement = output.forwardingProgressSnapshot.pcmContent
        XCTAssertNotEqual(
            replacement.lifecycleGeneration,
            second.lifecycleGeneration
        )
        XCTAssertNotEqual(replacement.windowSequence, second.windowSequence)
        XCTAssertEqual(replacement.sourceStartFrame, 0)
        XCTAssertEqual(replacement.sourceEndFrame, 48_000)
        output.stop()
    }

    func testPCMContentMeasuresFinalRezeroedSilenceWithoutRetainingDirtyPCM()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                renderForTesting: { samples, frameCount in
                    for frame in 0..<frameCount {
                        samples[frame] = .max
                    }
                    return false
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try output.start()
        let buffer = try XCTUnwrap(operations.allocatedBuffers.first)
        for _ in 0..<100 {
            output.debugInvokeRealtimeCallbackForTesting(
                queue: operations.queue,
                buffer: buffer
            )
        }

        let content = output.forwardingProgressSnapshot.pcmContent
        XCTAssertGreaterThan(content.lifecycleGeneration, 0)
        XCTAssertEqual(content.windowSequence, 1)
        XCTAssertEqual(content.completedFrameCount, 48_000)
        XCTAssertEqual(content.sourceStartFrame, 0)
        XCTAssertEqual(content.sourceEndFrame, 48_000)
        XCTAssertEqual(content.windowFrameCount, 48_000)
        XCTAssertEqual(content.metrics.rms, 0)
        XCTAssertEqual(content.metrics.rmsDBFS, -160)
        XCTAssertEqual(content.metrics.peak, 0)
        XCTAssertEqual(content.metrics.peakDBFS, -160)
        XCTAssertEqual(content.metrics.dc, 0)
        XCTAssertEqual(content.metrics.zeroFraction, 1)
        XCTAssertEqual(content.metrics.clippingFraction, 0)
        output.stop()
    }

    func testPCMContentUsesMonoDCAndClippingThresholds()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        var renderedBufferCount = 0
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                renderForTesting: { samples, frameCount in
                    for frame in 0..<frameCount {
                        let sample: Int16
                        if renderedBufferCount < 100 {
                            let variation: Int16 = frame.isMultiple(of: 2)
                                ? -100
                                : 100
                            sample = 1_000 + variation
                        } else {
                            switch frame % 4 {
                            case 0:
                                sample = 32_760
                            case 1:
                                sample = -32_760
                            case 2:
                                sample = 127
                            default:
                                sample = -127
                            }
                        }
                        samples[frame] = sample
                    }
                    renderedBufferCount += 1
                    return true
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try output.start()
        let buffer = try XCTUnwrap(operations.allocatedBuffers.first)
        for _ in 0..<100 {
            output.debugInvokeRealtimeCallbackForTesting(
                queue: operations.queue,
                buffer: buffer
            )
        }
        let dcBiased = output.forwardingProgressSnapshot.pcmContent
        XCTAssertEqual(
            dcBiased.metrics.dc,
            1_000.0 / 32_768.0,
            accuracy: 0.000_000_001
        )

        for _ in 0..<100 {
            output.debugInvokeRealtimeCallbackForTesting(
                queue: operations.queue,
                buffer: buffer
            )
        }
        let thresholded = output.forwardingProgressSnapshot.pcmContent
        XCTAssertEqual(thresholded.metrics.clippingFraction, 0.5)
        XCTAssertEqual(thresholded.metrics.zeroFraction, 0)
        XCTAssertEqual(
            thresholded.metrics.peak,
            32_760.0 / 32_768.0,
            accuracy: 0.000_000_001
        )
        output.stop()
    }

    func testContentFingerprintComparisonRequiresExactCurrentWindowIdentity() {
        let fingerprint: UInt64 = 0x7b4a_93d2_105e_6fc1
        let pcm = BlackHoleMicrophoneOutputPCMContentSnapshot(
            lifecycleGeneration: 4,
            windowSequence: 9,
            completedFrameCount: 96_000,
            sourceStartFrame: 48_000,
            sourceEndFrame: 96_000,
            windowFrameCount: 48_000,
            windowFingerprint: fingerprint,
            metrics: .zero
        )
        func progress(
            fingerprint decodedFingerprint: UInt64,
            start: UInt64 = 48_000,
            end: UInt64 = 96_000,
            byteCount: UInt64 = 96_000,
            generation: UInt64 = 7,
            windowGeneration: UInt64 = 7,
            boundGeneration: UInt64 = 7,
            windowFirstRenderCall: UInt64 = 1,
            boundRenderCallFloor: UInt64 = 0,
            silenceFallbackCount: UInt64 = 0,
            enqueueFailureCount: UInt64 = 0
        ) -> BlackHoleMicrophoneOutputProgressSnapshot {
            var native = ASMacDecodedPlayoutTelemetrySnapshot()
            native.playoutGeneration = generation
            native.hasCompletedWindow = true
            native.completedWindowSequence = 2
            native.completedWindowGeneration = windowGeneration
            native.completedWindowFirstRenderCall =
                windowFirstRenderCall
            native.completedWindowLastRenderCall =
                windowFirstRenderCall + 99
            native.completedWindowFrameCount = 48_000
            native.completedWindowByteCount = byteCount
            native.completedWindowSourceStartFrame = start
            native.completedWindowSourceEndFrame = end
            native.completedWindowFingerprint = decodedFingerprint
            return BlackHoleMicrophoneOutputProgressSnapshot(
                queueRunning: true,
                postStartCallbackCount: 1,
                requestedFrameCount: 48_000,
                successfulPullCount: 1,
                successfulFrameCount: 48_000,
                silenceFallbackCount: silenceFallbackCount,
                silenceFrameCount: 0,
                enqueueFailureCount: enqueueFailureCount,
                lastEnqueueStatus: noErr,
                pcmContent: pcm,
                decodedContent:
                    BlackHoleMicrophoneOutputDecodedContentSnapshot(native),
                boundDecodedPlayoutGeneration: boundGeneration,
                boundDecodedRenderCallFloor: boundRenderCallFloor
            )
        }

        let matching = progress(fingerprint: fingerprint)
        XCTAssertTrue(matching.contentWindowsAlign)
        XCTAssertTrue(matching.alignedContentFingerprintsMatch)

        let differentContent = progress(fingerprint: fingerprint ^ 1)
        XCTAssertTrue(differentContent.contentWindowsAlign)
        XCTAssertFalse(differentContent.alignedContentFingerprintsMatch)

        XCTAssertFalse(
            progress(fingerprint: fingerprint, start: 47_999)
                .contentWindowsAlign
        )
        XCTAssertFalse(
            progress(fingerprint: fingerprint, byteCount: 95_998)
                .contentWindowsAlign
        )
        XCTAssertFalse(
            progress(
                fingerprint: fingerprint,
                windowGeneration: 6
            ).contentWindowsAlign
        )
        XCTAssertFalse(
            progress(
                fingerprint: fingerprint,
                generation: 8,
                windowGeneration: 8
            ).contentWindowsAlign,
            "A new decoded playout generation must not align with stale queue-lifetime frame coordinates."
        )
        XCTAssertFalse(
            progress(
                fingerprint: fingerprint,
                boundGeneration: 0
            ).contentWindowsAlign
        )
        XCTAssertFalse(
            progress(
                fingerprint: fingerprint,
                windowFirstRenderCall: 100,
                boundRenderCallFloor: 100
            ).contentWindowsAlign,
            "A completed decoded window from before this output lifetime must not align even when its range and fingerprint match."
        )
        XCTAssertFalse(
            progress(
                fingerprint: fingerprint,
                silenceFallbackCount: 1
            ).contentWindowsAlign
        )
        XCTAssertFalse(
            progress(
                fingerprint: fingerprint,
                enqueueFailureCount: 1
            ).contentWindowsAlign
        )
    }

    func testStartBindsOnlyDecodedGenerationStableAcrossPriming() throws {
        let stableBindings =
            BlackHoleScriptedDecodedBinding([(7, 0), (7, 3)])
        let stableOperations = FakeBlackHoleAudioQueueOperations()
        let stableOutput = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: stableOperations,
                renderForTesting: { _, _ in true },
                decodedPlayoutBindingForTesting: {
                    stableBindings.read()
                },
                runtimeFailureHandler: { _, _ in }
            )
        )
        try stableOutput.start()
        XCTAssertEqual(
            stableOutput.boundDecodedPlayoutGenerationForTesting,
            7
        )
        XCTAssertEqual(
            stableOutput.boundDecodedRenderCallFloorForTesting,
            3,
            "The content window floor begins only when PCM admission opens."
        )
        XCTAssertEqual(stableBindings.readCount, 2)
        stableOutput.stop()

        let changingBindings =
            BlackHoleScriptedDecodedBinding([(7, 0), (8, 3)])
        let changingOperations = FakeBlackHoleAudioQueueOperations()
        let changingOutput = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: changingOperations,
                renderForTesting: { _, _ in true },
                decodedPlayoutBindingForTesting: {
                    changingBindings.read()
                },
                runtimeFailureHandler: { _, _ in }
            )
        )
        try changingOutput.start()
        XCTAssertEqual(
            changingOutput.boundDecodedPlayoutGenerationForTesting,
            0,
            "A decoded restart during silent startup must not inherit the later generation."
        )
        XCTAssertEqual(changingBindings.readCount, 2)
        changingOutput.stop()

        let failedPrimingBindings =
            BlackHoleScriptedDecodedBinding([(7, 0), (7, 3)])
        let failedPrimingOutput = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations:
                    FakeBlackHoleAudioQueueOperations(),
                renderForTesting: { _, _ in false },
                decodedPlayoutBindingForTesting: {
                    failedPrimingBindings.read()
                },
                runtimeFailureHandler: { _, _ in }
            )
        )
        try failedPrimingOutput.start()
        XCTAssertEqual(
            failedPrimingOutput
                .boundDecodedPlayoutGenerationForTesting,
            7,
            "Silent priming never calls the failing renderer; readiness "
                + "still requires a later admitted successful pull."
        )
        failedPrimingOutput.stop()
    }

    func testProgressWatchdogToleratesContinuouslyAdvancingSilenceBeforeFirstPCM()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let clock = BlackHoleManualMonotonicClock()
        let failures = BlackHoleRuntimeFailureProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                progressStallGraceNanoseconds:
                    Self.progressStallGraceNanoseconds,
                runtimeFailureHandler: { _, error in
                    failures.record(error)
                }
            )
        )

        try output.start()
        let generation = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        let buffer = try XCTUnwrap(operations.allocatedBuffers.first)

        for _ in 0..<4 {
            clock.advance(
                by: Self.progressStallGraceNanoseconds - 1
            )
            output.debugInvokeRealtimeCallbackForTesting(
                queue: operations.queue,
                buffer: buffer
            )
            output.debugPollRuntimeFailureMonitoringForTesting(
                generation: generation
            )
        }
        clock.advance(
            by: Self.progressStallGraceNanoseconds - 1
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        XCTAssertTrue(failures.errors.isEmpty)
        XCTAssertEqual(
            output.forwardingProgressSnapshot
                .postStartCallbackCount,
            4
        )
        XCTAssertEqual(
            output.forwardingProgressSnapshot
                .successfulFrameCount,
            0
        )
        output.stop()
    }

    func testProgressWatchdogReportsSilentCallbackCessationBeforeFirstPCMExactlyOnce()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let clock = BlackHoleManualMonotonicClock()
        let failures = BlackHoleRuntimeFailureProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                progressStallGraceNanoseconds:
                    Self.progressStallGraceNanoseconds,
                runtimeFailureHandler: { _, error in
                    failures.record(error)
                }
            )
        )

        try output.start()
        let generation = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        let buffer = try XCTUnwrap(operations.allocatedBuffers.first)
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        clock.advance(by: Self.progressStallGraceNanoseconds)
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        XCTAssertEqual(failures.errors, [.progressStalled])
        output.stop()
    }

    func testProgressWatchdogReportsMissingStartupCallbacksExactlyOnce()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let clock = BlackHoleManualMonotonicClock()
        let failures = BlackHoleRuntimeFailureProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                progressStallGraceNanoseconds:
                    Self.progressStallGraceNanoseconds,
                runtimeFailureHandler: { _, error in
                    failures.record(error)
                }
            )
        )

        try output.start()
        let generation = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        clock.advance(by: Self.progressStallGraceNanoseconds)
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        XCTAssertEqual(failures.errors, [.progressStalled])
        XCTAssertEqual(
            output.forwardingProgressSnapshot
                .postStartCallbackCount,
            0
        )
        output.stop()
    }

    func testProgressWatchdogAllowsDelayedFirstPCMAndThenTracksHealthyFrames()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let clock = BlackHoleManualMonotonicClock()
        let render = BlackHoleRenderOutcomeProbe(succeeds: false)
        let failures = BlackHoleRuntimeFailureProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                progressStallGraceNanoseconds:
                    Self.progressStallGraceNanoseconds,
                renderForTesting: { samples, frameCount in
                    render.render(
                        samples: samples,
                        frameCount: frameCount
                    )
                },
                runtimeFailureHandler: { _, error in
                    failures.record(error)
                }
            )
        )

        try output.start()
        let generation = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        let buffer = try XCTUnwrap(operations.allocatedBuffers.first)

        clock.advance(
            by: Self.progressStallGraceNanoseconds - 1
        )
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        clock.advance(
            by: Self.progressStallGraceNanoseconds - 1
        )
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        render.setSucceeds(true)
        clock.advance(
            by: Self.progressStallGraceNanoseconds - 1
        )
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        clock.advance(
            by: Self.progressStallGraceNanoseconds - 1
        )
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        XCTAssertTrue(failures.errors.isEmpty)
        XCTAssertEqual(
            output.forwardingProgressSnapshot
                .successfulFrameCount,
            960
        )
        output.stop()
    }

    func testProgressWatchdogReportsPostSuccessTimeoutExactlyOnce()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let clock = BlackHoleManualMonotonicClock()
        let render = BlackHoleRenderOutcomeProbe(succeeds: true)
        let failures = BlackHoleRuntimeFailureProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                progressStallGraceNanoseconds:
                    Self.progressStallGraceNanoseconds,
                renderForTesting: { samples, frameCount in
                    render.render(samples: samples, frameCount: frameCount)
                },
                runtimeFailureHandler: { _, error in
                    failures.record(error)
                }
            )
        )

        try output.start()
        let generation = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        let buffer = try XCTUnwrap(operations.allocatedBuffers.first)
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        clock.advance(by: Self.progressStallGraceNanoseconds)
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        XCTAssertEqual(failures.errors, [.progressStalled])
        output.stop()
    }

    func testProgressWatchdogRefreshesOnHealthyFrameAdvances()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let clock = BlackHoleManualMonotonicClock()
        let render = BlackHoleRenderOutcomeProbe(succeeds: true)
        let failures = BlackHoleRuntimeFailureProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                progressStallGraceNanoseconds:
                    Self.progressStallGraceNanoseconds,
                renderForTesting: { samples, frameCount in
                    render.render(samples: samples, frameCount: frameCount)
                },
                runtimeFailureHandler: { _, error in
                    failures.record(error)
                }
            )
        )

        try output.start()
        let generation = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        let buffer = try XCTUnwrap(operations.allocatedBuffers.first)
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        clock.advance(by: Self.progressStallGraceNanoseconds - 1)
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )
        clock.advance(by: Self.progressStallGraceNanoseconds - 1)
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        XCTAssertTrue(failures.errors.isEmpty)
        output.stop()
    }

    func testStopAndRestartFencePreviousWatchdogGeneration() throws {
        let operations = FakeBlackHoleAudioQueueOperations()
        let clock = BlackHoleManualMonotonicClock()
        let failures = BlackHoleRuntimeFailureProbe()
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                progressStallGraceNanoseconds:
                    Self.progressStallGraceNanoseconds,
                runtimeFailureHandler: { _, error in
                    failures.record(error)
                }
            )
        )

        try output.start()
        let firstGeneration = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        clock.advance(by: Self.progressStallGraceNanoseconds * 2)
        output.stop()
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: firstGeneration
        )

        try output.start()
        let secondGeneration = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        XCTAssertNotEqual(firstGeneration, secondGeneration)
        let secondBuffer = try XCTUnwrap(
            operations.allocatedBuffers.last
        )
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: secondBuffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: secondGeneration
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: firstGeneration
        )

        XCTAssertTrue(failures.errors.isEmpty)
        output.stop()
    }

    func testEnqueueFailureWinsWhenPollRunsBetweenFailureAndProgressPublications()
        throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            enqueueStatuses: [
                noErr,
                noErr,
                noErr,
                noErr,
                Self.firstRuntimeFailure,
            ]
        )
        let clock = BlackHoleManualMonotonicClock()
        let render = BlackHoleRenderOutcomeProbe(succeeds: true)
        let failures = BlackHoleRuntimeFailureProbe()
        let interlock =
            BlackHoleMicrophoneOutputRuntimeEnqueueFailurePublicationInterlock()
        let callbackInvocationCompleted = DispatchGroup()
        let handlerEntered = DispatchSemaphore(value: 0)
        let pollCompleted = DispatchGroup()
        let allowHandlerStop = DispatchSemaphore(value: 0)
        let output = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                runtimeFailureNow: { clock.read() },
                progressStallGraceNanoseconds:
                    Self.progressStallGraceNanoseconds,
                runtimeEnqueueFailurePublicationInterlockForTesting:
                    interlock,
                renderForTesting: { samples, frameCount in
                    render.render(samples: samples, frameCount: frameCount)
                },
                runtimeFailureHandler: { output, error in
                    failures.record(error)
                    handlerEntered.signal()
                    allowHandlerStop.wait()
                    output.stop()
                }
            )
        )

        try output.start()
        let generation = try XCTUnwrap(
            output.debugRuntimeFailureMonitoringGenerationForTesting()
        )
        let buffer = try XCTUnwrap(operations.allocatedBuffers.first)
        output.debugInvokeRealtimeCallbackForTesting(
            queue: operations.queue,
            buffer: buffer
        )
        output.debugPollRuntimeFailureMonitoringForTesting(
            generation: generation
        )

        let callbackContext = try XCTUnwrap(
            output.debugRealtimeCallbackContextForTesting()
        )
        let callbackInvocation = BlackHoleCallbackInvocationBox(
            context: callbackContext,
            queue: operations.queue,
            buffer: buffer
        )
        render.setSucceeds(false)
        clock.advance(by: Self.progressStallGraceNanoseconds)
        interlock.armNextFailureCallback()
        callbackInvocationCompleted.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { callbackInvocationCompleted.leave() }
            BlackHoleMicrophoneOutput
                .debugInvokeRealtimeCallbackWithContextForTesting(
                    context: callbackInvocation.context,
                    queue: callbackInvocation.queue,
                    buffer: callbackInvocation.buffer
                )
        }

        var pollStarted = false
        defer {
            withExtendedLifetime(output) {
                interlock.releaseCallback()
                callbackInvocationCompleted.wait()
                allowHandlerStop.signal()
                if pollStarted {
                    pollCompleted.wait()
                }
            }
        }

        guard interlock.waitUntilCallbackPaused(
            timeout: .now() + .seconds(1)
        ) == .success else {
            XCTFail(
                "The intended async callback did not pause after " +
                    "publishing its enqueue failure."
            )
            return
        }
        let interleavedSnapshot =
            output.forwardingProgressSnapshot
        XCTAssertEqual(interleavedSnapshot.postStartCallbackCount, 1)
        XCTAssertEqual(interleavedSnapshot.enqueueFailureCount, 0)

        pollCompleted.enter()
        pollStarted = true
        DispatchQueue.global(qos: .userInitiated).async {
            defer { pollCompleted.leave() }
            output.debugPollRuntimeFailureMonitoringForTesting(
                generation: generation
            )
        }
        guard handlerEntered.wait(
            timeout: .now() + .seconds(1)
        ) == .success else {
            XCTFail(
                "The failure poll did not enter the runtime handler."
            )
            return
        }
        interlock.releaseCallback()
        guard callbackInvocationCompleted.wait(
            timeout: .now() + .seconds(1)
        ) == .success else {
            XCTFail(
                "The paused callback did not return after release."
            )
            return
        }
        allowHandlerStop.signal()
        guard pollCompleted.wait(
            timeout: .now() + .seconds(1)
        ) == .success else {
            XCTFail(
                "The failure poll did not return after handler stop."
            )
            return
        }

        XCTAssertEqual(
            failures.errors,
            [
                .operation(
                    "re-enqueue BlackHole output buffer",
                    Self.firstRuntimeFailure
                ),
            ]
        )

        let progress = output.forwardingProgressSnapshot
        XCTAssertEqual(progress.postStartCallbackCount, 2)
        XCTAssertEqual(progress.requestedFrameCount, 960)
        XCTAssertEqual(progress.successfulPullCount, 1)
        XCTAssertEqual(progress.successfulFrameCount, 480)
        XCTAssertEqual(progress.silenceFallbackCount, 1)
        XCTAssertEqual(progress.silenceFrameCount, 480)
        XCTAssertEqual(progress.enqueueFailureCount, 1)
        XCTAssertEqual(
            progress.lastEnqueueStatus,
            Self.firstRuntimeFailure
        )
        output.stop()
    }

    func testStopFailureAndDeinitFenceHeldCallbackBeforeDispose() throws {
        let operations = FakeBlackHoleAudioQueueOperations(
            stopStatus: Self.callbackStopFailure
        )
        let callbackProbe = BlackHoleCallbackHoldProbe()
        let deinitProbe = BlackHoleDeinitProbe()
        let callbackReturned = DispatchSemaphore(value: 0)
        let releaseReturned = DispatchSemaphore(value: 0)
        var output: BlackHoleMicrophoneOutput? = try XCTUnwrap(
            BlackHoleMicrophoneOutput(
                testingAudioQueueOperations: operations,
                renderForTesting: { _, frameCount in
                    callbackProbe.render(frameCount: frameCount)
                },
                deinitForTesting: {
                    deinitProbe.record()
                },
                runtimeFailureHandler: { _, _ in }
            )
        )

        try XCTUnwrap(output).start()
        let renderCountAfterPriming = callbackProbe.count
        callbackProbe.holdNextRender()

        let callbackContext = try XCTUnwrap(
            output?.debugRealtimeCallbackContextForTesting()
        )
        let callbackBuffer = try XCTUnwrap(
            operations.allocatedBuffers.first
        )
        let callbackInvocation = BlackHoleCallbackInvocationBox(
            context: callbackContext,
            queue: operations.queue,
            buffer: callbackBuffer
        )
        DispatchQueue.global(qos: .userInitiated).async {
            BlackHoleMicrophoneOutput
                .debugInvokeRealtimeCallbackWithContextForTesting(
                    context: callbackInvocation.context,
                    queue: callbackInvocation.queue,
                    buffer: callbackInvocation.buffer
                )
            callbackReturned.signal()
        }

        XCTAssertEqual(
            callbackProbe.entered.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(callbackProbe.count, renderCountAfterPriming + 1)

        let weakOutput = BlackHoleWeakOutputBox(try XCTUnwrap(output))
        let releaseBox = BlackHoleOutputReleaseBox(try XCTUnwrap(output))
        output = nil
        DispatchQueue.global(qos: .userInitiated).async {
            releaseBox.output = nil
            releaseReturned.signal()
        }

        let stopDeadline = Date().addingTimeInterval(1)
        while operations.stopCallCount == 0, Date() < stopDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(operations.stopCallCount, 1)
        XCTAssertEqual(operations.disposeCallCount, 0)
        XCTAssertEqual(operations.activeAllocationCount, 3)
        XCTAssertEqual(
            releaseReturned.wait(timeout: .now() + .milliseconds(20)),
            .timedOut
        )
        XCTAssertEqual(
            deinitProbe.completed.wait(
                timeout: .now() + .milliseconds(20)
            ),
            .timedOut
        )

        BlackHoleMicrophoneOutput
            .debugInvokeRealtimeCallbackWithContextForTesting(
                context: callbackInvocation.context,
                queue: callbackInvocation.queue,
                buffer: callbackInvocation.buffer
            )
        XCTAssertEqual(callbackProbe.count, renderCountAfterPriming + 1)
        XCTAssertEqual(operations.enqueueCallCount, 3)

        callbackProbe.releaseHeldRender()
        XCTAssertEqual(
            callbackReturned.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(
            releaseReturned.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(
            deinitProbe.completed.wait(timeout: .now() + .seconds(1)),
            .success
        )

        XCTAssertNil(weakOutput.output)
        XCTAssertEqual(operations.stopCallCount, 1)
        XCTAssertEqual(operations.disposeCallCount, 1)
        XCTAssertEqual(operations.freeBufferCallCount, 0)
        XCTAssertEqual(operations.activeAllocationCount, 0)
        XCTAssertEqual(
            operations.enqueueCallCount,
            3,
            "Closing PCM admission while a pull is in flight must scrub and retire it."
        )
        XCTAssertEqual(operations.enqueueAfterDisposeCallCount, 0)
    }
}

private struct FakeBlackHoleDeviceTimeResult {
    let status: OSStatus
    let timestamp: AudioTimeStamp

    static func success(
        sampleTime: Double = 0,
        hostTime: UInt64 = 1,
        flags: AudioTimeStampFlags =
            BlackHoleFaceTimeClockPolicy.requiredTimestampFlags
    ) -> Self {
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mHostTime = hostTime
        timestamp.mFlags = flags
        return Self(status: noErr, timestamp: timestamp)
    }
}

private final class FakeBlackHoleAudioQueueOperations:
    BlackHoleMicrophoneOutputAudioQueueOperations,
    @unchecked Sendable
{
    var queue: AudioQueueRef {
        withLock { latestQueue }
    }

    private let lock = NSLock()
    private let deviceUID: String
    private let deviceID: AudioDeviceID
    private let translateDeviceStatuses: [OSStatus]
    private let translatedDeviceIDSequence: [AudioDeviceID?]
    private let createStatus: OSStatus
    private let setDeviceStatus: OSStatus
    private let currentDeviceStatus: OSStatus
    private let currentDeviceUIDOverride: String?
    private let currentDeviceUIDSequence: [String]
    private let allocateStatuses: [OSStatus]
    private let enqueueStatuses: [OSStatus]
    private let startStatus: OSStatus
    private let streamDescriptionStatuses: [OSStatus]
    private let streamDescriptionValues:
        [AudioStreamBasicDescription]
    private let deviceSampleRateStatuses: [OSStatus]
    private let deviceSampleRateValues: [Double]
    private let deviceChannelCountStatuses: [OSStatus]
    private let deviceChannelCountValues: [UInt32]
    private let converterErrorReadStatuses: [OSStatus]
    private let converterErrorValues: [UInt32]
    private let deviceTimeResults:
        [FakeBlackHoleDeviceTimeResult]
    private let nominalSampleRateStatus: OSStatus
    private let nominalSampleRateValue: Double
    private let stopStatus: OSStatus
    private let disposeStatus: OSStatus
    private let disposeStatuses: [OSStatus]
    private let reportedBufferCapacities: [Int: UInt32]
    private let startQueueInterlock:
        BlackHoleAudioQueueStartInterlock?
    private var allocations: [FakeAudioQueueBufferAllocation] = []
    private var selectedDeviceUIDsStorage: [String] = []
    private var allocateCallCountStorage = 0
    private var enqueueCallCountStorage = 0
    private var startCallCountStorage = 0
    private var requestedFormatsStorage:
        [AudioStreamBasicDescription] = []
    private var callbackContextsStorage:
        [UnsafeMutableRawPointer] = []
    private var streamDescriptionReadCountStorage = 0
    private var deviceSampleRateReadCountStorage = 0
    private var deviceChannelCountReadCountStorage = 0
    private var converterErrorReadCountStorage = 0
    private var deviceTimeReadCountStorage = 0
    private var nominalSampleRateReadCountStorage = 0
    private var stopCallCountStorage = 0
    private var freeBufferCallCountStorage = 0
    private var disposeCallCountStorage = 0
    private var createCallCountStorage = 0
    private var enqueueAfterDisposeCallCountStorage = 0
    private var translateDeviceReadCountStorage = 0
    private var translatedDeviceUIDsStorage: [String] = []
    private var currentDeviceReadCountStorage = 0
    private var operationTraceStorage: [String] = []
    private var latestQueue: AudioQueueRef =
        OpaquePointer(bitPattern: 0xB10C)!
    private var disposedQueues: Set<UInt> = []

    init(
        deviceUID: String =
            WorldwideVirtualMicrophoneEndpointContract
                .hiddenMirrorSinkDeviceUID,
        deviceID: AudioDeviceID = 89,
        translateDeviceStatuses: [OSStatus] = [],
        translatedDeviceIDSequence: [AudioDeviceID?] = [],
        createStatus: OSStatus = noErr,
        setDeviceStatus: OSStatus = noErr,
        currentDeviceStatus: OSStatus = noErr,
        currentDeviceUIDOverride: String? = nil,
        currentDeviceUIDSequence: [String] = [],
        allocateStatuses: [OSStatus] = [],
        enqueueStatuses: [OSStatus] = [],
        startStatus: OSStatus = noErr,
        streamDescriptionStatuses: [OSStatus] = [],
        streamDescriptionValues: [AudioStreamBasicDescription] = [
            BlackHoleMicrophoneOutputFormatPolicy
                .requiredStreamDescription,
        ],
        deviceSampleRateStatuses: [OSStatus] = [],
        deviceSampleRateValues: [Double] = [48_000],
        deviceChannelCountStatuses: [OSStatus] = [],
        deviceChannelCountValues: [UInt32] = [1],
        converterErrorReadStatuses: [OSStatus] = [],
        converterErrorValues: [UInt32] = [0],
        deviceTimeResults: [FakeBlackHoleDeviceTimeResult] = [],
        nominalSampleRateStatus: OSStatus = noErr,
        nominalSampleRateValue: Double = 48_000,
        stopStatus: OSStatus = noErr,
        disposeStatus: OSStatus = noErr,
        disposeStatuses: [OSStatus] = [],
        reportedBufferCapacities: [Int: UInt32] = [:],
        startQueueInterlock:
            BlackHoleAudioQueueStartInterlock? = nil
    ) {
        self.deviceUID = deviceUID
        self.deviceID = deviceID
        self.translateDeviceStatuses = translateDeviceStatuses
        self.translatedDeviceIDSequence =
            translatedDeviceIDSequence
        self.createStatus = createStatus
        self.setDeviceStatus = setDeviceStatus
        self.currentDeviceStatus = currentDeviceStatus
        self.currentDeviceUIDOverride = currentDeviceUIDOverride
        self.currentDeviceUIDSequence = currentDeviceUIDSequence
        self.allocateStatuses = allocateStatuses
        self.enqueueStatuses = enqueueStatuses
        self.startStatus = startStatus
        self.streamDescriptionStatuses =
            streamDescriptionStatuses
        self.streamDescriptionValues = streamDescriptionValues
        self.deviceSampleRateStatuses = deviceSampleRateStatuses
        self.deviceSampleRateValues = deviceSampleRateValues
        self.deviceChannelCountStatuses =
            deviceChannelCountStatuses
        self.deviceChannelCountValues = deviceChannelCountValues
        self.converterErrorReadStatuses =
            converterErrorReadStatuses
        self.converterErrorValues = converterErrorValues
        self.deviceTimeResults = deviceTimeResults
        self.nominalSampleRateStatus = nominalSampleRateStatus
        self.nominalSampleRateValue = nominalSampleRateValue
        self.stopStatus = stopStatus
        self.disposeStatus = disposeStatus
        self.disposeStatuses = disposeStatuses
        self.reportedBufferCapacities = reportedBufferCapacities
        self.startQueueInterlock = startQueueInterlock
    }

    deinit {
        lock.lock()
        let allocations = self.allocations
        lock.unlock()
        for allocation in allocations {
            allocation.freeIfNeeded()
        }
    }

    var selectedDeviceUIDs: [String] {
        withLock { selectedDeviceUIDsStorage }
    }

    var translatedDeviceUIDs: [String] {
        withLock { translatedDeviceUIDsStorage }
    }

    var allocateCallCount: Int {
        withLock { allocateCallCountStorage }
    }

    var enqueueCallCount: Int {
        withLock { enqueueCallCountStorage }
    }

    var startCallCount: Int {
        withLock { startCallCountStorage }
    }

    var requestedFormats: [AudioStreamBasicDescription] {
        withLock { requestedFormatsStorage }
    }

    var callbackContexts: [UnsafeMutableRawPointer] {
        withLock { callbackContextsStorage }
    }

    var streamDescriptionReadCount: Int {
        withLock { streamDescriptionReadCountStorage }
    }

    var deviceSampleRateReadCount: Int {
        withLock { deviceSampleRateReadCountStorage }
    }

    var deviceChannelCountReadCount: Int {
        withLock { deviceChannelCountReadCountStorage }
    }

    var converterErrorReadCount: Int {
        withLock { converterErrorReadCountStorage }
    }

    var deviceTimeReadCount: Int {
        withLock { deviceTimeReadCountStorage }
    }

    var nominalSampleRateReadCount: Int {
        withLock { nominalSampleRateReadCountStorage }
    }

    var operationTrace: [String] {
        withLock { operationTraceStorage }
    }

    var stopCallCount: Int {
        withLock { stopCallCountStorage }
    }

    var freeBufferCallCount: Int {
        withLock { freeBufferCallCountStorage }
    }

    var disposeCallCount: Int {
        withLock { disposeCallCountStorage }
    }

    var createCallCount: Int {
        withLock { createCallCountStorage }
    }

    var enqueueAfterDisposeCallCount: Int {
        withLock { enqueueAfterDisposeCallCountStorage }
    }

    var allocatedBuffers: [AudioQueueBufferRef] {
        withLock { allocations.map(\.buffer) }
    }

    var activeAllocationCount: Int {
        withLock {
            allocations.filter { !$0.isFreed }.count
        }
    }

    func createOutputQueue() -> (
        status: OSStatus,
        queue: AudioQueueRef?
    ) {
        withLock {
            createCallCountStorage += 1
            allocations.removeAll(where: { $0.isFreed })
            let identity = UInt(0xB10C + createCallCountStorage * 0x100)
            latestQueue = OpaquePointer(bitPattern: identity)!
            return (createStatus, latestQueue)
        }
    }

    func createOutputQueue(
        requestedFormat: AudioStreamBasicDescription
    ) -> (
        status: OSStatus,
        queue: AudioQueueRef?
    ) {
        withLock {
            requestedFormatsStorage.append(requestedFormat)
            createCallCountStorage += 1
            allocations.removeAll(where: { $0.isFreed })
            let identity = UInt(
                0xB10C + createCallCountStorage * 0x100
            )
            latestQueue = OpaquePointer(bitPattern: identity)!
            return (createStatus, latestQueue)
        }
    }

    func createOutputQueue(
        requestedFormat: AudioStreamBasicDescription,
        callbackContext: UnsafeMutableRawPointer
    ) -> (
        status: OSStatus,
        queue: AudioQueueRef?
    ) {
        withLock {
            requestedFormatsStorage.append(requestedFormat)
            callbackContextsStorage.append(callbackContext)
            createCallCountStorage += 1
            allocations.removeAll(where: { $0.isFreed })
            let identity = UInt(
                0xB10C + createCallCountStorage * 0x100
            )
            latestQueue = OpaquePointer(bitPattern: identity)!
            return (createStatus, latestQueue)
        }
    }

    func translateDeviceID(
        exactUID: String
    ) -> (status: OSStatus, deviceID: AudioDeviceID?) {
        withLock {
            translatedDeviceUIDsStorage.append(exactUID)
            let index = translateDeviceReadCountStorage
            translateDeviceReadCountStorage += 1
            let status = index < translateDeviceStatuses.count
                ? translateDeviceStatuses[index]
                : noErr
            guard status == noErr else {
                return (status, nil)
            }
            let translatedID = index
                < translatedDeviceIDSequence.count
                ? translatedDeviceIDSequence[index]
                : deviceID
            return (noErr, translatedID)
        }
    }

    func setCurrentDevice(
        _ uid: String,
        on _: AudioQueueRef
    ) -> OSStatus {
        withLock {
            selectedDeviceUIDsStorage.append(uid)
            return setDeviceStatus
        }
    }

    func currentDeviceUID(
        on _: AudioQueueRef
    ) -> (status: OSStatus, uid: String?) {
        withLock {
            guard currentDeviceStatus == noErr else {
                return (currentDeviceStatus, nil)
            }
            let sequenceUID: String?
            if currentDeviceUIDSequence.isEmpty {
                sequenceUID = nil
            } else {
                let index = min(
                    currentDeviceReadCountStorage,
                    currentDeviceUIDSequence.count - 1
                )
                sequenceUID = currentDeviceUIDSequence[index]
            }
            currentDeviceReadCountStorage += 1
            return (
                noErr,
                sequenceUID
                    ?? currentDeviceUIDOverride
                    ?? selectedDeviceUIDsStorage.last
                    ?? deviceUID
            )
        }
    }

    func allocateBuffer(
        on queue: AudioQueueRef,
        byteCount: UInt32
    ) -> (
        status: OSStatus,
        buffer: AudioQueueBufferRef?
    ) {
        withLock {
            let identity = Self.identity(queue)
            guard !disposedQueues.contains(identity) else {
                return (kAudio_ParamError, nil)
            }
            let index = allocateCallCountStorage
            allocateCallCountStorage += 1
            let status = index < allocateStatuses.count
                ? allocateStatuses[index]
                : noErr
            guard status == noErr else {
                return (status, nil)
            }

            let capacity = reportedBufferCapacities[index] ?? byteCount
            let allocation = FakeAudioQueueBufferAllocation(
                queueIdentity: identity,
                capacity: capacity
            )
            allocations.append(allocation)
            return (status, allocation.buffer)
        }
    }

    func enqueueBuffer(
        _ buffer: AudioQueueBufferRef,
        on queue: AudioQueueRef
    ) -> OSStatus {
        withLock {
            let identity = Self.identity(queue)
            guard !disposedQueues.contains(identity),
                  let allocation = allocations.first(where: {
                      $0.buffer == buffer
                          && $0.queueIdentity == identity
                  }),
                  !allocation.isFreed else {
                enqueueAfterDisposeCallCountStorage += 1
                return kAudio_ParamError
            }

            let index = enqueueCallCountStorage
            enqueueCallCountStorage += 1
            return index < enqueueStatuses.count
                ? enqueueStatuses[index]
                : noErr
        }
    }

    func startQueue(_ queue: AudioQueueRef) -> OSStatus {
        let status = withLock {
            guard !disposedQueues.contains(Self.identity(queue)) else {
                return kAudio_ParamError
            }
            startCallCountStorage += 1
            operationTraceStorage.append("start")
            return startStatus
        }
        startQueueInterlock?.pauseFirstStart()
        return status
    }

    func queueStreamDescription(
        on queue: AudioQueueRef
    ) -> (
        status: OSStatus,
        value: AudioStreamBasicDescription
    ) {
        withLock {
            guard !disposedQueues.contains(Self.identity(queue)) else {
                return (
                    kAudio_ParamError,
                    AudioStreamBasicDescription()
                )
            }
            let index = streamDescriptionReadCountStorage
            streamDescriptionReadCountStorage += 1
            let status = index < streamDescriptionStatuses.count
                ? streamDescriptionStatuses[index]
                : noErr
            guard !streamDescriptionValues.isEmpty else {
                return (kAudio_ParamError, AudioStreamBasicDescription())
            }
            let value = streamDescriptionValues[
                min(index, streamDescriptionValues.count - 1)
            ]
            return (status, value)
        }
    }

    func queueDeviceSampleRate(
        on queue: AudioQueueRef
    ) -> (status: OSStatus, value: Double) {
        withLock {
            guard !disposedQueues.contains(Self.identity(queue)) else {
                return (kAudio_ParamError, 0)
            }
            let index = deviceSampleRateReadCountStorage
            deviceSampleRateReadCountStorage += 1
            let status = index < deviceSampleRateStatuses.count
                ? deviceSampleRateStatuses[index]
                : noErr
            guard !deviceSampleRateValues.isEmpty else {
                return (kAudio_ParamError, 0)
            }
            let value = deviceSampleRateValues[
                min(index, deviceSampleRateValues.count - 1)
            ]
            return (status, value)
        }
    }

    func queueDeviceChannelCount(
        on queue: AudioQueueRef
    ) -> (status: OSStatus, value: UInt32) {
        withLock {
            guard !disposedQueues.contains(Self.identity(queue)) else {
                return (kAudio_ParamError, 0)
            }
            let index = deviceChannelCountReadCountStorage
            deviceChannelCountReadCountStorage += 1
            let status = index < deviceChannelCountStatuses.count
                ? deviceChannelCountStatuses[index]
                : noErr
            guard !deviceChannelCountValues.isEmpty else {
                return (kAudio_ParamError, 0)
            }
            let value = deviceChannelCountValues[
                min(index, deviceChannelCountValues.count - 1)
            ]
            return (status, value)
        }
    }

    func queueConverterError(
        on queue: AudioQueueRef
    ) -> (status: OSStatus, value: UInt32) {
        withLock {
            guard !disposedQueues.contains(Self.identity(queue)) else {
                return (kAudio_ParamError, 0)
            }
            let index = converterErrorReadCountStorage
            converterErrorReadCountStorage += 1
            let status = index < converterErrorReadStatuses.count
                ? converterErrorReadStatuses[index]
                : noErr
            guard !converterErrorValues.isEmpty else {
                return (kAudio_ParamError, 0)
            }
            let value = converterErrorValues[
                min(index, converterErrorValues.count - 1)
            ]
            return (status, value)
        }
    }

    func deviceCurrentTime(
        on queue: AudioQueueRef
    ) -> (status: OSStatus, timestamp: AudioTimeStamp) {
        withLock {
            guard !disposedQueues.contains(Self.identity(queue)) else {
                return (
                    kAudio_ParamError,
                    AudioTimeStamp()
                )
            }
            operationTraceStorage.append("device-current-time")
            let index = deviceTimeReadCountStorage
            deviceTimeReadCountStorage += 1
            if deviceTimeResults.isEmpty {
                let baseHostTime = AudioConvertNanosToHostTime(
                    1_000_000_000
                )
                let intervalHostTime = AudioConvertNanosToHostTime(
                    10_000_000
                )
                let result = FakeBlackHoleDeviceTimeResult.success(
                    sampleTime: Double(index * 480),
                    hostTime: baseHostTime
                        + UInt64(index) * intervalHostTime
                )
                return (result.status, result.timestamp)
            }
            let result = deviceTimeResults[
                min(index, deviceTimeResults.count - 1)
            ]
            return (result.status, result.timestamp)
        }
    }

    func nominalSampleRate(
        for deviceID: AudioDeviceID
    ) -> (status: OSStatus, value: Double) {
        withLock {
            guard deviceID == self.deviceID else {
                return (kAudio_ParamError, 0)
            }
            nominalSampleRateReadCountStorage += 1
            operationTraceStorage.append("nominal-sample-rate")
            return (
                nominalSampleRateStatus,
                nominalSampleRateValue
            )
        }
    }

    func stopQueue(
        _ queue: AudioQueueRef,
        immediate _: Bool
    ) -> OSStatus {
        withLock {
            guard !disposedQueues.contains(Self.identity(queue)) else {
                return kAudio_ParamError
            }
            stopCallCountStorage += 1
            return stopStatus
        }
    }

    func freeBuffer(
        _ buffer: AudioQueueBufferRef,
        from queue: AudioQueueRef
    ) -> OSStatus {
        withLock {
            let identity = Self.identity(queue)
            guard let allocation = allocations.first(where: {
                $0.buffer == buffer
                    && $0.queueIdentity == identity
            }), !allocation.isFreed else {
                return kAudio_ParamError
            }

            allocation.freeIfNeeded()
            freeBufferCallCountStorage += 1
            return noErr
        }
    }

    func disposeQueue(
        _ queue: AudioQueueRef,
        immediate _: Bool
    ) -> OSStatus {
        withLock {
            let identity = Self.identity(queue)
            guard !disposedQueues.contains(identity) else {
                preconditionFailure(
                    "AudioQueueDispose was called twice for terminal queue \(identity)"
                )
            }

            let index = disposeCallCountStorage
            disposeCallCountStorage += 1
            let status =
                index < disposeStatuses.count
                    ? disposeStatuses[index]
                    : disposeStatus
            disposedQueues.insert(identity)
            for allocation in allocations
                where allocation.queueIdentity == identity {
                allocation.freeIfNeeded()
            }
            return status
        }
    }

    private static func identity(
        _ queue: AudioQueueRef
    ) -> UInt {
        UInt(bitPattern: queue)
    }

    private func withLock<T>(
        _ body: () -> T
    ) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class BlackHoleAudioQueueStartInterlock:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let firstStartEntered = DispatchSemaphore(value: 0)
    private let firstStartRelease = DispatchSemaphore(value: 0)
    private var shouldPauseFirstStart = true

    func pauseFirstStart() {
        lock.lock()
        let shouldPause = shouldPauseFirstStart
        shouldPauseFirstStart = false
        lock.unlock()
        guard shouldPause else { return }
        firstStartEntered.signal()
        firstStartRelease.wait()
    }

    func waitUntilFirstStartEntered(
        timeout: DispatchTime
    ) -> DispatchTimeoutResult {
        firstStartEntered.wait(timeout: timeout)
    }

    func releaseFirstStart() {
        firstStartRelease.signal()
    }
}

private final class BlackHoleOutputStartOutcomeProbe:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var didSucceedStorage = false
    private var errorStorage: BlackHoleMicrophoneOutputError?

    var didSucceed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didSucceedStorage
    }

    var error: BlackHoleMicrophoneOutputError? {
        lock.lock()
        defer { lock.unlock() }
        return errorStorage
    }

    func recordSuccess() {
        lock.lock()
        didSucceedStorage = true
        lock.unlock()
    }

    func record(_ error: any Error) {
        lock.lock()
        errorStorage = error as? BlackHoleMicrophoneOutputError
        lock.unlock()
    }
}

private final class FakeAudioQueueBufferAllocation {
    let queueIdentity: UInt
    let buffer: AudioQueueBufferRef
    let data: UnsafeMutableRawPointer
    private(set) var isFreed = false

    init(queueIdentity: UInt, capacity: UInt32) {
        self.queueIdentity = queueIdentity
        data = UnsafeMutableRawPointer.allocate(
            byteCount: max(Int(capacity), 1),
            alignment: MemoryLayout<Int16>.alignment
        )
        buffer = AudioQueueBufferRef.allocate(capacity: 1)
        buffer.initialize(
            to: AudioQueueBuffer(
                mAudioDataBytesCapacity: capacity,
                mAudioData: data,
                mAudioDataByteSize: 0,
                mUserData: nil,
                mPacketDescriptionCapacity: 0,
                mPacketDescriptions: nil,
                mPacketDescriptionCount: 0
            )
        )
    }

    func freeIfNeeded() {
        guard !isFreed else { return }
        isFreed = true
        buffer.deinitialize(count: 1)
        buffer.deallocate()
        data.deallocate()
    }
}

private final class BlackHoleManualMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func read() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by delta: UInt64) {
        lock.lock()
        value &+= delta
        lock.unlock()
    }
}

private final class BlackHoleScriptedDecodedBinding:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let values: [(generation: UInt64, renderCallCount: UInt64)]
    private var index = 0

    init(
        _ values: [(generation: UInt64, renderCallCount: UInt64)]
    ) {
        precondition(!values.isEmpty)
        self.values = values
    }

    func read() -> (generation: UInt64, renderCallCount: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }
}

private final class BlackHoleRenderOutcomeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var succeeds: Bool

    init(succeeds: Bool) {
        self.succeeds = succeeds
    }

    func setSucceeds(_ succeeds: Bool) {
        lock.lock()
        self.succeeds = succeeds
        lock.unlock()
    }

    func render(
        samples _: UnsafeMutablePointer<Int16>,
        frameCount _: Int
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return succeeds
    }
}

private final class BlackHoleCallbackHoldProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldHoldNextRender = false
    private var renderCountStorage = 0
    let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return renderCountStorage
    }

    func holdNextRender() {
        lock.lock()
        shouldHoldNextRender = true
        lock.unlock()
    }

    func render(frameCount _: Int) -> Bool {
        lock.lock()
        renderCountStorage += 1
        let shouldHold = shouldHoldNextRender
        shouldHoldNextRender = false
        lock.unlock()

        if shouldHold {
            entered.signal()
            release.wait()
        }
        return false
    }

    func releaseHeldRender() {
        release.signal()
    }
}

private final class BlackHoleCallbackInvocationBox: @unchecked Sendable {
    let context: UnsafeMutableRawPointer
    let queue: AudioQueueRef
    let buffer: AudioQueueBufferRef

    init(
        context: UnsafeMutableRawPointer,
        queue: AudioQueueRef,
        buffer: AudioQueueBufferRef
    ) {
        self.context = context
        self.queue = queue
        self.buffer = buffer
    }
}

private final class BlackHoleOutputReleaseBox: @unchecked Sendable {
    var output: BlackHoleMicrophoneOutput?

    init(_ output: BlackHoleMicrophoneOutput) {
        self.output = output
    }
}

private final class BlackHoleWeakOutputBox: @unchecked Sendable {
    weak var output: BlackHoleMicrophoneOutput?

    init(_ output: BlackHoleMicrophoneOutput) {
        self.output = output
    }
}

private final class BlackHoleDeinitProbe: @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)

    func record() {
        completed.signal()
    }
}

private final class BlackHoleCallbackContextDeinitProbe:
    @unchecked Sendable
{
    let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var countStorage = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return countStorage
    }

    func record() {
        lock.lock()
        countStorage += 1
        lock.unlock()
        completed.signal()
    }
}


private final class BlackHoleRenderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var frameCounts: [Int] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frameCounts.count
    }

    func record(frameCount: Int) {
        lock.lock()
        frameCounts.append(frameCount)
        lock.unlock()
    }
}

private final class BlackHoleRuntimeFailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var errorsStorage: [BlackHoleMicrophoneOutputError] = []
    private var gateWasOpenStorage: [Bool] = []
    private var pcmAdmissionWasOpenStorage: [Bool] = []
    private var writerGateReopenSucceededStorage: [Bool] = []

    var errors: [BlackHoleMicrophoneOutputError] {
        lock.lock()
        defer { lock.unlock() }
        return errorsStorage
    }

    var gateWasOpen: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return gateWasOpenStorage
    }

    var pcmAdmissionWasOpen: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return pcmAdmissionWasOpenStorage
    }

    var writerGateReopenSucceeded: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return writerGateReopenSucceededStorage
    }

    func record(
        _ error: BlackHoleMicrophoneOutputError,
        gateIsOpen: Bool? = nil,
        pcmAdmissionIsOpen: Bool? = nil,
        writerGateReopenSucceeded: Bool? = nil
    ) {
        lock.lock()
        errorsStorage.append(error)
        if let gateIsOpen {
            gateWasOpenStorage.append(gateIsOpen)
        }
        if let pcmAdmissionIsOpen {
            pcmAdmissionWasOpenStorage.append(
                pcmAdmissionIsOpen
            )
        }
        if let writerGateReopenSucceeded {
            writerGateReopenSucceededStorage.append(
                writerGateReopenSucceeded
            )
        }
        lock.unlock()
    }
}
#endif
