import AVFAudio
import AudioToolbox
import RemoteSessionCore
import XCTest
@testable import WebRTCTransport

/// Verifies the native WebRTC audio-device contract and recovery authorization boundary.
/// Cumulative diagnostics, RemoteIO topology, 48 kHz stereo playback configuration, and
/// synchronous authorization revocation form the oracles for rejecting call-style audio paths.
@MainActor
final class WebRTCAudioPlaybackSessionTests: XCTestCase {
    func testRecoveryAuthorizationRejectsSideEffectsAfterRevocation() {
        let authorization = WebRTCIOSPlayoutRecoveryAuthorization()
        let counter = LockedInteger()

        authorization.revoke()

        XCTAssertFalse(
            authorization.performIfValidForTesting {
                counter.increment()
            }
        )
        XCTAssertEqual(counter.value, 0)
        XCTAssertFalse(authorization.isValid)
    }

    func testMicrophoneAuthorizationRejectsSideEffectsAfterRevocation() {
        let authorization = WebRTCIOSMicrophoneAuthorization()
        let counter = LockedInteger()

        authorization.revoke()

        XCTAssertFalse(
            authorization.performIfValidForTesting {
                counter.increment()
            }
        )
        XCTAssertEqual(counter.value, 0)
    }

    func testMicrophoneRealtimeGateRevocationDrainsExactAdmission() {
        let authorization = WebRTCIOSMicrophoneAuthorization()
        let revokeFinished = DispatchSemaphore(value: 0)

        XCTAssertTrue(authorization.debugBeginRealtimeAdmissionForTesting())
        DispatchQueue.global(qos: .userInitiated).async {
            authorization.revoke()
            revokeFinished.signal()
        }

        authorization.waitForRealtimeGateClosureForTesting()
        XCTAssertEqual(revokeFinished.wait(timeout: .now()), .timedOut)

        authorization.debugEndRealtimeAdmissionForTesting()
        XCTAssertEqual(revokeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(authorization.isValid)
    }

    func testMicrophoneRealtimeGateRejectsAdmissionAfterRevokeReturns() {
        let authorization = WebRTCIOSMicrophoneAuthorization()

        authorization.revoke()

        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(authorization.debugBeginRealtimeAdmissionForTesting())
    }

    func testDeviceRealtimeGateClosureDrainsExactAdmissionBeforeReset() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        let closeFinished = DispatchSemaphore(value: 0)
        defer { _ = harness.debugTerminateForTesting() }

        harness.debugInstallMicrophoneAuthorizationForTesting(authorization)
        XCTAssertTrue(harness.debugPublishCurrentMicrophoneAuthorizationForTesting())
        XCTAssertTrue(harness.debugBeginRealtimeAdmissionForTesting())

        DispatchQueue.global(qos: .userInitiated).async {
            harness.debugCloseAndFenceRealtimeGateForTesting()
            closeFinished.signal()
        }

        harness.waitForRealtimeGateClosureForTesting()
        XCTAssertEqual(closeFinished.wait(timeout: .now()), .timedOut)
        XCTAssertTrue(authorization.isValid)

        harness.debugEndRealtimeAdmissionForTesting()
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())
    }

    func testInvalidMicrophoneAuthorizationCannotOpenDeviceGate() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        defer { _ = harness.debugTerminateForTesting() }

        authorization.revoke()
        harness.debugInstallMicrophoneAuthorizationForTesting(authorization)

        XCTAssertFalse(harness.debugPublishCurrentMicrophoneAuthorizationForTesting())
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())
    }

    func testReplacingAuthorizationPreservesExactAdmittedGateIdentity() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let first = WebRTCIOSMicrophoneAuthorization()
        let second = WebRTCIOSMicrophoneAuthorization()
        let replacementFinished = DispatchSemaphore(value: 0)
        defer { _ = harness.debugTerminateForTesting() }

        harness.debugInstallMicrophoneAuthorizationForTesting(first)
        XCTAssertTrue(harness.debugPublishCurrentMicrophoneAuthorizationForTesting())
        XCTAssertTrue(harness.debugBeginRealtimeAdmissionForTesting())

        DispatchQueue.global(qos: .userInitiated).async {
            harness.debugInstallMicrophoneAuthorizationForTesting(second)
            replacementFinished.signal()
        }

        harness.waitForRealtimeGateClosureForTesting()
        XCTAssertEqual(replacementFinished.wait(timeout: .now()), .timedOut)
        XCTAssertTrue(first.isValid)
        XCTAssertTrue(second.isValid)

        harness.debugEndRealtimeAdmissionForTesting()
        XCTAssertEqual(replacementFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(first.isValid)
        XCTAssertTrue(second.isValid)

        XCTAssertTrue(harness.debugPublishCurrentMicrophoneAuthorizationForTesting())
        XCTAssertTrue(harness.debugBeginRealtimeAdmissionForTesting())
        harness.debugEndRealtimeAdmissionForTesting()
    }

    func testTerminalDebugTeardownFencesAdmissionThenRevokesAuthorization() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        let terminateFinished = DispatchSemaphore(value: 0)

        harness.debugInstallMicrophoneAuthorizationForTesting(authorization)
        XCTAssertTrue(harness.debugPublishCurrentMicrophoneAuthorizationForTesting())
        XCTAssertTrue(harness.debugBeginRealtimeAdmissionForTesting())

        DispatchQueue.global(qos: .userInitiated).async {
            _ = harness.debugTerminateForTesting()
            terminateFinished.signal()
        }

        harness.waitForRealtimeGateClosureForTesting()
        XCTAssertEqual(terminateFinished.wait(timeout: .now()), .timedOut)
        XCTAssertTrue(authorization.isValid)

        harness.debugEndRealtimeAdmissionForTesting()
        XCTAssertEqual(terminateFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(harness.debugPublishCurrentMicrophoneAuthorizationForTesting())
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())
        XCTAssertTrue(harness.debugTerminateForTesting())
    }

    func testDevicePublicationStartsClosedAndOpensOnlyCurrentAuthorization() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let first = WebRTCIOSMicrophoneAuthorization()
        let second = WebRTCIOSMicrophoneAuthorization()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())

        harness.debugInstallMicrophoneAuthorizationForTesting(first)
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())
        XCTAssertTrue(harness.debugPublishCurrentMicrophoneAuthorizationForTesting())
        XCTAssertTrue(harness.debugBeginRealtimeAdmissionForTesting())
        harness.debugEndRealtimeAdmissionForTesting()

        harness.debugInstallMicrophoneAuthorizationForTesting(second)
        XCTAssertFalse(first.isValid)
        XCTAssertTrue(second.isValid)
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())

        XCTAssertTrue(harness.debugPublishCurrentMicrophoneAuthorizationForTesting())
        XCTAssertTrue(harness.debugBeginRealtimeAdmissionForTesting())
        harness.debugEndRealtimeAdmissionForTesting()
    }

    func testRecoveryAuthorizationRevocationWaitsForAuthorizedNativeBoundary() {
        let authorization = WebRTCIOSPlayoutRecoveryAuthorization()
        let operationStarted = DispatchSemaphore(value: 0)
        let allowOperationToFinish = DispatchSemaphore(value: 0)
        let operationFinished = DispatchSemaphore(value: 0)
        let revokeStarted = DispatchSemaphore(value: 0)
        let revokeFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            authorization.performIfValidForTesting {
                operationStarted.signal()
                _ = allowOperationToFinish.wait(timeout: .now() + 2)
            }
            operationFinished.signal()
        }
        XCTAssertEqual(operationStarted.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            revokeStarted.signal()
            authorization.revoke()
            revokeFinished.signal()
        }
        XCTAssertEqual(revokeStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            revokeFinished.wait(timeout: .now() + 0.25),
            .timedOut,
            "Synchronous revocation must wait for an authorized native operation to linearize."
        )

        allowOperationToFinish.signal()
        XCTAssertEqual(operationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(revokeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(authorization.isValid)
    }

    func testQueuedNativeRecoveryRejectsRevokedAttemptBeforeRebuild() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let retiredAuthorization = WebRTCIOSPlayoutRecoveryAuthorization()

        harness.queueRecovery(authorization: retiredAuthorization)
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertEqual(harness.diagnostics.requestCount, 1)
        XCTAssertEqual(harness.diagnostics.rebuildCount, 0)

        retiredAuthorization.revoke()
        XCTAssertTrue(harness.runNextQueuedOperation())

        let rejected = harness.diagnostics
        XCTAssertEqual(rejected.requestCount, 1)
        XCTAssertEqual(rejected.authorizationRejectionCount, 1)
        XCTAssertEqual(rejected.rebuildCount, 0)
        XCTAssertFalse(rejected.sessionActive)
        XCTAssertFalse(rejected.remoteIOCreated)

        let currentAuthorization = WebRTCIOSPlayoutRecoveryAuthorization()
        harness.queueRecovery(authorization: currentAuthorization)
        XCTAssertTrue(harness.runNextQueuedOperation())

        let accepted = harness.diagnostics
        XCTAssertEqual(accepted.requestCount, 2)
        XCTAssertEqual(accepted.authorizationRejectionCount, 1)
        XCTAssertEqual(accepted.rebuildCount, 1)
        XCTAssertFalse(accepted.sessionActive)
        XCTAssertFalse(accepted.remoteIOCreated)
    }

    func testNativeCountersRemainCumulativeAndCallbackPublishesLast() {
        let harness = WebRTCIOSPlayoutPublicationTestHarness()

        harness.publishCallback(frameCount: 480, status: noErr)
        let firstPrePublication = harness.prePublicationSnapshot
        XCTAssertEqual(firstPrePublication.callbackCount, 0)
        XCTAssertEqual(firstPrePublication.frameCount, 480)
        XCTAssertEqual(firstPrePublication.failureCount, 0)
        XCTAssertEqual(firstPrePublication.lastFrameCount, 480)
        XCTAssertEqual(firstPrePublication.lastStatus, noErr)

        let firstPublished = harness.snapshot
        XCTAssertEqual(firstPublished.callbackCount, 1)
        XCTAssertEqual(firstPublished.frameCount, 480)
        XCTAssertEqual(firstPublished.failureCount, 0)

        harness.markRecoveryBoundary()
        harness.publishCallback(frameCount: 240, status: -50)
        let secondPrePublication = harness.prePublicationSnapshot
        XCTAssertEqual(secondPrePublication.callbackCount, 1)
        XCTAssertEqual(secondPrePublication.frameCount, 720)
        XCTAssertEqual(secondPrePublication.failureCount, 1)
        XCTAssertEqual(secondPrePublication.lastFrameCount, 240)
        XCTAssertEqual(secondPrePublication.lastStatus, -50)

        let secondPublished = harness.snapshot
        XCTAssertEqual(secondPublished.callbackCount, 2)
        XCTAssertEqual(secondPublished.frameCount, 720)
        XCTAssertEqual(secondPublished.failureCount, 1)
    }

    func testProductionPCMAnalyzerDistinguishesStereoContentSilenceAndClipping() {
        let harness = WebRTCIOSPlayoutPublicationTestHarness()
        let stereo: [Int16] = [
            1_000, -2_000,
            .max, .min,
            300, 300,
            -400, 500,
        ]

        harness.analyzePCM16(samples: stereo)
        let content = harness.snapshot
        XCTAssertEqual(content.pcmSampleCount, 8)
        XCTAssertEqual(content.pcmNonzeroSampleCount, 8)
        XCTAssertEqual(content.pcmAbsoluteSampleSum, 70_035)
        XCTAssertEqual(content.pcmLeftAbsoluteSampleSum, 34_467)
        XCTAssertEqual(content.pcmRightAbsoluteSampleSum, 35_568)
        XCTAssertEqual(content.pcmStereoDifferenceAbsoluteSampleSum, 69_435)
        XCTAssertEqual(content.pcmClippedSampleCount, 2)
        XCTAssertEqual(content.explicitSilenceCallbackCount, 0)
        XCTAssertEqual(content.nearSilenceCallbackCount, 0)
        XCTAssertEqual(content.currentConsecutiveNearSilenceFrameCount, 0)
        XCTAssertEqual(content.maximumConsecutiveNearSilenceFrameCount, 0)
        XCTAssertEqual(content.pcmLeftZeroCrossingCount, 1)
        XCTAssertEqual(content.pcmRightZeroCrossingCount, 1)
        XCTAssertEqual(content.pcmEnvelopeTransitionCount, 0)
        XCTAssertEqual(content.lastCallbackMeanMagnitude, 8_754)
        XCTAssertEqual(content.lastPeakMagnitude, 32_768)

        harness.analyzePCM16(
            samples: [Int16](repeating: 0, count: 8),
            outputIsSilence: true
        )
        let silence = harness.snapshot
        XCTAssertEqual(silence.pcmSampleCount, 16)
        XCTAssertEqual(silence.pcmNonzeroSampleCount, 8)
        XCTAssertEqual(silence.pcmAbsoluteSampleSum, 70_035)
        XCTAssertEqual(silence.pcmLeftAbsoluteSampleSum, 34_467)
        XCTAssertEqual(silence.pcmRightAbsoluteSampleSum, 35_568)
        XCTAssertEqual(silence.pcmStereoDifferenceAbsoluteSampleSum, 69_435)
        XCTAssertEqual(silence.pcmClippedSampleCount, 2)
        XCTAssertEqual(silence.explicitSilenceCallbackCount, 1)
        XCTAssertEqual(silence.nearSilenceCallbackCount, 1)
        XCTAssertEqual(silence.currentConsecutiveNearSilenceFrameCount, 4)
        XCTAssertEqual(silence.maximumConsecutiveNearSilenceFrameCount, 4)
        XCTAssertEqual(silence.pcmLeftZeroCrossingCount, 1)
        XCTAssertEqual(silence.pcmRightZeroCrossingCount, 1)
        XCTAssertEqual(silence.pcmEnvelopeTransitionCount, 0)
        XCTAssertEqual(silence.lastCallbackMeanMagnitude, 0)
        XCTAssertEqual(silence.lastPeakMagnitude, 0)
    }

    func testProductionPCMAnalyzerTracksAndResetsConsecutiveNearSilence() {
        let harness = WebRTCIOSPlayoutPublicationTestHarness()

        harness.analyzePCM16(samples: [Int16](repeating: 0, count: 960))
        var snapshot = harness.snapshot
        XCTAssertEqual(snapshot.nearSilenceCallbackCount, 1)
        XCTAssertEqual(snapshot.currentConsecutiveNearSilenceFrameCount, 480)
        XCTAssertEqual(snapshot.maximumConsecutiveNearSilenceFrameCount, 480)

        // Fully nonzero dither is still near-silence because its mean magnitude is below 256.
        harness.analyzePCM16(samples: [Int16](repeating: 1, count: 480))
        snapshot = harness.snapshot
        XCTAssertEqual(snapshot.nearSilenceCallbackCount, 2)
        XCTAssertEqual(snapshot.currentConsecutiveNearSilenceFrameCount, 720)
        XCTAssertEqual(snapshot.maximumConsecutiveNearSilenceFrameCount, 720)

        // The deterministic physical tone is comfortably above both density and mean gates.
        harness.analyzePCM16(samples: [Int16](repeating: 2_000, count: 960))
        snapshot = harness.snapshot
        XCTAssertEqual(snapshot.nearSilenceCallbackCount, 2)
        XCTAssertEqual(snapshot.currentConsecutiveNearSilenceFrameCount, 0)
        XCTAssertEqual(snapshot.maximumConsecutiveNearSilenceFrameCount, 720)

        // Two loud impulses put mean magnitude above 256 but cannot pass the independent 90%
        // nonzero-density gate.
        var sparseImpulse = [Int16](repeating: 0, count: 240)
        sparseImpulse[0] = .max
        sparseImpulse[1] = .max
        harness.analyzePCM16(samples: sparseImpulse)
        snapshot = harness.snapshot
        XCTAssertEqual(snapshot.nearSilenceCallbackCount, 3)
        XCTAssertEqual(snapshot.currentConsecutiveNearSilenceFrameCount, 120)
        XCTAssertEqual(snapshot.maximumConsecutiveNearSilenceFrameCount, 720)

        harness.analyzePCM16(samples: [Int16](repeating: 2_000, count: 240))
        harness.analyzePCM16(
            samples: [Int16](repeating: 0, count: 240),
            outputIsSilence: true
        )
        snapshot = harness.snapshot
        XCTAssertEqual(snapshot.nearSilenceCallbackCount, 4)
        XCTAssertEqual(snapshot.currentConsecutiveNearSilenceFrameCount, 120)
        XCTAssertEqual(snapshot.maximumConsecutiveNearSilenceFrameCount, 720)
    }

    func testProductionPCMAnalyzerEnforcesExactDensityAndMeanMagnitudeBoundaries() {
        let densityHarness = WebRTCIOSPlayoutPublicationTestHarness()
        let exactlyNinetyPercentNonzero =
            [Int16](repeating: 1_000, count: 180) + [Int16](repeating: 0, count: 20)
        densityHarness.analyzePCM16(samples: exactlyNinetyPercentNonzero)
        XCTAssertEqual(densityHarness.snapshot.nearSilenceCallbackCount, 0)

        let eightyNinePercentNonzero =
            [Int16](repeating: 1_000, count: 178) + [Int16](repeating: 0, count: 22)
        densityHarness.analyzePCM16(samples: eightyNinePercentNonzero)
        XCTAssertEqual(densityHarness.snapshot.nearSilenceCallbackCount, 1)

        let magnitudeHarness = WebRTCIOSPlayoutPublicationTestHarness()
        magnitudeHarness.analyzePCM16(samples: [Int16](repeating: 256, count: 200))
        XCTAssertEqual(magnitudeHarness.snapshot.nearSilenceCallbackCount, 0)
        magnitudeHarness.analyzePCM16(samples: [Int16](repeating: 255, count: 200))
        XCTAssertEqual(magnitudeHarness.snapshot.nearSilenceCallbackCount, 1)
    }

    func testProductionPCMAnalyzerIdentifiesIndependent997And1499HertzToneChannels() {
        let harness = WebRTCIOSPlayoutPublicationTestHarness()
        let sampleRate = 48_000.0
        let frameCount = 4_800
        var interleaved = [Int16]()
        interleaved.reserveCapacity(frameCount * 2)
        for frame in 0..<frameCount {
            let time = Double(frame) / sampleRate
            interleaved.append(
                Int16((sin(2 * .pi * 997 * time) * 8_000).rounded())
            )
            interleaved.append(
                Int16((sin(2 * .pi * 1_499 * time) * 8_000).rounded())
            )
        }

        harness.analyzePCM16(samples: interleaved)
        var snapshot = harness.snapshot
        XCTAssertEqual(snapshot.pcmLeftZeroCrossingCount, 199)
        XCTAssertEqual(snapshot.pcmRightZeroCrossingCount, 299)
        XCTAssertEqual(snapshot.nearSilenceCallbackCount, 0)

        // Both generated tones end negative. A positive frame proves signs persist across the
        // callback boundary rather than each buffer being counted independently.
        harness.analyzePCM16(samples: [100, 100])
        snapshot = harness.snapshot
        XCTAssertEqual(snapshot.pcmLeftZeroCrossingCount, 200)
        XCTAssertEqual(snapshot.pcmRightZeroCrossingCount, 300)
    }

    func testProductionPCMAnalyzerDetectsCodedBandTransitionsAndRapidGainFlicker() {
        let coded = WebRTCIOSPlayoutPublicationTestHarness()
        let sampleRate = 48_000.0
        let framesPerCallback = 480
        let callbackCount = 200
        for callback in 0..<callbackCount {
            let highBand = (callback / 50).isMultiple(of: 2) == false
            let amplitude = highBand ? 3_000.0 : 9_000.0
            let leftFrequency = highBand ? 8_003.0 : 997.0
            let rightFrequency = highBand ? 11_003.0 : 1_499.0
            var interleaved = [Int16]()
            interleaved.reserveCapacity(framesPerCallback * 2)
            for localFrame in 0..<framesPerCallback {
                let frame = callback * framesPerCallback + localFrame
                let time = Double(frame) / sampleRate
                interleaved.append(
                    Int16((sin(2 * .pi * leftFrequency * time) * amplitude).rounded())
                )
                interleaved.append(
                    Int16((sin(2 * .pi * rightFrequency * time) * amplitude).rounded())
                )
            }
            coded.analyzePCM16(samples: interleaved)
        }
        let codedSnapshot = coded.snapshot
        XCTAssertEqual(codedSnapshot.nearSilenceCallbackCount, 0)
        XCTAssertEqual(codedSnapshot.pcmEnvelopeTransitionCount, 3)
        XCTAssertEqual(codedSnapshot.pcmShapeAnomalyCallbackCount, 0)
        XCTAssertEqual(
            codedSnapshot.pcmBoundaryDiscontinuityCallbackCount,
            0,
            "The intentional 500 ms level/frequency transitions must not look like phase resets."
        )
        XCTAssertEqual(codedSnapshot.pcmLeftZeroCrossingCount, 17_999, accuracy: 2)
        XCTAssertEqual(codedSnapshot.pcmRightZeroCrossingCount, 25_003, accuracy: 2)

        let flicker = WebRTCIOSPlayoutPublicationTestHarness()
        for callback in 0..<20 {
            let magnitude: Int16 = callback.isMultiple(of: 2) ? 8_000 : 1_000
            flicker.analyzePCM16(samples: [Int16](repeating: magnitude, count: 960))
        }
        XCTAssertEqual(
            flicker.snapshot.pcmEnvelopeTransitionCount,
            19,
            "Every alternating 10 ms gain step must be machine-visible."
        )

        let boundary = WebRTCIOSPlayoutPublicationTestHarness()
        boundary.analyzePCM16(samples: [Int16](repeating: 2_000, count: 960))
        boundary.analyzePCM16(samples: [Int16](repeating: 2_800, count: 960))
        XCTAssertEqual(
            boundary.snapshot.pcmEnvelopeTransitionCount,
            0,
            "The exact 40% tolerance boundary is not a violation."
        )
        boundary.analyzePCM16(samples: [Int16](repeating: 2_801, count: 960))
        XCTAssertEqual(boundary.snapshot.pcmEnvelopeTransitionCount, 0)
        boundary.analyzePCM16(samples: [Int16](repeating: 1_999, count: 960))
        XCTAssertEqual(boundary.snapshot.pcmEnvelopeTransitionCount, 1)
    }

    func testProductionPCMAnalyzerAcceptsContinuousToneAcrossCallbackBoundaries() {
        let harness = WebRTCIOSPlayoutPublicationTestHarness()
        let framesPerCallback = 480

        for callback in 0..<100 {
            harness.analyzePCM16(
                samples: Self.stereoChallengeTone(
                    frames: (callback * framesPerCallback)..<((callback + 1) * framesPerCallback)
                )
            )
        }

        let snapshot = harness.snapshot
        XCTAssertEqual(snapshot.pcmShapeAnomalyCallbackCount, 0)
        XCTAssertEqual(snapshot.pcmBoundaryDiscontinuityCallbackCount, 0)
    }

    func testProductionPCMAnalyzerCountsRepeatedPhaseResetBlocksCumulatively() {
        let harness = WebRTCIOSPlayoutPublicationTestHarness()
        let resetBlock = Self.stereoChallengeTone(frames: 0..<480)

        for _ in 0..<20 {
            harness.analyzePCM16(samples: resetBlock)
        }

        var snapshot = harness.snapshot
        XCTAssertEqual(snapshot.pcmShapeAnomalyCallbackCount, 0)
        XCTAssertEqual(
            snapshot.pcmBoundaryDiscontinuityCallbackCount,
            19,
            "Each 10 ms phase reset after the first callback must remain machine-visible."
        )

        // This block is phase-continuous with the immediately preceding reset block. It proves a
        // final healthy callback cannot clear the lifetime-cumulative evidence already observed.
        harness.analyzePCM16(samples: Self.stereoChallengeTone(frames: 480..<960))
        snapshot = harness.snapshot
        XCTAssertEqual(snapshot.pcmShapeAnomalyCallbackCount, 0)
        XCTAssertEqual(snapshot.pcmBoundaryDiscontinuityCallbackCount, 19)
    }

    func testProductionPCMAnalyzerCountsShapeMutantsCumulatively() {
        let harness = WebRTCIOSPlayoutPublicationTestHarness()

        let flat = [Int16](repeating: 2_000, count: 960)
        harness.analyzePCM16(samples: flat)
        XCTAssertEqual(harness.snapshot.pcmShapeAnomalyCallbackCount, 1)

        var square = [Int16]()
        square.reserveCapacity(960)
        for frame in 0..<480 {
            let sample: Int16 = frame.isMultiple(of: 2) ? 8_000 : -8_000
            square.append(sample)
            square.append(sample)
        }
        harness.analyzePCM16(samples: square)
        XCTAssertEqual(harness.snapshot.pcmShapeAnomalyCallbackCount, 2)

        var impulse = [Int16](repeating: 0, count: 960)
        impulse[240] = .max
        impulse[241] = .min
        harness.analyzePCM16(samples: impulse)
        XCTAssertEqual(harness.snapshot.pcmShapeAnomalyCallbackCount, 3)

        harness.analyzePCM16(samples: Self.stereoChallengeTone(frames: 0..<480))
        let finalSnapshot = harness.snapshot
        XCTAssertEqual(
            finalSnapshot.pcmShapeAnomalyCallbackCount,
            3,
            "A final clean callback must not erase prior flat, square, or impulse evidence."
        )
    }

    func testProductionSuccessfulCallbackTimingDetectsOnlyGapsBeyond25Milliseconds() {
        let harness = WebRTCIOSPlayoutPublicationTestHarness()

        harness.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 1_000_000_000)
        harness.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 1_010_000_000)
        harness.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 1_035_000_000)
        var snapshot = harness.snapshot
        XCTAssertEqual(snapshot.callbackGapViolationCount, 0)
        XCTAssertEqual(snapshot.maximumCallbackGapNanoseconds, 25_000_000)

        harness.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 1_060_000_001)
        snapshot = harness.snapshot
        XCTAssertEqual(snapshot.callbackGapViolationCount, 1)
        XCTAssertEqual(snapshot.maximumCallbackGapNanoseconds, 25_000_001)

        // A regressed clock reading is ignored and cannot lower the cadence baseline.
        harness.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 1_050_000_000)
        harness.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 1_070_000_001)
        snapshot = harness.snapshot
        XCTAssertEqual(snapshot.callbackGapViolationCount, 1)
        XCTAssertEqual(snapshot.maximumCallbackGapNanoseconds, 25_000_001)

        let recurring = WebRTCIOSPlayoutPublicationTestHarness()
        recurring.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 2_000_000_000)
        recurring.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 2_020_000_000)
        recurring.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 2_050_000_000)
        recurring.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 2_090_000_000)
        XCTAssertEqual(
            recurring.snapshot.callbackGapViolationCount,
            2,
            "Recurring 30 ms and 40 ms disruptions must both be counted; 20 ms remains tolerated."
        )
        XCTAssertEqual(recurring.snapshot.maximumCallbackGapNanoseconds, 40_000_000)
    }

    func testProductionRecoveryPreservesNativeLifetimeCounters() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        harness.publishCallback(frameCount: 480, status: noErr)
        harness.publishCallback(frameCount: 240, status: -50)

        let beforeRecovery = harness.diagnostics
        XCTAssertEqual(beforeRecovery.playoutCallbackCount, 2)
        XCTAssertEqual(beforeRecovery.playoutFrameCount, 720)
        XCTAssertEqual(beforeRecovery.playoutFailureCount, 1)
        XCTAssertEqual(beforeRecovery.lastPlayoutFrameCount, 240)
        XCTAssertEqual(beforeRecovery.lastPlayoutStatus, -50)

        let authorization = WebRTCIOSPlayoutRecoveryAuthorization()
        harness.queueRecovery(authorization: authorization)
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertTrue(harness.runNextQueuedOperation())
        XCTAssertFalse(authorization.isValid)

        let afterRecovery = harness.diagnostics
        XCTAssertEqual(afterRecovery.rebuildCount, 1)
        XCTAssertEqual(afterRecovery.playoutCallbackCount, 2)
        XCTAssertEqual(afterRecovery.playoutFrameCount, 720)
        XCTAssertEqual(afterRecovery.playoutFailureCount, 1)
        XCTAssertEqual(afterRecovery.lastPlayoutFrameCount, 240)
        XCTAssertEqual(afterRecovery.lastPlayoutStatus, -50)
    }

    func testActivationOpensOnlyTheManualWebRTCGate() throws {
        let native = WebRTCAudioSessionStub()
        let playback = WebRTCAudioPlaybackSession(session: native)

        try playback.activate()
        try playback.recover()

        XCTAssertTrue(native.isAudioEnabled)
        XCTAssertEqual(native.prepareCount, 2)
        XCTAssertTrue(native.configuredModes.isEmpty)
        XCTAssertTrue(native.setActiveValues.isEmpty)
        XCTAssertEqual(native.lockCount, 0)
        XCTAssertEqual(native.unlockCount, 0)
    }

    func testManualDisabledPreparationNeverActivatesOrConfiguresAudioSession() {
        let native = WebRTCAudioSessionStub()
        native.isAudioEnabled = true
        let playback = WebRTCAudioPlaybackSession(session: native)

        playback.prepareManualAudioDisabled()

        XCTAssertFalse(native.isAudioEnabled)
        XCTAssertEqual(native.prepareCount, 1)
        XCTAssertTrue(native.configuredModes.isEmpty)
        XCTAssertTrue(native.setActiveValues.isEmpty)
        XCTAssertEqual(native.lockCount, 0)
        XCTAssertEqual(native.unlockCount, 0)
    }

    func testDeactivationClosesTheGateWithoutCompetingForAVAudioSessionOwnership() throws {
        let native = WebRTCAudioSessionStub()
        let playback = WebRTCAudioPlaybackSession(session: native)

        try playback.activate()
        playback.deactivate()
        playback.deactivate()

        XCTAssertFalse(native.isAudioEnabled)
        XCTAssertTrue(native.configuredModes.isEmpty)
        XCTAssertTrue(native.setActiveValues.isEmpty)
    }

    func testDeclaredMediaConfigurationMatchesCustomDeviceContract() {
        let configuration = WebRTCAudioPlaybackSession.playbackConfiguration()

        XCTAssertEqual(configuration.category, AVAudioSession.Category.playback.rawValue)
        XCTAssertEqual(configuration.mode, AVAudioSession.Mode.default.rawValue)
        XCTAssertEqual(configuration.categoryOptions, [])
        XCTAssertFalse(configuration.categoryOptions.contains(.mixWithOthers))
        XCTAssertEqual(configuration.sampleRate, 48_000)
        XCTAssertEqual(configuration.ioBufferDuration, 0.010)
        XCTAssertEqual(configuration.outputNumberOfChannels, 2)
    }

    func testViewerBeginsWithNoMicrophoneOrAudioSessionLease() async throws {
        let viewer = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [])
        )

        let initialDiagnostics = await viewer.iOSPlayoutDiagnostics()
        let value = try XCTUnwrap(initialDiagnostics)
        XCTAssertFalse(value.playing)
        XCTAssertFalse(value.sessionActive)
        XCTAssertFalse(value.ownsSessionActivation)
        XCTAssertFalse(value.remoteIOCreated)
        XCTAssertFalse(value.inputBusEnabled)
        XCTAssertFalse(value.outputBusEnabled)
        XCTAssertFalse(value.recoveryRequired)
        XCTAssertFalse(value.explicitResumeRequired)
        XCTAssertEqual(value.failureCode, 0)
        XCTAssertEqual(value.lastLifecycleStatus, noErr)
        XCTAssertNil(value.failureMessage)
        XCTAssertEqual(value.playoutCallbackGapViolationCount, 0)
        XCTAssertEqual(value.playoutMaximumCallbackGapNanoseconds, 0)
        XCTAssertEqual(value.playoutNearSilenceCallbackCount, 0)
        XCTAssertEqual(value.playoutCurrentConsecutiveNearSilenceFrameCount, 0)
        XCTAssertEqual(value.playoutMaximumConsecutiveNearSilenceFrameCount, 0)
        XCTAssertEqual(value.playoutPCMLeftZeroCrossingCount, 0)
        XCTAssertEqual(value.playoutPCMRightZeroCrossingCount, 0)
        XCTAssertEqual(value.playoutPCMEnvelopeTransitionCount, 0)
        XCTAssertEqual(value.playoutPCMShapeAnomalyCallbackCount, 0)
        XCTAssertEqual(value.playoutPCMBoundaryDiscontinuityCallbackCount, 0)
        XCTAssertEqual(value.playoutLastCallbackMeanMagnitude, 0)
        XCTAssertEqual(value.unexpectedRecordingRequestCount, 0)

        await viewer.close()
    }

    /// Runtime—not a direct protocol invocation—proof that a real peer connection initializes
    /// and clocks the injected output-only RemoteIO device on physical iOS hardware.
    func testPeerUsesStereoRemoteIOAndReceivesNativePlayoutCallbacks() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip(
            "iOS 26.5 Simulator has no registered RemoteIO component factory and aborts "
                + "AudioComponentInstanceNew after its CoreAudio RPC timeout; run on iPhone."
        )
        #else
        let playback = WebRTCAudioPlaybackSession()
        try playback.activate()
        defer { playback.deactivate() }

        let host = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .host, iceServers: [])
        )
        let viewer = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [])
        )
        let forwardingFailures = LockedFailures()
        let remoteAudioExpectationGate = LockedOnce()
        let remoteAudio = expectation(description: "viewer received native remote audio track")

        let hostForwarder = Task {
            for await event in host.events {
                guard !Task.isCancelled else { return }
                if case .outboundSignal(let payload) = event {
                    do { try await viewer.receive(payload) }
                    catch { forwardingFailures.append(error) }
                }
            }
        }
        let viewerForwarder = Task {
            for await event in viewer.events {
                guard !Task.isCancelled else { return }
                switch event {
                case .outboundSignal(let payload):
                    do { try await host.receive(payload) }
                    catch { forwardingFailures.append(error) }
                case .remoteAudioTrack(let track):
                    track.setEnabled(true)
                    if remoteAudioExpectationGate.claim() {
                        remoteAudio.fulfill()
                    }
                default:
                    break
                }
            }
        }

        try await host.start()
        await fulfillment(of: [remoteAudio], timeout: 10)

        for _ in 0..<200 where !(await host.isTransportHealthyForCapture()) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let authorization = WebRTCAudioAuthorization()
        try await host.enableSystemAudioIfTransportHealthy(authorization: authorization)

        var diagnostics = await viewer.iOSPlayoutDiagnostics()
        for _ in 0..<500 where (diagnostics?.playoutCallbackCount ?? 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
            diagnostics = await viewer.iOSPlayoutDiagnostics()
        }

        let value = try XCTUnwrap(diagnostics)
        XCTAssertTrue(value.initialized)
        XCTAssertTrue(value.playoutInitialized)
        XCTAssertTrue(value.playing)
        XCTAssertTrue(value.sessionActive)
        XCTAssertTrue(value.ownsSessionActivation)
        XCTAssertTrue(value.remoteIOCreated)
        XCTAssertFalse(value.inputBusEnabled, "The custom viewer device must never open a mic bus.")
        XCTAssertTrue(value.outputBusEnabled)
        XCTAssertFalse(value.recoveryRequired)
        XCTAssertFalse(value.explicitResumeRequired)
        XCTAssertTrue(value.categoryIsMediaPlayback)
        XCTAssertTrue(value.modeIsDefault)
        XCTAssertFalse(AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers))
        XCTAssertEqual(value.sampleRate, 48_000, accuracy: 0.5)
        XCTAssertEqual(
            value.outputIOBufferDuration,
            AVAudioSession.sharedInstance().ioBufferDuration,
            accuracy: 0.000_001
        )
        XCTAssertEqual(value.outputChannelCount, 2)
        XCTAssertEqual(value.audioUnitSubType, kAudioUnitSubType_RemoteIO)
        XCTAssertEqual(value.failureCode, 0)
        XCTAssertEqual(value.lastLifecycleStatus, noErr)
        XCTAssertNil(value.failureMessage)
        XCTAssertGreaterThan(value.playoutCallbackCount, 0)
        XCTAssertGreaterThan(value.playoutFrameCount, 0)
        XCTAssertEqual(value.playoutFailureCount, 0)
        XCTAssertEqual(value.unexpectedRecordingRequestCount, 0)
        XCTAssertEqual(value.lastPlayoutStatus, noErr)
        XCTAssertTrue(forwardingFailures.values.isEmpty, forwardingFailures.values.joined(separator: "\n"))

        // A normal app-lifecycle recovery signal must be idempotent while this exact device owns
        // healthy playout. In particular, it must not tear down RemoteIO and produce an audible gap.
        let healthyRecoveryAuthorization = WebRTCIOSPlayoutRecoveryAuthorization()
        await viewer.requestIOSPlayoutRecovery(
            authorization: healthyRecoveryAuthorization
        )
        try await Task.sleep(for: .milliseconds(50))
        let healthyRecoveryDiagnostics = await viewer.iOSPlayoutDiagnostics()
        let afterHealthyRecoveryRequest = try XCTUnwrap(healthyRecoveryDiagnostics)
        XCTAssertTrue(afterHealthyRecoveryRequest.playing)
        XCTAssertTrue(afterHealthyRecoveryRequest.sessionActive)
        XCTAssertTrue(afterHealthyRecoveryRequest.ownsSessionActivation)
        XCTAssertFalse(afterHealthyRecoveryRequest.recoveryRequired)
        XCTAssertFalse(afterHealthyRecoveryRequest.explicitResumeRequired)
        XCTAssertEqual(afterHealthyRecoveryRequest.failureCode, 0)
        XCTAssertGreaterThan(
            afterHealthyRecoveryRequest.playoutCallbackCount,
            value.playoutCallbackCount
        )

        // The old-output-device path deliberately fails closed so a removed headset cannot leak
        // remote audio through the speaker. Only an explicit recovery request may resume it.
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            ]
        )
        var routeFailure = await viewer.iOSPlayoutDiagnostics()
        for _ in 0..<200 where !Self.hasCompletedFailClosedRouteTransition(routeFailure) {
            try await Task.sleep(for: .milliseconds(10))
            routeFailure = await viewer.iOSPlayoutDiagnostics()
        }
        let failedClosed = try XCTUnwrap(routeFailure)
        XCTAssertFalse(failedClosed.playing)
        XCTAssertFalse(failedClosed.sessionActive)
        XCTAssertFalse(failedClosed.ownsSessionActivation)
        XCTAssertFalse(failedClosed.remoteIOCreated)
        XCTAssertTrue(failedClosed.recoveryRequired)
        XCTAssertTrue(failedClosed.explicitResumeRequired)
        XCTAssertEqual(failedClosed.failureCode, 19)
        XCTAssertNotNil(failedClosed.failureMessage)

        let routeRecoveryAuthorization = WebRTCIOSPlayoutRecoveryAuthorization()
        await viewer.requestIOSPlayoutRecovery(
            authorization: routeRecoveryAuthorization
        )
        var recovered = await viewer.iOSPlayoutDiagnostics()
        for _ in 0..<500 where recovered?.playing != true {
            try await Task.sleep(for: .milliseconds(10))
            recovered = await viewer.iOSPlayoutDiagnostics()
        }
        let recoveredValue = try XCTUnwrap(recovered)
        XCTAssertTrue(recoveredValue.playing)
        XCTAssertTrue(recoveredValue.sessionActive)
        XCTAssertTrue(recoveredValue.ownsSessionActivation)
        XCTAssertFalse(recoveredValue.recoveryRequired)
        XCTAssertFalse(recoveredValue.explicitResumeRequired)
        XCTAssertEqual(recoveredValue.failureCode, 0)
        XCTAssertNil(recoveredValue.failureMessage)

        await host.close()
        await viewer.close()
        hostForwarder.cancel()
        viewerForwarder.cancel()
        #endif
    }

    // MARK: - Native diagnostics fixtures

    private static func hasCompletedFailClosedRouteTransition(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics?
    ) -> Bool {
        guard let diagnostics else { return false }
        return diagnostics.explicitResumeRequired
            && diagnostics.recoveryRequired
            && !diagnostics.playing
            && !diagnostics.sessionActive
            && !diagnostics.ownsSessionActivation
            && !diagnostics.remoteIOCreated
    }

    private static func stereoChallengeTone(frames: Range<Int>) -> [Int16] {
        let sampleRate = 48_000.0
        var samples = [Int16]()
        samples.reserveCapacity(frames.count * 2)
        for frame in frames {
            let time = Double(frame) / sampleRate
            samples.append(
                Int16((sin(2 * .pi * 997 * time) * 9_000).rounded())
            )
            samples.append(
                Int16((sin(2 * .pi * 1_499 * time) * 9_000).rounded())
            )
        }
        return samples
    }
}

// MARK: - Thread-safe test probes

/// One-shot claim primitive used to assert native callback serialization under contention.
private final class LockedOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var wasClaimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !wasClaimed else { return false }
            wasClaimed = true
            return true
        }
    }
}

private final class LockedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ error: any Error) {
        lock.withLock { storage.append(String(describing: error)) }
    }
}

private final class LockedInteger: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

@MainActor
private final class WebRTCAudioSessionStub: WebRTCAudioSessionControlling {
    var isActive = false
    var isAudioEnabled = false
    private(set) var configuredModes: [String] = []
    private(set) var setActiveValues: [Bool] = []
    private(set) var prepareCount = 0
    private(set) var lockCount = 0
    private(set) var unlockCount = 0

    func prepareForManualAudio() { prepareCount += 1 }
    func lockForConfiguration() { lockCount += 1 }
    func unlockForConfiguration() { unlockCount += 1 }
    func configurePlayback(mode: AVAudioSession.Mode) throws {
        configuredModes.append(mode.rawValue)
    }
    func setActive(_ active: Bool) throws {
        setActiveValues.append(active)
        isActive = active
    }
}
