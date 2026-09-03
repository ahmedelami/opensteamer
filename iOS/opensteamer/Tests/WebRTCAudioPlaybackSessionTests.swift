import AVFAudio
import AudioToolbox
import RemoteSessionCore
import XCTest
@testable import WebRTCTransport

/// Verifies the native WebRTC audio-device contract and recovery authorization boundary.
/// Deterministic tests assert the production configuration-operation inputs and synchronous
/// revocation rules; the physical-device test remains the hardware RemoteIO oracle.
@MainActor
final class WebRTCAudioPlaybackSessionTests: XCTestCase {
    func testRecoveryAuthorizationPublishesExactTerminalOutcomeAndGeneration() {
        let accepted = WebRTCIOSPlayoutRecoveryAuthorization()
        let rejected = WebRTCIOSPlayoutRecoveryAuthorization()
        let revoked = WebRTCIOSPlayoutRecoveryAuthorization()

        XCTAssertNotEqual(accepted.generation, 0)
        XCTAssertNotEqual(accepted.generation, rejected.generation)
        XCTAssertEqual(accepted.terminalGeneration, 0)
        XCTAssertEqual(accepted.terminalOutcome, .pending)

        XCTAssertTrue(accepted.performIfValidForTesting {})
        XCTAssertEqual(accepted.terminalGeneration, accepted.generation)
        XCTAssertEqual(accepted.terminalOutcome, .accepted)
        XCTAssertTrue(accepted.hasAcceptedTerminalOutcome)

        XCTAssertFalse(rejected.rejectIfValidForTesting())
        XCTAssertEqual(rejected.terminalGeneration, rejected.generation)
        XCTAssertEqual(rejected.terminalOutcome, .rejected)
        XCTAssertFalse(rejected.hasAcceptedTerminalOutcome)

        revoked.revoke()
        XCTAssertEqual(revoked.terminalGeneration, revoked.generation)
        XCTAssertEqual(revoked.terminalOutcome, .revoked)
        XCTAssertFalse(revoked.hasAcceptedTerminalOutcome)
        revoked.revoke()
        XCTAssertEqual(revoked.terminalOutcome, .revoked)
    }

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

    func testExactNativeAudioPolicyEffectsRejectMissingTransactionTag() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugExactAudioPolicyEffectsRejectMissingTagForTesting()
        )
    }

    func testInitializedMicrophoneCloseFailsClosedWithoutDelegate() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugInitializedMicrophoneCloseFailsClosedWithoutDelegateForTesting()
        )
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

    func testMicrophoneStageKeepsPCMClosedUntilExactOneShotGenerationApproval() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        defer { _ = harness.debugTerminateForTesting() }

        harness.debugMarkHealthyPlayoutForTesting()
        harness.debugSetCaptureRouteBuiltInMicrophoneForTesting(true)
        let before = harness.diagnostics
        XCTAssertFalse(before.inputBusEnabled)
        XCTAssertFalse(before.captureRouteIsBuiltInMicrophone)
        XCTAssertTrue(before.outputBusEnabled)
        XCTAssertTrue(before.microphoneDeviceGateClosedAndDrained)
        XCTAssertFalse(before.microphoneAuthorizationGatePublished)

        XCTAssertTrue(
            harness.setMicrophoneAuthorizationForTesting(authorization)
        )

        let staged = harness.diagnostics
        let generation = authorization.recordingGeneration
        XCTAssertGreaterThan(generation, 0)
        XCTAssertEqual(staged.microphoneRecordingGeneration, generation)
        XCTAssertEqual(staged.approvedMicrophoneRecordingGeneration, 0)
        XCTAssertTrue(staged.inputBusEnabled)
        XCTAssertTrue(staged.outputBusEnabled)
        XCTAssertTrue(staged.categoryIsMediaPlayAndRecord)
        XCTAssertTrue(staged.modeIsDefault)
        XCTAssertEqual(
            harness.lastConfiguredCategory,
            AVAudioSession.Category.playAndRecord.rawValue
        )
        XCTAssertEqual(
            AVAudioSession.CategoryOptions(
                rawValue: harness.lastConfiguredCategoryOptions
            ),
            [.defaultToSpeaker, .allowBluetoothA2DP]
        )
        XCTAssertFalse(staged.categoryOptionsAreEmpty)
        XCTAssertTrue(staged.categoryOptionsAreIPhoneMicrophoneRouting)
        XCTAssertFalse(staged.categoryOptionsAreMixWithOthers)
        XCTAssertTrue(staged.microphoneDeviceGateClosedAndDrained)
        XCTAssertFalse(staged.microphoneAuthorizationGatePublished)
        XCTAssertEqual(
            staged.microphoneRealtimeAdmissionCount,
            before.microphoneRealtimeAdmissionCount
        )
        XCTAssertEqual(
            staged.microphoneDeliveryCallbackCount,
            before.microphoneDeliveryCallbackCount
        )
        XCTAssertEqual(
            staged.microphoneDeliveredFrameCount,
            before.microphoneDeliveredFrameCount
        )
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())

        XCTAssertTrue(
            harness.debugPublishCurrentMicrophoneAuthorizationForTesting()
        )

        let approved = harness.diagnostics
        XCTAssertEqual(approved.microphoneRecordingGeneration, generation)
        XCTAssertEqual(
            approved.approvedMicrophoneRecordingGeneration,
            generation
        )
        XCTAssertFalse(approved.microphoneDeviceGateClosedAndDrained)
        XCTAssertTrue(approved.microphoneAuthorizationGatePublished)
        XCTAssertTrue(
            approved.captureRouteIsBuiltInMicrophone,
            "An approved generation may publish only the privacy-minimal live built-in-mic route proof."
        )
        XCTAssertTrue(harness.debugBeginRealtimeAdmissionForTesting())
        harness.debugEndRealtimeAdmissionForTesting()

        harness.debugSetCaptureRouteBuiltInMicrophoneForTesting(false)
        XCTAssertFalse(
            harness.diagnostics.captureRouteIsBuiltInMicrophone,
            "A live capture-route mutation must clear the proof without exposing a port identity."
        )
        harness.debugSetCaptureRouteBuiltInMicrophoneForTesting(true)
        XCTAssertFalse(
            harness.diagnostics.captureRouteIsBuiltInMicrophone,
            "Returning to the built-in route cannot revive a retired proof without fresh exact publication."
        )

        XCTAssertFalse(
            harness.debugPublishCurrentMicrophoneAuthorizationForTesting(),
            "A generation approval must be consumed exactly once."
        )

        let duplicate = harness.diagnostics
        XCTAssertEqual(duplicate.microphoneRecordingGeneration, generation)
        XCTAssertEqual(duplicate.approvedMicrophoneRecordingGeneration, 0)
        XCTAssertTrue(duplicate.microphoneDeviceGateClosedAndDrained)
        XCTAssertFalse(duplicate.microphoneAuthorizationGatePublished)
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())
    }

    func testInactiveA2DPRouteCannotIssueChannelPreferenceRequests() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertFalse(
            harness.debugApplyActiveChannelPreferencesForTesting(
                sessionActive: false,
                maximumInputChannels: 0,
                maximumOutputChannels: 2,
                microphoneEnabled: true
            )
        )
        XCTAssertEqual(harness.lastChannelPreferenceOperations, [])
    }

    func testActiveDuplexRouteAppliesStereoThenMonoPreferences() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness.debugApplyActiveChannelPreferencesForTesting(
                sessionActive: true,
                maximumInputChannels: 1,
                maximumOutputChannels: 2,
                microphoneEnabled: true
            )
        )
        XCTAssertEqual(
            harness.lastChannelPreferenceOperations,
            ["output=2", "input=1"]
        )
    }

    func testActiveOutputOnlyRouteRejectsMicrophoneBeforeAnyPreferenceRequest() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertFalse(
            harness.debugApplyActiveChannelPreferencesForTesting(
                sessionActive: true,
                maximumInputChannels: 0,
                maximumOutputChannels: 2,
                microphoneEnabled: true
            )
        )
        XCTAssertEqual(harness.lastChannelPreferenceOperations, [])
    }

    func testExpectedRouteTransactionConsumesActivationAndBoundConfigurationEvents() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertEqual(
            harness.debugClassifyExpectedRouteChangeForTesting(
                .pendingActivation
            ),
            .consume
        )
        XCTAssertEqual(
            harness.debugClassifyExpectedRouteChangeForTesting(
                .pendingBound
            ),
            .consume
        )
        XCTAssertEqual(
            harness.debugClassifyExpectedRouteChangeForTesting(
                .pendingCategory
            ),
            .unrelated
        )
    }

    func testExpectedRouteTransactionRejectsWrongProvenanceAndOutputOverride() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        for scenario: WebRTCIOSExpectedRouteChangeTestScenario in [
            .pendingOverride,
            .pendingWrongPreviousRoute,
            .pendingWrongGeneration,
            .pendingWrongOwnership,
            .pendingCoalescedSkippedIntermediate,
            .pendingExpired,
            .pendingSequenceNotAdvanced,
            .pendingWrongSystemGeneration,
            .pendingWrongPolicy,
            .pendingMissingFingerprint,
            .pendingOutputChanged,
        ] {
            XCTAssertEqual(
                harness.debugClassifyExpectedRouteChangeForTesting(scenario),
                .rejectTransaction,
                "Scenario \(scenario.rawValue) was not rejected."
            )
        }
    }

    func testConvergedRouteTransactionIsIdempotentOnlyForExactBoundedDuplicates() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertEqual(
            harness.debugClassifyExpectedRouteChangeForTesting(
                .convergedDuplicate
            ),
            .consume
        )
        for scenario: WebRTCIOSExpectedRouteChangeTestScenario in [
            .convergedChangedRoute,
            .convergedRecoveryRequired,
            .convergedExpired,
            .convergedWrongOwnership,
            .convergedInactive,
            .convergedOutputMissing,
            .convergedChannelMismatch,
            .convergedTargetMismatch,
            .convergedPreferredMismatch,
            .convergedWrongSystemGeneration,
            .convergedWrongGeneration,
            .convergedPreviousUnseen,
            .convergedExplicitResumeRequired,
        ] {
            XCTAssertEqual(
                harness.debugClassifyExpectedRouteChangeForTesting(scenario),
                .unrelated,
                "Scenario \(scenario.rawValue) was incorrectly consumed."
            )
        }
    }

    func testRemoteIOStartRouteTransactionAcceptsOnlyExactReasonEightEvidence() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertEqual(
            harness.debugClassifyExpectedRouteChangeForTesting(.preparedExact),
            .consume
        )
        XCTAssertEqual(
            harness.debugClassifyExpectedRouteChangeForTesting(
                .startingCoalescedExactRoute
            ),
            .consume,
            "A delayed/coalesced reason-8 event is harmless only when the complete prepared route remains exact."
        )
        XCTAssertEqual(
            harness.debugClassifyExpectedRouteChangeForTesting(
                .convergedStartSettlementCoalescedExactRoute
            ),
            .consume,
            "A previous-unseen coalesced reason-8 may be consumed after publication only while the exact native-start settlement claim owns it."
        )
        XCTAssertEqual(
            harness.debugClassifyExpectedRouteChangeForTesting(
                .convergedStartSettlementExpired
            ),
            .unrelated,
            "An expired native-start claim must not lend provenance to a previous-unseen route event."
        )

        for scenario: WebRTCIOSExpectedRouteChangeTestScenario in [
            .preparedChangedRoute,
            .startingChangedRoute,
            .startingOutputChanged,
            .startingWrongOwnership,
            .startingRecoveryRequired,
            .startingOldDeviceUnavailable,
            .startingChannelMismatch,
            .startingInactive,
            .startingWrongGeneration,
            .startingWrongSystemGeneration,
            .startingTargetMismatch,
            .startingPreferredMismatch,
            .startingExplicitResumeRequired,
        ] {
            XCTAssertEqual(
                harness.debugClassifyExpectedRouteChangeForTesting(scenario),
                .rejectTransaction,
                "Start-time scenario \(scenario.rawValue) was not rejected."
            )
        }
        XCTAssertEqual(
            harness.debugClassifyExpectedRouteChangeForTesting(.startingCategory),
            .unrelated
        )
    }

    func testRemoteIOStartSettlementProductionStateIsOneShotAcrossCommit() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugRemoteIOStartSettlementAcceptsDelayedObservationForTesting(),
            "The production transaction state must retire a claim consumed while Starting at commit (including a synchronous pre-stamp ingress), preserve an unused claim for one exact +250 ms post-commit ingress, and reject replay, expiry, wrong transaction, and the stamp sequence."
        )
    }

    func testOnlySupersededReasonEightCanBeAbsorbedByNewerTransaction() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness.debugSupersededRouteObservationIsSuppressedForTesting(
                oldDeviceUnavailable: false
            )
        )
        XCTAssertFalse(
            harness.debugSupersededRouteObservationIsSuppressedForTesting(
                oldDeviceUnavailable: true
            ),
            "Physical device loss must always reach explicit-resume policy."
        )
    }

    func testOnlyReasonEightFromRetiredSystemAudioGenerationIsSuppressed() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugRetiredSystemGenerationRouteObservationIsSuppressedForTesting(
                    oldDeviceUnavailable: false
                )
        )
        XCTAssertFalse(
            harness
                .debugRetiredSystemGenerationRouteObservationIsSuppressedForTesting(
                    oldDeviceUnavailable: true
                ),
            "A generation change must never hide physical device loss."
        )
    }

    func testReasonEightArbitrationSupportsSwiftFirstAndNativeFirstDelivery() {
        let harness =
            WebRTCRouteConfigurationChangeArbitrationTestHarness()

        for disposition: WebRTCRouteConfigurationChangeDisposition in [
            .consumed,
            .liveRejectionOwnedByWaiter,
            .staleSuppressed,
            .generic,
            .uninitialized,
        ] {
            XCTAssertTrue(
                harness.debugWaiterFirstResolvesForTesting(disposition),
                "Swift-first arbitration lost disposition \(disposition)."
            )
            XCTAssertTrue(
                harness.debugNativeFirstResolvesForTesting(disposition),
                "Native-first arbitration lost disposition \(disposition)."
            )
        }
    }

    func testReasonEightNativeFirstDispositionSurvivesResolverReplacement() {
        let harness =
            WebRTCRouteConfigurationChangeArbitrationTestHarness()

        for disposition: WebRTCRouteConfigurationChangeDisposition in [
            .consumed,
            .staleSuppressed,
        ] {
            XCTAssertTrue(
                harness
                    .debugNativeFirstResolverReplacementPreservesDispositionForTesting(
                        disposition
                    ),
                "Resolver replacement overwrote exact disposition \(disposition)."
            )
        }
    }

    func testReasonEightArbitrationIsExactAndTimeoutCompletesOnce() {
        let harness =
            WebRTCRouteConfigurationChangeArbitrationTestHarness()

        XCTAssertTrue(
            harness
                .debugExactNotificationIdentityRejectsStaleResolutionForTesting(),
            "A replacement notification must not borrow a retired notification's native disposition."
        )
        XCTAssertTrue(
            harness.debugTimeoutCompletesExactlyOnceForTesting(),
            "A late native resolution after timeout must not deliver a second generic recovery."
        )
    }

    func testReasonEightTimeoutBeforeLateNativeBindCompletesOnceAndCleansRecord() {
        let harness =
            WebRTCRouteConfigurationChangeArbitrationTestHarness()

        XCTAssertTrue(
            harness
                .debugTimeoutBeforeNativeBindThenLateResolutionCompletesExactlyOnceForTesting(),
            "A late native bind after timeout must neither redeliver nor recreate arbitration state."
        )
        XCTAssertEqual(
            harness.debugArbitrationRecordCountForTesting(),
            0,
            "Timeout followed by late native resolution must leave no arbitration records."
        )
    }

    func testExplicitResumeFailureRemainsStickyWhileLatched() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        harness.debugMarkRouteLossForTesting()
        let explicitResume = harness.diagnostics
        XCTAssertTrue(explicitResume.explicitResumeRequired)
        XCTAssertEqual(explicitResume.failureCode, 19)

        harness.debugAttemptFailureOverwriteForTesting()
        let afterOverwriteAttempt = harness.diagnostics
        XCTAssertTrue(afterOverwriteAttempt.explicitResumeRequired)
        XCTAssertEqual(afterOverwriteAttempt.failureCode, 19)
        XCTAssertEqual(
            afterOverwriteAttempt.lastLifecycleStatus,
            explicitResume.lastLifecycleStatus
        )
    }

    func testRunningButUnpublishedAudioUnitIsStoppedDuringRollback() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugRunningUnpublishedAudioUnitStopInvariantHoldsForTesting()
        )
    }

    func testOnlyRouteEvidenceThatClosedTheGateRetainsMicrophonePublicationClosure() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertFalse(
            harness
                .debugRouteEvidenceOwnsMicrophonePublicationClosureForTesting(
                    recordedClosure: false,
                    inFlightCount: 0
                )
        )
        XCTAssertTrue(
            harness
                .debugRouteEvidenceOwnsMicrophonePublicationClosureForTesting(
                    recordedClosure: true,
                    inFlightCount: 0
                )
        )
        // An in-flight count cannot fabricate ownership if ingress never
        // recorded a closure (for example, while playout was stopped).
        XCTAssertFalse(
            harness
                .debugRouteEvidenceOwnsMicrophonePublicationClosureForTesting(
                    recordedClosure: false,
                    inFlightCount: 1
                )
        )
        XCTAssertTrue(
            harness
                .debugRecordedConsumedRouteClosureSchedulesFreshResolutionForTesting(),
            "A drained recorded closure must always reach fresh device-queue resolution."
        )
    }

    func testCategoryObservationClosesOnlyWhenTrackedResolutionOwnsIt() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugTrackedCategoryObservationOwnsRouteClosureForTesting(),
            "Category/options evidence racing approval must keep microphone publication closed."
        )
        XCTAssertTrue(
            harness
                .debugUntrackedCategoryObservationAvoidsUnownedRouteClosureForTesting(),
            "Output-only or hosted category evidence must not strand gates without a transaction-owned resolver."
        )
        XCTAssertTrue(
            harness
                .debugConsumedPublicationQueuesRecordedRouteClosureResolutionForTesting(),
            "A closure drained before commit must remain closed at publication and queue fresh resolution once the transaction is consumed."
        )
    }

    func testExpectedCategoryObservationUsesCapturedTransactionPolicy() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness.debugExpectedCategoryObservationIsAbsorbedForTesting(
                .microphoneExact
            ),
            "The exact playAndRecord/default/40 notification must remain tied to the microphone transaction that authored it."
        )
        XCTAssertTrue(
            harness.debugExpectedCategoryObservationIsAbsorbedForTesting(
                .outputOnlyExact
            ),
            "The exact playback/default/empty notification must remain tied to its output-only transaction."
        )
    }

    func testUnexpectedCategoryObservationStillFailsExactPolicyFence() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        for scenario: WebRTCIOSExpectedCategoryObservationTestScenario in [
            .untracked,
            .wrongOptions,
            .wrongMode,
            .wrongSharingPolicy,
            .wrongConfigurationGeneration,
            .wrongSystemAudioGeneration,
            .sequenceNotAdvanced,
            .expired,
        ] {
            XCTAssertFalse(
                harness.debugExpectedCategoryObservationIsAbsorbedForTesting(
                    scenario
                ),
                "Unexpected category scenario \(scenario.rawValue) bypassed fail-closed validation."
            )
        }
    }

    func testRetiredExpectedCategoryObservationUsesProductionAsyncPipeline() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness.debugDriveRetiredExpectedCategoryObservationForTesting(
                exactPolicy: true
            )
        )
        XCTAssertEqual(harness.queuedOperationCount, 0)
        XCTAssertEqual(harness.diagnostics.failureCode, 0)
        XCTAssertFalse(harness.diagnostics.recoveryRequired)
    }

    func testRetiredMismatchedCategoryObservationStillReachesNativeFailClose() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness.debugDriveRetiredExpectedCategoryObservationForTesting(
                exactPolicy: false
            )
        )
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertTrue(harness.runNextQueuedOperation())
        XCTAssertEqual(harness.diagnostics.failureCode, 20)
        XCTAssertTrue(harness.diagnostics.recoveryRequired)
    }

    func testFinalMicrophonePublicationRejectsDelayedRouteIngressAndUsesSnapshotOwnership() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugFinalMicrophonePublicationRejectsDelayedRouteIngressForTesting(),
            "Category or route ingress after the final fresh session sample must block microphone gate publication."
        )
        XCTAssertTrue(
            harness
                .debugRouteLockedOwnershipSnapshotComparatorForTesting(),
            "Route-locked gate publication must use the atomic ownership snapshot without acquiring the ownership lock."
        )
        XCTAssertTrue(
            harness
                .debugImmutableRouteRejectionSnapshotSurvivesLaterRouteForTesting(),
            "Failure diagnostics must retain the redacted immutable ingress that rejected the transaction, not a later live route."
        )
    }

    func testClearRetiresInFlightExpectedRouteObservationIdentity() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugClearRetiresInFlightExpectedRouteObservationForTesting()
        )
    }

    func testOldQueuedRouteCompletionCannotMutateRearmedTransaction() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugOldQueuedRouteObservationCannotMutateRearmedTransactionForTesting(),
            "A completion carrying a retired transaction ID must leave the new transaction's state and in-flight count untouched."
        )
    }

    func testRecordedClosureResolutionUsesFreshRouteEvidence() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugRecordedConsumedRouteClosureUsesFreshRouteForTesting(),
            "A recorded consumed closure must resolve from the fresh device-queue route, not the stale final ingress snapshot."
        )
    }

    func testNotificationSequenceChangeBlocksFreshRouteReopen() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugNotificationSequenceChangeBlocksFreshRouteReopenForTesting(),
            "A notification admitted after fresh validation must retain the fail-closed gate instead of reopening it."
        )
    }

    func testRouteTransactionFailureSnapshotIsStructuredAndRedactsUIDs() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        let first =
            harness.debugStructuredRouteTransactionFailureSnapshotForTesting()
        let second =
            harness.debugStructuredRouteTransactionFailureSnapshotForTesting()

        XCTAssertEqual(first, second, "Redacted fingerprints must correlate across snapshots.")
        XCTAssertTrue(first.contains("routeTxn{phase=fresh-reopen state=consumed"))
        XCTAssertTrue(first.contains("txn=71 expectedTxn=71"))
        XCTAssertTrue(
            first.contains(
                "notification={current=73 baseline=68 required=72 inFlight=0}"
            )
        )
        XCTAssertTrue(
            first.contains("generation={configuration=11/12 system=41/42}")
        )
        XCTAssertTrue(first.contains("ownership={bound=91 current=92}"))
        XCTAssertTrue(
            first.contains(
                "failed=[notificationSequence,configurationGeneration,systemAudioGeneration,ownershipToken]"
            )
        )
        XCTAssertTrue(first.contains("targetInputUID=sha256/128:"))
        XCTAssertTrue(first.contains("inputUID=sha256/128:"))
        XCTAssertTrue(first.contains("preferredInputUID=sha256/128:"))
        XCTAssertFalse(first.contains("PRIVATE-INPUT-UID"))
        XCTAssertFalse(first.contains("PRIVATE-OUTPUT-UID"))
    }

    func testMicrophoneApprovalRejectsZeroWrongStaleRevokedAndRetiredGenerations() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        defer { _ = harness.debugTerminateForTesting() }

        harness.debugMarkHealthyPlayoutForTesting()

        XCTAssertTrue(
            harness.setMicrophoneAuthorizationForTesting(authorization)
        )
        let firstGeneration = authorization.recordingGeneration
        XCTAssertGreaterThan(firstGeneration, 0)
        authorization.debugSetRecordingGenerationForTesting(0)
        XCTAssertFalse(
            harness.debugPublishCurrentMicrophoneAuthorizationForTesting()
        )
        XCTAssertTrue(
            harness.diagnostics.microphoneDeviceGateClosedAndDrained
        )
        XCTAssertFalse(
            harness.diagnostics.microphoneAuthorizationGatePublished
        )

        XCTAssertTrue(
            harness.setMicrophoneAuthorizationForTesting(authorization)
        )
        let secondGeneration = authorization.recordingGeneration
        XCTAssertGreaterThan(secondGeneration, 0)
        XCTAssertNotEqual(secondGeneration, firstGeneration)
        authorization.debugSetRecordingGenerationForTesting(
            secondGeneration &+ 1
        )
        XCTAssertFalse(
            harness.debugPublishCurrentMicrophoneAuthorizationForTesting()
        )
        XCTAssertEqual(
            harness.diagnostics.microphoneRecordingGeneration,
            secondGeneration
        )
        XCTAssertEqual(
            harness.diagnostics.approvedMicrophoneRecordingGeneration,
            0
        )

        XCTAssertTrue(
            harness.setMicrophoneAuthorizationForTesting(authorization)
        )
        let thirdGeneration = authorization.recordingGeneration
        XCTAssertGreaterThan(thirdGeneration, 0)
        XCTAssertNotEqual(thirdGeneration, secondGeneration)
        authorization.debugSetRecordingGenerationForTesting(secondGeneration)
        XCTAssertFalse(
            harness.debugPublishCurrentMicrophoneAuthorizationForTesting(),
            "An authorization carrying a prior nonzero generation must fail closed."
        )
        XCTAssertEqual(
            harness.diagnostics.microphoneRecordingGeneration,
            thirdGeneration
        )

        XCTAssertTrue(
            harness.setMicrophoneAuthorizationForTesting(authorization)
        )
        let fourthGeneration = authorization.recordingGeneration
        XCTAssertGreaterThan(fourthGeneration, 0)
        authorization.revoke()
        XCTAssertFalse(
            harness.debugPublishCurrentMicrophoneAuthorizationForTesting()
        )
        XCTAssertTrue(
            harness.diagnostics.microphoneDeviceGateClosedAndDrained
        )
        XCTAssertFalse(
            harness.diagnostics.microphoneAuthorizationGatePublished
        )

        let replacement = WebRTCIOSMicrophoneAuthorization()
        XCTAssertTrue(
            harness.setMicrophoneAuthorizationForTesting(replacement)
        )
        let replacementGeneration = replacement.recordingGeneration
        XCTAssertGreaterThan(replacementGeneration, 0)
        XCTAssertTrue(harness.setMicrophoneAuthorizationForTesting(nil))

        let retired = harness.diagnostics
        XCTAssertFalse(replacement.isValid)
        XCTAssertEqual(retired.microphoneRecordingGeneration, 0)
        XCTAssertEqual(retired.approvedMicrophoneRecordingGeneration, 0)
        XCTAssertTrue(retired.microphoneDeviceGateClosedAndDrained)
        XCTAssertFalse(retired.microphoneAuthorizationGatePublished)
        XCTAssertFalse(
            harness.debugPublishCurrentMicrophoneAuthorizationForTesting()
        )
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())
    }

    func testMicrophoneStageFailureDoesNotRebuildOrRepublishStaleInput() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        defer { _ = harness.debugTerminateForTesting() }

        harness.debugMarkHealthyPlayoutForTesting()
        let before = harness.diagnostics
        let configurationCount = harness.configurationOperationCount
        harness.debugSetOutputRouteAvailableForTesting(false)

        XCTAssertFalse(
            harness.setMicrophoneAuthorizationForTesting(authorization)
        )

        let failed = harness.diagnostics
        XCTAssertFalse(authorization.isValid)
        XCTAssertEqual(failed.microphoneRecordingGeneration, 0)
        XCTAssertEqual(failed.approvedMicrophoneRecordingGeneration, 0)
        XCTAssertTrue(failed.microphoneDeviceGateClosedAndDrained)
        XCTAssertFalse(failed.microphoneAuthorizationGatePublished)
        XCTAssertFalse(failed.inputBusEnabled)
        XCTAssertFalse(failed.outputBusEnabled)
        XCTAssertFalse(failed.sessionActive)
        XCTAssertEqual(
            failed.microphoneRealtimeAdmissionCount,
            before.microphoneRealtimeAdmissionCount
        )
        XCTAssertEqual(
            failed.microphoneDeliveryCallbackCount,
            before.microphoneDeliveryCallbackCount
        )
        XCTAssertEqual(
            failed.microphoneDeliveredFrameCount,
            before.microphoneDeliveredFrameCount
        )
        XCTAssertEqual(
            harness.configurationOperationCount,
            configurationCount + 1,
            "A failed duplex stage must not trigger an ordinary second rebuild."
        )
        XCTAssertFalse(
            harness.debugPublishCurrentMicrophoneAuthorizationForTesting()
        )
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())
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

    func testHostedCallAuthorizationRevocationWaitsForAuthorizedRecoveryBoundary() {
        let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: UUID(),
            origin: .interruption
        )
        let operationStarted = DispatchSemaphore(value: 0)
        let allowOperationToFinish = DispatchSemaphore(value: 0)
        let operationReachedEnd = DispatchSemaphore(value: 0)
        let recoveryFinished = DispatchSemaphore(value: 0)
        let revokeStarted = DispatchSemaphore(value: 0)
        let revokeFinished = DispatchSemaphore(value: 0)
        let revocationRecorder = HostedCallTestingRevocationRecorder()
        let systemAudioGeneration: UInt64 = 0xCA11_1001

        DispatchQueue.global(qos: .userInitiated).async {
            _ = authorization.performRecoveryIfValidForTesting(
                systemAudioGeneration: systemAudioGeneration,
                revocationHandler: {
                    revocationRecorder.record()
                }
            ) {
                operationStarted.signal()
                _ = allowOperationToFinish.wait(timeout: .now() + 2)
                operationReachedEnd.signal()
            }
            recoveryFinished.signal()
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
            "Hosted-call revocation must wait for the in-flight authorized operation."
        )
        XCTAssertEqual(authorization.systemAudioGeneration, systemAudioGeneration)
        XCTAssertEqual(revocationRecorder.count, 0)

        allowOperationToFinish.signal()
        XCTAssertEqual(operationReachedEnd.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(recoveryFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(revokeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertEqual(authorization.systemAudioGeneration, systemAudioGeneration)
        XCTAssertEqual(revocationRecorder.count, 1)
        authorization.revoke()
        XCTAssertEqual(revocationRecorder.count, 1)
        XCTAssertFalse(
            authorization.performRecoveryIfValidForTesting {
                XCTFail("No hosted recovery operation may begin after revoke returns.")
            }
        )
    }

    func testHostedCallAuthorizationTestingRecoveryInstallsGenerationAndRevokesSynchronouslyOnce() {
        let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: UUID(),
            origin: .interruption
        )
        let rejectedRevocation = HostedCallTestingRevocationRecorder()
        let acceptedRevocation = HostedCallTestingRevocationRecorder()
        var operationCount = 0
        let generation: UInt64 = 0xCA11_2001

        XCTAssertFalse(
            authorization.performRecoveryIfValidForTesting(
                systemAudioGeneration: 0,
                revocationHandler: { rejectedRevocation.record() }
            ) {
                operationCount += 1
            }
        )
        XCTAssertEqual(operationCount, 0)
        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(authorization.isRecoveryPending)
        XCTAssertEqual(authorization.systemAudioGeneration, 0)

        XCTAssertTrue(
            authorization.performRecoveryIfValidForTesting(
                systemAudioGeneration: generation,
                revocationHandler: { acceptedRevocation.record() }
            ) {
                operationCount += 1
            }
        )
        XCTAssertEqual(operationCount, 1)
        XCTAssertTrue(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertEqual(authorization.systemAudioGeneration, generation)
        XCTAssertEqual(rejectedRevocation.count, 0)
        XCTAssertEqual(acceptedRevocation.count, 0)

        authorization.revoke()
        XCTAssertFalse(authorization.isValid)
        XCTAssertEqual(authorization.systemAudioGeneration, generation)
        XCTAssertEqual(rejectedRevocation.count, 0)
        XCTAssertEqual(acceptedRevocation.count, 1)

        authorization.revoke()
        XCTAssertEqual(acceptedRevocation.count, 1)
    }

    func testHostedCallAuthorizationTestingRecoveryRejectsReuseAndPreservesFirstInstall() {
        let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: UUID(),
            origin: .interruption
        )
        let firstRevocation = HostedCallTestingRevocationRecorder()
        let sameGenerationRevocation = HostedCallTestingRevocationRecorder()
        let replacementRevocation = HostedCallTestingRevocationRecorder()
        var rejectedOperationCount = 0
        let firstGeneration: UInt64 = 0xCA11_2002
        let replacementGeneration: UInt64 = 0xCA11_2003

        XCTAssertTrue(
            authorization.performRecoveryIfValidForTesting(
                systemAudioGeneration: firstGeneration,
                revocationHandler: { firstRevocation.record() }
            )
        )
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertEqual(authorization.systemAudioGeneration, firstGeneration)

        XCTAssertFalse(
            authorization.performRecoveryIfValidForTesting(
                systemAudioGeneration: firstGeneration,
                revocationHandler: { sameGenerationRevocation.record() }
            ) {
                rejectedOperationCount += 1
            }
        )
        XCTAssertFalse(
            authorization.performRecoveryIfValidForTesting(
                systemAudioGeneration: replacementGeneration,
                revocationHandler: { replacementRevocation.record() }
            ) {
                rejectedOperationCount += 1
            }
        )
        XCTAssertEqual(rejectedOperationCount, 0)
        XCTAssertEqual(authorization.systemAudioGeneration, firstGeneration)

        authorization.revoke()
        XCTAssertEqual(firstRevocation.count, 1)
        XCTAssertEqual(sameGenerationRevocation.count, 0)
        XCTAssertEqual(replacementRevocation.count, 0)
    }

    func testHostedCallAuthorizationTestingRecoveryRejectsConsumedAndRevokedClaims() {
        let consumedAuthorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: UUID(),
            origin: .interruption
        )
        var bareOperationCount = 0
        XCTAssertTrue(
            consumedAuthorization.performRecoveryIfValidForTesting {
                bareOperationCount += 1
            }
        )
        XCTAssertEqual(bareOperationCount, 1)
        XCTAssertFalse(consumedAuthorization.isRecoveryPending)
        XCTAssertEqual(consumedAuthorization.systemAudioGeneration, 0)
        let consumedRevocation = HostedCallTestingRevocationRecorder()
        var consumedOperationCount = 0
        XCTAssertFalse(
            consumedAuthorization.performRecoveryIfValidForTesting(
                systemAudioGeneration: 0xCA11_2004,
                revocationHandler: { consumedRevocation.record() }
            ) {
                consumedOperationCount += 1
            }
        )
        XCTAssertEqual(consumedOperationCount, 0)
        consumedAuthorization.revoke()
        XCTAssertEqual(consumedRevocation.count, 0)

        let revokedAuthorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: UUID(),
            origin: .interruption
        )
        let revokedRevocation = HostedCallTestingRevocationRecorder()
        var revokedOperationCount = 0
        revokedAuthorization.revoke()
        XCTAssertFalse(
            revokedAuthorization.performRecoveryIfValidForTesting(
                systemAudioGeneration: 0xCA11_2005,
                revocationHandler: { revokedRevocation.record() }
            ) {
                revokedOperationCount += 1
            }
        )
        XCTAssertEqual(revokedOperationCount, 0)
        XCTAssertFalse(revokedAuthorization.isValid)
        XCTAssertFalse(revokedAuthorization.isRecoveryPending)
        XCTAssertEqual(revokedAuthorization.systemAudioGeneration, 0)
        XCTAssertEqual(revokedRevocation.count, 0)
    }

    private final class HostedCallTestingRevocationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        func record() {
            lock.lock()
            storage += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
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

    // MARK: - Connected hosted-call playout recovery

    func testStartupConnectedCallArmIsQuiescentUntilFirstStartPlayout() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let policyID = UUID()
        let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: policyID,
            origin: .startupConnectedCall
        )
        defer { _ = harness.debugTerminateForTesting() }

        let before = harness.diagnostics
        XCTAssertEqual(harness.configurationOperationCount, 0)
        XCTAssertFalse(before.sessionActive)
        XCTAssertFalse(before.remoteIOCreated)
        XCTAssertFalse(before.inputBusEnabled)
        XCTAssertFalse(before.outputBusEnabled)
        XCTAssertFalse(before.hostedCallMode)
        XCTAssertTrue(before.microphoneDeviceGateClosedAndDrained)
        XCTAssertFalse(before.microphoneAuthorizationGatePublished)
        XCTAssertEqual(before.microphoneRecordingGeneration, 0)
        XCTAssertEqual(before.approvedMicrophoneRecordingGeneration, 0)

        XCTAssertTrue(
            harness.armStartupConnectedCallPlayout(
                authorization: authorization
            )
        )

        let armed = harness.diagnostics
        XCTAssertEqual(harness.configurationOperationCount, 0)
        XCTAssertEqual(harness.hostedCallPolicyID, policyID)
        XCTAssertTrue(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertGreaterThan(authorization.systemAudioGeneration, 0)
        XCTAssertFalse(armed.sessionActive)
        XCTAssertFalse(armed.remoteIOCreated)
        XCTAssertFalse(armed.inputBusEnabled)
        XCTAssertFalse(armed.outputBusEnabled)
        XCTAssertFalse(armed.recoveryRequired)
        XCTAssertFalse(armed.explicitResumeRequired)
        XCTAssertTrue(armed.hostedCallMode)
        XCTAssertTrue(armed.hostedCallAuthorizationValid)
        XCTAssertFalse(armed.hostedCallRecoveryPending)
        XCTAssertEqual(armed.hostedCallOrigin, .startupConnectedCall)
        XCTAssertEqual(
            armed.hostedCallAuthorizationGeneration,
            authorization.systemAudioGeneration
        )
        XCTAssertEqual(
            armed.systemAudioGeneration,
            authorization.systemAudioGeneration
        )

        // Exact duplicate arming is idempotent and still has no AVAudioSession side effects.
        XCTAssertTrue(
            harness.armStartupConnectedCallPlayout(
                authorization: authorization
            )
        )
        XCTAssertEqual(harness.configurationOperationCount, 0)

        XCTAssertTrue(harness.debugStartPlayoutForTesting())

        let started = harness.diagnostics
        XCTAssertEqual(harness.configurationOperationCount, 1)
        XCTAssertTrue(started.sessionActive)
        XCTAssertFalse(
            started.remoteIOCreated,
            "The deterministic harness records production policy selection without claiming hardware RemoteIO creation."
        )
        XCTAssertFalse(started.inputBusEnabled)
        XCTAssertTrue(started.outputBusEnabled)
        XCTAssertFalse(started.recoveryRequired)
        XCTAssertFalse(started.explicitResumeRequired)
        XCTAssertFalse(started.categoryOptionsAreEmpty)
        XCTAssertTrue(started.categoryOptionsAreMixWithOthers)
        XCTAssertTrue(started.routeSharingPolicyIsDefault)
        XCTAssertTrue(started.hostedCallMode)
        XCTAssertEqual(started.hostedCallOrigin, .startupConnectedCall)
        assertLastRecordedAudioConfiguration(
            harness,
            options: .mixWithOthers,
            expectedOperationCount: 1
        )
    }

    func testStartupConnectedCallArmRejectsEveryNonquiescentOrStaleClaim() {
        struct RejectionCase {
            let name: String
            let origin: WebRTCIOSHostedCallPlayoutOrigin
            let arrange: (
                WebRTCIOSPlayoutRecoveryTestHarness,
                WebRTCIOSHostedCallPlayoutAuthorization
            ) -> Void
        }

        let cases: [RejectionCase] = [
            RejectionCase(
                name: "wrong origin",
                origin: .interruption,
                arrange: { _, _ in }
            ),
            RejectionCase(
                name: "interrupted",
                origin: .startupConnectedCall,
                arrange: { harness, _ in
                    harness.debugMarkInterruptedFailClosedForTesting()
                }
            ),
            RejectionCase(
                name: "stale consumed generation",
                origin: .startupConnectedCall,
                arrange: { _, authorization in
                    XCTAssertTrue(
                        authorization.performRecoveryIfValidForTesting(
                            systemAudioGeneration: 0xCA11_6001,
                            revocationHandler: {}
                        )
                    )
                }
            ),
            RejectionCase(
                name: "live microphone authorization",
                origin: .startupConnectedCall,
                arrange: { harness, _ in
                    harness.debugInstallMicrophoneAuthorizationForTesting(
                        WebRTCIOSMicrophoneAuthorization()
                    )
                }
            ),
            RejectionCase(
                name: "live playout topology",
                origin: .startupConnectedCall,
                arrange: { harness, _ in
                    harness.debugMarkHealthyPlayoutForTesting()
                }
            ),
            RejectionCase(
                name: "recovery and explicit resume",
                origin: .startupConnectedCall,
                arrange: { harness, _ in
                    harness.debugMarkRouteLossForTesting()
                    harness.debugSetOutputRouteAvailableForTesting(true)
                }
            ),
        ]

        for testCase in cases {
            let harness = WebRTCIOSPlayoutRecoveryTestHarness()
            let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
                policyID: UUID(),
                origin: testCase.origin
            )
            defer { _ = harness.debugTerminateForTesting() }
            testCase.arrange(harness, authorization)
            let configurationCount = harness.configurationOperationCount

            XCTAssertFalse(
                harness.armStartupConnectedCallPlayout(
                    authorization: authorization
                ),
                testCase.name
            )
            XCTAssertFalse(authorization.isValid, testCase.name)
            XCTAssertNil(harness.hostedCallPolicyID, testCase.name)
            XCTAssertFalse(harness.diagnostics.hostedCallMode, testCase.name)
            XCTAssertNil(harness.diagnostics.hostedCallOrigin, testCase.name)
            XCTAssertEqual(
                harness.configurationOperationCount,
                configurationCount,
                testCase.name
            )
        }
    }

    func testStartupConnectedCallArmDefersRouteValidationUntilActivation() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: UUID(),
            origin: .startupConnectedCall
        )
        defer { _ = harness.debugTerminateForTesting() }

        harness.debugSetOutputRouteAvailableForTesting(false)

        XCTAssertTrue(
            harness.armStartupConnectedCallPlayout(
                authorization: authorization
            )
        )
        XCTAssertEqual(harness.configurationOperationCount, 0)
        XCTAssertTrue(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertFalse(harness.debugStartPlayoutForTesting())

        let failed = harness.diagnostics
        XCTAssertEqual(harness.configurationOperationCount, 1)
        XCTAssertFalse(authorization.isValid)
        XCTAssertNil(harness.hostedCallPolicyID)
        XCTAssertFalse(failed.sessionActive)
        XCTAssertFalse(failed.inputBusEnabled)
        XCTAssertFalse(failed.outputBusEnabled)
        XCTAssertTrue(failed.recoveryRequired)
        XCTAssertFalse(failed.hasOutputRoute)
        XCTAssertFalse(failed.hostedCallMode)
    }

    func testStartupHostedRevocationAndGenerationAdvanceRemainQuiescent() {
        for revoke in [true, false] {
            let harness = WebRTCIOSPlayoutRecoveryTestHarness()
            let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
                policyID: UUID(),
                origin: .startupConnectedCall
            )
            defer { _ = harness.debugTerminateForTesting() }

            XCTAssertTrue(
                harness.armStartupConnectedCallPlayout(
                    authorization: authorization
                )
            )
            XCTAssertEqual(harness.configurationOperationCount, 0)

            if revoke {
                authorization.revoke()
            } else {
                harness.debugAdvanceSystemAudioGenerationForTesting()
            }

            let revoked = harness.diagnostics
            XCTAssertFalse(authorization.isValid)
            XCTAssertNil(harness.hostedCallPolicyID)
            XCTAssertFalse(revoked.sessionActive)
            XCTAssertFalse(revoked.remoteIOCreated)
            XCTAssertFalse(revoked.inputBusEnabled)
            XCTAssertFalse(revoked.outputBusEnabled)
            XCTAssertTrue(revoked.recoveryRequired)
            XCTAssertFalse(revoked.hostedCallMode)
            XCTAssertNil(revoked.hostedCallOrigin)
            XCTAssertEqual(harness.configurationOperationCount, 0)
            XCTAssertFalse(harness.debugStartPlayoutForTesting())
            XCTAssertEqual(harness.configurationOperationCount, 0)
        }
    }

    func testHostedCallAuthorizationSeparatesPersistentOwnershipFromOneShotRecovery() {
        let policyID = UUID()
        let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: policyID,
            origin: .interruption
        )
        let counter = LockedInteger()

        XCTAssertEqual(authorization.policyID, policyID)
        XCTAssertEqual(authorization.origin, .interruption)
        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(authorization.isRecoveryPending)
        XCTAssertEqual(authorization.systemAudioGeneration, 0)

        XCTAssertTrue(
            authorization.performRecoveryIfValidForTesting {
                counter.increment()
            }
        )
        XCTAssertEqual(counter.value, 1)
        XCTAssertTrue(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertEqual(authorization.systemAudioGeneration, 0)

        XCTAssertFalse(
            authorization.performRecoveryIfValidForTesting {
                counter.increment()
            }
        )
        XCTAssertEqual(counter.value, 1)

        authorization.revoke()
        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertEqual(authorization.policyID, policyID)

        let revokedPolicyID = UUID()
        let revoked = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: revokedPolicyID,
            origin: .interruption
        )
        revoked.revoke()

        XCTAssertEqual(revoked.policyID, revokedPolicyID)
        XCTAssertEqual(revoked.origin, .interruption)
        XCTAssertFalse(revoked.isValid)
        XCTAssertFalse(revoked.isRecoveryPending)
        XCTAssertEqual(revoked.systemAudioGeneration, 0)
        XCTAssertFalse(
            revoked.performRecoveryIfValidForTesting {
                counter.increment()
            }
        )
        XCTAssertEqual(counter.value, 1)
    }

    func testHostedCallRequestWaitsForInterruptedFailCloseAndRejectsOrdinaryRecovery() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let policyID = UUID()
        let hostedAuthorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: policyID,
            origin: .interruption
        )
        defer { _ = harness.debugTerminateForTesting() }

        harness.debugMarkHealthyPlayoutForTesting()
        let healthy = harness.diagnostics
        XCTAssertTrue(healthy.sessionActive)
        XCTAssertFalse(
            healthy.remoteIOCreated,
            "The deterministic harness must not claim hardware AudioUnit creation."
        )
        XCTAssertFalse(healthy.inputBusEnabled)
        XCTAssertTrue(healthy.outputBusEnabled)
        XCTAssertFalse(healthy.recoveryRequired)
        XCTAssertFalse(healthy.explicitResumeRequired)
        XCTAssertTrue(healthy.categoryOptionsAreEmpty)
        XCTAssertFalse(healthy.categoryOptionsAreIPhoneMicrophoneRouting)
        XCTAssertFalse(healthy.categoryOptionsAreMixWithOthers)
        XCTAssertTrue(healthy.routeSharingPolicyIsDefault)
        XCTAssertTrue(healthy.hasOutputRoute)
        XCTAssertFalse(healthy.hostedCallMode)
        assertLastRecordedAudioConfiguration(
            harness,
            options: [],
            expectedOperationCount: 1
        )

        harness.queueHostedCallRecovery(authorization: hostedAuthorization)
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertTrue(harness.runNextQueuedOperation())
        XCTAssertEqual(harness.queuedOperationCount, 0)

        let afterHealthyRequest = harness.diagnostics
        XCTAssertEqual(afterHealthyRequest.requestCount, 1)
        XCTAssertEqual(afterHealthyRequest.authorizationRejectionCount, 0)
        XCTAssertEqual(afterHealthyRequest.rebuildCount, 0)
        XCTAssertTrue(afterHealthyRequest.sessionActive)
        XCTAssertFalse(afterHealthyRequest.remoteIOCreated)
        XCTAssertTrue(afterHealthyRequest.outputBusEnabled)
        XCTAssertFalse(afterHealthyRequest.hostedCallMode)
        XCTAssertFalse(afterHealthyRequest.hostedCallAuthorizationValid)
        XCTAssertFalse(afterHealthyRequest.hostedCallRecoveryPending)
        XCTAssertNil(harness.hostedCallPolicyID)
        XCTAssertTrue(hostedAuthorization.isValid)
        XCTAssertTrue(hostedAuthorization.isRecoveryPending)
        XCTAssertEqual(hostedAuthorization.systemAudioGeneration, 0)
        XCTAssertEqual(harness.configurationOperationCount, 1)

        harness.debugMarkInterruptedFailClosedForTesting()
        let microphoneAuthorization = WebRTCIOSMicrophoneAuthorization()
        harness.debugInstallMicrophoneAuthorizationForTesting(
            microphoneAuthorization
        )
        XCTAssertTrue(microphoneAuthorization.isValid)

        let ordinaryAuthorization = WebRTCIOSPlayoutRecoveryAuthorization()
        harness.queueRecovery(authorization: ordinaryAuthorization)
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertTrue(harness.runNextQueuedOperation())

        let afterOrdinaryRecovery = harness.diagnostics
        XCTAssertEqual(afterOrdinaryRecovery.requestCount, 2)
        XCTAssertEqual(afterOrdinaryRecovery.authorizationRejectionCount, 1)
        XCTAssertEqual(afterOrdinaryRecovery.rebuildCount, 0)
        XCTAssertFalse(ordinaryAuthorization.isValid)
        XCTAssertTrue(hostedAuthorization.isValid)
        XCTAssertTrue(hostedAuthorization.isRecoveryPending)
        XCTAssertEqual(hostedAuthorization.systemAudioGeneration, 0)
        assertQuiescentWithoutHostedCallPolicy(
            harness,
            recoveryRequired: true,
            explicitResumeRequired: false
        )

        harness.queueHostedCallRecovery(authorization: hostedAuthorization)
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertTrue(harness.runNextQueuedOperation())
        XCTAssertEqual(harness.queuedOperationCount, 0)

        let whileInterrupted = harness.diagnostics
        XCTAssertEqual(whileInterrupted.requestCount, 3)
        XCTAssertEqual(whileInterrupted.authorizationRejectionCount, 1)
        XCTAssertEqual(whileInterrupted.rebuildCount, 0)
        XCTAssertTrue(hostedAuthorization.isValid)
        XCTAssertTrue(hostedAuthorization.isRecoveryPending)
        XCTAssertEqual(hostedAuthorization.systemAudioGeneration, 0)
        assertQuiescentWithoutHostedCallPolicy(
            harness,
            recoveryRequired: true,
            explicitResumeRequired: false
        )

        harness.debugMarkInterruptionEndedFailClosedForTesting()

        harness.queueHostedCallRecovery(authorization: hostedAuthorization)
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertTrue(harness.runNextQueuedOperation())
        XCTAssertEqual(harness.queuedOperationCount, 0)

        let live = harness.diagnostics
        XCTAssertEqual(live.requestCount, 4)
        XCTAssertEqual(live.authorizationRejectionCount, 1)
        XCTAssertEqual(live.rebuildCount, 1)
        XCTAssertTrue(hostedAuthorization.isValid)
        XCTAssertFalse(hostedAuthorization.isRecoveryPending)
        XCTAssertFalse(microphoneAuthorization.isValid)
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())
        XCTAssertEqual(harness.hostedCallPolicyID, policyID)
        XCTAssertTrue(live.sessionActive)
        XCTAssertFalse(
            live.remoteIOCreated,
            "The hosted deterministic boundary records configuration but creates no AudioUnit."
        )
        XCTAssertFalse(live.inputBusEnabled)
        XCTAssertTrue(live.outputBusEnabled)
        XCTAssertFalse(live.recoveryRequired)
        XCTAssertFalse(live.explicitResumeRequired)
        XCTAssertFalse(live.categoryOptionsAreEmpty)
        XCTAssertTrue(live.categoryOptionsAreMixWithOthers)
        XCTAssertTrue(live.routeSharingPolicyIsDefault)
        XCTAssertTrue(live.hasOutputRoute)
        XCTAssertTrue(live.hostedCallMode)
        XCTAssertTrue(live.hostedCallAuthorizationValid)
        XCTAssertFalse(live.hostedCallRecoveryPending)
        XCTAssertGreaterThan(live.systemAudioGeneration, 0)
        XCTAssertEqual(
            live.hostedCallAuthorizationGeneration,
            live.systemAudioGeneration
        )
        XCTAssertEqual(
            hostedAuthorization.systemAudioGeneration,
            live.systemAudioGeneration
        )
        assertLastRecordedAudioConfiguration(
            harness,
            options: .mixWithOthers,
            expectedOperationCount: 2
        )
    }

    func testDuplicateQueuedHostedRequestCoalescesWithoutRetiringInstalledPolicy() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let policyID = UUID()
        let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: policyID,
            origin: .interruption
        )
        defer { _ = harness.debugTerminateForTesting() }

        harness.debugMarkInterruptedFailClosedForTesting()
        harness.debugMarkInterruptionEndedFailClosedForTesting()
        harness.queueHostedCallRecovery(authorization: authorization)
        harness.queueHostedCallRecovery(authorization: authorization)

        XCTAssertEqual(harness.queuedOperationCount, 2)
        XCTAssertEqual(harness.diagnostics.requestCount, 2)
        XCTAssertTrue(harness.runNextQueuedOperation())

        let installed = harness.diagnostics
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertEqual(installed.requestCount, 2)
        XCTAssertEqual(installed.authorizationRejectionCount, 0)
        XCTAssertEqual(installed.rebuildCount, 1)
        XCTAssertTrue(installed.hostedCallMode)
        XCTAssertTrue(installed.hostedCallAuthorizationValid)
        XCTAssertFalse(installed.hostedCallRecoveryPending)
        XCTAssertTrue(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertEqual(harness.hostedCallPolicyID, policyID)
        let installedGeneration = installed.systemAudioGeneration
        assertLastRecordedAudioConfiguration(
            harness,
            options: .mixWithOthers,
            expectedOperationCount: 1
        )

        XCTAssertTrue(harness.runNextQueuedOperation())
        XCTAssertEqual(harness.queuedOperationCount, 0)

        let coalesced = harness.diagnostics
        XCTAssertEqual(coalesced.requestCount, 2)
        XCTAssertEqual(coalesced.authorizationRejectionCount, 0)
        XCTAssertEqual(coalesced.rebuildCount, 1)
        XCTAssertEqual(coalesced.systemAudioGeneration, installedGeneration)
        XCTAssertTrue(coalesced.hostedCallMode)
        XCTAssertTrue(coalesced.hostedCallAuthorizationValid)
        XCTAssertFalse(coalesced.hostedCallRecoveryPending)
        XCTAssertTrue(coalesced.sessionActive)
        XCTAssertFalse(coalesced.remoteIOCreated)
        XCTAssertFalse(coalesced.inputBusEnabled)
        XCTAssertTrue(coalesced.outputBusEnabled)
        XCTAssertTrue(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertGreaterThan(authorization.systemAudioGeneration, 0)
        XCTAssertEqual(
            authorization.systemAudioGeneration,
            coalesced.systemAudioGeneration
        )
        XCTAssertEqual(harness.hostedCallPolicyID, policyID)
        assertLastRecordedAudioConfiguration(
            harness,
            options: .mixWithOthers,
            expectedOperationCount: 1
        )

        let differentAuthorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: UUID(),
            origin: .interruption
        )
        harness.queueHostedCallRecovery(authorization: differentAuthorization)
        XCTAssertTrue(harness.runNextQueuedOperation())

        let differentRejected = harness.diagnostics
        XCTAssertEqual(differentRejected.requestCount, 3)
        XCTAssertEqual(differentRejected.authorizationRejectionCount, 1)
        XCTAssertEqual(differentRejected.rebuildCount, 1)
        XCTAssertFalse(differentAuthorization.isValid)
        XCTAssertFalse(differentAuthorization.isRecoveryPending)
        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(differentRejected.hostedCallMode)
        XCTAssertTrue(differentRejected.hostedCallAuthorizationValid)
        XCTAssertEqual(harness.hostedCallPolicyID, policyID)
        assertLastRecordedAudioConfiguration(
            harness,
            options: .mixWithOthers,
            expectedOperationCount: 1
        )
    }

    func testHostedPolicyRejectsNewMicrophoneAuthorizationWithoutRetiringPlayout() {
        let (harness, hostedAuthorization) = makeLiveHostedCallHarness()
        let microphoneAuthorization = WebRTCIOSMicrophoneAuthorization()
        defer { _ = harness.debugTerminateForTesting() }
        let before = harness.diagnostics
        let configurationCount = harness.configurationOperationCount

        XCTAssertFalse(
            harness.setMicrophoneAuthorizationForTesting(
                microphoneAuthorization
            )
        )

        let after = harness.diagnostics
        XCTAssertFalse(microphoneAuthorization.isValid)
        XCTAssertTrue(hostedAuthorization.isValid)
        XCTAssertFalse(hostedAuthorization.isRecoveryPending)
        XCTAssertEqual(after.requestCount, before.requestCount)
        XCTAssertEqual(
            after.authorizationRejectionCount,
            before.authorizationRejectionCount
        )
        XCTAssertEqual(after.rebuildCount, before.rebuildCount)
        XCTAssertEqual(
            after.unexpectedRecordingRequestCount,
            before.unexpectedRecordingRequestCount + 1
        )
        XCTAssertTrue(after.hostedCallMode)
        XCTAssertTrue(after.hostedCallAuthorizationValid)
        XCTAssertFalse(after.inputBusEnabled)
        XCTAssertTrue(after.outputBusEnabled)
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())
        XCTAssertEqual(
            harness.configurationOperationCount,
            configurationCount
        )
        XCTAssertEqual(
            harness.hostedCallPolicyID,
            hostedAuthorization.policyID
        )
        assertLastRecordedAudioConfiguration(
            harness,
            options: .mixWithOthers,
            expectedOperationCount: configurationCount
        )
    }

    func testHostedRecoveryRejectsRevokedStaleMissingRouteAndActivationFailure() {
        do {
            let harness = WebRTCIOSPlayoutRecoveryTestHarness()
            let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
                policyID: UUID(),
                origin: .interruption
            )
            defer { _ = harness.debugTerminateForTesting() }

            harness.debugMarkInterruptedFailClosedForTesting()
            harness.queueHostedCallRecovery(authorization: authorization)
            XCTAssertEqual(harness.queuedOperationCount, 1)

            authorization.revoke()
            XCTAssertTrue(harness.runNextQueuedOperation())

            let rejected = harness.diagnostics
            XCTAssertEqual(rejected.requestCount, 1)
            XCTAssertEqual(rejected.authorizationRejectionCount, 1)
            XCTAssertEqual(rejected.rebuildCount, 0)
            XCTAssertFalse(authorization.isValid)
            XCTAssertFalse(authorization.isRecoveryPending)
            XCTAssertEqual(authorization.systemAudioGeneration, 0)
            assertQuiescentWithoutHostedCallPolicy(
                harness,
                recoveryRequired: true,
                explicitResumeRequired: false
            )
        }

        do {
            let harness = WebRTCIOSPlayoutRecoveryTestHarness()
            let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
                policyID: UUID(),
                origin: .interruption
            )
            defer { _ = harness.debugTerminateForTesting() }

            harness.debugMarkInterruptedFailClosedForTesting()
            let queuedGeneration = harness.diagnostics.systemAudioGeneration
            harness.queueHostedCallRecovery(authorization: authorization)
            harness.debugAdvanceSystemAudioGenerationForTesting()

            XCTAssertGreaterThan(
                harness.diagnostics.systemAudioGeneration,
                queuedGeneration
            )
            XCTAssertTrue(authorization.isValid)
            XCTAssertTrue(authorization.isRecoveryPending)
            XCTAssertTrue(harness.runNextQueuedOperation())

            let rejected = harness.diagnostics
            XCTAssertEqual(rejected.requestCount, 1)
            XCTAssertEqual(rejected.authorizationRejectionCount, 1)
            XCTAssertEqual(rejected.rebuildCount, 0)
            XCTAssertFalse(authorization.isValid)
            XCTAssertFalse(authorization.isRecoveryPending)
            XCTAssertEqual(authorization.systemAudioGeneration, 0)
            assertQuiescentWithoutHostedCallPolicy(
                harness,
                recoveryRequired: true,
                explicitResumeRequired: false
            )
        }

        do {
            let harness = WebRTCIOSPlayoutRecoveryTestHarness()
            let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
                policyID: UUID(),
                origin: .interruption
            )
            defer { _ = harness.debugTerminateForTesting() }

            harness.debugMarkInterruptedFailClosedForTesting()
            harness.debugMarkInterruptionEndedFailClosedForTesting()
            harness.debugSetOutputRouteAvailableForTesting(false)
            harness.queueHostedCallRecovery(authorization: authorization)
            XCTAssertTrue(harness.runNextQueuedOperation())

            let rejected = harness.diagnostics
            XCTAssertEqual(rejected.requestCount, 1)
            XCTAssertEqual(rejected.authorizationRejectionCount, 1)
            XCTAssertEqual(rejected.rebuildCount, 1)
            XCTAssertFalse(rejected.hasOutputRoute)
            XCTAssertFalse(authorization.isValid)
            XCTAssertFalse(authorization.isRecoveryPending)
            XCTAssertGreaterThan(authorization.systemAudioGeneration, 0)
            XCTAssertNotEqual(
                authorization.systemAudioGeneration,
                rejected.systemAudioGeneration
            )
            assertQuiescentWithoutHostedCallPolicy(
                harness,
                recoveryRequired: true,
                explicitResumeRequired: false
            )
        }

        do {
            let harness = WebRTCIOSPlayoutRecoveryTestHarness()
            let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
                policyID: UUID(),
                origin: .interruption
            )
            defer { _ = harness.debugTerminateForTesting() }

            harness.debugMarkInterruptedFailClosedForTesting()
            harness.debugMarkInterruptionEndedFailClosedForTesting()
            harness.debugFailNextHostedCallActivationForTesting()
            harness.queueHostedCallRecovery(authorization: authorization)
            XCTAssertTrue(harness.runNextQueuedOperation())

            let rejected = harness.diagnostics
            XCTAssertEqual(rejected.requestCount, 1)
            XCTAssertEqual(rejected.authorizationRejectionCount, 1)
            XCTAssertEqual(rejected.rebuildCount, 1)
            XCTAssertFalse(authorization.isValid)
            XCTAssertFalse(authorization.isRecoveryPending)
            XCTAssertGreaterThan(authorization.systemAudioGeneration, 0)
            XCTAssertNotEqual(
                authorization.systemAudioGeneration,
                rejected.systemAudioGeneration
            )
            assertQuiescentWithoutHostedCallPolicy(
                harness,
                recoveryRequired: true,
                explicitResumeRequired: false
            )
        }
    }

    func testHostedPolicyRetiresOnRouteLossGenerationAdvanceAndTeardown() {
        do {
            let (harness, authorization) = makeLiveHostedCallHarness()
            defer { _ = harness.debugTerminateForTesting() }
            let liveGeneration = harness.diagnostics.systemAudioGeneration

            harness.debugMarkRouteLossForTesting()

            let retired = harness.diagnostics
            XCTAssertEqual(retired.requestCount, 1)
            XCTAssertEqual(retired.authorizationRejectionCount, 0)
            XCTAssertEqual(retired.rebuildCount, 1)
            XCTAssertFalse(retired.hasOutputRoute)
            XCTAssertGreaterThan(retired.systemAudioGeneration, liveGeneration)
            XCTAssertFalse(authorization.isValid)
            XCTAssertFalse(authorization.isRecoveryPending)
            assertQuiescentWithoutHostedCallPolicy(
                harness,
                recoveryRequired: true,
                explicitResumeRequired: true
            )
        }

        do {
            let (harness, authorization) = makeLiveHostedCallHarness()
            defer { _ = harness.debugTerminateForTesting() }
            let liveGeneration = harness.diagnostics.systemAudioGeneration

            harness.debugAdvanceSystemAudioGenerationForTesting()

            let retired = harness.diagnostics
            XCTAssertEqual(retired.requestCount, 1)
            XCTAssertEqual(retired.authorizationRejectionCount, 0)
            XCTAssertEqual(retired.rebuildCount, 1)
            XCTAssertTrue(retired.hasOutputRoute)
            XCTAssertGreaterThan(retired.systemAudioGeneration, liveGeneration)
            XCTAssertFalse(authorization.isValid)
            XCTAssertFalse(authorization.isRecoveryPending)
            assertQuiescentWithoutHostedCallPolicy(
                harness,
                recoveryRequired: true,
                explicitResumeRequired: false
            )
        }

        do {
            let (harness, authorization) = makeLiveHostedCallHarness()
            let liveGeneration = harness.diagnostics.systemAudioGeneration

            XCTAssertTrue(harness.debugTerminateForTesting())

            let retired = harness.diagnostics
            XCTAssertEqual(retired.requestCount, 1)
            XCTAssertEqual(retired.authorizationRejectionCount, 0)
            XCTAssertEqual(retired.rebuildCount, 1)
            XCTAssertGreaterThan(retired.systemAudioGeneration, liveGeneration)
            XCTAssertFalse(authorization.isValid)
            XCTAssertFalse(authorization.isRecoveryPending)
            assertQuiescentWithoutHostedCallPolicy(
                harness,
                recoveryRequired: false,
                explicitResumeRequired: false
            )
        }
    }

    func testRevokingLiveHostedAuthorizationSynchronouslyRestoresFailClosedState() {
        let (harness, authorization) = makeLiveHostedCallHarness()
        defer { _ = harness.debugTerminateForTesting() }
        let live = harness.diagnostics

        authorization.revoke()

        let revoked = harness.diagnostics
        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertGreaterThan(revoked.systemAudioGeneration, live.systemAudioGeneration)
        XCTAssertEqual(revoked.requestCount, live.requestCount)
        XCTAssertEqual(
            revoked.authorizationRejectionCount,
            live.authorizationRejectionCount
        )
        XCTAssertEqual(revoked.rebuildCount, live.rebuildCount)
        XCTAssertEqual(harness.configurationOperationCount, 1)
        XCTAssertTrue(revoked.hasOutputRoute)
        assertQuiescentWithoutHostedCallPolicy(
            harness,
            recoveryRequired: true,
            explicitResumeRequired: false
        )
    }

    func testInterruptionEndedRetiresHostedPolicyAndOrdinaryRecoveryRestoresNormalConfiguration() {
        let (harness, hostedAuthorization) = makeLiveHostedCallHarness()
        defer { _ = harness.debugTerminateForTesting() }
        let live = harness.diagnostics
        let hostedConfigurationCount = harness.configurationOperationCount

        harness.debugMarkInterruptionEndedFailClosedForTesting()

        let ended = harness.diagnostics
        XCTAssertFalse(hostedAuthorization.isValid)
        XCTAssertFalse(hostedAuthorization.isRecoveryPending)
        XCTAssertEqual(ended.requestCount, live.requestCount)
        XCTAssertEqual(
            ended.authorizationRejectionCount,
            live.authorizationRejectionCount
        )
        XCTAssertEqual(ended.rebuildCount, live.rebuildCount)
        XCTAssertEqual(
            harness.configurationOperationCount,
            hostedConfigurationCount
        )
        assertQuiescentWithoutHostedCallPolicy(
            harness,
            recoveryRequired: true,
            explicitResumeRequired: false
        )

        let ordinaryAuthorization = WebRTCIOSPlayoutRecoveryAuthorization()
        harness.queueRecovery(authorization: ordinaryAuthorization)
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertTrue(harness.runNextQueuedOperation())

        let normal = harness.diagnostics
        XCTAssertFalse(ordinaryAuthorization.isValid)
        XCTAssertEqual(normal.requestCount, live.requestCount + 1)
        XCTAssertEqual(
            normal.authorizationRejectionCount,
            live.authorizationRejectionCount
        )
        XCTAssertEqual(normal.rebuildCount, live.rebuildCount + 1)
        XCTAssertTrue(normal.sessionActive)
        XCTAssertFalse(
            normal.remoteIOCreated,
            "Simulator recovery records the production operation without creating RemoteIO."
        )
        XCTAssertFalse(normal.inputBusEnabled)
        XCTAssertTrue(normal.outputBusEnabled)
        XCTAssertFalse(normal.recoveryRequired)
        XCTAssertFalse(normal.explicitResumeRequired)
        XCTAssertTrue(normal.categoryOptionsAreEmpty)
        XCTAssertFalse(normal.categoryOptionsAreIPhoneMicrophoneRouting)
        XCTAssertFalse(normal.categoryOptionsAreMixWithOthers)
        XCTAssertTrue(normal.routeSharingPolicyIsDefault)
        XCTAssertTrue(normal.hasOutputRoute)
        XCTAssertFalse(normal.hostedCallMode)
        XCTAssertFalse(normal.hostedCallAuthorizationValid)
        XCTAssertFalse(normal.hostedCallRecoveryPending)
        XCTAssertEqual(normal.hostedCallAuthorizationGeneration, 0)
        XCTAssertNil(harness.hostedCallPolicyID)
        assertLastRecordedAudioConfiguration(
            harness,
            options: [],
            expectedOperationCount: hostedConfigurationCount + 1
        )
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

    func testHostedCallInterruptionPreparationPreservesButNeverOpensTheManualGate() {
        let native = WebRTCAudioSessionStub()
        native.isAudioEnabled = true
        let playback = WebRTCAudioPlaybackSession(session: native)

        playback.prepareForHostedCallInterruption()
        playback.prepareForHostedCallInterruption()

        XCTAssertTrue(native.isAudioEnabled)
        XCTAssertEqual(native.prepareCount, 2)
        XCTAssertTrue(native.configuredModes.isEmpty)
        XCTAssertTrue(native.setActiveValues.isEmpty)
        XCTAssertEqual(native.lockCount, 0)
        XCTAssertEqual(native.unlockCount, 0)

        playback.prepareManualAudioDisabled()

        XCTAssertFalse(native.isAudioEnabled)
        XCTAssertEqual(native.prepareCount, 3)

        // Hosted-capable preparation preserves the current gate; it must not reopen a gate that a
        // route, media-services, failure, or terminal boundary already closed.
        playback.prepareForHostedCallInterruption()

        XCTAssertFalse(native.isAudioEnabled)
        XCTAssertEqual(native.prepareCount, 4)
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

    func testPublicMicrophonePolicyRejectsUnboundCapabilitiesBeforeNativeEffect()
        async throws
    {
        let viewer = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(
                role: .viewer,
                iceServers: []
            )
        )
        let nativePolicyCallCount = LockedInteger()
        await viewer.debugInstallIPhoneMicrophonePolicyApplier { _ in
            nativePolicyCallCount.increment()
            return true
        }

        let microphoneAuthorization = WebRTCIOSMicrophoneAuthorization()
        do {
            try await viewer.enableIPhoneMicrophone(
                authorization: microphoneAuthorization
            )
            XCTFail("An unbound public microphone authorization must fail closed.")
        } catch {
            XCTAssertFalse(microphoneAuthorization.isValid)
            XCTAssertNil(
                microphoneAuthorization.stagedTransactionTagGeneration
            )
        }

        let outputOnlyToken = WebRTCIOSOutputOnlyMicrophoneToken(
            ownerEpoch: UUID(),
            lifecycleGeneration: 1,
            target: WebRTCIOSOutputOnlyMicrophoneTarget(
                category: AVAudioSession.Category.playback.rawValue,
                mode: AVAudioSession.Mode.default.rawValue
            )
        )
        let outputOnlyApplied = await viewer.disableIPhoneMicrophone(
            outputOnlyToken: outputOnlyToken
        )

        XCTAssertFalse(outputOnlyApplied)
        XCTAssertEqual(outputOnlyToken.state, .revoked)
        XCTAssertNil(outputOnlyToken.stagedTransactionTagGeneration)
        XCTAssertEqual(nativePolicyCallCount.value, 0)
        let closeResult = await viewer.close()
        XCTAssertTrue(closeResult)
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
        let healthyRecoveryTransaction = WebRTCIOSAudioTransactionContext(
            operationID: try XCTUnwrap(
                UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")
            ),
            authorityEpoch: 1,
            operationRevision: 1
        )
        let healthyRecoveryAuthorization =
            WebRTCIOSPlayoutRecoveryAuthorization(
                transaction: healthyRecoveryTransaction
            )
        XCTAssertTrue(
            viewer.stageIOSPlayoutRecoveryTransaction(
                authorization: healthyRecoveryAuthorization,
                inputRequired: false
            )
        )
        XCTAssertNotNil(
            healthyRecoveryAuthorization.stagedTransactionTagGeneration
        )
        let healthyRecoveryWasRequested =
            await viewer.requestIOSPlayoutRecovery(
                authorization: healthyRecoveryAuthorization
            )
        XCTAssertTrue(healthyRecoveryWasRequested)
        try await Task.sleep(for: .milliseconds(50))
        let healthyRecoveryReceipt = try XCTUnwrap(
            healthyRecoveryAuthorization.terminalReceipt
        )
        XCTAssertEqual(
            healthyRecoveryReceipt.transaction,
            healthyRecoveryTransaction
        )
        XCTAssertEqual(healthyRecoveryReceipt.outcome, .accepted)
        XCTAssertTrue(
            healthyRecoveryReceipt.policyMatchesRequestedTarget
        )
        XCTAssertEqual(
            healthyRecoveryReceipt.authorizationGeneration,
            healthyRecoveryReceipt.terminalGeneration
        )
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

        let routeRecoveryTransaction = WebRTCIOSAudioTransactionContext(
            operationID: try XCTUnwrap(
                UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F")
            ),
            authorityEpoch: 1,
            operationRevision: 2
        )
        let routeRecoveryAuthorization =
            WebRTCIOSPlayoutRecoveryAuthorization(
                transaction: routeRecoveryTransaction
            )
        XCTAssertTrue(
            viewer.stageIOSPlayoutRecoveryTransaction(
                authorization: routeRecoveryAuthorization,
                inputRequired: false
            )
        )
        XCTAssertNotNil(
            routeRecoveryAuthorization.stagedTransactionTagGeneration
        )
        let routeRecoveryWasRequested =
            await viewer.requestIOSPlayoutRecovery(
                authorization: routeRecoveryAuthorization
            )
        XCTAssertTrue(routeRecoveryWasRequested)
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
        let routeRecoveryReceipt = try XCTUnwrap(
            routeRecoveryAuthorization.terminalReceipt
        )
        XCTAssertEqual(
            routeRecoveryReceipt.transaction,
            routeRecoveryTransaction
        )
        XCTAssertEqual(routeRecoveryReceipt.outcome, .accepted)
        XCTAssertTrue(routeRecoveryReceipt.policyMatchesRequestedTarget)
        XCTAssertEqual(
            routeRecoveryReceipt.authorizationGeneration,
            routeRecoveryReceipt.terminalGeneration
        )

        await host.close()
        await viewer.close()
        hostForwarder.cancel()
        viewerForwarder.cancel()
        #endif
    }

    // MARK: - Native diagnostics fixtures

    private func makeLiveHostedCallHarness(
        policyID: UUID = UUID()
    ) -> (
        harness: WebRTCIOSPlayoutRecoveryTestHarness,
        authorization: WebRTCIOSHostedCallPlayoutAuthorization
    ) {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: policyID,
            origin: .interruption
        )

        harness.debugMarkInterruptedFailClosedForTesting()
        harness.debugMarkInterruptionEndedFailClosedForTesting()
        harness.queueHostedCallRecovery(authorization: authorization)
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertTrue(harness.runNextQueuedOperation())

        let live = harness.diagnostics
        XCTAssertEqual(live.requestCount, 1)
        XCTAssertEqual(live.authorizationRejectionCount, 0)
        XCTAssertEqual(live.rebuildCount, 1)
        XCTAssertTrue(live.sessionActive)
        XCTAssertFalse(
            live.remoteIOCreated,
            "The deterministic harness is not a hardware RemoteIO oracle."
        )
        XCTAssertFalse(live.inputBusEnabled)
        XCTAssertTrue(live.outputBusEnabled)
        XCTAssertTrue(live.hostedCallMode)
        XCTAssertTrue(live.hostedCallAuthorizationValid)
        XCTAssertFalse(live.hostedCallRecoveryPending)
        XCTAssertTrue(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertEqual(harness.hostedCallPolicyID, policyID)
        assertLastRecordedAudioConfiguration(
            harness,
            options: .mixWithOthers,
            expectedOperationCount: 1
        )

        return (harness, authorization)
    }

    private func assertQuiescentWithoutHostedCallPolicy(
        _ harness: WebRTCIOSPlayoutRecoveryTestHarness,
        recoveryRequired: Bool,
        explicitResumeRequired: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let diagnostics = harness.diagnostics

        XCTAssertFalse(diagnostics.sessionActive, file: file, line: line)
        XCTAssertFalse(diagnostics.remoteIOCreated, file: file, line: line)
        XCTAssertFalse(diagnostics.inputBusEnabled, file: file, line: line)
        XCTAssertFalse(diagnostics.outputBusEnabled, file: file, line: line)
        XCTAssertEqual(
            diagnostics.recoveryRequired,
            recoveryRequired,
            file: file,
            line: line
        )
        XCTAssertEqual(
            diagnostics.explicitResumeRequired,
            explicitResumeRequired,
            file: file,
            line: line
        )
        XCTAssertFalse(diagnostics.hostedCallMode, file: file, line: line)
        XCTAssertFalse(
            diagnostics.hostedCallAuthorizationValid,
            file: file,
            line: line
        )
        XCTAssertFalse(
            diagnostics.hostedCallRecoveryPending,
            file: file,
            line: line
        )
        XCTAssertEqual(
            diagnostics.hostedCallAuthorizationGeneration,
            0,
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            diagnostics.systemAudioGeneration,
            0,
            file: file,
            line: line
        )
        XCTAssertNil(harness.hostedCallPolicyID, file: file, line: line)
    }

    private func assertLastRecordedAudioConfiguration(
        _ harness: WebRTCIOSPlayoutRecoveryTestHarness,
        options: AVAudioSession.CategoryOptions,
        expectedOperationCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            harness.configurationOperationCount,
            expectedOperationCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            harness.lastConfiguredCategory,
            AVAudioSession.Category.playback.rawValue,
            file: file,
            line: line
        )
        XCTAssertEqual(
            harness.lastConfiguredMode,
            AVAudioSession.Mode.default.rawValue,
            file: file,
            line: line
        )
        XCTAssertEqual(
            harness.lastConfiguredRouteSharingPolicy,
            Int(AVAudioSession.RouteSharingPolicy.default.rawValue),
            file: file,
            line: line
        )
        XCTAssertEqual(
            harness.lastConfiguredCategoryOptions,
            UInt(options.rawValue),
            file: file,
            line: line
        )
        XCTAssertFalse(
            harness.lastConfiguredInputBusEnabled,
            file: file,
            line: line
        )
        XCTAssertTrue(
            harness.lastConfiguredOutputBusEnabled,
            file: file,
            line: line
        )

        let format = harness.lastConfiguredOutputStreamFormat
        XCTAssertEqual(
            format.mSampleRate,
            48_000,
            accuracy: 0.001,
            file: file,
            line: line
        )
        XCTAssertEqual(
            format.mFormatID,
            kAudioFormatLinearPCM,
            file: file,
            line: line
        )
        XCTAssertEqual(
            format.mFormatFlags,
            kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            file: file,
            line: line
        )
        XCTAssertEqual(format.mBytesPerPacket, 4, file: file, line: line)
        XCTAssertEqual(format.mFramesPerPacket, 1, file: file, line: line)
        XCTAssertEqual(format.mBytesPerFrame, 4, file: file, line: line)
        XCTAssertEqual(format.mChannelsPerFrame, 2, file: file, line: line)
        XCTAssertEqual(format.mBitsPerChannel, 16, file: file, line: line)
        XCTAssertEqual(format.mReserved, 0, file: file, line: line)
    }

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
