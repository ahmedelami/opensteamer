import AVFAudio
import Dispatch
import IOSWebRTCAudioDeviceShim
import RemoteSessionCore
import XCTest
@testable import opensteamer
@testable import WebRTCTransport

/// State-machine tests for worldwide background playback, interruptions, calls, and runtime proof.
/// Every fixture records both native-device and per-track gates; playback is considered active only
/// when transport health and fresh RemoteIO evidence satisfy the policy for the current generation.
@MainActor
final class WorldwideAudioLifecycleTests: XCTestCase {
    private static let iPhoneMicrophoneCategoryOptionsRawValue =
        AVAudioSession.CategoryOptions.defaultToSpeaker
            .union(.allowBluetoothA2DP)
            .rawValue

    private enum RawMicrophoneReadRevocationBoundary:
        String,
        CaseIterable
    {
        case callStart
        case manualMicrophoneOff
        case permissionDenial
        case transportUncertainty
        case audioPolicyRotation
        case peerReplacement
        case teardown
    }

    private enum PrematureMacHostedCallChallengeOutcome: Equatable {
        case localSuccess
        case localFailure
    }

    func testWorldwidePlaybackConfigurationUsesOnlyValidExplicitOptions() {
        let configuration = WebRTCAudioPlaybackSession.playbackConfiguration()

        XCTAssertEqual(configuration.category, AVAudioSession.Category.playback.rawValue)
        XCTAssertEqual(configuration.mode, AVAudioSession.Mode.default.rawValue)
        XCTAssertEqual(configuration.categoryOptions, [])
        XCTAssertFalse(configuration.categoryOptions.contains(.mixWithOthers))
        XCTAssertFalse(configuration.categoryOptions.contains(.allowAirPlay))
        XCTAssertGreaterThan(configuration.inputNumberOfChannels, 0)
        XCTAssertEqual(configuration.outputNumberOfChannels, 2)
    }

    func testOrdinaryPlayoutLivenessRecoversFrozenRenderCallbacks() {
        let sessionGeneration = UUID()
        let audioPolicyGeneration = UUID()
        let peerIdentity = ObjectIdentifier(self)
        var tracker = IOSOrdinaryPlayoutLivenessTracker()

        XCTAssertEqual(
            tracker.observe(
                sessionGeneration: sessionGeneration,
                audioPolicyGeneration: audioPolicyGeneration,
                peerIdentity: peerIdentity,
                collectedAt: Date(timeIntervalSince1970: 0),
                oracle: ordinaryLivenessOracle(
                    sessionGeneration: sessionGeneration,
                    audioPolicyGeneration: audioPolicyGeneration,
                    callbacks: 10,
                    frames: 4_800,
                    pcmNonzero: 1_000,
                    pcmAbsolute: 1_000_000,
                    inboundEnergy: 1
                )
            ),
            .waiting
        )
        XCTAssertEqual(
            tracker.observe(
                sessionGeneration: sessionGeneration,
                audioPolicyGeneration: audioPolicyGeneration,
                peerIdentity: peerIdentity,
                collectedAt: Date(timeIntervalSince1970: 1),
                oracle: ordinaryLivenessOracle(
                    sessionGeneration: sessionGeneration,
                    audioPolicyGeneration: audioPolicyGeneration,
                    callbacks: 10,
                    frames: 4_800,
                    pcmNonzero: 1_000,
                    pcmAbsolute: 1_000_000,
                    inboundEnergy: 1
                )
            ),
            .waiting
        )
        XCTAssertEqual(
            tracker.observe(
                sessionGeneration: sessionGeneration,
                audioPolicyGeneration: audioPolicyGeneration,
                peerIdentity: peerIdentity,
                collectedAt: Date(timeIntervalSince1970: 2),
                oracle: ordinaryLivenessOracle(
                    sessionGeneration: sessionGeneration,
                    audioPolicyGeneration: audioPolicyGeneration,
                    callbacks: 10,
                    frames: 4_800,
                    pcmNonzero: 1_000,
                    pcmAbsolute: 1_000_000,
                    inboundEnergy: 1
                )
            ),
            .waiting
        )
        XCTAssertEqual(
            tracker.observe(
                sessionGeneration: sessionGeneration,
                audioPolicyGeneration: audioPolicyGeneration,
                peerIdentity: peerIdentity,
                collectedAt: Date(timeIntervalSince1970: 4.6),
                oracle: ordinaryLivenessOracle(
                    sessionGeneration: sessionGeneration,
                    audioPolicyGeneration: audioPolicyGeneration,
                    callbacks: 10,
                    frames: 4_800,
                    pcmNonzero: 1_000,
                    pcmAbsolute: 1_000_000,
                    inboundEnergy: 1
                )
            ),
            .recover(.callbacksFrozen)
        )
    }

    func testOrdinaryPlayoutLivenessRecoversInboundEnergyWithoutPCM() {
        let sessionGeneration = UUID()
        let audioPolicyGeneration = UUID()
        let peerIdentity = ObjectIdentifier(self)
        var tracker = IOSOrdinaryPlayoutLivenessTracker()

        let observations: [(TimeInterval, UInt64, UInt64, Double)] = [
            (0, 10, 4_800, 1),
            (1, 11, 5_280, 1.1),
            (4.6, 12, 5_760, 1.2),
        ]
        let results = observations.map { time, callbacks, frames, energy in
            tracker.observe(
                sessionGeneration: sessionGeneration,
                audioPolicyGeneration: audioPolicyGeneration,
                peerIdentity: peerIdentity,
                collectedAt: Date(timeIntervalSince1970: time),
                oracle: ordinaryLivenessOracle(
                    sessionGeneration: sessionGeneration,
                    audioPolicyGeneration: audioPolicyGeneration,
                    callbacks: callbacks,
                    frames: frames,
                    pcmNonzero: 1_000,
                    pcmAbsolute: 1_000_000,
                    inboundEnergy: energy
                )
            )
        }

        XCTAssertEqual(results[0], .waiting)
        XCTAssertEqual(results[1], .waiting)
        XCTAssertEqual(
            results[2],
            .recover(.inboundEnergyWithoutPCM)
        )
    }

    func testOrdinaryPlayoutLivenessAcceptsAdvancingCallbacksDuringSourceSilence() {
        let sessionGeneration = UUID()
        let audioPolicyGeneration = UUID()
        let peerIdentity = ObjectIdentifier(self)
        var tracker = IOSOrdinaryPlayoutLivenessTracker()

        _ = tracker.observe(
            sessionGeneration: sessionGeneration,
            audioPolicyGeneration: audioPolicyGeneration,
            peerIdentity: peerIdentity,
            collectedAt: Date(timeIntervalSince1970: 0),
            oracle: ordinaryLivenessOracle(
                sessionGeneration: sessionGeneration,
                audioPolicyGeneration: audioPolicyGeneration,
                callbacks: 10,
                frames: 4_800,
                pcmNonzero: 0,
                pcmAbsolute: 0,
                inboundEnergy: 0
            )
        )
        XCTAssertEqual(
            tracker.observe(
                sessionGeneration: sessionGeneration,
                audioPolicyGeneration: audioPolicyGeneration,
                peerIdentity: peerIdentity,
                collectedAt: Date(timeIntervalSince1970: 1),
                oracle: ordinaryLivenessOracle(
                    sessionGeneration: sessionGeneration,
                    audioPolicyGeneration: audioPolicyGeneration,
                    callbacks: 11,
                    frames: 5_280,
                    pcmNonzero: 0,
                    pcmAbsolute: 0,
                    inboundEnergy: 0
                )
            ),
            .healthy
        )
    }

    func testMicrophoneTopologyCategoryOptionsMatchNativeShimContract() throws {
        // IOSWebRTCAudioDeviceShim's ASIPhoneMicrophoneCategoryOptions uses this exact union.
        XCTAssertEqual(
            Self.iPhoneMicrophoneCategoryOptionsRawValue,
            0x28
        )

        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        fixture.controller.prepare(serverName: "Mac mini")

        fixture.controller.beginMicrophoneTopologyTransition(
            isEnabled: true
        )
        let microphoneChange = try XCTUnwrap(
            fixture.events.lastArmedCategoryChange
        )
        XCTAssertEqual(
            microphoneChange.category,
            AVAudioSession.Category.playAndRecord.rawValue
        )
        XCTAssertEqual(
            microphoneChange.categoryOptionsRawValue,
            Self.iPhoneMicrophoneCategoryOptionsRawValue
        )

        fixture.events.onEngineConfigurationChanged?()
        let microphoneRecovery = try XCTUnwrap(
            fixture.events.lastArmedCategoryChange
        )
        XCTAssertEqual(
            microphoneRecovery.category,
            AVAudioSession.Category.playAndRecord.rawValue
        )
        XCTAssertEqual(
            microphoneRecovery.categoryOptionsRawValue,
            Self.iPhoneMicrophoneCategoryOptionsRawValue
        )

        fixture.controller.beginMicrophoneTopologyTransition(
            isEnabled: false
        )
        let outputOnlyChange = try XCTUnwrap(
            fixture.events.lastArmedCategoryChange
        )
        XCTAssertEqual(
            outputOnlyChange.category,
            AVAudioSession.Category.playback.rawValue
        )
        XCTAssertEqual(outputOnlyChange.categoryOptionsRawValue, 0)
    }

    func testNativeMicrophoneStageFailurePrecedenceKeepsLifecycleBoundariesFailClosed() {
        let harness = ASIOSStereoPlayoutRecoveryTestHarness()

        XCTAssertEqual(
            harness.debugClassifyMicrophoneStageFailureForTesting(
                wantsPlayout: false,
                interrupted: true,
                explicitResumeRequired: true,
                recoveryRequired: true
            ),
            .interrupted
        )
        XCTAssertEqual(
            harness.debugClassifyMicrophoneStageFailureForTesting(
                wantsPlayout: false,
                interrupted: false,
                explicitResumeRequired: true,
                recoveryRequired: true
            ),
            .explicitResumeRequired
        )
        XCTAssertEqual(
            harness.debugClassifyMicrophoneStageFailureForTesting(
                wantsPlayout: false,
                interrupted: false,
                explicitResumeRequired: false,
                recoveryRequired: true
            ),
            .nativeRecoveryRequired
        )
        XCTAssertEqual(
            harness.debugClassifyMicrophoneStageFailureForTesting(
                wantsPlayout: false,
                interrupted: false,
                explicitResumeRequired: false,
                recoveryRequired: false
            ),
            .playoutNotReady
        )
    }

    func testMicrophoneAdmissionFailurePreservesExactNativeRouteEvidence() async throws {
        let peer = try makeAudioRacePeer()
        let diagnostics = iosPlayoutDiagnostics(
            callbacks: 0,
            frames: 0,
            failures: 1,
            failureCode: 4,
            lastLifecycleStatus: kAudio_ParamError,
            initialized: true,
            playoutInitialized: false,
            playing: false,
            sessionActive: false,
            ownsSessionActivation: false,
            remoteIOCreated: false,
            inputBusEnabled: false,
            outputBusEnabled: false,
            categoryIsMediaPlayback: false,
            categoryIsMediaPlayAndRecord: true,
            sampleRate: 48_000,
            outputChannelCount: 1,
            failureMessage:
                "The active route cannot satisfy the 48 kHz stereo output policy (output=1, input=1)."
        )
        await peer.debugInstallIPhoneMicrophoneStageFailureForTesting(
            diagnostics
        )
        let authorization = WebRTCIOSMicrophoneAuthorization()
        let capturedError: WebRTCTransportError?

        do {
            try await peer
                .debugEnableIPhoneMicrophoneThroughNativeStageForTesting(
                    authorization
                )
            capturedError = nil
            XCTFail("The injected zero-generation native stage must fail.")
        } catch let error as WebRTCTransportError {
            capturedError = error
        }

        guard case .nativeFailure(let description) = capturedError else {
            await peer.close()
            return XCTFail("Expected the exact native stage failure.")
        }

        XCTAssertTrue(description.contains("code=4"))
        XCTAssertTrue(description.contains("status=-50"))
        XCTAssertTrue(description.contains("category=playAndRecord"))
        XCTAssertTrue(description.contains("outputChannels=1"))
        XCTAssertTrue(description.contains("output=1, input=1"))
        XCTAssertNotEqual(
            description,
            "The current iPhone route could not stage the authorized microphone topology."
        )
        XCTAssertFalse(authorization.isValid)
        await peer.close()
    }

    func testMicrophoneAdmissionFailurePreservesTypedNativeStageReason() async throws {
        let peer = try makeAudioRacePeer()
        let diagnostics = iosPlayoutDiagnostics(
            callbacks: 0,
            frames: 0,
            failures: 1,
            failureCode: 4,
            lastLifecycleStatus: kAudio_ParamError,
            initialized: true,
            playoutInitialized: false,
            playing: false,
            sessionActive: false,
            ownsSessionActivation: false,
            remoteIOCreated: false,
            inputBusEnabled: false,
            outputBusEnabled: false,
            categoryIsMediaPlayback: false,
            categoryIsMediaPlayAndRecord: true,
            sampleRate: 48_000,
            outputChannelCount: 1,
            failureMessage: "Injected startup topology failure."
        )
        await peer.debugInstallIPhoneMicrophoneStageFailureForTesting(
            diagnostics,
            reason: .playoutNotReady
        )
        let authorization = WebRTCIOSMicrophoneAuthorization()
        let capturedError: WebRTCTransportError?

        do {
            try await peer
                .debugEnableIPhoneMicrophoneThroughNativeStageForTesting(
                    authorization
                )
            capturedError = nil
            XCTFail("The injected typed native stage must fail.")
        } catch let error as WebRTCTransportError {
            capturedError = error
        }

        guard case .iPhoneMicrophoneStageFailed(
            reason: .playoutNotReady,
            message: let description
        ) = capturedError else {
            await peer.close()
            return XCTFail("Expected the exact typed native stage failure.")
        }
        XCTAssertTrue(description.contains("code=4"))
        XCTAssertTrue(description.contains("status=-50"))
        XCTAssertTrue(description.contains("Injected startup topology failure"))
        XCTAssertFalse(authorization.isValid)
        await peer.close()
    }

    func testLegacyLongFormPlaybackConfigurationUsesNoExplicitOptions() {
        XCTAssertEqual(AudioSessionManager.playbackCategory, .playback)
        XCTAssertEqual(AudioSessionManager.playbackMode, .moviePlayback)
        XCTAssertEqual(AudioSessionManager.playbackRouteSharingPolicy, .longFormAudio)
        XCTAssertTrue(AudioSessionManager.playbackCategoryOptions.isEmpty)
    }

    func testPhysicalDeviceCanConfigureLegacyBackgroundPlaybackSession() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip(
            "AVAudioSession route validation must run on a physical iPhone; "
                + "Simulator audio does not exercise the hardware session boundary."
        )
        #else
        let manager = AudioSessionManager()
        defer { manager.deactivate() }

        try manager.activate()

        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .moviePlayback)
        XCTAssertEqual(session.routeSharingPolicy, .longFormAudio)
        XCTAssertGreaterThan(session.sampleRate, 0)
        #endif
    }

    func testBackgroundLifecycleKeepsPlaybackPreparedAndNeverDeactivates() {
        let fixture = makeFixture()
        var snapshots: [WorldwideAudioLifecycleSnapshot] = []
        fixture.controller.onSnapshotChanged = { snapshots.append($0) }

        fixture.controller.prepare(serverName: "Office Mac")
        XCTAssertEqual(fixture.playback.activateCount, 1)
        XCTAssertEqual(fixture.events.startCount, 1)
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Waiting for Mac audio")
        XCTAssertFalse(fixture.background.publications.last?.isPlaying ?? true)

        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Reconnecting audio")
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.controller.transportBecameHealthy()
        XCTAssertEqual(fixture.playback.recoverCount, 1)
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Playing")
        XCTAssertTrue(fixture.controller.snapshot.isPlaying)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)

        fixture.controller.appBecameInactive()
        fixture.controller.appEnteredBackground()

        XCTAssertEqual(fixture.background.beginCount, 2)
        XCTAssertEqual(fixture.playback.recoverCount, 2)
        XCTAssertEqual(fixture.playback.deactivateCount, 0)
        XCTAssertEqual(fixture.events.stopCount, 0)
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Playing")
        XCTAssertTrue(fixture.background.publications.last?.isPlaying ?? false)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)

        fixture.controller.appBecameActive()
        XCTAssertEqual(fixture.playback.recoverCount, 3)
        XCTAssertGreaterThanOrEqual(fixture.background.endCount, 1)
        XCTAssertEqual(fixture.playback.deactivateCount, 0)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)

        fixture.controller.stop()
        XCTAssertEqual(fixture.playback.deactivateCount, 1)
        XCTAssertEqual(fixture.events.stopCount, 1)
        XCTAssertEqual(fixture.background.clearCount, 1)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(fixture.controller.snapshot, inactiveSnapshot)
        XCTAssertEqual(snapshots.last, inactiveSnapshot)
    }

    func testConnectedCallAtStartupStaysClosedUntilNativeArmAndHostedProof() throws {
        let fixture = makeFixture(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        var order: [String] = []
        var hostedAuthorization:
            WebRTCIOSHostedCallPlayoutAuthorization?
        fixture.controller.onCallActivityChanged = { isActive in
            order.append(isActive ? "call-active" : "call-inactive")
        }
        fixture.controller.onHostedCallPlayoutRecoveryRequested = {
            hostedAuthorization = $0
            order.append("hosted")
        }

        fixture.controller.prepare(serverName: "Mac mini")

        let authorization = try XCTUnwrap(hostedAuthorization)
        XCTAssertEqual(order, ["call-active", "hosted"])
        XCTAssertEqual(authorization.origin, .startupConnectedCall)
        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(authorization.isRecoveryPending)
        XCTAssertEqual(authorization.systemAudioGeneration, 0)
        XCTAssertEqual(fixture.callActivity.startCount, 1)
        XCTAssertEqual(fixture.playback.activateCount, 0)
        XCTAssertEqual(fixture.playback.recoverCount, 0)
        XCTAssertEqual(fixture.playback.prepareManualAudioDisabledCount, 1)
        XCTAssertEqual(fixture.playback.activateArmedHostedCallPlayoutCount, 0)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())

        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        fixture.controller.updateHostedCallRuntimePlayout(
            policyID: authorization.policyID,
            isReady: true
        )

        XCTAssertEqual(fixture.playback.recoverCount, 0)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Starting playback"
        )

        let scopeID = try XCTUnwrap(
            fixture.controller.hostedCallScopeID(for: authorization)
        )
        XCTAssertTrue(
            authorization.performRecoveryIfValidForTesting(
                systemAudioGeneration: 0xCA11_5001,
                revocationHandler: {}
            )
        )
        XCTAssertTrue(
            fixture.controller.activateArmedStartupConnectedCallPlayout(
                scopeID: scopeID,
                policyID: authorization.policyID,
                authorization: authorization
            )
        )
        XCTAssertEqual(
            fixture.playback.activateArmedHostedCallPlayoutCount,
            1
        )
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)

        fixture.controller.updateHostedCallRuntimePlayout(
            policyID: authorization.policyID,
            isReady: true
        )

        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertTrue(fixture.controller.snapshot.isPlaying)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Playing — iPhone call may reduce quality"
        )
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())
    }

    func testTrackArrivingDuringPendingStartupHostedPolicyCannotStartOrdinaryProof() throws {
        let fixture = makeFixture(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        let arrivingTrack = RemoteAudioStub(initiallyEnabled: true)
        var authorization:
            WebRTCIOSHostedCallPlayoutAuthorization?
        var proofInvalidations: [Bool] = []
        fixture.controller.onHostedCallPlayoutRecoveryRequested = {
            authorization = $0
        }
        fixture.controller.onAudioProofInvalidated = {
            proofInvalidations.append($0)
        }

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(arrivingTrack)
        fixture.controller.transportBecameHealthy()

        let pending = try XCTUnwrap(authorization)
        XCTAssertEqual(pending.origin, .startupConnectedCall)
        XCTAssertTrue(pending.isRecoveryPending)
        XCTAssertFalse(arrivingTrack.isEnabled)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertEqual(fixture.playback.activateCount, 0)
        XCTAssertEqual(fixture.playback.recoverCount, 0)
        XCTAssertEqual(proofInvalidations, [true])
        XCTAssertTrue(fixture.controller.snapshot.isRemoteAudioAvailable)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
    }

    func testRingingOnlyCallAtStartupUsesOrdinaryBestEffortPlayoutWithMicrophoneClosed() {
        let fixture = makeFixture(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 0
        )
        var hostedRequestCount = 0
        fixture.controller.onHostedCallPlayoutRecoveryRequested = { _ in
            hostedRequestCount += 1
        }

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()

        XCTAssertEqual(hostedRequestCount, 0)
        XCTAssertEqual(fixture.playback.activateCount, 1)
        XCTAssertEqual(fixture.playback.recoverCount, 1)
        XCTAssertEqual(fixture.playback.prepareManualAudioDisabledCount, 0)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertTrue(fixture.controller.snapshot.isPlaying)
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Playing — iPhone call may reduce quality"
        )
    }

    func testStartupConnectedCallAuthorizationIsReplacedByFreshInterruptionOrigin() throws {
        let fixture = makeFixture(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        var authorizations: [WebRTCIOSHostedCallPlayoutAuthorization] = []
        fixture.controller.onHostedCallPlayoutRecoveryRequested = {
            authorizations.append($0)
        }

        fixture.controller.prepare(serverName: "Mac mini")
        let startup = try XCTUnwrap(authorizations.first)
        let startupScope = try XCTUnwrap(
            fixture.controller.hostedCallScopeID(for: startup)
        )

        fixture.events.onInterruptionBegan?(.default)

        XCTAssertEqual(authorizations.count, 2)
        let interruption = authorizations[1]
        XCTAssertEqual(startup.origin, .startupConnectedCall)
        XCTAssertFalse(startup.isValid)
        XCTAssertEqual(interruption.origin, .interruption)
        XCTAssertTrue(interruption.isValid)
        XCTAssertTrue(interruption.isRecoveryPending)
        XCTAssertNotEqual(interruption.policyID, startup.policyID)
        XCTAssertNotEqual(
            try XCTUnwrap(
                fixture.controller.hostedCallScopeID(for: interruption)
            ),
            startupScope
        )
        XCTAssertEqual(
            fixture.playback.prepareForHostedCallInterruptionCount,
            1
        )
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
    }

    func testConnectedCallStartupEndRevokesOwnershipAndBeginsFreshOrdinaryRecovery() throws {
        let fixture = makeFixture(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        var startupAuthorization:
            WebRTCIOSHostedCallPlayoutAuthorization?
        fixture.controller.onHostedCallPlayoutRecoveryRequested = {
            startupAuthorization = $0
        }

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        let startup = try XCTUnwrap(startupAuthorization)

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 0,
            connectedNonEndedCallCount: 0
        )

        XCTAssertFalse(startup.isValid)
        XCTAssertNil(fixture.controller.hostedCallScopeID(for: startup))
        XCTAssertEqual(fixture.playback.activateCount, 0)
        XCTAssertEqual(fixture.playback.activateArmedHostedCallPlayoutCount, 0)
        XCTAssertEqual(fixture.playback.recoverCount, 1)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertTrue(fixture.controller.snapshot.isPlaying)
        XCTAssertTrue(fixture.controller.microphoneActivationIsAllowed())
    }

    func testFailedStartupHostedPolicyStaysClosedUntilConnectedCallEnds() throws {
        let fixture = makeFixture(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        var startupAuthorization:
            WebRTCIOSHostedCallPlayoutAuthorization?
        fixture.controller.onHostedCallPlayoutRecoveryRequested = {
            startupAuthorization = $0
        }

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        let startup = try XCTUnwrap(startupAuthorization)

        fixture.controller.failHostedCallRuntimePlayout(
            policyID: startup.policyID,
            authorization: startup,
            failureMessage: "Hosted startup failed",
            diagnostic: "Deterministic startup proof failure"
        )
        fixture.controller.appBecameActive()
        fixture.events.onRouteChanged?("Audio route changed")

        XCTAssertFalse(startup.isValid)
        XCTAssertEqual(fixture.playback.recoverCount, 0)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 0,
            connectedNonEndedCallCount: 0
        )

        XCTAssertEqual(fixture.playback.recoverCount, 1)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertTrue(fixture.controller.snapshot.isPlaying)
    }

    func testHostedCategoryNotificationCannotSubstituteForExactRuntimeProof() throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        fixture.controller.updateRuntimePlayout(isReady: true)
        fixture.controller.beginMicrophoneTopologyTransition(
            isEnabled: false
        )
        let predecessorOperationID = try XCTUnwrap(
            fixture.events.lastArmedCategoryChange?.operationID
        )
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        var hostedAuthorization:
            WebRTCIOSHostedCallPlayoutAuthorization?
        fixture.controller.onHostedCallPlayoutRecoveryRequested = {
            hostedAuthorization = $0
        }

        fixture.events.onInterruptionBegan?(.default)
        let authorization = try XCTUnwrap(hostedAuthorization)
        let armedChange = try XCTUnwrap(
            fixture.events.lastArmedCategoryChange
        )
        let hostedChange = AudioSessionCategoryChange(
            category: AVAudioSession.Category.playback.rawValue,
            mode: AVAudioSession.Mode.default.rawValue,
            categoryOptionsRawValue:
                AVAudioSession.CategoryOptions.mixWithOthers.rawValue,
            operationID: armedChange.operationID
        )

        fixture.events.onCategoryChanged?(
            AudioSessionCategoryChange(
                category: hostedChange.category,
                mode: hostedChange.mode,
                categoryOptionsRawValue:
                    hostedChange.categoryOptionsRawValue,
                operationIDIsAmbiguous: true,
                ambiguousPredecessorOperationID:
                    predecessorOperationID
            )
        )
        XCTAssertTrue(authorization.isValid)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)

        // Even a manager-inferred exact operation ID remains observational because the OS
        // notification itself carried no causal ID.
        fixture.events.onCategoryChanged?(hostedChange)
        XCTAssertTrue(authorization.isValid)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)

        // This empty closure consumes only the lifecycle authorization boundary. The separate
        // runtime callback below represents the exact native diagnostics boundary.
        XCTAssertTrue(
            authorization.performRecoveryIfValidForTesting {}
        )
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.controller.updateHostedCallRuntimePlayout(
            policyID: authorization.policyID,
            isReady: false
        )

        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Starting playback"
        )
    }

    func testLiveCallPreflightBlocksMicrophoneWithoutMutingPlayout() {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        let recoverCountBeforeCall = fixture.playback.recoverCount

        fixture.callActivity.stageLiveNonEndedCallCountWithoutCallback(1)

        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())
        XCTAssertEqual(fixture.playback.recoverCount, recoverCountBeforeCall)
        XCTAssertEqual(fixture.playback.prepareManualAudioDisabledCount, 0)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Playing — iPhone call may reduce quality"
        )
    }

    func testRealWebRTCPlaybackPreservesDefaultInterruptionDeviceForOneHostedRequest() {
        let native = CrossLayerWebRTCAudioSessionStub()
        let playback = WebRTCAudioPlaybackSession(session: native)
        let background = CrossLayerBackgroundPlaybackStub()
        let events = CrossLayerAudioSessionEventMonitorStub()
        let callActivity = CallActivityStub()
        let remoteAudio = RemoteAudioStub(initiallyEnabled: true)
        let controller = WorldwideAudioLifecycleController(
            playback: playback,
            backgroundPlayback: background,
            events: events,
            callActivity: callActivity
        )
        var proofInvalidations: [Bool] = []
        var hostedRequestCount = 0
        controller.onAudioProofInvalidated = {
            proofInvalidations.append($0)
        }
        controller.onHostedCallPlayoutRecoveryRequested = { _ in
            hostedRequestCount += 1
        }

        controller.prepare(serverName: "Mac mini")
        controller.remoteAudioBecameAvailable(remoteAudio)
        controller.transportBecameHealthy()
        controller.updateRuntimePlayout(isReady: true)

        XCTAssertTrue(native.isAudioEnabled)
        XCTAssertTrue(remoteAudio.isEnabled)
        XCTAssertTrue(controller.snapshot.isPlaying)
        XCTAssertEqual(native.prepareCount, 2)

        events.onInterruptionBegan?(.default)

        XCTAssertTrue(native.isAudioEnabled)
        XCTAssertEqual(native.prepareCount, 3)
        XCTAssertTrue(native.configuredModes.isEmpty)
        XCTAssertTrue(native.setActiveValues.isEmpty)
        XCTAssertEqual(proofInvalidations, [false, true])
        XCTAssertFalse(remoteAudio.isEnabled)
        XCTAssertFalse(controller.snapshot.isPlaying)
        XCTAssertEqual(controller.snapshot.stateText, "Interrupted")
        XCTAssertEqual(hostedRequestCount, 0)

        callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )

        XCTAssertEqual(hostedRequestCount, 1)
        XCTAssertTrue(native.isAudioEnabled)
        XCTAssertFalse(remoteAudio.isEnabled)
        XCTAssertFalse(controller.snapshot.isPlaying)

        callActivity.setCallSnapshot(
            nonEndedCallCount: 2,
            connectedNonEndedCallCount: 1
        )

        XCTAssertEqual(hostedRequestCount, 1)

        controller.stop()

        XCTAssertFalse(native.isAudioEnabled)
    }

    func testRealWebRTCPlaybackClosesGateForNonHostedAndSystemBoundaries() {
        func makeController() -> (
            controller: WorldwideAudioLifecycleController,
            native: CrossLayerWebRTCAudioSessionStub,
            events: CrossLayerAudioSessionEventMonitorStub
        ) {
            let native = CrossLayerWebRTCAudioSessionStub()
            let events = CrossLayerAudioSessionEventMonitorStub()
            let controller = WorldwideAudioLifecycleController(
                playback: WebRTCAudioPlaybackSession(session: native),
                backgroundPlayback: CrossLayerBackgroundPlaybackStub(),
                events: events,
                callActivity: CallActivityStub()
            )
            return (controller, native, events)
        }

    let nonHostedReasons: [AudioSessionInterruptionBeganReason] = [
        .unavailable,
        .other(rawValue: 2),
    ]
        for reason in nonHostedReasons {
            let fixture = makeController()
            fixture.controller.prepare(serverName: "Mac mini")
            XCTAssertTrue(fixture.native.isAudioEnabled)

            fixture.events.onInterruptionBegan?(reason)

            XCTAssertFalse(
                fixture.native.isAudioEnabled,
                "Reason \(reason) must close the process-wide WebRTC gate."
            )
            fixture.controller.stop()
        }

        do {
            let fixture = makeController()
            fixture.controller.prepare(serverName: "Mac mini")
            fixture.events.onInterruptionBegan?(.default)
            XCTAssertTrue(fixture.native.isAudioEnabled)

            fixture.events.onRouteChanged?(
                "Audio route changed: device unavailable"
            )

            XCTAssertFalse(fixture.native.isAudioEnabled)
            fixture.controller.stop()
        }

        do {
            let fixture = makeController()
            fixture.controller.prepare(serverName: "Mac mini")
            fixture.events.onInterruptionBegan?(.default)
            XCTAssertTrue(fixture.native.isAudioEnabled)

            fixture.events.onMediaServicesLost?()

            XCTAssertFalse(fixture.native.isAudioEnabled)

            // Mutate the injected process-wide gate back open to prove reset independently
            // reasserts the fail-closed boundary rather than relying on the preceding loss write.
            fixture.native.isAudioEnabled = true
            fixture.events.onMediaServicesReset?()

            XCTAssertFalse(fixture.native.isAudioEnabled)
            fixture.controller.stop()
        }

        do {
            let fixture = makeController()
            fixture.controller.prepare(serverName: "Mac mini")
            fixture.events.onInterruptionBegan?(.default)
            XCTAssertTrue(fixture.native.isAudioEnabled)

            fixture.controller.stop()

            XCTAssertFalse(fixture.native.isAudioEnabled)
        }
    }

    func testConnectedCallThenDefaultInterruptionRequestsHostedPolicyAfterFailClose() throws {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )

        var order: [String] = []
        var hostedAuthorization:
            WebRTCIOSHostedCallPlayoutAuthorization?
        fixture.controller.onAudioProofInvalidated = { _ in
            order.append("invalidated")
        }
        fixture.controller.onHostedCallPlayoutRecoveryRequested = {
            authorization in
            hostedAuthorization = authorization
            order.append("hosted")
        }

        fixture.events.onInterruptionBegan?(.default)

        let authorization = try XCTUnwrap(hostedAuthorization)
        let armedChange = try XCTUnwrap(
            fixture.events.lastArmedCategoryChange
        )
        XCTAssertEqual(order, ["invalidated", "hosted"])
        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(authorization.isRecoveryPending)
        XCTAssertEqual(authorization.origin, .interruption)
        XCTAssertEqual(armedChange.operationID, authorization.policyID)
        XCTAssertEqual(
            armedChange.category,
            AVAudioSession.Category.playback.rawValue
        )
        XCTAssertEqual(
            armedChange.mode,
            AVAudioSession.Mode.default.rawValue
        )
        XCTAssertEqual(
            armedChange.categoryOptionsRawValue,
            AVAudioSession.CategoryOptions.mixWithOthers.rawValue
        )
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertEqual(
            fixture.playback.prepareForHostedCallInterruptionCount,
            1
        )
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            0
        )
    }

    func testDefaultInterruptionWaitsForConnectedCallAndPublishesMicrophoneStateFirst() {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()

        var order: [String] = []
        var hostedRequestCount = 0
        fixture.controller.onCallActivityChanged = { isActive in
            order.append(isActive ? "call-active" : "call-inactive")
        }
        fixture.controller.onHostedCallPlayoutRecoveryRequested = { _ in
            hostedRequestCount += 1
            order.append("hosted")
        }

        fixture.events.onInterruptionBegan?(.default)
        XCTAssertEqual(hostedRequestCount, 0)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertEqual(
            fixture.playback.prepareForHostedCallInterruptionCount,
            1
        )
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            0
        )

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )

        XCTAssertEqual(order, ["call-active", "hosted"])
        XCTAssertEqual(hostedRequestCount, 1)

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 2,
            connectedNonEndedCallCount: 1
        )
        XCTAssertEqual(hostedRequestCount, 1)
    }

    func testRingingCallBlocksMicrophoneWithoutHostedRequest() {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        var hostedRequestCount = 0
        fixture.controller.onHostedCallPlayoutRecoveryRequested = { _ in
            hostedRequestCount += 1
        }

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 0
        )
        fixture.events.onInterruptionBegan?(.default)

        XCTAssertEqual(hostedRequestCount, 0)
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertEqual(
            fixture.playback.prepareForHostedCallInterruptionCount,
            1
        )
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            0
        )
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
    }

    func testMissingAndNonDefaultInterruptionReasonsRemainGeneric() {
        let reasons: [AudioSessionInterruptionBeganReason] = [
            .unavailable,
            .other(rawValue: 2),
        ]

        for reason in reasons {
            let fixture = makeFixture()
            fixture.controller.prepare(serverName: "Mac mini")
            fixture.controller.remoteAudioBecameAvailable(
                fixture.remoteAudio
            )
            fixture.controller.transportBecameHealthy()
            fixture.callActivity.setCallSnapshot(
                nonEndedCallCount: 1,
                connectedNonEndedCallCount: 1
            )
            var hostedRequestCount = 0
            fixture.controller
                .onHostedCallPlayoutRecoveryRequested = { _ in
                    hostedRequestCount += 1
                }

            fixture.events.onInterruptionBegan?(reason)

            XCTAssertEqual(
                hostedRequestCount,
                0,
                "Reason \(reason) incorrectly authorized hosted playout."
            )
            XCTAssertFalse(fixture.playback.nativeAudioEnabled)
            XCTAssertFalse(fixture.remoteAudio.isEnabled)
        }
    }

    func testEveryNonCategoryRouteEventRevokesHostedPolicyAndClosesInterruptionEpoch() throws {
        let routeEvents: [
            (message: String, requiresExplicitResume: Bool)
        ] = [
            ("Audio route changed: new device", false),
            ("Audio route changed: override", false),
            ("Audio route changed: wake from sleep", false),
            ("Audio route configuration changed", false),
            ("Audio route changed", false),
            ("Audio route changed: device unavailable", true),
            ("Audio route changed: no suitable route", true),
        ]

        for routeEvent in routeEvents {
            let fixture = makeFixture()
            fixture.controller.prepare(serverName: "Mac mini")
            fixture.controller.remoteAudioBecameAvailable(
                fixture.remoteAudio
            )
            fixture.controller.transportBecameHealthy()
            fixture.callActivity.setCallSnapshot(
                nonEndedCallCount: 1,
                connectedNonEndedCallCount: 1
            )
            var hostedAuthorization:
                WebRTCIOSHostedCallPlayoutAuthorization?
            fixture.controller
                .onHostedCallPlayoutRecoveryRequested = {
                    hostedAuthorization = $0
                }
            fixture.events.onInterruptionBegan?(.default)
            let authorization = try XCTUnwrap(
                hostedAuthorization
            )
            let recoverCountBeforeRoute =
                fixture.playback.recoverCount

            fixture.events.onRouteChanged?(
                routeEvent.message
            )

            XCTAssertFalse(
                authorization.isValid,
                "Hosted authorization survived \(routeEvent.message)."
            )
            XCTAssertFalse(fixture.playback.nativeAudioEnabled)
            XCTAssertFalse(fixture.remoteAudio.isEnabled)
            XCTAssertFalse(fixture.controller.snapshot.isPlaying)
            XCTAssertEqual(
                fixture.controller.snapshot.requiresExplicitResume,
                routeEvent.requiresExplicitResume
            )
            XCTAssertEqual(
                fixture.playback.recoverCount,
                recoverCountBeforeRoute,
                "Interrupted route handling attempted ordinary recovery for \(routeEvent.message)."
            )

            let preIssueFixture = makeFixture()
            preIssueFixture.controller.prepare(
                serverName: "Mac mini"
            )
            preIssueFixture.controller.remoteAudioBecameAvailable(
                preIssueFixture.remoteAudio
            )
            preIssueFixture.controller.transportBecameHealthy()
            var preIssueRequestCount = 0
            preIssueFixture.controller
                .onHostedCallPlayoutRecoveryRequested = { _ in
                    preIssueRequestCount += 1
                }

            preIssueFixture.events.onInterruptionBegan?(
                .default
            )
            preIssueFixture.events.onRouteChanged?(
                routeEvent.message
            )
            preIssueFixture.callActivity.setCallSnapshot(
                nonEndedCallCount: 1,
                connectedNonEndedCallCount: 1
            )

            XCTAssertEqual(
                preIssueRequestCount,
                0,
                "A later CallKit event reopened the route-retired interruption epoch for \(routeEvent.message)."
            )
            XCTAssertFalse(
                preIssueFixture.remoteAudio.isEnabled
            )
        }
    }

    func testOverlappingCallsRetainHostedPolicyWhileAnyConnectedCallRemains() throws {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 2,
            connectedNonEndedCallCount: 2
        )

        var hostedAuthorizations:
            [WebRTCIOSHostedCallPlayoutAuthorization] = []
        fixture.controller.onHostedCallPlayoutRecoveryRequested = {
            hostedAuthorizations.append($0)
        }
        fixture.events.onInterruptionBegan?(.default)

        let authorization = try XCTUnwrap(
            hostedAuthorizations.first
        )
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 2,
            connectedNonEndedCallCount: 1
        )
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )

        XCTAssertEqual(hostedAuthorizations.count, 1)
        XCTAssertTrue(authorization.isValid)

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 0
        )

        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
    }

    func testHostedCategoryNotificationAcceptsExactMixWithOthersPolicy() throws {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        var hostedAuthorization:
            WebRTCIOSHostedCallPlayoutAuthorization?
        fixture.controller.onHostedCallPlayoutRecoveryRequested = {
            hostedAuthorization = $0
        }

        fixture.events.onInterruptionBegan?(.default)
        let authorization = try XCTUnwrap(hostedAuthorization)
        fixture.events.deliverArmedCategoryChange(
            AudioSessionCategoryChange(
                category: AVAudioSession.Category.playback.rawValue,
                mode: AVAudioSession.Mode.default.rawValue,
                categoryOptionsRawValue:
                    AVAudioSession.CategoryOptions.mixWithOthers.rawValue
            )
        )

        XCTAssertTrue(authorization.isValid)
        XCTAssertEqual(
            fixture.playback.prepareForHostedCallInterruptionCount,
            1
        )
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            0
        )
        XCTAssertNil(fixture.controller.snapshot.errorText)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Interrupted"
        )
    }

    func testHostedCallEndBeforeInterruptionEndRecoversOnlyAfterResumeHint() throws {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        var hostedAuthorization:
            WebRTCIOSHostedCallPlayoutAuthorization?
        fixture.controller.onHostedCallPlayoutRecoveryRequested = {
            hostedAuthorization = $0
        }
        fixture.events.onInterruptionBegan?(.default)
        let authorization = try XCTUnwrap(hostedAuthorization)
        let recoverCountBeforeCallEnd = fixture.playback.recoverCount

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 0,
            connectedNonEndedCallCount: 0
        )

        XCTAssertFalse(authorization.isValid)
        XCTAssertEqual(
            fixture.playback.recoverCount,
            recoverCountBeforeCallEnd
        )
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.events.onInterruptionEnded?(true)

        XCTAssertEqual(
            fixture.playback.recoverCount,
            recoverCountBeforeCallEnd + 1
        )
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
    }

    func testMediaServicesLossClosesImmediatelyAndRecoveryWaitsForReset() {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        XCTAssertTrue(fixture.controller.snapshot.isPlaying)
        let recoverCountBeforeLoss =
            fixture.playback.recoverCount

        fixture.events.onMediaServicesLost?()

        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        XCTAssertEqual(
            fixture.playback.recoverCount,
            recoverCountBeforeLoss
        )

        fixture.controller.appBecameActive()
        fixture.events.onEngineConfigurationChanged?()

        XCTAssertEqual(
            fixture.playback.recoverCount,
            recoverCountBeforeLoss,
            "Loss-to-reset attempted ordinary recovery."
        )
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.events.onMediaServicesReset?()

        XCTAssertEqual(
            fixture.playback.recoverCount,
            recoverCountBeforeLoss + 1
        )
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertTrue(fixture.controller.snapshot.isPlaying)
    }

    func testHostedInterruptionEndResumesExactPolicyAndRecoversAfterCallEnd() throws {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        var hostedAuthorization:
            WebRTCIOSHostedCallPlayoutAuthorization?
        var resumedAuthorization:
            WebRTCIOSHostedCallPlayoutAuthorization?
        fixture.controller.onHostedCallPlayoutRecoveryRequested = {
            hostedAuthorization = $0
        }
        fixture.controller.onHostedCallPlayoutRecoveryResumed = {
            resumedAuthorization = $0
        }
        fixture.events.onInterruptionBegan?(.default)
        let authorization = try XCTUnwrap(hostedAuthorization)
        let recoverCountBeforeEnd = fixture.playback.recoverCount
        let manualDisabledCountBeforeEnd =
            fixture.playback.prepareManualAudioDisabledCount

        fixture.events.onInterruptionEnded?(true)

        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(authorization.isRecoveryPending)
        XCTAssertTrue(resumedAuthorization === authorization)
        XCTAssertEqual(
            fixture.playback.recoverCount,
            recoverCountBeforeEnd
        )
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            manualDisabledCountBeforeEnd
        )
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 0,
            connectedNonEndedCallCount: 0
        )

        XCTAssertFalse(authorization.isValid)
        XCTAssertEqual(
            fixture.playback.recoverCount,
            recoverCountBeforeEnd + 1
        )
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
    }

    func testHostedInterruptionWithoutResumeRemainsExplicitAfterCallKitClears() throws {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        var hostedAuthorization:
            WebRTCIOSHostedCallPlayoutAuthorization?
        fixture.controller.onHostedCallPlayoutRecoveryRequested = {
            hostedAuthorization = $0
        }
        fixture.events.onInterruptionBegan?(.default)
        let authorization = try XCTUnwrap(hostedAuthorization)
        let recoverCountBeforeEnd = fixture.playback.recoverCount

        fixture.events.onInterruptionEnded?(false)
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 0,
            connectedNonEndedCallCount: 0
        )

        XCTAssertFalse(authorization.isValid)
        XCTAssertTrue(
            fixture.controller.snapshot.requiresExplicitResume
        )
        XCTAssertEqual(
            fixture.playback.recoverCount,
            recoverCountBeforeEnd
        )
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.controller.resumePlayback()

        XCTAssertEqual(
            fixture.playback.recoverCount,
            recoverCountBeforeEnd + 1
        )
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
    }

    #if DEBUG
    func testAutomaticMicrophoneRequiresAuthenticatedPairedHandoff() async throws {
        let untrusted = try makeAutomaticMicrophonePolicyFixture(provenance: .unauthenticated)
        let untrustedNativePolicies = AudioLockedValues<Bool>()
        var untrustedPermissionRequestCount = 0
        untrusted.viewModel.debugInstallIPhoneMicrophonePermissionRequester {
            untrustedPermissionRequestCount += 1
            return false
        }
        await untrusted.peer.debugInstallIPhoneMicrophonePolicyApplier {
            isEnabled in
            untrustedNativePolicies.append(isEnabled)
            return true
        }

        XCTAssertFalse(untrusted.viewModel.microphoneIntentEnabled)
        XCTAssertNil(
            untrusted.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )
        untrusted.viewModel.handleAppBecameActive()
        await untrusted.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        XCTAssertEqual(untrustedPermissionRequestCount, 0)
        XCTAssertFalse(untrusted.viewModel.microphoneIntentEnabled)
        XCTAssertNil(
            untrusted.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )
        let untrustedPolicySnapshot =
            await untrusted.peer.debugIPhoneMicrophonePolicySnapshot
        XCTAssertNil(untrustedPolicySnapshot.activeAuthorizationIdentity)
        XCTAssertFalse(untrustedPolicySnapshot.trackIsEnabled)
        XCTAssertTrue(untrustedNativePolicies.values.isEmpty)

        untrusted.viewModel.disconnect()
        await untrusted.peer.close()

        let authenticated = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        let authenticatedNativePolicies = AudioLockedValues<Bool>()
        let permissionRequested = expectation(description: "authenticated permission request")
        var authenticatedPermissionRequestCount = 0
        authenticated.viewModel.debugInstallIPhoneMicrophonePermissionRequester {
            authenticatedPermissionRequestCount += 1
            permissionRequested.fulfill()
            return false
        }
        await authenticated.peer.debugInstallIPhoneMicrophonePolicyApplier {
            isEnabled in
            authenticatedNativePolicies.append(isEnabled)
            return true
        }

        XCTAssertFalse(authenticated.viewModel.microphoneIntentEnabled)
        XCTAssertNil(
            authenticated.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )
        await authenticated.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        XCTAssertEqual(authenticatedPermissionRequestCount, 0)
        XCTAssertFalse(authenticated.viewModel.microphoneIntentEnabled)
        XCTAssertNil(
            authenticated.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )
        let beforeActivePolicySnapshot =
            await authenticated.peer.debugIPhoneMicrophonePolicySnapshot
        XCTAssertNil(beforeActivePolicySnapshot.activeAuthorizationIdentity)
        XCTAssertFalse(beforeActivePolicySnapshot.trackIsEnabled)
        XCTAssertTrue(authenticatedNativePolicies.values.isEmpty)

        authenticated.viewModel.handleAppBecameActive()
        await fulfillment(of: [permissionRequested], timeout: 2)
        XCTAssertEqual(authenticatedPermissionRequestCount, 1)
        XCTAssertTrue(authenticatedNativePolicies.values.isEmpty)

        authenticated.viewModel.disconnect()
        await authenticated.peer.close()
    }

    func testAutomaticMicrophoneAttemptsPermissionOnceAndStartsThroughReconcile() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        let permissionStarted = expectation(description: "automatic permission started")
        let enableAttempted = expectation(description: "reconcile attempted native enable")
        enableAttempted.assertForOverFulfill = false
        let permissionGate = AudioNonCooperativeGate<Bool>()
        var permissionRequestCount = 0
        var enableAttemptCount = 0
        session.viewModel.debugInstallIPhoneMicrophonePermissionRequester {
            permissionRequestCount += 1
            permissionStarted.fulfill()
            return await permissionGate.wait()
        }
        session.viewModel.debugInstallIPhoneMicrophoneEnableAttemptObserver {
            enableAttemptCount += 1
            enableAttempted.fulfill()
        }

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(of: [permissionStarted], timeout: 2)
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        XCTAssertEqual(permissionRequestCount, 1)

        await permissionGate.open(true)
        await fulfillment(of: [enableAttempted], timeout: 2)
        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertEqual(enableAttemptCount, 1)
        XCTAssertTrue(session.viewModel.microphoneIntentEnabled)

        session.viewModel.toggleIPhoneMicrophone()
        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testStartupConnectedCallRestoresCachedAutomaticMicrophoneOnlyAfterOrdinaryRecoveryProof()
        async throws {
        let fixture = makeFixture(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        let peer = try makeAudioRacePeer()
        let microphoneCommitted = expectation(
            description: "post-startup-call microphone committed"
        )
        let nativeOutputOnlyRecoveryConsumed = expectation(
            description: "post-startup-call native output-only recovery consumed"
        )
        var enableCount = 0
        var outputPolicyRecoveryWasEntered = false
        let isPostCallRecovery = AudioMainActorFlag()
        let didObservePostCallRecovery = AudioMainActorFlag()

        // Keep the test on the lifecycle boundary: hosted-call proof itself is covered separately.
        fixture.controller.onHostedCallPlayoutRecoveryRequested = { _ in }
        viewModel.debugInstallScreenSessionForTests(
            peer: peer,
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        installProductionShapedIOSRecoveryHarness(
            on: viewModel,
            peer: peer
        ) {
            guard isPostCallRecovery.value,
                  !didObservePostCallRecovery.value else { return }
            didObservePostCallRecovery.value = true
            XCTAssertEqual(enableCount, 0)
            nativeOutputOnlyRecoveryConsumed.fulfill()
        }
        viewModel.debugCacheIPhoneMicrophonePermissionForTests()
        viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { _ in
                enableCount += 1
            },
            disable: { _, _ in true }
        )
        viewModel.debugInstallIPhoneMicrophoneDidCommitObserver { _ in
            microphoneCommitted.fulfill()
        }
        fixture.playback.onRecover = {
            outputPolicyRecoveryWasEntered = true
            XCTAssertEqual(enableCount, 0)
        }

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        viewModel.handleAppBecameActive()

        XCTAssertTrue(viewModel.microphoneIntentEnabled)
        XCTAssertFalse(viewModel.isMicrophoneSending)
        XCTAssertEqual(
            viewModel.microphoneStateText,
            "Muted — iPhone call active"
        )

        isPostCallRecovery.value = true
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 0,
            connectedNonEndedCallCount: 0
        )

        XCTAssertTrue(outputPolicyRecoveryWasEntered)
        XCTAssertEqual(enableCount, 0)
        XCTAssertFalse(viewModel.isMicrophoneSending)
        XCTAssertEqual(fixture.playback.recoverCount, 1)

        await fulfillment(
            of: [
                nativeOutputOnlyRecoveryConsumed,
                microphoneCommitted,
            ],
            timeout: 2
        )

        XCTAssertTrue(didObservePostCallRecovery.value)
        XCTAssertEqual(enableCount, 1)
        XCTAssertTrue(viewModel.isMicrophoneSending)
        XCTAssertEqual(viewModel.microphoneStateText, "On")

        viewModel.disconnect()
        await peer.close()
    }

    func testInterruptionOriginCallEndRestoresCachedAutomaticMicrophoneOnlyAfterOrdinaryRecoveryProof()
        async throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        let peer = try makeAudioRacePeer()
        let initialMicrophoneCommitted = expectation(
            description: "initial automatic microphone committed"
        )
        let restoredMicrophoneCommitted = expectation(
            description: "post-interruption microphone committed"
        )
        let nativeOutputOnlyRecoveryConsumed = expectation(
            description: "post-interruption native output-only recovery consumed"
        )
        var enableCount = 0
        let isPostCallRecovery = AudioMainActorFlag()
        let didObservePostCallRecovery = AudioMainActorFlag()

        fixture.controller.onHostedCallPlayoutRecoveryRequested = { _ in }
        viewModel.debugInstallScreenSessionForTests(
            peer: peer,
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        installProductionShapedIOSRecoveryHarness(
            on: viewModel,
            peer: peer
        ) {
            guard isPostCallRecovery.value,
                  !didObservePostCallRecovery.value else { return }
            didObservePostCallRecovery.value = true
            XCTAssertEqual(enableCount, 1)
            nativeOutputOnlyRecoveryConsumed.fulfill()
        }
        viewModel.debugCacheIPhoneMicrophonePermissionForTests()
        viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { _ in
                enableCount += 1
            },
            disable: { _, _ in true }
        )
        viewModel.debugInstallIPhoneMicrophoneDidCommitObserver { _ in
            if enableCount == 1 {
                initialMicrophoneCommitted.fulfill()
            } else if enableCount == 2 {
                restoredMicrophoneCommitted.fulfill()
            }
        }

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        viewModel.handleAppBecameActive()
        await fulfillment(of: [initialMicrophoneCommitted], timeout: 2)

        XCTAssertTrue(viewModel.isMicrophoneSending)
        var outputPolicyRecoveryWasEntered = false
        fixture.playback.onRecover = {
            outputPolicyRecoveryWasEntered = true
            XCTAssertEqual(enableCount, 1)
            let category = fixture.events.lastArmedCategoryChange
            XCTAssertEqual(
                category?.category,
                AVAudioSession.Category.playback.rawValue
            )
            XCTAssertEqual(
                category?.mode,
                AVAudioSession.Mode.default.rawValue
            )
            XCTAssertEqual(category?.categoryOptionsRawValue, 0)
            XCTAssertTrue(
                viewModel.debugIOSPlayoutInputPolicyMatchesForTests(
                    iosPlayoutDiagnostics(
                        callbacks: 1,
                        frames: 480,
                        failures: 0,
                        inputBusEnabled: false,
                        categoryIsMediaPlayback: true,
                        categoryIsMediaPlayAndRecord: false
                    )
                )
            )
        }
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )

        XCTAssertFalse(viewModel.isMicrophoneSending)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)

        fixture.events.onInterruptionBegan?(.default)
        fixture.events.onInterruptionEnded?(true)
        isPostCallRecovery.value = true
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 0,
            connectedNonEndedCallCount: 0
        )

        XCTAssertTrue(outputPolicyRecoveryWasEntered)
        XCTAssertEqual(enableCount, 1)
        XCTAssertFalse(viewModel.isMicrophoneSending)

        await fulfillment(
            of: [
                nativeOutputOnlyRecoveryConsumed,
                restoredMicrophoneCommitted,
            ],
            timeout: 2
        )

        XCTAssertTrue(didObservePostCallRecovery.value)
        XCTAssertEqual(enableCount, 2)
        XCTAssertTrue(viewModel.isMicrophoneSending)
        XCTAssertEqual(viewModel.microphoneStateText, "On")

        viewModel.disconnect()
        await peer.close()
    }

    func testStartupConnectedCallRestoresAuthenticatedMicrophoneWithoutInboundAudio()
        async throws {
        let fixture = makeFixture(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        let peer = try makeAudioRacePeer()
        let microphoneCommitted = expectation(
            description: "mic-only post-call microphone committed"
        )
        let nativeOutputOnlyRecoveryConsumed = expectation(
            description: "mic-only native output-only recovery consumed"
        )
        var enableCount = 0
        var didConsumeOutputOnlyRecovery = false
        var fullDuplexDiagnosticsOrdinal: UInt64 = 30

        fixture.controller.onHostedCallPlayoutRecoveryRequested = { _ in }
        viewModel.debugInstallScreenSessionForTests(
            peer: peer,
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        viewModel.debugInstallIOSPlayoutDiagnosticsReader {
            requestedPeer in
            XCTAssertTrue(requestedPeer === peer)
            let microphoneIsAuthorized =
                viewModel
                    .debugIPhoneMicrophoneAuthorizationForTests?
                    .isValid == true
            if microphoneIsAuthorized {
                fullDuplexDiagnosticsOrdinal &+= 1
                return iosPlayoutDiagnostics(
                    callbacks: fullDuplexDiagnosticsOrdinal,
                    frames: fullDuplexDiagnosticsOrdinal * 480,
                    failures: 0,
                    inputBusEnabled: true,
                    categoryIsMediaPlayback: false,
                    categoryIsMediaPlayAndRecord: true
                )
            }
            // The first consumed post-recovery sample intentionally has no callback/frame
            // advancement over the baseline. Installed output-only policy, not inbound PCM or a
            // fresh render callback, is the microphone-admission milestone.
            return iosPlayoutDiagnostics(
                callbacks: 20,
                frames: 9_600,
                failures: 0
            )
        }
        viewModel.debugInstallIOSPlayoutRecoveryRequester {
            requestedPeer,
            authorization in
            XCTAssertTrue(requestedPeer === peer)
            if !didConsumeOutputOnlyRecovery {
                XCTAssertEqual(enableCount, 0)
                didConsumeOutputOnlyRecovery = true
                nativeOutputOnlyRecoveryConsumed.fulfill()
            } else {
                // Microphone admission rotates the audio policy. If its replacement full-duplex
                // proof inherits the still-fresh recovery requirement, a second native request is
                // correct and necessarily occurs only after the microphone enable was issued.
                XCTAssertEqual(enableCount, 1)
            }
            XCTAssertTrue(
                authorization.performIfValidForTesting {}
            )
        }
        viewModel.debugCacheIPhoneMicrophonePermissionForTests()
        viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { _ in enableCount += 1 },
            disable: { _, _ in true }
        )
        viewModel.debugInstallIPhoneMicrophoneDidCommitObserver { _ in
            microphoneCommitted.fulfill()
        }

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()
        viewModel.handleAppBecameActive()
        XCTAssertFalse(viewModel.isRemoteAudioAvailable)
        XCTAssertFalse(viewModel.isRemoteAudioPlaying)
        XCTAssertTrue(viewModel.microphoneIntentEnabled)

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 0,
            connectedNonEndedCallCount: 0
        )
        XCTAssertEqual(enableCount, 0)

        await fulfillment(
            of: [
                nativeOutputOnlyRecoveryConsumed,
                microphoneCommitted,
            ],
            timeout: 2
        )
        XCTAssertEqual(enableCount, 1)
        XCTAssertTrue(viewModel.isMicrophoneSending)
        XCTAssertFalse(viewModel.isRemoteAudioAvailable)
        XCTAssertFalse(viewModel.isRemoteAudioPlaying)

        viewModel.disconnect()
        await peer.close()
    }

    func testPostCallMilestoneRejectsNewLiveCallDuringOutputOnlyDiagnostic()
        async throws {
        let fixture = makeFixture(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        let peer = try makeAudioRacePeer()
        var enableCount = 0

        fixture.controller.onHostedCallPlayoutRecoveryRequested = { _ in }
        viewModel.debugInstallScreenSessionForTests(
            peer: peer,
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        viewModel.debugCacheIPhoneMicrophonePermissionForTests()
        viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { _ in enableCount += 1 },
            disable: { _, _ in true }
        )
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()
        viewModel.handleAppBecameActive()

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 0,
            connectedNonEndedCallCount: 0
        )
        let milestone = try XCTUnwrap(
            fixture.controller
                .postCallMicrophoneRecoveryMilestone
        )
        let baseline = iosPlayoutDiagnostics(
            callbacks: 20,
            frames: 9_600,
            failures: 0
        )
        let handle = viewModel
            .debugStartIOSPlayoutProofAttemptForTests(
                requestRecovery: true,
                preRecoveryDiagnostics: baseline,
                expectedPeer: peer,
                postCallRecoveryMilestone: milestone
            )
        let authorization = try XCTUnwrap(
            viewModel
                .debugIOSPlayoutRecoveryAuthorizationForTests
        )
        XCTAssertTrue(
            authorization.performIfValidForTesting {}
        )

        // Simulate CallKit's live aggregate changing before its observer callback reaches the
        // lifecycle. Completion re-samples it synchronously and rejects the now-stale UUID.
        fixture.callActivity
            .stageLiveNonEndedCallCountWithoutCallback(1)
        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                baseline,
                handle: handle,
                source: .polling
            )
        )

        XCTAssertNil(
            fixture.controller
                .postCallMicrophoneRecoveryMilestone
        )
        XCTAssertFalse(
            fixture.controller.microphoneActivationIsAllowed()
        )
        XCTAssertEqual(enableCount, 0)
        XCTAssertFalse(viewModel.isMicrophoneSending)
        XCTAssertEqual(
            viewModel.microphoneStateText,
            "Muted — iPhone call active"
        )

        viewModel.disconnect()
        await peer.close()
    }

    func testReplacementProofAttemptCannotCompleteOlderPostCallMilestone()
        async throws {
        let fixture = makeFixture(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        let peer = try makeAudioRacePeer()
        let microphoneCommitted = expectation(
            description: "replacement milestone microphone committed"
        )
        var enableCount = 0

        fixture.controller.onHostedCallPlayoutRecoveryRequested = { _ in }
        viewModel.debugInstallScreenSessionForTests(
            peer: peer,
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        viewModel.debugCacheIPhoneMicrophonePermissionForTests()
        viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { _ in enableCount += 1 },
            disable: { _, _ in true }
        )
        viewModel.debugInstallIPhoneMicrophoneDidCommitObserver {
            _ in
            microphoneCommitted.fulfill()
        }
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()
        viewModel.handleAppBecameActive()

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 0,
            connectedNonEndedCallCount: 0
        )
        let olderMilestone = try XCTUnwrap(
            fixture.controller
                .postCallMicrophoneRecoveryMilestone
        )
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 0,
            connectedNonEndedCallCount: 0
        )
        let replacementMilestone = try XCTUnwrap(
            fixture.controller
                .postCallMicrophoneRecoveryMilestone
        )
        XCTAssertNotEqual(
            olderMilestone,
            replacementMilestone
        )

        let diagnostics = iosPlayoutDiagnostics(
            callbacks: 40,
            frames: 19_200,
            failures: 0
        )
        let staleHandle = viewModel
            .debugStartIOSPlayoutProofAttemptForTests(
                requestRecovery: true,
                preRecoveryDiagnostics: diagnostics,
                expectedPeer: peer,
                postCallRecoveryMilestone: olderMilestone
            )
        let staleAuthorization = try XCTUnwrap(
            viewModel
                .debugIOSPlayoutRecoveryAuthorizationForTests
        )
        XCTAssertTrue(
            staleAuthorization.performIfValidForTesting {}
        )
        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                diagnostics,
                handle: staleHandle,
                source: .polling
            )
        )
        XCTAssertEqual(
            fixture.controller
                .postCallMicrophoneRecoveryMilestone,
            replacementMilestone
        )
        XCTAssertEqual(enableCount, 0)

        let replacementHandle = viewModel
            .debugStartIOSPlayoutProofAttemptForTests(
                requestRecovery: true,
                preRecoveryDiagnostics: diagnostics,
                expectedPeer: peer,
                postCallRecoveryMilestone:
                    replacementMilestone
            )
        let replacementAuthorization = try XCTUnwrap(
            viewModel
                .debugIOSPlayoutRecoveryAuthorizationForTests
        )
        XCTAssertTrue(
            replacementAuthorization
                .performIfValidForTesting {}
        )
        // Completing the exact replacement milestone synchronously starts microphone admission.
        // A successful admission then starts the production full-duplex playout proof. Give that
        // replacement proof production-shaped input topology; the otherwise bare race-test peer
        // can report output-only diagnostics immediately and legitimately suspend the microphone,
        // racing this milestone-ownership assertion with an unrelated proof failure.
        installProductionShapedIOSRecoveryHarness(
            on: viewModel,
            peer: peer
        )
        XCTAssertTrue(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                diagnostics,
                handle: replacementHandle,
                source: .polling
            )
        )
        await fulfillment(of: [microphoneCommitted], timeout: 2)

        XCTAssertNil(
            fixture.controller
                .postCallMicrophoneRecoveryMilestone
        )
        XCTAssertEqual(enableCount, 1)
        XCTAssertTrue(viewModel.isMicrophoneSending)

        viewModel.disconnect()
        await peer.close()
    }

    func testPostCallMilestoneRequiresConsumedAuthorizationAndOutputOnlyPolicyWithoutFreshFrames()
        async throws {
        let fixture = makeFixture(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        let peer = try makeAudioRacePeer()
        let microphoneCommitted = expectation(
            description: "exact output-only milestone microphone committed"
        )
        var enableCount = 0

        fixture.controller.onHostedCallPlayoutRecoveryRequested = { _ in }
        viewModel.debugInstallScreenSessionForTests(
            peer: peer,
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        viewModel.debugCacheIPhoneMicrophonePermissionForTests()
        viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { _ in enableCount += 1 },
            disable: { _, _ in true }
        )
        viewModel.debugInstallIPhoneMicrophoneDidCommitObserver {
            _ in
            microphoneCommitted.fulfill()
        }
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()
        viewModel.handleAppBecameActive()
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 0,
            connectedNonEndedCallCount: 0
        )

        let milestone = try XCTUnwrap(
            fixture.controller
                .postCallMicrophoneRecoveryMilestone
        )
        let outputOnly = iosPlayoutDiagnostics(
            callbacks: 50,
            frames: 24_000,
            failures: 0
        )
        let firstHandle = viewModel
            .debugStartIOSPlayoutProofAttemptForTests(
                requestRecovery: true,
                preRecoveryDiagnostics: outputOnly,
                expectedPeer: peer,
                postCallRecoveryMilestone: milestone
            )
        let firstAuthorization = try XCTUnwrap(
            viewModel
                .debugIOSPlayoutRecoveryAuthorizationForTests
        )

        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                outputOnly,
                handle: firstHandle,
                source: .polling
            ),
            "Diagnostics cannot complete a still-valid native recovery authorization."
        )
        XCTAssertEqual(enableCount, 0)
        XCTAssertEqual(
            fixture.controller
                .postCallMicrophoneRecoveryMilestone,
            milestone
        )
        XCTAssertTrue(
            firstAuthorization.performIfValidForTesting {}
        )
        let wrongCategory = iosPlayoutDiagnostics(
            callbacks: 50,
            frames: 24_000,
            failures: 0,
            inputBusEnabled: false,
            categoryIsMediaPlayback: false,
            categoryIsMediaPlayAndRecord: true
        )
        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                wrongCategory,
                handle: firstHandle,
                source: .polling
            )
        )
        XCTAssertEqual(enableCount, 0)
        XCTAssertEqual(
            fixture.controller
                .postCallMicrophoneRecoveryMilestone,
            milestone
        )

        // A replacement exact attempt may use the still-current milestone. Its first healthy
        // output-only sample deliberately equals its baseline; no fresh callback/frame or inbound
        // PCM is required to reopen input.
        let replacementHandle = viewModel
            .debugStartIOSPlayoutProofAttemptForTests(
                requestRecovery: true,
                preRecoveryDiagnostics: outputOnly,
                expectedPeer: peer,
                postCallRecoveryMilestone: milestone
            )
        let replacementAuthorization = try XCTUnwrap(
            viewModel
                .debugIOSPlayoutRecoveryAuthorizationForTests
        )
        XCTAssertTrue(
            replacementAuthorization
                .performIfValidForTesting {}
        )
        // Completing the milestone starts the production full-duplex proof. Keep this bare
        // race-test peer from immediately reporting output-only topology and suspending the
        // microphone before the committed-state assertion below.
        installProductionShapedIOSRecoveryHarness(
            on: viewModel,
            peer: peer
        )
        XCTAssertTrue(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                outputOnly,
                handle: replacementHandle,
                source: .polling
            )
        )
        await fulfillment(of: [microphoneCommitted], timeout: 2)

        XCTAssertEqual(enableCount, 1)
        XCTAssertTrue(viewModel.isMicrophoneSending)
        XCTAssertNil(
            fixture.controller
                .postCallMicrophoneRecoveryMilestone
        )

        viewModel.disconnect()
        await peer.close()
    }

    func testRejectedOrRevokedRecoveryCannotConsumePostCallMilestoneFromOldHealthySnapshot()
        throws {
        enum TerminalVariant: CaseIterable {
            case rejected
            case revoked
        }

        for variant in TerminalVariant.allCases {
            let (viewModel, fixture) =
                makePreparedProofViewModel()
            fixture.callActivity.setCallSnapshot(
                nonEndedCallCount: 1,
                connectedNonEndedCallCount: 1
            )
            fixture.callActivity.setCallSnapshot(
                nonEndedCallCount: 0,
                connectedNonEndedCallCount: 0
            )
            let milestone = try XCTUnwrap(
                fixture.controller
                    .postCallMicrophoneRecoveryMilestone
            )
            let oldHealthySnapshot = iosPlayoutDiagnostics(
                callbacks: 77,
                frames: 36_960,
                failures: 0
            )
            let handle = viewModel
                .debugStartIOSPlayoutProofAttemptForTests(
                    requestRecovery: true,
                    preRecoveryDiagnostics:
                        oldHealthySnapshot,
                    postCallRecoveryMilestone: milestone
                )
            let authorization = try XCTUnwrap(
                viewModel
                    .debugIOSPlayoutRecoveryAuthorizationForTests
            )

            switch variant {
            case .rejected:
                XCTAssertFalse(
                    authorization.rejectIfValidForTesting()
                )
                XCTAssertEqual(
                    authorization.terminalOutcome,
                    .rejected
                )
            case .revoked:
                authorization.revoke()
                XCTAssertEqual(
                    authorization.terminalOutcome,
                    .revoked
                )
            }
            XCTAssertEqual(
                authorization.terminalGeneration,
                authorization.generation
            )

            XCTAssertFalse(
                viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                    oldHealthySnapshot,
                    handle: handle,
                    source: .polling
                )
            )
            XCTAssertEqual(
                viewModel.debugIOSPlayoutProofState.stage,
                .awaitingRecoveryAuthorization
            )
            XCTAssertEqual(
                fixture.controller
                    .postCallMicrophoneRecoveryMilestone,
                milestone
            )
            XCTAssertFalse(viewModel.isMicrophoneSending)
        }
    }

    func testPostCallRestoreReconcilesAfterStaleMicrophoneCleanupRetires()
        async throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        let peer = try makeAudioRacePeer()
        let firstEnableFailed = expectation(
            description: "initial enable entered cleanup"
        )
        let restoredMicrophoneCommitted = expectation(
            description: "post-cleanup microphone committed"
        )
        let cleanupEntered = expectation(
            description: "stale microphone cleanup blocked"
        )
        let nativeOutputOnlyRecoveryConsumed = expectation(
            description: "cleanup-race native output-only recovery consumed"
        )
        let cleanupGate = AudioNonCooperativeGate<Bool>()
        var enableCount = 0
        var cleanupBlockWasEntered = false
        let isPostCallRecovery = AudioMainActorFlag()
        let didObservePostCallRecovery = AudioMainActorFlag()

        fixture.controller.onHostedCallPlayoutRecoveryRequested = { _ in }
        viewModel.debugInstallScreenSessionForTests(
            peer: peer,
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        installProductionShapedIOSRecoveryHarness(
            on: viewModel,
            peer: peer
        ) {
            guard isPostCallRecovery.value,
                  !didObservePostCallRecovery.value else { return }
            didObservePostCallRecovery.value = true
            nativeOutputOnlyRecoveryConsumed.fulfill()
        }
        viewModel.debugCacheIPhoneMicrophonePermissionForTests()
        viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { _ in
                enableCount += 1
                if enableCount == 1 {
                    firstEnableFailed.fulfill()
                    throw TestAudioError.activation
                }
            },
            disable: { authorization, _ in
                if !cleanupBlockWasEntered, authorization != nil {
                    cleanupBlockWasEntered = true
                    cleanupEntered.fulfill()
                    return await cleanupGate.wait()
                }
                return true
            }
        )
        viewModel.debugInstallIPhoneMicrophoneDidCommitObserver { _ in
            if enableCount == 2 {
                restoredMicrophoneCommitted.fulfill()
            }
        }

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()
        viewModel.handleAppBecameActive()
        await fulfillment(
            of: [firstEnableFailed, cleanupEntered],
            timeout: 2
        )
        XCTAssertTrue(
            viewModel.isMicrophoneAdmissionCleanupInProgress
        )

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        fixture.events.onInterruptionBegan?(.default)
        fixture.events.onInterruptionEnded?(true)
        isPostCallRecovery.value = true
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 0,
            connectedNonEndedCallCount: 0
        )

        XCTAssertEqual(enableCount, 1)
        XCTAssertTrue(
            viewModel.isMicrophoneAdmissionCleanupInProgress
        )
        await fulfillment(
            of: [nativeOutputOnlyRecoveryConsumed],
            timeout: 2
        )
        XCTAssertEqual(enableCount, 1)
        XCTAssertTrue(
            viewModel.isMicrophoneAdmissionCleanupInProgress
        )
        await cleanupGate.open(true)
        await fulfillment(
            of: [restoredMicrophoneCommitted],
            timeout: 2
        )

        XCTAssertEqual(enableCount, 2)
        XCTAssertFalse(
            viewModel.isMicrophoneAdmissionCleanupInProgress
        )
        XCTAssertTrue(viewModel.isMicrophoneSending)
        XCTAssertEqual(viewModel.microphoneStateText, "On")

        viewModel.disconnect()
        await peer.close()
    }

    func testStaleMicrophoneCleanupCannotReenableAfterPermissionDenial()
        async throws {
        try await assertStaleMicrophoneCleanupDoesNotReenable(
            after: .permissionDenial
        )
    }

    func testStaleMicrophoneCleanupCannotReenableAfterDisconnect()
        async throws {
        try await assertStaleMicrophoneCleanupDoesNotReenable(
            after: .disconnect
        )
    }

    func testCallStartRevokesInFlightMicrophoneBeforeArmingRollbackFence()
        async throws {
        let fixture = makeFixture()
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        let peer = try makeAudioRacePeer()
        let enableEntered = expectation(
            description: "in-flight microphone enable entered"
        )
        let rollbackFenceArmed = expectation(
            description: "call privacy rollback fence armed"
        )
        let staleEnableWasDisabled = expectation(
            description: "retired in-flight enable disabled"
        )
        let enableGate = AudioNonCooperativeGate<Void>()
        var capturedAuthorization:
            WebRTCIOSMicrophoneAuthorization?
        var commitCount = 0

        viewModel.debugInstallScreenSessionForTests(
            peer: peer,
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        viewModel.debugCacheIPhoneMicrophonePermissionForTests()
        viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { authorization in
                capturedAuthorization = authorization
                enableEntered.fulfill()
                await enableGate.wait()
            },
            disable: { authorization, outputOnlyToken in
                XCTAssertTrue(
                    authorization === capturedAuthorization
                )
                XCTAssertNil(outputOnlyToken)
                staleEnableWasDisabled.fulfill()
                return true
            }
        )
        viewModel.debugInstallIPhoneMicrophoneDidCommitObserver {
            _ in
            commitCount += 1
        }

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        viewModel.handleAppBecameActive()
        await fulfillment(of: [enableEntered], timeout: 2)

        let authorization = try XCTUnwrap(capturedAuthorization)
        let enableCategoryOperation = try XCTUnwrap(
            fixture.events.lastArmedCategoryChange
        )
        XCTAssertTrue(authorization.isValid)
        XCTAssertEqual(
            enableCategoryOperation.category,
            AVAudioSession.Category.playAndRecord.rawValue
        )
        fixture.events.onArmCategoryChangeOperation = {
            rollbackChange in
            guard rollbackChange.category
                    == AVAudioSession.Category.playback.rawValue else {
                return
            }
            XCTAssertFalse(
                authorization.isValid,
                "Realtime authorization must retire before logical rollback is armed."
            )
            rollbackFenceArmed.fulfill()
        }

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )

        await fulfillment(of: [rollbackFenceArmed], timeout: 2)
        XCTAssertFalse(authorization.isValid)
        XCTAssertNil(
            viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )
        XCTAssertFalse(viewModel.isMicrophoneSending)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)

        // A queued notification from the now-revoked enable is absorbed only by its exact
        // predecessor fence and cannot close the independent downlink.
        fixture.events.onCategoryChanged?(
            AudioSessionCategoryChange(
                category:
                    AVAudioSession.Category.playAndRecord.rawValue,
                mode: AVAudioSession.Mode.default.rawValue,
                categoryOptionsRawValue:
                    Self.iPhoneMicrophoneCategoryOptionsRawValue,
                operationID:
                    enableCategoryOperation.operationID
            )
        )
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)

        await enableGate.open(())
        await fulfillment(
            of: [staleEnableWasDisabled],
            timeout: 2
        )
        XCTAssertEqual(commitCount, 0)
        XCTAssertFalse(viewModel.isMicrophoneSending)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)

        viewModel.disconnect()
        await peer.close()
    }

    func testPassiveForegroundCallResampleRevokesEstablishedMicrophoneBeforeRollbackFence()
        async throws {
        let fixture = makeFixture()
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        let peer = try makeAudioRacePeer()
        let microphoneCommitted = expectation(
            description: "established microphone committed"
        )
        let rollbackFenceArmed = expectation(
            description: "passive recovery call rollback armed"
        )
        var capturedAuthorization:
            WebRTCIOSMicrophoneAuthorization?
        var observedRollback = false

        viewModel.debugInstallScreenSessionForTests(
            peer: peer,
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        viewModel.debugCacheIPhoneMicrophonePermissionForTests()
        viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { authorization in
                capturedAuthorization = authorization
            },
            disable: { _, _ in true }
        )
        viewModel.debugInstallIPhoneMicrophoneDidCommitObserver {
            _ in microphoneCommitted.fulfill()
        }

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        viewModel.handleAppBecameActive()
        await fulfillment(of: [microphoneCommitted], timeout: 2)

        let authorization = try XCTUnwrap(capturedAuthorization)
        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(viewModel.isMicrophoneSending)

        viewModel.handleAppBecameInactive()
        fixture.callActivity
            .stageLiveNonEndedCallCountWithoutCallback(1)
        fixture.events.onArmCategoryChangeOperation = {
            change in
            guard !observedRollback,
                  change.category
                    == AVAudioSession.Category.playback.rawValue else {
                return
            }
            observedRollback = true
            XCTAssertFalse(
                authorization.isValid,
                "Call-start revocation must precede the rollback category fence."
            )
            rollbackFenceArmed.fulfill()
        }

        viewModel.handleAppBecameActive()
        await fulfillment(of: [rollbackFenceArmed], timeout: 2)

        XCTAssertFalse(authorization.isValid)
        XCTAssertNil(
            viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )
        XCTAssertFalse(viewModel.isMicrophoneSending)
        XCTAssertEqual(
            viewModel.microphoneStateText,
            "Muted — iPhone call active"
        )

        viewModel.disconnect()
        await peer.close()
    }

    func testFinalMicrophoneAdmissionCallResamplePreservesRetiredEnableRollbackFence()
        async throws {
        let fixture = makeFixture()
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        let peer = try makeAudioRacePeer()
        let enableEntered = expectation(
            description: "final-sampler enable entered"
        )
        let rollbackFenceArmed = expectation(
            description: "final-sampler rollback armed"
        )
        let staleEnableWasDisabled = expectation(
            description: "final-sampler stale enable disabled"
        )
        let enableGate = AudioNonCooperativeGate<Void>()
        var capturedAuthorization:
            WebRTCIOSMicrophoneAuthorization?
        var commitCount = 0

        viewModel.debugInstallScreenSessionForTests(
            peer: peer,
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        viewModel.debugCacheIPhoneMicrophonePermissionForTests()
        viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { authorization in
                capturedAuthorization = authorization
                enableEntered.fulfill()
                await enableGate.wait()
                fixture.callActivity
                    .stageLiveNonEndedCallCountWithoutCallback(1)
            },
            disable: { authorization, outputOnlyToken in
                XCTAssertTrue(
                    authorization === capturedAuthorization
                )
                XCTAssertNil(
                    outputOnlyToken,
                    "Reentrant CallKit retirement must retain its rollback fence."
                )
                staleEnableWasDisabled.fulfill()
                return true
            }
        )
        viewModel.debugInstallIPhoneMicrophoneDidCommitObserver {
            _ in commitCount += 1
        }

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        viewModel.handleAppBecameActive()
        await fulfillment(of: [enableEntered], timeout: 2)

        let authorization = try XCTUnwrap(capturedAuthorization)
        let enableCategoryOperation = try XCTUnwrap(
            fixture.events.lastArmedCategoryChange
        )
        fixture.events.onArmCategoryChangeOperation = {
            change in
            guard change.category
                    == AVAudioSession.Category.playback.rawValue else {
                return
            }
            XCTAssertFalse(authorization.isValid)
            rollbackFenceArmed.fulfill()
        }

        await enableGate.open(())
        await fulfillment(
            of: [rollbackFenceArmed, staleEnableWasDisabled],
            timeout: 2
        )

        XCTAssertEqual(commitCount, 0)
        XCTAssertFalse(authorization.isValid)
        XCTAssertNil(
            viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )
        XCTAssertFalse(viewModel.isMicrophoneSending)

        fixture.events.onCategoryChanged?(
            AudioSessionCategoryChange(
                category:
                    AVAudioSession.Category.playAndRecord.rawValue,
                mode: AVAudioSession.Mode.default.rawValue,
                categoryOptionsRawValue:
                    Self.iPhoneMicrophoneCategoryOptionsRawValue,
                operationID:
                    enableCategoryOperation.operationID
            )
        )
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertNil(fixture.controller.snapshot.errorText)

        viewModel.disconnect()
        await peer.close()
    }

    func testAutomaticMicrophoneStartsOnHealthyTransportWithoutRemoteAudio() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff,
            installsRemoteAudioTrack: false
        )
        let permissionRequested = expectation(
            description: "automatic permission requested"
        )
        let enableCommitted = expectation(
            description: "microphone enabled without inbound audio"
        )
        var permissionRequestCount = 0
        var nativeAuthorization: WebRTCIOSMicrophoneAuthorization?

        session.viewModel.debugInstallIPhoneMicrophonePermissionRequester {
            permissionRequestCount += 1
            permissionRequested.fulfill()
            return true
        }
        session.viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { authorization in
                nativeAuthorization = authorization
            },
            disable: { authorization, _ in
                if authorization == nil
                    || nativeAuthorization === authorization {
                    nativeAuthorization = nil
                }
                return true
            }
        )
        session.viewModel.debugInstallIPhoneMicrophoneDidCommitObserver {
            authorization in
            XCTAssertTrue(nativeAuthorization === authorization)
            enableCommitted.fulfill()
        }

        XCTAssertFalse(session.viewModel.isRemoteAudioAvailable)
        XCTAssertFalse(session.viewModel.isRemoteAudioPlaying)

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(
            of: [permissionRequested, enableCommitted],
            timeout: 2
        )

        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertTrue(session.viewModel.canViewScreen)
        XCTAssertFalse(session.viewModel.isRemoteAudioAvailable)
        XCTAssertFalse(session.viewModel.isRemoteAudioPlaying)
        XCTAssertTrue(session.viewModel.microphoneIntentEnabled)
        XCTAssertTrue(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(session.viewModel.microphoneStateText, "On")
        XCTAssertTrue(
            nativeAuthorization
                === session.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )

        session.viewModel.toggleIPhoneMicrophone()
        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testNativeAutomaticMicrophoneFailureLatchesUntilExplicitRetry() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff,
            installsRemoteAudioTrack: false
        )
        let permissionRequested = expectation(
            description: "automatic permission requested"
        )
        let firstEnableFailed = expectation(
            description: "first native microphone enable failed"
        )
        let retryCommitted = expectation(
            description: "explicit microphone retry committed"
        )
        let cleanupGate = AudioNonCooperativeGate<Bool>()
        var enableAttemptCount = 0
        var nativeAuthorization: WebRTCIOSMicrophoneAuthorization?

        session.viewModel.debugInstallIPhoneMicrophonePermissionRequester {
            permissionRequested.fulfill()
            return true
        }
        session.viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { authorization in
                enableAttemptCount += 1
                if enableAttemptCount == 1 {
                    firstEnableFailed.fulfill()
                    throw TestAudioError.activation
                }
                nativeAuthorization = authorization
            },
            disable: { authorization, _ in
                if enableAttemptCount == 1,
                   authorization != nil {
                    return await cleanupGate.wait()
                }
                if authorization == nil
                    || nativeAuthorization === authorization {
                    nativeAuthorization = nil
                }
                return true
            }
        )
        session.viewModel.debugInstallIPhoneMicrophoneDidCommitObserver {
            authorization in
            XCTAssertTrue(nativeAuthorization === authorization)
            retryCommitted.fulfill()
        }

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(
            of: [permissionRequested, firstEnableFailed],
            timeout: 2
        )
        await cleanupGate.waitUntilBlocked()
        XCTAssertTrue(
            session.viewModel.isMicrophoneAdmissionCleanupInProgress
        )
        XCTAssertFalse(session.viewModel.canToggleIPhoneMicrophone)
        XCTAssertEqual(
            session.viewModel.microphoneStateText,
            "Recovering audio"
        )
        session.viewModel.toggleIPhoneMicrophone()
        for index in 0..<12 {
            session.fixture.controller.updateRuntimePlayout(
                isReady: index.isMultiple(of: 2)
            )
            await Task.yield()
        }

        XCTAssertEqual(enableAttemptCount, 1)
        await cleanupGate.open(true)
        for _ in 0..<12 {
            await Task.yield()
        }
        XCTAssertFalse(
            session.viewModel.isMicrophoneAdmissionCleanupInProgress
        )
        XCTAssertTrue(session.viewModel.microphoneIntentEnabled)
        XCTAssertFalse(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(session.viewModel.microphoneStateText, "Unavailable")
        XCTAssertEqual(session.viewModel.microphoneError, "activation failed")
        XCTAssertEqual(
            session.viewModel.iPhoneMicrophoneButtonTitle,
            "Retry iPhone Microphone"
        )
        XCTAssertEqual(
            session.viewModel.iPhoneMicrophoneButtonSystemImage,
            "arrow.clockwise"
        )

        session.viewModel.toggleIPhoneMicrophone()
        await fulfillment(of: [retryCommitted], timeout: 2)

        XCTAssertEqual(enableAttemptCount, 2)
        XCTAssertTrue(session.viewModel.microphoneIntentEnabled)
        XCTAssertTrue(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(session.viewModel.microphoneStateText, "On")
        XCTAssertNil(session.viewModel.microphoneError)
        XCTAssertEqual(
            session.viewModel.iPhoneMicrophoneButtonTitle,
            "Turn Off iPhone Microphone"
        )

        session.viewModel.toggleIPhoneMicrophone()
        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testRetryableNativeMicrophoneStartupFailureRecoversAndCommitsAutomatically()
        async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff,
            installsRemoteAudioTrack: false
        )
        let permissionRequested = expectation(
            description: "retryable startup permission requested"
        )
        let firstEnableFailed = expectation(
            description: "retryable native startup failed"
        )
        let recoveryRequested = expectation(
            description: "native output-only recovery requested"
        )
        let recoveredCommit = expectation(
            description: "automatic native startup recovery committed"
        )
        let recoveryGate = AudioNonCooperativeGate<Void>()
        var enableAttemptCount = 0
        var diagnosticsOrdinal: UInt64 = 10
        var admissionRecoveryRequestCount = 0
        var recoverCountAtFirstFailure: Int?
        var nativeAuthorization: WebRTCIOSMicrophoneAuthorization?

        session.viewModel.debugInstallIPhoneMicrophonePermissionRequester {
            permissionRequested.fulfill()
            return true
        }
        session.viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { authorization in
                enableAttemptCount += 1
                if enableAttemptCount == 1 {
                    recoverCountAtFirstFailure =
                        session.fixture.playback.recoverCount
                    firstEnableFailed.fulfill()
                    throw WebRTCTransportError.iPhoneMicrophoneStageFailed(
                        reason: .playoutNotReady,
                        message: "The native microphone path was not ready."
                    )
                }
                nativeAuthorization = authorization
            },
            disable: { authorization, _ in
                authorization?.revoke()
                if authorization == nil
                    || nativeAuthorization === authorization {
                    nativeAuthorization = nil
                }
                return true
            }
        )
        session.viewModel.debugInstallIPhoneMicrophoneDidCommitObserver {
            authorization in
            XCTAssertEqual(enableAttemptCount, 2)
            XCTAssertTrue(nativeAuthorization === authorization)
            recoveredCommit.fulfill()
        }
        session.viewModel.debugInstallIOSPlayoutDiagnosticsReader {
            requestedPeer in
            XCTAssertTrue(requestedPeer === session.peer)
            diagnosticsOrdinal &+= 1
            let microphoneIsAuthorized =
                session.viewModel
                    .debugIPhoneMicrophoneAuthorizationForTests?
                    .isValid == true
            return iosPlayoutDiagnostics(
                callbacks: diagnosticsOrdinal,
                frames: diagnosticsOrdinal * 480,
                failures: 0,
                inputBusEnabled: microphoneIsAuthorized,
                categoryIsMediaPlayback: !microphoneIsAuthorized,
                categoryIsMediaPlayAndRecord: microphoneIsAuthorized
            )
        }
        session.viewModel.debugInstallIOSPlayoutRecoveryRequester {
            requestedPeer,
            authorization in
            XCTAssertTrue(requestedPeer === session.peer)
            if enableAttemptCount == 1 {
                admissionRecoveryRequestCount += 1
                if admissionRecoveryRequestCount == 1 {
                    recoveryRequested.fulfill()
                } else {
                    XCTFail(
                        "A passive proof refresh replaced the owned microphone recovery."
                    )
                }
                await recoveryGate.wait()
            }
            XCTAssertTrue(
                authorization.performIfValidForTesting {}
            )
        }

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(
            of: [
                permissionRequested,
                firstEnableFailed,
                recoveryRequested,
            ],
            timeout: 2
        )
        XCTAssertNotNil(
            session.viewModel
                .debugBeginIOSPlayoutProofForRaceTests(
                    requestRecovery: false
                )
        )
        for _ in 0..<8 {
            await Task.yield()
        }
        XCTAssertEqual(
            enableAttemptCount,
            1,
            "Microphone readmission must wait for the native recovery proof."
        )
        XCTAssertEqual(admissionRecoveryRequestCount, 1)
        await recoveryGate.open(())
        await fulfillment(of: [recoveredCommit], timeout: 2)

        XCTAssertEqual(enableAttemptCount, 2)
        XCTAssertEqual(
            session.fixture.playback.recoverCount,
            try XCTUnwrap(recoverCountAtFirstFailure) + 1
        )
        XCTAssertFalse(
            session.viewModel.isMicrophoneAdmissionCleanupInProgress
        )
        XCTAssertTrue(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(session.viewModel.microphoneStateText, "On")
        XCTAssertNil(session.viewModel.microphoneError)

        session.viewModel.toggleIPhoneMicrophone()
        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testRetryableNativeMicrophoneStartupGetsOneRecoveryPerTransportBinding()
        async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff,
            installsRemoteAudioTrack: false
        )
        let permissionRequested = expectation(
            description: "bounded startup permission requested"
        )
        let firstFailure = expectation(
            description: "first binding initial startup failure"
        )
        let boundedSecondFailure = expectation(
            description: "first binding post-recovery startup failure"
        )
        let replacementFailure = expectation(
            description: "replacement binding initial startup failure"
        )
        let replacementCommit = expectation(
            description: "replacement binding recovery committed"
        )
        var enableAttemptCount = 0
        var recoverCountAtFirstBindingFailure: Int?
        var recoverCountAtReplacementBindingFailure: Int?
        var nativeAuthorization: WebRTCIOSMicrophoneAuthorization?

        session.viewModel.debugInstallIPhoneMicrophonePermissionRequester {
            permissionRequested.fulfill()
            return true
        }
        session.viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { authorization in
                enableAttemptCount += 1
                switch enableAttemptCount {
                case 1:
                    recoverCountAtFirstBindingFailure =
                        session.fixture.playback.recoverCount
                    firstFailure.fulfill()
                case 2:
                    boundedSecondFailure.fulfill()
                case 3:
                    recoverCountAtReplacementBindingFailure =
                        session.fixture.playback.recoverCount
                    replacementFailure.fulfill()
                case 4:
                    nativeAuthorization = authorization
                    return
                default:
                    XCTFail(
                        "A bounded startup recovery created an enable loop."
                    )
                    return
                }
                throw WebRTCTransportError.iPhoneMicrophoneStageFailed(
                    reason: .topologyStillNotStaged,
                    message: "The microphone topology remained unstaged."
                )
            },
            disable: { authorization, _ in
                authorization?.revoke()
                if authorization == nil
                    || nativeAuthorization === authorization {
                    nativeAuthorization = nil
                }
                return true
            }
        )
        session.viewModel.debugInstallIPhoneMicrophoneDidCommitObserver {
            authorization in
            XCTAssertEqual(enableAttemptCount, 4)
            XCTAssertTrue(nativeAuthorization === authorization)
            replacementCommit.fulfill()
        }
        installProductionShapedIOSRecoveryHarness(
            on: session.viewModel,
            peer: session.peer
        )

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(
            of: [
                permissionRequested,
                firstFailure,
                boundedSecondFailure,
            ],
            timeout: 2
        )
        for _ in 0..<12
        where session.viewModel.isMicrophoneAdmissionCleanupInProgress {
            await Task.yield()
        }

        XCTAssertEqual(enableAttemptCount, 2)
        XCTAssertEqual(
            session.fixture.playback.recoverCount,
            try XCTUnwrap(recoverCountAtFirstBindingFailure) + 1
        )
        XCTAssertFalse(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(session.viewModel.microphoneStateText, "Unavailable")
        XCTAssertTrue(
            session.viewModel.microphoneError?
                .contains("after automatic audio recovery") == true
        )

        session.viewModel.disconnect()
        await session.peer.close()
        session.fixture.controller.prepare(serverName: "Replacement Mac")
        let replacementPeer = try makeAudioRacePeer()
        session.viewModel.debugInstallScreenSessionForTests(
            peer: replacementPeer,
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        installProductionShapedIOSRecoveryHarness(
            on: session.viewModel,
            peer: replacementPeer
        )

        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(
            of: [replacementFailure, replacementCommit],
            timeout: 2
        )

        XCTAssertEqual(enableAttemptCount, 4)
        XCTAssertEqual(
            session.fixture.playback.recoverCount,
            try XCTUnwrap(
                recoverCountAtReplacementBindingFailure
            ) + 1
        )
        XCTAssertTrue(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(session.viewModel.microphoneStateText, "On")
        XCTAssertNil(session.viewModel.microphoneError)

        session.viewModel.toggleIPhoneMicrophone()
        session.viewModel.disconnect()
        await replacementPeer.close()
    }

    func testTransportRaceWaitsForFreshHealthyProofThenRetriesAutomatically()
        async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff,
            installsRemoteAudioTrack: false
        )
        let permissionRequested = expectation(
            description: "automatic permission requested"
        )
        let firstEnableDeferred = expectation(
            description: "first transport-raced enable deferred"
        )
        let retryCommitted = expectation(
            description: "fresh healthy proof committed retry"
        )
        var enableAttemptCount = 0
        var nativeAuthorization: WebRTCIOSMicrophoneAuthorization?

        session.viewModel.debugInstallIPhoneMicrophonePermissionRequester {
            permissionRequested.fulfill()
            return true
        }
        session.viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { authorization in
                enableAttemptCount += 1
                if enableAttemptCount == 1 {
                    firstEnableDeferred.fulfill()
                    throw WebRTCTransportError.transportNotHealthy
                }
                nativeAuthorization = authorization
            },
            disable: { authorization, _ in
                if authorization == nil
                    || nativeAuthorization === authorization {
                    nativeAuthorization = nil
                }
                return true
            }
        )
        session.viewModel.debugInstallIPhoneMicrophoneDidCommitObserver {
            authorization in
            XCTAssertTrue(nativeAuthorization === authorization)
            retryCommitted.fulfill()
        }

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(
            of: [permissionRequested, firstEnableDeferred],
            timeout: 2
        )
        for index in 0..<12 {
            session.fixture.controller.updateRuntimePlayout(
                isReady: index.isMultiple(of: 2)
            )
            await Task.yield()
        }

        XCTAssertEqual(enableAttemptCount, 1)
        XCTAssertTrue(session.viewModel.microphoneIntentEnabled)
        XCTAssertFalse(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(
            session.viewModel.microphoneStateText,
            "Paused — waiting for healthy connection"
        )

        session.viewModel
            .debugMarkViewerTransportUncertainForAutomaticMicrophoneTests()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(of: [retryCommitted], timeout: 2)

        XCTAssertEqual(enableAttemptCount, 2)
        XCTAssertTrue(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(session.viewModel.microphoneStateText, "On")
        XCTAssertNil(session.viewModel.microphoneError)

        session.viewModel.toggleIPhoneMicrophone()
        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testTransportUncertaintyRetiresEstablishedMicrophoneBeforeHealthyReAdmission() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        let permissionRequested = expectation(
            description: "reconnect microphone permission"
        )
        let initialCommit = expectation(
            description: "initial reconnect microphone commit"
        )
        let retiredAuthorizationDisabled = expectation(
            description: "reconnect retired authorization disabled"
        )
        retiredAuthorizationDisabled.assertForOverFulfill = false
        let recoveredCommit = expectation(
            description: "reconnect fresh microphone commit"
        )
        var enableAuthorizations:
            [WebRTCIOSMicrophoneAuthorization] = []
        var committedAuthorizations:
            [WebRTCIOSMicrophoneAuthorization] = []

        session.viewModel
            .debugInstallIPhoneMicrophonePermissionRequester {
                permissionRequested.fulfill()
                return true
            }
        session.viewModel
            .debugInstallIPhoneMicrophoneNativeHandlers(
                enable: { authorization in
                    enableAuthorizations.append(authorization)
                    authorization
                        .debugSetRecordingGenerationForTesting(
                            0xA11C_E500
                                + UInt64(
                                    enableAuthorizations.count
                                )
                        )
                },
                disable: { authorization, _ in
                    if authorization
                        === enableAuthorizations.first {
                        retiredAuthorizationDisabled.fulfill()
                    }
                    authorization?.revoke()
                    return true
                }
            )
        session.viewModel
            .debugInstallIPhoneMicrophoneDidCommitObserver {
                authorization in
                committedAuthorizations.append(authorization)
                switch committedAuthorizations.count {
                case 1:
                    initialCommit.fulfill()
                case 2:
                    recoveredCommit.fulfill()
                default:
                    XCTFail(
                        "Reconnect committed more than one replacement microphone."
                    )
                }
            }

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(
            of: [permissionRequested, initialCommit],
            timeout: 2
        )
        let retiredAuthorization = try XCTUnwrap(
            session.viewModel
                .debugIPhoneMicrophoneAuthorizationForTests
        )
        XCTAssertTrue(retiredAuthorization.isValid)
        XCTAssertTrue(session.viewModel.isMicrophoneSending)

        session.viewModel
            .debugMarkViewerTransportUncertainForAutomaticMicrophoneTests()

        XCTAssertFalse(retiredAuthorization.isValid)
        XCTAssertNil(
            session.viewModel
                .debugIPhoneMicrophoneAuthorizationForTests
        )
        XCTAssertFalse(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(
            session.viewModel.microphoneStateText,
            "Paused — reconnecting"
        )
        await fulfillment(
            of: [retiredAuthorizationDisabled],
            timeout: 2
        )

        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(of: [recoveredCommit], timeout: 2)
        let recoveredAuthorization = try XCTUnwrap(
            session.viewModel
                .debugIPhoneMicrophoneAuthorizationForTests
        )

        XCTAssertFalse(
            recoveredAuthorization === retiredAuthorization
        )
        XCTAssertNotEqual(
            recoveredAuthorization.recordingGeneration,
            retiredAuthorization.recordingGeneration
        )
        XCTAssertTrue(recoveredAuthorization.isValid)
        XCTAssertEqual(enableAuthorizations.count, 2)
        XCTAssertEqual(committedAuthorizations.count, 2)
        XCTAssertTrue(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(session.viewModel.microphoneStateText, "On")

        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        XCTAssertEqual(enableAuthorizations.count, 2)
        XCTAssertEqual(committedAuthorizations.count, 2)
        XCTAssertTrue(
            session.viewModel
                .debugIPhoneMicrophoneAuthorizationForTests
                === recoveredAuthorization
        )

        session.viewModel.toggleIPhoneMicrophone()
        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testAutomaticMicrophoneStartsAfterAuthenticatedRecoveryProofWithoutRemoteAudio()
        async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff,
            installsRemoteAudioTrack: false
        )
        let permissionRequested = expectation(
            description: "recovery requested microphone permission"
        )
        let enableCommitted = expectation(
            description: "recovery committed microphone enable"
        )
        var permissionRequestCount = 0
        var nativeAuthorization:
            WebRTCIOSMicrophoneAuthorization?

        session.viewModel
            .debugInstallIPhoneMicrophonePermissionRequester {
                permissionRequestCount += 1
                permissionRequested.fulfill()
                return true
            }
        session.viewModel
            .debugInstallIPhoneMicrophoneNativeHandlers(
                enable: { authorization in
                    nativeAuthorization = authorization
                },
                disable: { authorization, _ in
                    if authorization == nil
                        || nativeAuthorization === authorization {
                        nativeAuthorization = nil
                    }
                    return true
                }
            )
        session.viewModel
            .debugInstallIPhoneMicrophoneDidCommitObserver {
                authorization in
                XCTAssertTrue(
                    nativeAuthorization === authorization
                )
                enableCommitted.fulfill()
            }

        session.viewModel
            .debugMarkViewerTransportUncertainForAutomaticMicrophoneTests()
        session.viewModel.handleAppBecameActive()

        XCTAssertFalse(
            session.viewModel.microphoneIntentEnabled
        )
        XCTAssertFalse(
            session.viewModel.isRemoteAudioAvailable
        )
        XCTAssertFalse(
            session.viewModel.isRemoteAudioPlaying
        )

        await session.viewModel
            .debugCompleteRecoveryProbeForAutomaticMicrophoneTests()
        await fulfillment(
            of: [permissionRequested, enableCommitted],
            timeout: 2
        )

        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertTrue(session.viewModel.canViewScreen)
        XCTAssertTrue(
            session.viewModel.microphoneIntentEnabled
        )
        XCTAssertTrue(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(
            session.viewModel.microphoneStateText,
            "On"
        )
        XCTAssertFalse(
            session.viewModel.isRemoteAudioAvailable
        )
        XCTAssertTrue(
            nativeAuthorization
                === session.viewModel
                    .debugIPhoneMicrophoneAuthorizationForTests
        )

        session.viewModel.toggleIPhoneMicrophone()
        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testInactiveDuringPendingNativeMicrophoneEnableRevokesAndRetriesOnce() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        let permissionRequested = expectation(
            description: "automatic permission granted"
        )
        let firstNativeEnableEntered = expectation(
            description: "first injected native enable entered"
        )
        let staleNativeEnableCleanedUp = expectation(
            description: "stale injected native enable cleaned up"
        )
        let freshNativeEnableCommitted = expectation(
            description: "fresh injected native enable committed"
        )
        let firstNativeEnableGate = AudioNonCooperativeGate<Bool>()
        var permissionRequestCount = 0
        var nativeAuthorization: WebRTCIOSMicrophoneAuthorization?
        var enableAuthorizations: [WebRTCIOSMicrophoneAuthorization] = []
        var disableAuthorizations: [WebRTCIOSMicrophoneAuthorization?] = []
        var committedAuthorizations: [WebRTCIOSMicrophoneAuthorization] = []

        session.viewModel.debugInstallIPhoneMicrophonePermissionRequester {
            permissionRequestCount += 1
            permissionRequested.fulfill()
            return true
        }

        session.viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { authorization in
                enableAuthorizations.append(authorization)
                switch enableAuthorizations.count {
                case 1:
                    firstNativeEnableEntered.fulfill()
                    _ = await firstNativeEnableGate.wait()
                case 2:
                    break
                default:
                    XCTFail("Native microphone enable attempted more than twice.")
                }
                nativeAuthorization = authorization
            },
            disable: { authorization, _ in
                disableAuthorizations.append(authorization)
                if authorization == nil
                    || nativeAuthorization === authorization {
                    nativeAuthorization = nil
                }
                if disableAuthorizations.count == 2 {
                    staleNativeEnableCleanedUp.fulfill()
                }
                return true
            }
        )
        session.viewModel.debugInstallIPhoneMicrophoneDidCommitObserver {
            authorization in
            committedAuthorizations.append(authorization)
            switch committedAuthorizations.count {
            case 1:
                freshNativeEnableCommitted.fulfill()
            default:
                XCTFail("Microphone authorization committed more than once.")
            }
        }

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(
            of: [
                permissionRequested,
                firstNativeEnableEntered,
            ],
            timeout: 2
        )

        let pendingAuthorization =
            session.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertEqual(enableAuthorizations.count, 1)
        XCTAssertTrue(enableAuthorizations.first === pendingAuthorization)
        XCTAssertNil(nativeAuthorization)
        XCTAssertEqual(pendingAuthorization?.isValid, true)
        XCTAssertFalse(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(session.viewModel.microphoneStateText, "Starting")

        session.viewModel.handleAppBecameInactive()
        XCTAssertEqual(pendingAuthorization?.isValid, false)
        XCTAssertNil(
            session.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )
        XCTAssertTrue(session.viewModel.microphoneIntentEnabled)
        XCTAssertFalse(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(
            session.viewModel.microphoneStateText,
            "Paused — waiting for app"
        )
        session.viewModel.handleAppEnteredBackground()
        await firstNativeEnableGate.open(true)
        await fulfillment(of: [staleNativeEnableCleanedUp], timeout: 2)
        let revokedAuthorization = try XCTUnwrap(pendingAuthorization)

        XCTAssertFalse(revokedAuthorization.isValid)
        XCTAssertNil(nativeAuthorization)
        XCTAssertTrue(committedAuthorizations.isEmpty)
        XCTAssertFalse(session.viewModel.isMicrophoneSending)
        XCTAssertNotEqual(session.viewModel.microphoneStateText, "On")
        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertEqual(enableAuthorizations.count, 1)
        XCTAssertEqual(disableAuthorizations.count, 2)
        XCTAssertTrue(
            disableAuthorizations.allSatisfy {
                $0 === revokedAuthorization
            }
        )

        session.viewModel.handleAppBecameActive()
        await fulfillment(of: [freshNativeEnableCommitted], timeout: 2)
        let recoveredAuthorization = try XCTUnwrap(
            session.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )

        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertEqual(enableAuthorizations.count, 2)
        XCTAssertTrue(enableAuthorizations[1] === recoveredAuthorization)
        XCTAssertEqual(committedAuthorizations.count, 1)
        XCTAssertTrue(
            committedAuthorizations[0] === recoveredAuthorization
        )
        XCTAssertTrue(nativeAuthorization === recoveredAuthorization)
        XCTAssertTrue(recoveredAuthorization.isValid)
        XCTAssertTrue(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(session.viewModel.microphoneStateText, "On")

        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        XCTAssertEqual(enableAuthorizations.count, 2)
        XCTAssertEqual(committedAuthorizations.count, 1)
        XCTAssertEqual(disableAuthorizations.count, 2)
        XCTAssertTrue(nativeAuthorization === recoveredAuthorization)

        session.viewModel.toggleIPhoneMicrophone()
        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testAutomaticMicrophoneDefersWhileAppIsInactive() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        let nativePolicies = AudioLockedValues<Bool>()
        let permissionRequested = expectation(description: "foreground permission request")
        var permissionRequestCount = 0
        session.viewModel.debugInstallIPhoneMicrophonePermissionRequester {
            permissionRequestCount += 1
            permissionRequested.fulfill()
            return false
        }
        await session.peer.debugInstallIPhoneMicrophonePolicyApplier {
            isEnabled in
            nativePolicies.append(isEnabled)
            return true
        }

        session.viewModel.handleAppBecameInactive()
        session.viewModel.handleAppEnteredBackground()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        XCTAssertEqual(permissionRequestCount, 0)
        XCTAssertFalse(session.viewModel.microphoneIntentEnabled)
        XCTAssertNil(
            session.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )
        let inactivePolicySnapshot =
            await session.peer.debugIPhoneMicrophonePolicySnapshot
        XCTAssertNil(inactivePolicySnapshot.activeAuthorizationIdentity)
        XCTAssertFalse(inactivePolicySnapshot.trackIsEnabled)
        XCTAssertTrue(nativePolicies.values.isEmpty)

        session.viewModel.handleAppBecameActive()
        await fulfillment(of: [permissionRequested], timeout: 2)
        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertNil(
            session.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )
        let deniedPolicySnapshot =
            await session.peer.debugIPhoneMicrophonePolicySnapshot
        XCTAssertNil(deniedPolicySnapshot.activeAuthorizationIdentity)
        XCTAssertFalse(deniedPolicySnapshot.trackIsEnabled)
        XCTAssertTrue(nativePolicies.values.isEmpty)

        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testGrantedAutomaticPermissionCompletionWhileInactiveWaitsForOneActiveReconcile() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        let permissionStarted = expectation(description: "automatic permission started")
        let permissionResolved = expectation(
            description: "granted permission resolved while inactive"
        )
        let enableCommitted = expectation(
            description: "foreground native enable committed"
        )
        let permissionGate = AudioNonCooperativeGate<Bool>()
        var permissionRequestCount = 0
        var nativeAuthorization: WebRTCIOSMicrophoneAuthorization?
        var enableAuthorizations: [WebRTCIOSMicrophoneAuthorization] = []
        var disableAuthorizations: [WebRTCIOSMicrophoneAuthorization?] = []
        session.viewModel.debugInstallIPhoneMicrophonePermissionRequester {
            permissionRequestCount += 1
            permissionStarted.fulfill()
            return await permissionGate.wait()
        }

        session.viewModel
            .debugInstallIPhoneMicrophonePermissionResolutionObserver {
                granted in
                XCTAssertTrue(granted)
                permissionResolved.fulfill()
            }
        session.viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { authorization in
                enableAuthorizations.append(authorization)
                nativeAuthorization = authorization
            },
            disable: { authorization, _ in
                disableAuthorizations.append(authorization)
                if authorization == nil
                    || nativeAuthorization === authorization {
                    nativeAuthorization = nil
                }
                return true
            }
        )
        session.viewModel.debugInstallIPhoneMicrophoneDidCommitObserver {
            authorization in
            XCTAssertTrue(nativeAuthorization === authorization)
            enableCommitted.fulfill()
        }

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(of: [permissionStarted], timeout: 2)
        await permissionGate.waitUntilBlocked()

        session.viewModel.handleAppBecameInactive()
        session.viewModel.handleAppEnteredBackground()
        await permissionGate.open(true)
        await fulfillment(of: [permissionResolved], timeout: 2)

        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertTrue(enableAuthorizations.isEmpty)
        XCTAssertTrue(disableAuthorizations.isEmpty)
        XCTAssertNil(nativeAuthorization)
        XCTAssertTrue(session.viewModel.microphoneIntentEnabled)
        XCTAssertFalse(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(
            session.viewModel.microphoneStateText,
            "Paused — waiting for app"
        )
        XCTAssertNil(
            session.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )

        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertTrue(enableAuthorizations.isEmpty)
        XCTAssertTrue(disableAuthorizations.isEmpty)
        XCTAssertNil(
            session.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )

        session.viewModel.handleAppBecameActive()
        await fulfillment(of: [enableCommitted], timeout: 2)
        let activeAuthorization = try XCTUnwrap(
            session.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )

        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertEqual(enableAuthorizations.count, 1)
        XCTAssertTrue(enableAuthorizations[0] === activeAuthorization)
        XCTAssertTrue(nativeAuthorization === activeAuthorization)
        XCTAssertTrue(disableAuthorizations.isEmpty)
        XCTAssertTrue(activeAuthorization.isValid)
        XCTAssertTrue(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(session.viewModel.microphoneStateText, "On")

        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        XCTAssertEqual(enableAuthorizations.count, 1)
        XCTAssertTrue(disableAuthorizations.isEmpty)
        XCTAssertTrue(nativeAuthorization === activeAuthorization)

        session.viewModel.toggleIPhoneMicrophone()
        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testManualMicrophoneOffCancelsPendingAutomaticAttemptAndPersistsAcrossRecovery() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        let permissionStarted = expectation(description: "automatic permission started")
        let permissionGate = AudioNonCooperativeGate<Bool>()
        var permissionRequestCount = 0
        session.viewModel.debugInstallIPhoneMicrophonePermissionRequester {
            permissionRequestCount += 1
            permissionStarted.fulfill()
            return await permissionGate.wait()
        }

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(of: [permissionStarted], timeout: 2)
        XCTAssertTrue(session.viewModel.microphoneIntentEnabled)

        session.viewModel.toggleIPhoneMicrophone()
        XCTAssertFalse(session.viewModel.microphoneIntentEnabled)
        await permissionGate.open(true)
        await Task.yield()

        session.viewModel.debugMarkViewerTransportUncertainForAutomaticMicrophoneTests()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        session.viewModel.handleAppBecameActive()
        await Task.yield()
        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertFalse(session.viewModel.microphoneIntentEnabled)

        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testDeniedAutomaticMicrophonePermissionDoesNotLoop() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        let permissionRequested = expectation(description: "denied permission request")
        var permissionRequestCount = 0
        session.viewModel.debugInstallIPhoneMicrophonePermissionRequester {
            permissionRequestCount += 1
            permissionRequested.fulfill()
            return false
        }

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(of: [permissionRequested], timeout: 2)
        await Task.yield()
        XCTAssertEqual(session.viewModel.microphoneStateText, "Permission denied")
        XCTAssertFalse(session.viewModel.microphoneIntentEnabled)

        session.viewModel.debugMarkViewerTransportUncertainForAutomaticMicrophoneTests()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        session.viewModel.handleAppBecameInactive()
        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await Task.yield()
        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertFalse(session.viewModel.microphoneIntentEnabled)

        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testNewAuthenticatedSessionMayRetryAutomaticMicrophoneAfterDenial() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        let firstRequest = expectation(description: "first session permission request")
        let secondRequest = expectation(description: "second session permission request")
        var permissionRequestCount = 0
        session.viewModel.debugInstallIPhoneMicrophonePermissionRequester {
            permissionRequestCount += 1
            switch permissionRequestCount {
            case 1:
                firstRequest.fulfill()
            case 2:
                secondRequest.fulfill()
            default:
                XCTFail("Automatic permission requested more than once in a media session.")
            }
            return false
        }

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(of: [firstRequest], timeout: 2)
        await Task.yield()
        XCTAssertEqual(permissionRequestCount, 1)

        session.viewModel.disconnect()
        await session.peer.close()
        session.fixture.controller.prepare(serverName: "Replacement Mac")
        session.fixture.controller.remoteAudioBecameAvailable(session.fixture.remoteAudio)
        let replacementPeer = try makeAudioRacePeer()
        session.viewModel.debugInstallScreenSessionForTests(
            peer: replacementPeer,
            provenance: .authenticatedPairedCoordinatorHandoff
        )

        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(of: [secondRequest], timeout: 2)
        await Task.yield()
        XCTAssertEqual(permissionRequestCount, 2)

        session.viewModel.disconnect()
        await replacementPeer.close()
    }

    func testEstablishedAutomaticMicrophoneRemainsSendingAcrossInactiveAndBackground() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        let permissionRequested = expectation(description: "automatic permission granted")
        let enableCommitted = expectation(
            description: "native microphone committed"
        )
        var permissionRequestCount = 0
        var nativeAuthorization: WebRTCIOSMicrophoneAuthorization?
        var enableAuthorizations: [WebRTCIOSMicrophoneAuthorization] = []
        var disableAuthorizations: [WebRTCIOSMicrophoneAuthorization?] = []
        session.viewModel.debugInstallIPhoneMicrophonePermissionRequester {
            permissionRequestCount += 1
            permissionRequested.fulfill()
            return true
        }
        session.viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { authorization in
                enableAuthorizations.append(authorization)
                nativeAuthorization = authorization
            },
            disable: { authorization, _ in
                disableAuthorizations.append(authorization)
                if authorization == nil
                    || nativeAuthorization === authorization {
                    nativeAuthorization = nil
                }
                return true
            }
        )
        session.viewModel.debugInstallIPhoneMicrophoneDidCommitObserver {
            authorization in
            XCTAssertTrue(nativeAuthorization === authorization)
            enableCommitted.fulfill()
        }

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(
            of: [permissionRequested, enableCommitted],
            timeout: 2
        )
        let authorization = try XCTUnwrap(
            session.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )

        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertEqual(enableAuthorizations.count, 1)
        XCTAssertTrue(enableAuthorizations[0] === authorization)
        XCTAssertTrue(nativeAuthorization === authorization)
        XCTAssertTrue(disableAuthorizations.isEmpty)
        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(session.viewModel.microphoneStateText, "On")

        session.viewModel.handleAppBecameInactive()
        let inactiveAuthorization = try XCTUnwrap(
            session.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )
        XCTAssertTrue(inactiveAuthorization === authorization)
        XCTAssertTrue(inactiveAuthorization.isValid)
        XCTAssertTrue(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(session.viewModel.microphoneStateText, "On")

        session.viewModel.handleAppEnteredBackground()
        let backgroundAuthorization = try XCTUnwrap(
            session.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )
        XCTAssertTrue(backgroundAuthorization === authorization)
        XCTAssertTrue(backgroundAuthorization.isValid)
        XCTAssertTrue(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(session.viewModel.microphoneStateText, "On")

        session.viewModel.handleAppBecameActive()
        let resumedAuthorization = try XCTUnwrap(
            session.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )
        XCTAssertTrue(resumedAuthorization === authorization)
        XCTAssertTrue(resumedAuthorization.isValid)
        XCTAssertTrue(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(session.viewModel.microphoneStateText, "On")
        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertEqual(enableAuthorizations.count, 1)
        XCTAssertTrue(disableAuthorizations.isEmpty)
        XCTAssertTrue(nativeAuthorization === authorization)

        session.viewModel.toggleIPhoneMicrophone()
        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testSustainedZeroMicrophoneStartupGetsOneAutomaticRecovery() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        installProductionShapedIOSRecoveryHarness(
            on: session.viewModel,
            peer: session.peer
        )
        let permissionRequested = expectation(
            description: "zero-start microphone permission"
        )
        let initialCommit = expectation(
            description: "initial zero-start microphone commit"
        )
        let recoveryCommit = expectation(
            description: "automatic zero-start microphone recovery commit"
        )
        var enableCount = 0
        var disableCount = 0
        var statisticsReadCount: UInt64 = 0
        var recordingGeneration: UInt64 = 0

        session.viewModel
            .debugInstallIPhoneMicrophonePermissionRequester {
                permissionRequested.fulfill()
                return true
            }
        session.viewModel
            .debugInstallIPhoneMicrophoneNativeHandlers(
                enable: { authorization in
                    enableCount += 1
                    recordingGeneration =
                        0xA11C_E100 + UInt64(enableCount)
                    authorization.debugSetRecordingGenerationForTesting(
                        recordingGeneration
                    )
                },
                disable: { authorization, _ in
                    disableCount += 1
                    authorization?.revoke()
                    return true
                }
            )
        session.viewModel
            .debugInstallIPhoneMicrophoneDidCommitObserver { _ in
                switch enableCount {
                case 1:
                    initialCommit.fulfill()
                case 2:
                    recoveryCommit.fulfill()
                default:
                    XCTFail(
                        "A continuous zero-start fault must not create an automatic recovery loop."
                    )
                }
            }
        session.viewModel
            .debugInstallIPhoneMicrophoneSenderStatisticsReader {
                [weak self] _ in
                guard let self else { return nil }
                statisticsReadCount += 1
                return self.rawMicrophoneSenderStatisticsForTests(
                    sample: statisticsReadCount,
                    counterSample: 0,
                    recordingGeneration: recordingGeneration
                )
            }

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(
            of: [permissionRequested, initialCommit],
            timeout: 2
        )
        let recoverCountBeforeStall =
            session.fixture.playback.recoverCount

        for _ in 0..<4 {
            await session.viewModel
                .debugRefreshRawMicrophoneOracleForTests(
                    from: session.peer
                )
        }
        await fulfillment(of: [recoveryCommit], timeout: 2)
        XCTAssertEqual(enableCount, 2)
        XCTAssertGreaterThanOrEqual(disableCount, 1)
        XCTAssertEqual(
            session.fixture.playback.recoverCount,
            recoverCountBeforeStall + 1
        )
        XCTAssertTrue(session.viewModel.isMicrophoneSending)

        for _ in 0..<4 {
            await session.viewModel
                .debugRefreshRawMicrophoneOracleForTests(
                    from: session.peer
                )
        }
        for _ in 0..<8 {
            await Task.yield()
        }
        XCTAssertEqual(
            session.fixture.playback.recoverCount,
            recoverCountBeforeStall + 1,
            "The same session gets only one automatic audio rebuild."
        )
        XCTAssertEqual(enableCount, 2)
        XCTAssertEqual(session.viewModel.microphoneStateText, "Unavailable")
        XCTAssertFalse(session.viewModel.isMicrophoneSending)

        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testSustainedMissingExactMicrophoneSenderStatisticsGetsOneAutomaticRecoveryAndThenFailsBoundedly() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff,
            installsRemoteAudioTrack: false
        )
        installProductionShapedIOSRecoveryHarness(
            on: session.viewModel,
            peer: session.peer
        )
        let permissionRequested = expectation(
            description: "missing-sender microphone permission"
        )
        let initialCommit = expectation(
            description: "initial missing-sender microphone commit"
        )
        let recoveryCommit = expectation(
            description: "missing-sender automatic recovery commit"
        )
        var enableCount = 0
        var disableCount = 0
        var recordingGeneration: UInt64 = 0
        var observationTime: TimeInterval = 1

        session.viewModel
            .debugInstallIPhoneMicrophonePermissionRequester {
                permissionRequested.fulfill()
                return true
            }
        session.viewModel
            .debugInstallIPhoneMicrophoneNativeHandlers(
                enable: { authorization in
                    enableCount += 1
                    recordingGeneration =
                        0xA11C_E200 + UInt64(enableCount)
                    authorization.debugSetRecordingGenerationForTesting(
                        recordingGeneration
                    )
                },
                disable: { authorization, _ in
                    disableCount += 1
                    authorization?.revoke()
                    return true
                }
            )
        session.viewModel
            .debugInstallIPhoneMicrophoneDidCommitObserver { _ in
                switch enableCount {
                case 1:
                    initialCommit.fulfill()
                case 2:
                    recoveryCommit.fulfill()
                default:
                    XCTFail(
                        "A missing sender must not create an automatic recovery loop."
                    )
                }
            }
        session.viewModel
            .debugInstallIPhoneMicrophoneSenderStatisticsReader { _ in
                nil
            }
        session.viewModel
            .debugInstallRawMicrophoneMissingStatisticsUptimeClock {
                defer { observationTime += 1 }
                return observationTime
            }

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(
            of: [permissionRequested, initialCommit],
            timeout: 2
        )
        let recoverCountBeforeStall =
            session.fixture.playback.recoverCount

        for _ in 0..<4 {
            await session.viewModel
                .debugRefreshRawMicrophoneOracleForTests(
                    from: session.peer
                )
        }
        await fulfillment(of: [recoveryCommit], timeout: 2)
        XCTAssertEqual(enableCount, 2)
        XCTAssertGreaterThanOrEqual(disableCount, 1)
        XCTAssertEqual(
            session.fixture.playback.recoverCount,
            recoverCountBeforeStall + 1
        )
        XCTAssertTrue(session.viewModel.isMicrophoneSending)

        for _ in 0..<4 {
            await session.viewModel
                .debugRefreshRawMicrophoneOracleForTests(
                    from: session.peer
                )
        }
        for _ in 0..<8 {
            await Task.yield()
        }
        XCTAssertEqual(
            session.fixture.playback.recoverCount,
            recoverCountBeforeStall + 1,
            "The same session gets only one automatic audio rebuild."
        )
        XCTAssertEqual(enableCount, 2)
        XCTAssertEqual(
            session.viewModel.microphoneStateText,
            "Unavailable"
        )
        XCTAssertFalse(session.viewModel.isMicrophoneSending)

        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testOneIsolatedExactSenderSampleCannotEraseNoProgressRecoveryEvidence() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        installProductionShapedIOSRecoveryHarness(
            on: session.viewModel,
            peer: session.peer
        )
        let permissionRequested = expectation(
            description: "intermittent sender permission"
        )
        let initialCommit = expectation(
            description: "intermittent sender initial commit"
        )
        let recoveryCommit = expectation(
            description: "intermittent sender recovery commit"
        )
        var enableCount = 0
        var recordingGeneration: UInt64 = 0
        var statisticsReadCount: UInt64 = 0
        var missingObservationTime: TimeInterval = 1

        session.viewModel
            .debugInstallIPhoneMicrophonePermissionRequester {
                permissionRequested.fulfill()
                return true
            }
        session.viewModel
            .debugInstallIPhoneMicrophoneNativeHandlers(
                enable: { authorization in
                    enableCount += 1
                    recordingGeneration =
                        0xA11C_E300 + UInt64(enableCount)
                    authorization.debugSetRecordingGenerationForTesting(
                        recordingGeneration
                    )
                },
                disable: { authorization, _ in
                    authorization?.revoke()
                    return true
                }
            )
        session.viewModel
            .debugInstallIPhoneMicrophoneDidCommitObserver { _ in
                switch enableCount {
                case 1:
                    initialCommit.fulfill()
                case 2:
                    recoveryCommit.fulfill()
                default:
                    XCTFail(
                        "One isolated report created an automatic recovery loop."
                    )
                }
            }
        session.viewModel
            .debugInstallIPhoneMicrophoneSenderStatisticsReader {
                [weak self] _ in
                statisticsReadCount += 1
                guard statisticsReadCount == 4,
                      let self else {
                    return nil
                }
                return self.rawMicrophoneSenderStatisticsForTests(
                    sample: 1,
                    recordingGeneration: recordingGeneration
                )
            }
        session.viewModel
            .debugInstallRawMicrophoneMissingStatisticsUptimeClock {
                defer { missingObservationTime += 1 }
                return missingObservationTime
            }

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(
            of: [permissionRequested, initialCommit],
            timeout: 2
        )
        let recoverCount = session.fixture.playback.recoverCount

        for _ in 0..<7 {
            await session.viewModel
                .debugRefreshRawMicrophoneOracleForTests(
                    from: session.peer
                )
        }
        await fulfillment(of: [recoveryCommit], timeout: 2)

        XCTAssertEqual(
            session.fixture.playback.recoverCount,
            recoverCount + 1,
            "Only coherent advancing evidence may reset the no-progress fault window."
        )
        XCTAssertEqual(enableCount, 2)
        XCTAssertTrue(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(session.viewModel.microphoneStateText, "On")

        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testInterleavedMissingAndFrozenExactSenderStatisticsStillRecover() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        installProductionShapedIOSRecoveryHarness(
            on: session.viewModel,
            peer: session.peer
        )
        let permissionRequested = expectation(
            description: "interleaved sender permission"
        )
        let initialCommit = expectation(
            description: "interleaved sender initial commit"
        )
        let recoveryCommit = expectation(
            description: "interleaved sender recovery commit"
        )
        var enableCount = 0
        var statisticsReadCount: UInt64 = 0
        var recordingGeneration: UInt64 = 0
        var missingObservationTime: TimeInterval = 1

        session.viewModel
            .debugInstallIPhoneMicrophonePermissionRequester {
                permissionRequested.fulfill()
                return true
            }
        session.viewModel
            .debugInstallIPhoneMicrophoneNativeHandlers(
                enable: { authorization in
                    enableCount += 1
                    recordingGeneration =
                        0xA11C_E350 + UInt64(enableCount)
                    authorization.debugSetRecordingGenerationForTesting(
                        recordingGeneration
                    )
                },
                disable: { authorization, _ in
                    authorization?.revoke()
                    return true
                }
            )
        session.viewModel
            .debugInstallIPhoneMicrophoneDidCommitObserver { _ in
                switch enableCount {
                case 1:
                    initialCommit.fulfill()
                case 2:
                    recoveryCommit.fulfill()
                default:
                    XCTFail(
                        "Interleaved evidence created an automatic recovery loop."
                    )
                }
            }
        session.viewModel
            .debugInstallIPhoneMicrophoneSenderStatisticsReader {
                [weak self] _ in
                statisticsReadCount += 1
                guard statisticsReadCount.isMultiple(of: 2),
                      let self else {
                    return nil
                }
                return self.rawMicrophoneSenderStatisticsForTests(
                    sample: statisticsReadCount,
                    counterSample: 0,
                    recordingGeneration: recordingGeneration
                )
            }
        session.viewModel
            .debugInstallRawMicrophoneMissingStatisticsUptimeClock {
                defer { missingObservationTime += 1 }
                return missingObservationTime
            }

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(
            of: [permissionRequested, initialCommit],
            timeout: 2
        )
        let recoverCount = session.fixture.playback.recoverCount

        for _ in 0..<8 {
            await session.viewModel
                .debugRefreshRawMicrophoneOracleForTests(
                    from: session.peer
                )
        }
        await fulfillment(of: [recoveryCommit], timeout: 2)

        XCTAssertEqual(enableCount, 2)
        XCTAssertEqual(
            session.fixture.playback.recoverCount,
            recoverCount + 1
        )
        XCTAssertTrue(session.viewModel.isMicrophoneSending)

        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testSuspendedMissingStatisticsReadCannotRecoverAcrossEveryRevocationBoundary() async throws {
        for boundary in RawMicrophoneReadRevocationBoundary.allCases {
            let session = try makeAutomaticMicrophonePolicyFixture(
                provenance: .authenticatedPairedCoordinatorHandoff
            )
            let permissionRequested = expectation(
                description: "\(boundary.rawValue) missing permission"
            )
            let microphoneCommitted = expectation(
                description: "\(boundary.rawValue) missing commit"
            )
            let staleReadStarted = expectation(
                description: "\(boundary.rawValue) missing read started"
            )
            staleReadStarted.assertForOverFulfill = false
            let readGate = AudioNonCooperativeGate<Void>()
            let recordingGeneration: UInt64 = 0xA11C_E401
            var readOrdinal = 0
            var missingObservationTime: TimeInterval = 1
            var stalledRecoveryAttemptCount = 0

            session.viewModel
                .debugInstallIPhoneMicrophonePermissionRequester {
                    permissionRequested.fulfill()
                    return true
                }
            session.viewModel
                .debugInstallIPhoneMicrophoneNativeHandlers(
                    enable: { authorization in
                        authorization
                            .debugSetRecordingGenerationForTesting(
                                recordingGeneration
                            )
                    },
                    disable: { authorization, _ in
                        authorization?.revoke()
                        return true
                    }
                )
            session.viewModel
                .debugInstallIPhoneMicrophoneDidCommitObserver { _ in
                    microphoneCommitted.fulfill()
                }
            session.viewModel
                .debugInstallIPhoneMicrophoneSenderStatisticsReader {
                    requestedPeer in
                    XCTAssertTrue(requestedPeer === session.peer)
                    readOrdinal += 1
                    guard readOrdinal == 4 else { return nil }
                    staleReadStarted.fulfill()
                    await readGate.wait()
                    return nil
                }
            session.viewModel
                .debugInstallRawMicrophoneMissingStatisticsUptimeClock {
                    defer { missingObservationTime += 1 }
                    return missingObservationTime
                }
            session.viewModel
                .debugInstallStalledIPhoneMicrophoneRecoveryObserver {
                    stalledRecoveryAttemptCount += 1
                }

            session.viewModel.handleAppBecameActive()
            await session.viewModel
                .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
            await fulfillment(
                of: [permissionRequested, microphoneCommitted],
                timeout: 2
            )

            for _ in 0..<3 {
                await session.viewModel
                    .debugRefreshRawMicrophoneOracleForTests(
                        from: session.peer
                    )
            }
            XCTAssertEqual(stalledRecoveryAttemptCount, 0)

            let staleRead = Task { @MainActor in
                await session.viewModel
                    .debugRefreshRawMicrophoneOracleForTests(
                        from: session.peer
                    )
            }
            await fulfillment(of: [staleReadStarted], timeout: 2)
            await readGate.waitUntilBlocked()

            var replacementPeer: WebRTCPeer?
            switch boundary {
            case .callStart:
                session.fixture.callActivity.setCallSnapshot(
                    nonEndedCallCount: 1,
                    connectedNonEndedCallCount: 1
                )

            case .manualMicrophoneOff:
                session.viewModel.toggleIPhoneMicrophone()

            case .permissionDenial:
                session.viewModel
                    .debugDenyIPhoneMicrophonePermissionForTests()

            case .transportUncertainty:
                session.viewModel
                    .debugMarkViewerTransportUncertainForAutomaticMicrophoneTests()

            case .audioPolicyRotation:
                session.viewModel.debugRotateAudioPolicyForTests()

            case .peerReplacement:
                let replacement = try makeAudioRacePeer()
                replacementPeer = replacement
                session.viewModel.debugInstallScreenSessionForTests(
                    peer: replacement,
                    provenance:
                        .authenticatedPairedCoordinatorHandoff
                )

            case .teardown:
                session.viewModel.disconnect()
            }

            await readGate.open(())
            await staleRead.value

            XCTAssertEqual(
                stalledRecoveryAttemptCount,
                0,
                "A stale nil read crossed \(boundary.rawValue)."
            )

            if boundary != .teardown {
                session.viewModel.disconnect()
            }
            await session.peer.close()
            if let replacementPeer {
                await replacementPeer.close()
            }
        }
    }

    func testRawMicrophoneOraclePublishesAfterTwoExactSamplesAndRevokesAtCallStartWithoutMutingPlayout() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        let permissionRequested = expectation(
            description: "raw oracle permission"
        )
        let microphoneCommitted = expectation(
            description: "raw oracle microphone committed"
        )
        let recordingGeneration: UInt64 = 0xA11C_E001
        var nextSample: UInt64 = 1
        let captureRouteIsBuiltInMicrophone =
            AudioLockedValue(true)
        let captureRouteProofGeneration =
            AudioLockedValue<UInt64>(13)
        var disableAttemptCount = 0

        session.viewModel
            .debugInstallIPhoneMicrophonePermissionRequester {
                permissionRequested.fulfill()
                return true
            }
        session.viewModel
            .debugInstallIPhoneMicrophoneNativeHandlers(
                enable: { authorization in
                    authorization
                        .debugSetRecordingGenerationForTesting(
                            recordingGeneration
                        )
                },
                disable: { authorization, _ in
                    disableAttemptCount += 1
                    authorization?.revoke()
                    return true
                }
            )
        session.viewModel
            .debugInstallIPhoneMicrophoneDidCommitObserver { _ in
                microphoneCommitted.fulfill()
            }
        session.viewModel
            .debugInstallIPhoneMicrophoneSenderStatisticsReader {
                [weak self] _ in
                guard let self else { return nil }
                defer { nextSample += 1 }
                return self.rawMicrophoneSenderStatisticsForTests(
                    sample: nextSample,
                    recordingGeneration: recordingGeneration,
                    captureRouteIsBuiltInMicrophone:
                        captureRouteIsBuiltInMicrophone.value,
                    captureRouteProofGeneration:
                        captureRouteProofGeneration.value
                )
            }

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(
            of: [permissionRequested, microphoneCommitted],
            timeout: 2
        )
        let authorization = try XCTUnwrap(
            session.viewModel
                .debugIPhoneMicrophoneAuthorizationForTests
        )
        XCTAssertEqual(
            authorization.recordingGeneration,
            recordingGeneration
        )
        XCTAssertTrue(session.viewModel.isMicrophoneSending)

        await session.viewModel
            .debugRefreshRawMicrophoneOracleForTests(
                from: session.peer
            )
        XCTAssertNil(
            session.viewModel.worldwideRawMicrophoneOracle,
            "One sample is only a baseline."
        )
        await session.viewModel
            .debugRefreshRawMicrophoneOracleForTests(
                from: session.peer
            )
        let oracle = try XCTUnwrap(
            session.viewModel.worldwideRawMicrophoneOracle
        )
        let accessibilityValue = try XCTUnwrap(
            BrowserView.rawMicrophoneOracleAccessibilityValue(
                oracle
            )
        )
        XCTAssertNotNil(
            PhysicalRawMicrophoneSnapshot(
                accessibilityValue: accessibilityValue
            )
        )
        XCTAssertTrue(accessibilityValue.hasPrefix("v=3|"))
        XCTAssertTrue(
            accessibilityValue.contains("|captureBuiltInMic=1")
        )

        captureRouteIsBuiltInMicrophone.set(false)
        await session.viewModel
            .debugRefreshRawMicrophoneOracleForTests(
                from: session.peer
            )
        XCTAssertNil(
            session.viewModel.worldwideRawMicrophoneOracle,
            "A non-built-in live capture route must revoke the published raw microphone oracle."
        )

        captureRouteIsBuiltInMicrophone.set(true)
        await session.viewModel
            .debugRefreshRawMicrophoneOracleForTests(
                from: session.peer
            )
        XCTAssertNil(
            session.viewModel.worldwideRawMicrophoneOracle,
            "The restored built-in route needs a fresh continuity baseline."
        )
        await session.viewModel
            .debugRefreshRawMicrophoneOracleForTests(
                from: session.peer
            )
        XCTAssertNotNil(
            session.viewModel.worldwideRawMicrophoneOracle
        )

        captureRouteProofGeneration.set(14)
        await session.viewModel
            .debugRefreshRawMicrophoneOracleForTests(
                from: session.peer
            )
        XCTAssertNil(
            session.viewModel.worldwideRawMicrophoneOracle,
            "A fresh exact route proof must retire the prior continuity window even when the built-in route type is unchanged."
        )
        await session.viewModel
            .debugRefreshRawMicrophoneOracleForTests(
                from: session.peer
            )
        XCTAssertNotNil(
            session.viewModel.worldwideRawMicrophoneOracle,
            "The rotated exact route proof may publish only after a fresh two-sample continuity window."
        )
        XCTAssertTrue(session.fixture.remoteAudio.isEnabled)
        let audioPolicyGenerationBeforeCall =
            session.viewModel.debugAudioPolicyGeneration

        session.fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )

        XCTAssertNil(
            session.viewModel.worldwideRawMicrophoneOracle,
            "Call ownership must revoke raw microphone proof synchronously."
        )
        XCTAssertFalse(session.viewModel.isMicrophoneSending)
        XCTAssertFalse(authorization.isValid)
        XCTAssertNil(
            session.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )
        XCTAssertEqual(disableAttemptCount, 0)
        XCTAssertEqual(
            session.viewModel.debugAudioPolicyGeneration,
            audioPolicyGenerationBeforeCall
        )
        XCTAssertTrue(
            session.fixture.remoteAudio.isEnabled,
            "The call transition must not close best-effort incoming Mac playout."
        )

        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testSuspendedRawMicrophoneStatisticsReadCannotRepublishAcrossEveryRevocationBoundary() async throws {
        for boundary in RawMicrophoneReadRevocationBoundary.allCases {
            let session = try makeAutomaticMicrophonePolicyFixture(
                provenance: .authenticatedPairedCoordinatorHandoff
            )
            let permissionRequested = expectation(
                description: "\(boundary.rawValue) permission"
            )
            let microphoneCommitted = expectation(
                description: "\(boundary.rawValue) microphone committed"
            )
            let staleReadStarted = expectation(
                description: "\(boundary.rawValue) stale raw read started"
            )
            staleReadStarted.assertForOverFulfill = false
            let readGate = AudioNonCooperativeGate<Void>()
            let recordingGeneration: UInt64 = 0xA11C_E101
            var readOrdinal: UInt64 = 0

            session.viewModel
                .debugInstallIPhoneMicrophonePermissionRequester {
                    permissionRequested.fulfill()
                    return true
                }
            session.viewModel
                .debugInstallIPhoneMicrophoneNativeHandlers(
                    enable: { authorization in
                        authorization
                            .debugSetRecordingGenerationForTesting(
                                recordingGeneration
                            )
                    },
                    disable: { authorization, _ in
                        authorization?.revoke()
                        return true
                    }
                )
            session.viewModel
                .debugInstallIPhoneMicrophoneDidCommitObserver { _ in
                    microphoneCommitted.fulfill()
                }
            session.viewModel
                .debugInstallIPhoneMicrophoneSenderStatisticsReader {
                    [weak self] requestedPeer in
                    guard let self else { return nil }
                    XCTAssertTrue(requestedPeer === session.peer)
                    readOrdinal += 1
                    if readOrdinal <= 2 {
                        return self.rawMicrophoneSenderStatisticsForTests(
                            sample: readOrdinal,
                            recordingGeneration: recordingGeneration
                        )
                    }
                    staleReadStarted.fulfill()
                    await readGate.wait()
                    return self.rawMicrophoneSenderStatisticsForTests(
                        sample: 3,
                        recordingGeneration: recordingGeneration
                    )
                }

            session.viewModel.handleAppBecameActive()
            await session.viewModel
                .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
            await fulfillment(
                of: [permissionRequested, microphoneCommitted],
                timeout: 2
            )

            await session.viewModel
                .debugRefreshRawMicrophoneOracleForTests(
                    from: session.peer
                )
            await session.viewModel
                .debugRefreshRawMicrophoneOracleForTests(
                    from: session.peer
                )
            XCTAssertNotNil(
                session.viewModel.worldwideRawMicrophoneOracle,
                "\(boundary.rawValue) precondition did not publish."
            )

            let staleRead = Task { @MainActor in
                await session.viewModel
                    .debugRefreshRawMicrophoneOracleForTests(
                        from: session.peer
                    )
            }
            await fulfillment(of: [staleReadStarted], timeout: 2)
            await readGate.waitUntilBlocked()

            var replacementPeer: WebRTCPeer?
            switch boundary {
            case .callStart:
                session.fixture.callActivity.setCallSnapshot(
                    nonEndedCallCount: 1,
                    connectedNonEndedCallCount: 1
                )
                XCTAssertTrue(
                    session.fixture.remoteAudio.isEnabled,
                    "Call-time incoming Mac playout must remain available."
                )

            case .manualMicrophoneOff:
                session.viewModel.toggleIPhoneMicrophone()

            case .permissionDenial:
                session.viewModel
                    .debugDenyIPhoneMicrophonePermissionForTests()

            case .transportUncertainty:
                session.viewModel
                    .debugMarkViewerTransportUncertainForAutomaticMicrophoneTests()

            case .audioPolicyRotation:
                session.viewModel.debugRotateAudioPolicyForTests()

            case .peerReplacement:
                let replacement = try makeAudioRacePeer()
                replacementPeer = replacement
                session.viewModel.debugInstallScreenSessionForTests(
                    peer: replacement,
                    provenance:
                        .authenticatedPairedCoordinatorHandoff
                )

            case .teardown:
                session.viewModel.disconnect()
            }

            XCTAssertNil(
                session.viewModel.worldwideRawMicrophoneOracle,
                "\(boundary.rawValue) did not synchronously retire raw proof."
            )

            await readGate.open(())
            await staleRead.value

            XCTAssertNil(
                session.viewModel.worldwideRawMicrophoneOracle,
                "The stale read republished across \(boundary.rawValue)."
            )

            if boundary != .teardown {
                session.viewModel.disconnect()
            }
            await session.peer.close()
            if let replacementPeer {
                await replacementPeer.close()
            }
        }
    }

    func testRepeatedWorldwideScenePhaseDeliveryIsIdempotentAtViewModel() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff
        )

        let initialRecoverCount = session.fixture.playback.recoverCount

        session.viewModel.handleAppBecameActive()
        let firstActiveRecoverCount =
            session.fixture.playback.recoverCount
        XCTAssertEqual(
            firstActiveRecoverCount,
            initialRecoverCount + 1
        )

        session.viewModel.handleAppBecameActive()
        XCTAssertEqual(
            session.fixture.playback.recoverCount,
            firstActiveRecoverCount
        )

        session.viewModel.handleAppBecameInactive()
        session.viewModel.handleAppBecameInactive()
        XCTAssertEqual(
            session.fixture.playback.recoverCount,
            firstActiveRecoverCount
        )

        session.viewModel.handleAppEnteredBackground()
        let firstBackgroundRecoverCount =
            session.fixture.playback.recoverCount
        XCTAssertEqual(
            firstBackgroundRecoverCount,
            firstActiveRecoverCount + 1
        )

        session.viewModel.handleAppEnteredBackground()
        XCTAssertEqual(
            session.fixture.playback.recoverCount,
            firstBackgroundRecoverCount
        )

        session.viewModel.handleAppBecameActive()
        let resumedRecoverCount =
            session.fixture.playback.recoverCount
        XCTAssertEqual(
            resumedRecoverCount,
            firstBackgroundRecoverCount + 1
        )

        session.viewModel.handleAppBecameActive()
        XCTAssertEqual(
            session.fixture.playback.recoverCount,
            resumedRecoverCount
        )

        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testAudioErrorSnapshotTearsDownEstablishedAutomaticMicrophone() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff
        )

        let permissionRequested = expectation(
            description: "automatic permission granted"
        )
        let enableCommitted = expectation(
            description: "native microphone committed"
        )
        let disableAttempted = expectation(
            description: "error snapshot requested native teardown"
        )
        var permissionRequestCount = 0
        var nativeAuthorization: WebRTCIOSMicrophoneAuthorization?
        var enableAuthorizations: [WebRTCIOSMicrophoneAuthorization] = []
        var disableAuthorizations: [WebRTCIOSMicrophoneAuthorization?] = []

        session.viewModel.debugInstallIPhoneMicrophonePermissionRequester {
            permissionRequestCount += 1
            permissionRequested.fulfill()
            return true
        }
        session.viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { authorization in
                enableAuthorizations.append(authorization)
                nativeAuthorization = authorization
            },
            disable: { authorization, _ in
                disableAuthorizations.append(authorization)
                if authorization == nil
                    || nativeAuthorization === authorization {
                    nativeAuthorization = nil
                }
                disableAttempted.fulfill()
                return true
            }
        )
        session.viewModel.debugInstallIPhoneMicrophoneDidCommitObserver {
            authorization in
            XCTAssertTrue(nativeAuthorization === authorization)
            enableCommitted.fulfill()
        }

        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(
            of: [permissionRequested, enableCommitted],
            timeout: 2
        )

        let authorization = try XCTUnwrap(
            session.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )
        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(session.viewModel.isMicrophoneSending)
        XCTAssertTrue(nativeAuthorization === authorization)

        session.fixture.playback.requiresRuntimePlayoutProof = true
        session.fixture.controller.updateRuntimePlayout(
            isReady: false,
            failureMessage: "Injected audio failure",
            diagnostic: "Injected audio diagnostic"
        )

        XCTAssertFalse(authorization.isValid)
        XCTAssertNil(
            session.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )
        XCTAssertFalse(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(
            session.viewModel.microphoneStateText,
            "Paused — audio unavailable"
        )

        await fulfillment(of: [disableAttempted], timeout: 2)

        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertEqual(enableAuthorizations.count, 1)
        XCTAssertTrue(enableAuthorizations[0] === authorization)
        XCTAssertEqual(disableAuthorizations.count, 1)
        XCTAssertTrue((disableAuthorizations.first ?? nil) === authorization)
        XCTAssertNil(nativeAuthorization)

        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testAudioErrorSnapshotBlocksFreshAutomaticMicrophoneAdmission() async throws {
        let session = try makeAutomaticMicrophonePolicyFixture(
            provenance: .authenticatedPairedCoordinatorHandoff,
            installsRemoteAudioTrack: false
        )
        let permissionStarted = expectation(
            description: "pre-admission permission request started"
        )
        let permissionGate = AudioNonCooperativeGate<Bool>()
        var permissionRequestCount = 0
        var enableAttemptCount = 0

        session.viewModel.debugInstallIPhoneMicrophonePermissionRequester {
            permissionRequestCount += 1
            permissionStarted.fulfill()
            return await permissionGate.wait()
        }
        session.viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { _ in
                enableAttemptCount += 1
            },
            disable: { authorization, _ in
                authorization?.revoke()
                return true
            }
        )
        session.viewModel.debugInstallIOSPlayoutDiagnosticsReader { _ in
            nil
        }

        session.fixture.playback.requiresRuntimePlayoutProof = true
        session.viewModel.handleAppBecameActive()
        await session.viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(of: [permissionStarted], timeout: 2)
        session.fixture.controller.updateRuntimePlayout(
            isReady: false,
            failureMessage: "Injected pre-admission audio failure",
            diagnostic: "The output-only topology is unavailable."
        )
        await permissionGate.open(true)
        for _ in 0..<12 {
            await Task.yield()
        }

        XCTAssertEqual(permissionRequestCount, 1)
        XCTAssertEqual(enableAttemptCount, 0)
        XCTAssertNil(
            session.viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )
        XCTAssertFalse(session.viewModel.isMicrophoneSending)
        XCTAssertEqual(
            session.viewModel.microphoneStateText,
            "Paused — audio unavailable"
        )

        session.viewModel.disconnect()
        await session.peer.close()
    }

    func testCallObserverDelegateRevokesAuthorizationBeforeReturning() {
        let observer = WorldwideCallActivityObserver()
        observer.debugSetLiveSnapshotForTests(.inactive)
        observer.startObserving()
        defer { observer.stopObserving() }
        let authorization = WebRTCIOSMicrophoneAuthorization()
        observer.onSnapshotChanged = { snapshot in
            if snapshot.hasNonEndedCall {
                authorization.revoke()
            }
        }

        observer.debugSetLiveSnapshotForTests(
            WorldwideCallActivitySnapshot(
                nonEndedCallCount: 1,
                connectedNonEndedCallCount: 0,
                membershipRevision: 1
            )
        )
        observer.debugDeliverDelegateInvalidationSynchronouslyForTests()

        XCTAssertEqual(
            observer.snapshot,
            WorldwideCallActivitySnapshot(
                nonEndedCallCount: 1,
                connectedNonEndedCallCount: 0,
                revision: 1,
                membershipRevision: 1
            )
        )
        XCTAssertFalse(
            authorization.isValid,
            "CallKit notification and microphone revocation must complete before delegate return."
        )
    }

    func testCallObserverPublishesConnectedChangeWhenNonEndedTotalIsStable() {
        let observer = WorldwideCallActivityObserver()
        observer.debugSetLiveSnapshotForTests(
            WorldwideCallActivitySnapshot(
                nonEndedCallCount: 1,
                connectedNonEndedCallCount: 0,
                membershipRevision: 7
            )
        )
        observer.startObserving()
        defer { observer.stopObserving() }
        var receivedSnapshots:
            [WorldwideCallActivitySnapshot] = []
        observer.onSnapshotChanged = {
            receivedSnapshots.append($0)
        }

        let connectedSnapshot = WorldwideCallActivitySnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1,
            revision: 1,
            membershipRevision: 7
        )
        observer.debugSetLiveSnapshotForTests(connectedSnapshot)
        observer.debugDeliverDelegateInvalidationSynchronouslyForTests()

        XCTAssertEqual(observer.snapshot, connectedSnapshot)
        XCTAssertEqual(receivedSnapshots, [connectedSnapshot])
    }

    func testMacHostedCallRequiresFreshChallengeEchoAfterEveryCallRevision() throws {
        let fixture = makeFixture()
        var challenges: [WebRTCMacHostedCallChallenge] = []
        fixture.controller.onMacHostedCallChallengeChanged = {
            if let challenge = $0 {
                challenges.append(challenge)
            }
        }
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        let firstChallenge = try XCTUnwrap(challenges.last)
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())

        fixture.controller.macHostedCallEvidenceChanged(
            WebRTCMacHostedCallEvidence(
                sequence: 1,
                challengeSequence: firstChallenge.sequence,
                challengeNonce: firstChallenge.nonce,
                callEpochNonce:
                    firstChallenge.callEpochNonce,
                state: .active
            )
        )
        XCTAssertTrue(fixture.controller.microphoneActivationIsAllowed())

        fixture.callActivity.replaceCallKeepingCurrentAggregate()
        let replacementChallenge = try XCTUnwrap(challenges.last)
        XCTAssertNotEqual(replacementChallenge, firstChallenge)
        XCTAssertNotEqual(
            replacementChallenge.callEpochNonce,
            firstChallenge.callEpochNonce
        )
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())

        // This response has a newer wire sequence but was sampled for the prior CallKit epoch.
        fixture.controller.macHostedCallEvidenceChanged(
            WebRTCMacHostedCallEvidence(
                sequence: 2,
                challengeSequence: firstChallenge.sequence,
                challengeNonce: firstChallenge.nonce,
                callEpochNonce:
                    firstChallenge.callEpochNonce,
                state: .active
            )
        )
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())

        fixture.controller.macHostedCallEvidenceChanged(
            WebRTCMacHostedCallEvidence(
                sequence: 3,
                challengeSequence: replacementChallenge.sequence,
                challengeNonce: replacementChallenge.nonce,
                callEpochNonce: firstChallenge.callEpochNonce,
                state: .active
            )
        )
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())

        fixture.controller.macHostedCallEvidenceChanged(
            WebRTCMacHostedCallEvidence(
                sequence: 4,
                challengeSequence: replacementChallenge.sequence,
                challengeNonce: replacementChallenge.nonce,
                callEpochNonce:
                    replacementChallenge.callEpochNonce,
                state: .active
            )
        )
        XCTAssertTrue(fixture.controller.microphoneActivationIsAllowed())
    }

    func testMacHostedCallPreflightSurvivesCallKitDeliveryRaceAndAdmitsOnlyAfterLiveCall()
        throws {
        let fixture = makeFixture()
        var challenges: [WebRTCMacHostedCallChallenge] = []
        fixture.controller.onMacHostedCallChallengeChanged = {
            if let challenge = $0 {
                challenges.append(challenge)
            }
        }
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()
        let preflight = try XCTUnwrap(challenges.first)

        fixture.controller.macHostedCallEvidenceChanged(
            WebRTCMacHostedCallEvidence(
                sequence: 1,
                challengeSequence: preflight.sequence,
                challengeNonce: preflight.nonce,
                callEpochNonce: preflight.callEpochNonce,
                state: .preflightArmed
            )
        )

        // Model the native Mac duplex edge reaching the phone before CallKit's delegate callback.
        // Evidence ingress must synchronously read the already-updated live aggregate, preserve the
        // prospectively installed challenge, and only then evaluate the active evidence.
        fixture.callActivity.stageLiveNonEndedCallCountWithoutCallback(1)
        fixture.controller.macHostedCallEvidenceChanged(
            WebRTCMacHostedCallEvidence(
                sequence: 2,
                challengeSequence: preflight.sequence,
                challengeNonce: preflight.nonce,
                callEpochNonce: preflight.callEpochNonce,
                state: .active
            )
        )

        XCTAssertEqual(challenges.last, preflight)
        XCTAssertTrue(fixture.controller.microphoneActivationIsAllowed())
    }

    func testMacHostedCallActivePreflightEvidenceWhileLiveCallKitInactiveContaminatesEpoch()
        throws {
        let fixture = makeFixture()
        var challenges: [WebRTCMacHostedCallChallenge] = []
        fixture.controller.onMacHostedCallChallengeChanged = {
            if let challenge = $0 {
                challenges.append(challenge)
            }
        }
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()
        let contaminated = try XCTUnwrap(challenges.first)

        fixture.controller.macHostedCallEvidenceChanged(
            WebRTCMacHostedCallEvidence(
                sequence: 1,
                challengeSequence: contaminated.sequence,
                challengeNonce: contaminated.nonce,
                callEpochNonce: contaminated.callEpochNonce,
                state: .active
            )
        )
        let replacement = try XCTUnwrap(challenges.last)
        XCTAssertNotEqual(replacement, contaminated)
        XCTAssertNotEqual(
            replacement.callEpochNonce,
            contaminated.callEpochNonce
        )

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        let postEdgeChallenge = try XCTUnwrap(challenges.last)
        XCTAssertNotEqual(postEdgeChallenge, contaminated)
        XCTAssertNotEqual(postEdgeChallenge, replacement)
        fixture.controller.macHostedCallEvidenceChanged(
            WebRTCMacHostedCallEvidence(
                sequence: 2,
                challengeSequence: contaminated.sequence,
                challengeNonce: contaminated.nonce,
                callEpochNonce: contaminated.callEpochNonce,
                state: .active
            )
        )

        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())
    }

    func testMacHostedCallInactivePoisonEvidenceCannotAcknowledgePreflight()
        throws {
        let fixture = makeFixture()
        var challenges: [WebRTCMacHostedCallChallenge] = []
        fixture.controller.onMacHostedCallChallengeChanged = {
            if let challenge = $0 {
                challenges.append(challenge)
            }
        }
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()
        let poisoned = try XCTUnwrap(challenges.first)

        fixture.controller.macHostedCallEvidenceChanged(
            WebRTCMacHostedCallEvidence(
                sequence: 1,
                challengeSequence: poisoned.sequence,
                challengeNonce: poisoned.nonce,
                callEpochNonce: poisoned.callEpochNonce,
                state: .inactive
            )
        )

        let replacement = try XCTUnwrap(challenges.last)
        XCTAssertNotEqual(replacement, poisoned)
        XCTAssertNotEqual(
            replacement.callEpochNonce,
            poisoned.callEpochNonce
        )
    }

    func testMacHostedCallUnacknowledgedPreflightRetriesAndCallEdgeFencesRetry()
        async throws {
        let fixture = makeFixture()
        let retryGate = AudioNonCooperativeGate<Void>()
        fixture.controller.debugInstallMacHostedCallPreflightRetryWaiter {
            await retryGate.wait()
        }
        var challenges: [WebRTCMacHostedCallChallenge] = []
        fixture.controller.onMacHostedCallChallengeChanged = {
            if let challenge = $0 {
                challenges.append(challenge)
            }
        }
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()
        let preflight = try XCTUnwrap(challenges.first)
        await retryGate.waitUntilBlocked()

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        let postEdgeChallenges = challenges
        XCTAssertNotEqual(postEdgeChallenges.last, preflight)
        await retryGate.open(())
        await Task.yield()

        XCTAssertEqual(challenges, postEdgeChallenges)
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())
    }

    func testMacHostedCallPreflightRetryDoesNotRetainControllerAcrossNoncooperativeWait()
        async {
        let playback = AudioPlaybackStub()
        let background = BackgroundPlaybackStub()
        let events = AudioSessionEventsStub()
        let callActivity = CallActivityStub()
        let retryGate = AudioNonCooperativeGate<Void>()
        var controller: WorldwideAudioLifecycleController? =
            WorldwideAudioLifecycleController(
                playback: playback,
                backgroundPlayback: background,
                events: events,
                callActivity: callActivity
            )
        controller?.debugInstallMacHostedCallPreflightRetryWaiter {
            await retryGate.wait()
        }
        controller?.prepare(serverName: "Mac mini")
        controller?.transportBecameHealthy()
        await retryGate.waitUntilBlocked()

        let releasedController = { [weak controller] in controller }
        controller = nil
        XCTAssertNil(
            releasedController(),
            "The self-owned retry task must not promote its weak controller across the wait."
        )

        await retryGate.open(())
        await Task.yield()
    }

    func testMacHostedCallEvidenceSynchronizesLiveCallReplacementBeforeAdmission()
        throws {
        let fixture = makeFixture()
        var challenges: [WebRTCMacHostedCallChallenge] = []
        fixture.controller.onMacHostedCallChallengeChanged = {
            if let challenge = $0 {
                challenges.append(challenge)
            }
        }
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        let firstChallenge = try XCTUnwrap(challenges.last)
        fixture.controller.macHostedCallEvidenceChanged(
            WebRTCMacHostedCallEvidence(
                sequence: 1,
                challengeSequence: firstChallenge.sequence,
                challengeNonce: firstChallenge.nonce,
                callEpochNonce: firstChallenge.callEpochNonce,
                state: .active
            )
        )
        XCTAssertTrue(fixture.controller.microphoneActivationIsAllowed())

        fixture.callActivity
            .stageLiveCallReplacementKeepingCurrentAggregateWithoutCallback()
        XCTAssertEqual(challenges.last, firstChallenge)

        fixture.controller.macHostedCallEvidenceChanged(
            WebRTCMacHostedCallEvidence(
                sequence: 2,
                challengeSequence: firstChallenge.sequence,
                challengeNonce: firstChallenge.nonce,
                callEpochNonce: firstChallenge.callEpochNonce,
                state: .active
            )
        )

        let replacementChallenge = try XCTUnwrap(challenges.last)
        XCTAssertNotEqual(replacementChallenge, firstChallenge)
        XCTAssertNotEqual(
            replacementChallenge.callEpochNonce,
            firstChallenge.callEpochNonce
        )
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())
    }

    func testMacHostedCallChallengeWaitsForForwardedAnswerWhenPrematureSendWouldSucceed()
        async throws {
        try await assertMacHostedCallChallengeWaitsForForwardedAnswer(
            prematureOutcome: .localSuccess
        )
    }

    func testMacHostedCallChallengeWaitsForForwardedAnswerWhenPrematureSendWouldFail()
        async throws {
        try await assertMacHostedCallChallengeWaitsForForwardedAnswer(
            prematureOutcome: .localFailure
        )
    }

    func testMacHostedCallChallengeAutomaticallyRetriesOneLoneFailure()
        async throws {
        let fixture = makeFixture()
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        let peer = try makeAudioRacePeer()
        viewModel.debugInstallScreenSessionForTests(peer: peer)

        var sendAttemptCount = 0
        var retryWaitCount = 0
        viewModel.debugInstallMacHostedCallChallengeAutomaticRetryWaiter {
            retryWaitCount += 1
            await Task.yield()
        }
        viewModel.debugInstallMacHostedCallChallengeSender {
            sourcePeer,
            _ in
            XCTAssertTrue(sourcePeer === peer)
            sendAttemptCount += 1
            if sendAttemptCount == 1 {
                throw WebRTCTransportError.transportNotHealthy
            }
        }

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        let answerContext = try XCTUnwrap(
            viewModel.debugMacHostedCallCapabilityRetryContextForTests()
        )
        viewModel.debugDeliverMacHostedCallCapabilityNegotiatedForTests(
            answerContext
        )

        await viewModel.debugWaitForMacHostedCallChallengeSendForTests()
        XCTAssertEqual(sendAttemptCount, 2)
        XCTAssertEqual(retryWaitCount, 1)

        viewModel.disconnect()
        await peer.close()
    }

    func testMacHostedCallChallengeRetryRetiresWhileWaiting()
        async throws {
        let fixture = makeFixture()
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        let peer = try makeAudioRacePeer()
        viewModel.debugInstallScreenSessionForTests(peer: peer)
        let retryGate = AudioNonCooperativeGate<Void>()
        let retryWaitReturned = expectation(
            description: "retired retry waiter returned"
        )
        var sendAttemptCount = 0
        viewModel.debugInstallMacHostedCallChallengeAutomaticRetryWaiter {
            await retryGate.wait()
            retryWaitReturned.fulfill()
        }
        viewModel.debugInstallMacHostedCallChallengeSender {
            sourcePeer,
            _ in
            XCTAssertTrue(sourcePeer === peer)
            sendAttemptCount += 1
            throw WebRTCTransportError.transportNotHealthy
        }

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        let answerContext = try XCTUnwrap(
            viewModel.debugMacHostedCallCapabilityRetryContextForTests()
        )
        viewModel.debugDeliverMacHostedCallCapabilityNegotiatedForTests(
            answerContext
        )

        await retryGate.waitUntilBlocked()
        XCTAssertEqual(sendAttemptCount, 1)
        viewModel.debugMarkViewerTransportUncertainForAutomaticMicrophoneTests()
        await retryGate.open(())
        await fulfillment(of: [retryWaitReturned], timeout: 2)
        await Task.yield()
        XCTAssertEqual(
            sendAttemptCount,
            1,
            "Retiring transport ownership during the delay must suppress the retry."
        )

        viewModel.disconnect()
        await peer.close()
    }

    private func assertMacHostedCallChallengeWaitsForForwardedAnswer(
        prematureOutcome: PrematureMacHostedCallChallengeOutcome
    ) async throws {
        let fixture = makeFixture()
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        let peer = try makeAudioRacePeer()
        viewModel.debugInstallScreenSessionForTests(peer: peer)

        let postAnswerSend = expectation(
            description: "challenge sent after SDP answer"
        )
        let answerWasForwarded = AudioMainActorFlag()
        var attemptedChallenges: [WebRTCMacHostedCallChallenge] = []
        viewModel.debugInstallMacHostedCallChallengeSender {
            sourcePeer,
            challenge in
            XCTAssertTrue(sourcePeer === peer)
            attemptedChallenges.append(challenge)
            guard answerWasForwarded.value else {
                XCTFail("The challenge lane opened before its ordered answer was forwarded.")
                if prematureOutcome == .localFailure {
                    throw WebRTCTransportError.transportNotHealthy
                }
                return
            }
            postAnswerSend.fulfill()
        }

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )

        await Task.yield()
        await viewModel.debugWaitForMacHostedCallChallengeSendForTests()
        XCTAssertTrue(
            attemptedChallenges.isEmpty,
            "Transport health must not launch even a locally successful challenge before the answer boundary."
        )
        let answerContext = try XCTUnwrap(
            viewModel.debugMacHostedCallCapabilityRetryContextForTests()
        )

        answerWasForwarded.value = true
        viewModel.debugDeliverMacHostedCallCapabilityNegotiatedForTests(
            answerContext
        )
        await fulfillment(of: [postAnswerSend], timeout: 2)
        await viewModel.debugWaitForMacHostedCallChallengeSendForTests()

        XCTAssertEqual(attemptedChallenges.count, 1)

        // A duplicate answer notification for the same peer/session/transport binding must not
        // resend an already successful challenge or invalidate evidence that may now be arriving.
        viewModel.debugDeliverMacHostedCallCapabilityNegotiatedForTests(
            answerContext
        )
        await viewModel.debugWaitForMacHostedCallChallengeSendForTests()
        XCTAssertEqual(attemptedChallenges.count, 1)

        // Beginning a replacement offer closes the old answer fence synchronously. A delayed
        // answer callback from that retired negotiation cannot reopen the challenge lane.
        viewModel.debugBeginMacHostedCallNegotiationForTests()
        viewModel.debugDeliverMacHostedCallCapabilityNegotiatedForTests(
            answerContext
        )
        await viewModel.debugWaitForMacHostedCallChallengeSendForTests()
        XCTAssertEqual(attemptedChallenges.count, 1)

        let replacementAnswerContext = try XCTUnwrap(
            viewModel.debugMacHostedCallCapabilityRetryContextForTests()
        )
        let replacementAnswerSend = expectation(
            description: "challenge sent after replacement SDP answer"
        )
        viewModel.debugInstallMacHostedCallChallengeSender {
            sourcePeer,
            challenge in
            XCTAssertTrue(sourcePeer === peer)
            attemptedChallenges.append(challenge)
            replacementAnswerSend.fulfill()
        }
        viewModel.debugDeliverMacHostedCallCapabilityNegotiatedForTests(
            replacementAnswerContext
        )
        await fulfillment(of: [replacementAnswerSend], timeout: 2)
        await viewModel.debugWaitForMacHostedCallChallengeSendForTests()
        XCTAssertEqual(attemptedChallenges.count, 2)
        XCTAssertEqual(attemptedChallenges.first, attemptedChallenges.last)

        let recoveredTransportSend = expectation(
            description: "same-negotiation transport recovery resends challenge"
        )
        viewModel.debugInstallMacHostedCallChallengeSender {
            sourcePeer,
            challenge in
            XCTAssertTrue(sourcePeer === peer)
            attemptedChallenges.append(challenge)
            recoveredTransportSend.fulfill()
        }
        viewModel.debugMarkViewerTransportUncertainForAutomaticMicrophoneTests()
        viewModel.debugDeliverMacHostedCallCapabilityNegotiatedForTests(
            replacementAnswerContext
        )
        await viewModel.debugWaitForMacHostedCallChallengeSendForTests()
        XCTAssertEqual(
            attemptedChallenges.count,
            2,
            "A same-negotiation answer callback must not send while transport is unhealthy."
        )

        await viewModel
            .debugMarkViewerTransportHealthyForAutomaticMicrophoneTests()
        await fulfillment(of: [recoveredTransportSend], timeout: 2)
        await viewModel.debugWaitForMacHostedCallChallengeSendForTests()
        XCTAssertEqual(
            attemptedChallenges.count,
            3,
            "Same-SDP ICE recovery must reuse the forwarded-answer fence without another answer."
        )

        viewModel.disconnect()
        await peer.close()
    }

    func testMacHostedCallAdmissionRequiresExactlyOneConnectedCall() throws {
        let fixture = makeFixture()
        var challenges: [WebRTCMacHostedCallChallenge] = []
        fixture.controller.onMacHostedCallChallengeChanged = {
            if let challenge = $0 {
                challenges.append(challenge)
            }
        }
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()
        var evidenceSequence: UInt64 = 1

        func publishActiveEvidence() throws {
            let challenge = try XCTUnwrap(challenges.last)
            fixture.controller.macHostedCallEvidenceChanged(
                WebRTCMacHostedCallEvidence(
                    sequence: evidenceSequence,
                    challengeSequence: challenge.sequence,
                    challengeNonce: challenge.nonce,
                    callEpochNonce:
                        challenge.callEpochNonce,
                    state: .active
                )
            )
            evidenceSequence &+= 1
        }

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 0
        )
        let ringingChallenge = try XCTUnwrap(challenges.last)
        try publishActiveEvidence()
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        let connectedChallenge = try XCTUnwrap(challenges.last)
        XCTAssertNotEqual(connectedChallenge, ringingChallenge)
        XCTAssertEqual(
            connectedChallenge.callEpochNonce,
            ringingChallenge.callEpochNonce
        )
        try publishActiveEvidence()
        XCTAssertTrue(fixture.controller.microphoneActivationIsAllowed())

        for counts in [(2, 1), (2, 2)] {
            fixture.callActivity.setCallSnapshot(
                nonEndedCallCount: counts.0,
                connectedNonEndedCallCount: counts.1
            )
            try publishActiveEvidence()
            XCTAssertFalse(
                fixture.controller.microphoneActivationIsAllowed(),
                "counts=\(counts)"
            )
        }
    }

    func testMacHostedCallTransportLossAndEvidenceRevocationRotateChallenge() throws {
        let fixture = makeFixture()
        var challenges: [WebRTCMacHostedCallChallenge] = []
        fixture.controller.onMacHostedCallChallengeChanged = {
            if let challenge = $0 {
                challenges.append(challenge)
            }
        }
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        let initialChallenge = try XCTUnwrap(challenges.last)
        fixture.controller.macHostedCallEvidenceChanged(
            WebRTCMacHostedCallEvidence(
                sequence: 1,
                challengeSequence: initialChallenge.sequence,
                challengeNonce: initialChallenge.nonce,
                callEpochNonce:
                    initialChallenge.callEpochNonce,
                state: .active
            )
        )
        XCTAssertTrue(fixture.controller.microphoneActivationIsAllowed())

        fixture.controller.transportBecameUncertain()
        let recoveryChallenge = try XCTUnwrap(challenges.last)
        XCTAssertNotEqual(recoveryChallenge, initialChallenge)
        XCTAssertEqual(
            recoveryChallenge.callEpochNonce,
            initialChallenge.callEpochNonce
        )
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())
        fixture.controller.transportBecameHealthy()

        fixture.controller.macHostedCallEvidenceChanged(
            WebRTCMacHostedCallEvidence(
                sequence: 2,
                challengeSequence: initialChallenge.sequence,
                challengeNonce: initialChallenge.nonce,
                callEpochNonce:
                    initialChallenge.callEpochNonce,
                state: .active
            )
        )
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())
        fixture.controller.macHostedCallEvidenceChanged(
            WebRTCMacHostedCallEvidence(
                sequence: 3,
                challengeSequence: recoveryChallenge.sequence,
                challengeNonce: recoveryChallenge.nonce,
                callEpochNonce:
                    recoveryChallenge.callEpochNonce,
                state: .active
            )
        )
        XCTAssertTrue(fixture.controller.microphoneActivationIsAllowed())

        fixture.controller.macHostedCallEvidenceChanged(nil)
        let leaseReplacementChallenge = try XCTUnwrap(challenges.last)
        XCTAssertNotEqual(leaseReplacementChallenge, recoveryChallenge)
        XCTAssertEqual(
            leaseReplacementChallenge.callEpochNonce,
            recoveryChallenge.callEpochNonce
        )
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())
    }

    func testInterruptionBlocksImmediatelyThenRequiresFreshMacChallengeAfterEnd() throws {
        let fixture = makeFixture()
        var currentChallenge: WebRTCMacHostedCallChallenge?
        fixture.controller.onMacHostedCallChallengeChanged = {
            currentChallenge = $0
        }
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        let challenge = try XCTUnwrap(currentChallenge)
        fixture.controller.macHostedCallEvidenceChanged(
            WebRTCMacHostedCallEvidence(
                sequence: 1,
                challengeSequence: challenge.sequence,
                challengeNonce: challenge.nonce,
                callEpochNonce:
                    challenge.callEpochNonce,
                state: .active
            )
        )
        XCTAssertTrue(fixture.controller.microphoneActivationIsAllowed())

        fixture.events.onInterruptionBegan?(.default)
        XCTAssertNil(currentChallenge)
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())
        fixture.events.onInterruptionEnded?(true)
        let recoveryChallenge = try XCTUnwrap(currentChallenge)
        XCTAssertNotEqual(recoveryChallenge, challenge)
        XCTAssertEqual(
            recoveryChallenge.callEpochNonce,
            challenge.callEpochNonce
        )

        fixture.controller.macHostedCallEvidenceChanged(
            WebRTCMacHostedCallEvidence(
                sequence: 2,
                challengeSequence: challenge.sequence,
                challengeNonce: challenge.nonce,
                callEpochNonce:
                    challenge.callEpochNonce,
                state: .active
            )
        )
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())
        fixture.controller.macHostedCallEvidenceChanged(
            WebRTCMacHostedCallEvidence(
                sequence: 3,
                challengeSequence: recoveryChallenge.sequence,
                challengeNonce: recoveryChallenge.nonce,
                callEpochNonce:
                    recoveryChallenge.callEpochNonce,
                state: .active
            )
        )
        XCTAssertTrue(fixture.controller.microphoneActivationIsAllowed())
    }

    func testInterruptionEndingBeforeCallKitDeliveryStillRequiresPostEdgeChallenge() throws {
        let fixture = makeFixture()
        var currentChallenge: WebRTCMacHostedCallChallenge?
        fixture.controller.onMacHostedCallChallengeChanged = {
            currentChallenge = $0
        }
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()

        fixture.events.onInterruptionBegan?(.default)
        fixture.events.onInterruptionEnded?(true)
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )

        let challenge = try XCTUnwrap(currentChallenge)
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())
        fixture.controller.macHostedCallEvidenceChanged(
            WebRTCMacHostedCallEvidence(
                sequence: 1,
                challengeSequence: challenge.sequence,
                challengeNonce: challenge.nonce,
                callEpochNonce:
                    challenge.callEpochNonce,
                state: .active
            )
        )
        XCTAssertTrue(fixture.controller.microphoneActivationIsAllowed())
    }

    func testAudioSessionManagerMapsInterruptionBeganReasonsExactly() {
        XCTAssertEqual(
            AudioSessionManager.interruptionBeganReason(rawValue: nil),
            .unavailable
        )
        XCTAssertEqual(
            AudioSessionManager.interruptionBeganReason(rawValue: 0),
            .default
        )
        XCTAssertEqual(
            AudioSessionManager.interruptionBeganReason(rawValue: 2),
            .other(rawValue: 2)
        )
        XCTAssertEqual(
            AudioSessionManager.interruptionBeganReason(rawValue: 99),
            .other(rawValue: 99)
        )
    }

    func testAudioSessionManagerDeliversBeganSynchronouslyAndIgnoresReasonForEnded() {
        let manager = AudioSessionManager()
        var returnedFromBeganDelivery = false
        var receivedReason:
            AudioSessionInterruptionBeganReason?
        var endedValues: [Bool] = []
        manager.onInterruptionBegan = { reason in
            XCTAssertFalse(returnedFromBeganDelivery)
            receivedReason = reason
        }
        manager.onInterruptionEnded = {
            endedValues.append($0)
        }

        manager.debugDeliverInterruptionSynchronouslyForTests(
            typeValue:
                AVAudioSession.InterruptionType.began.rawValue,
            reasonValue: 0
        )
        returnedFromBeganDelivery = true

        XCTAssertEqual(receivedReason, .default)

        manager.debugDeliverInterruptionSynchronouslyForTests(
            typeValue:
                AVAudioSession.InterruptionType.ended.rawValue,
            optionsValue:
                AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            reasonValue: 2
        )

        XCTAssertEqual(receivedReason, .default)
        XCTAssertEqual(endedValues, [true])
    }

    func testAudioSessionManagerDeliversMediaServicesLossSynchronously() {
        let manager = AudioSessionManager()
        var returnedFromDelivery = false
        var callbackCount = 0
        manager.onMediaServicesLost = {
            XCTAssertFalse(returnedFromDelivery)
            callbackCount += 1
        }

        manager.debugDeliverMediaServicesLostSynchronouslyForTests()
        returnedFromDelivery = true

        XCTAssertEqual(callbackCount, 1)
    }

    func testAudioSessionManagerSuppressesOnlyNativeOwnedReasonEightOutcomes() {
        let manager = AudioSessionManager()
        let generation = manager.debugObservationGenerationForTests
        var routeMessages: [String] = []
        manager.onRouteChanged = {
            routeMessages.append($0)
        }

        for disposition: WebRTCRouteConfigurationChangeDisposition in [
            .consumed,
            .liveRejectionOwnedByWaiter,
            .staleSuppressed,
        ] {
            manager.debugDeliverRouteConfigurationChangeDispositionForTests(
                disposition,
                registeredObservationGeneration: generation
            )
        }
        XCTAssertTrue(routeMessages.isEmpty)

        for disposition: WebRTCRouteConfigurationChangeDisposition in [
            .generic,
            .uninitialized,
            .timedOut,
        ] {
            manager.debugDeliverRouteConfigurationChangeDispositionForTests(
                disposition,
                registeredObservationGeneration: generation
            )
        }
        XCTAssertEqual(
            routeMessages,
            Array(
                repeating: "Audio route configuration changed",
                count: 3
            ),
            "Generic output-only, unavailable-native, and timeout outcomes each require exactly one ordinary recovery callback."
        )
    }

    func testAudioSessionManagerReasonEightFallbackCoversNativeUnavailabilityAndFencesRetiredObserver() {
        let manager = AudioSessionManager()
        var callbackCount = 0
        manager.onRouteChanged = { _ in
            callbackCount += 1
        }

        let preInitializationGeneration =
            manager.debugObservationGenerationForTests
        manager.debugDeliverRouteConfigurationChangeDispositionForTests(
            .timedOut,
            registeredObservationGeneration: preInitializationGeneration
        )
        XCTAssertEqual(callbackCount, 1)

        manager.startObserving()
        let activeGeneration = manager.debugObservationGenerationForTests
        XCTAssertNotEqual(activeGeneration, preInitializationGeneration)
        manager.debugDeliverRouteConfigurationChangeDispositionForTests(
            .uninitialized,
            registeredObservationGeneration: activeGeneration
        )
        XCTAssertEqual(callbackCount, 2)

        manager.stopObserving()
        manager.debugDeliverRouteConfigurationChangeDispositionForTests(
            .generic,
            registeredObservationGeneration: activeGeneration
        )
        XCTAssertEqual(
            callbackCount,
            2,
            "A delayed result from the retired observer must not recover after observation stops."
        )
    }

    func testAudioSessionManagerFencesDelayedReasonEightFallbackAcrossPolicyRotation() {
        let manager = AudioSessionManager()
        var routeCallbackCount = 0
        manager.onRouteChanged = { _ in
            routeCallbackCount += 1
        }
        manager.startObserving()
        let observationGeneration =
            manager.debugObservationGenerationForTests

        manager.updateRouteConfigurationChangePolicyEpoch(41)
        manager.updateRouteConfigurationChangePolicyEpoch(42)
        manager.debugDeliverRouteConfigurationChangeDispositionForTests(
            .timedOut,
            registeredObservationGeneration: observationGeneration,
            notificationSequence: 1,
            audioPolicyEpoch: 41,
            latestNotificationSequence: 1
        )
        XCTAssertEqual(
            routeCallbackCount,
            0,
            "A delayed fallback captured under the retired policy must not recover the replacement policy."
        )

        manager.debugDeliverRouteConfigurationChangeDispositionForTests(
            .generic,
            registeredObservationGeneration: observationGeneration,
            notificationSequence: 2,
            audioPolicyEpoch: 42,
            latestNotificationSequence: 2
        )
        XCTAssertEqual(routeCallbackCount, 1)

        manager.debugDeliverRouteConfigurationChangeDispositionForTests(
            .uninitialized,
            registeredObservationGeneration: observationGeneration,
            notificationSequence: 1,
            audioPolicyEpoch: 42,
            latestNotificationSequence: 2
        )
        XCTAssertEqual(
            routeCallbackCount,
            1,
            "An older suspended delivery must not retire policy after a newer reason-8 ingress."
        )
    }

    func testControllerDrivenFreshRecoveryFencesDelayedReasonEightFallback() {
        let manager = AudioSessionManager()
        let playback = AudioPlaybackStub()
        let background = BackgroundPlaybackStub()
        let callActivity = CallActivityStub()
        let controller = WorldwideAudioLifecycleController(
            playback: playback,
            backgroundPlayback: background,
            events: manager,
            callActivity: callActivity
        )
        defer { controller.stop() }

        controller.prepare(serverName: "Mac mini")
        let observationGeneration =
            manager.debugObservationGenerationForTests
        let ingressPolicyEpoch =
            manager.debugRouteConfigurationChangePolicyEpochForTests
        let recoveriesBeforeFreshPolicy = playback.recoverCount

        // Transport health installs a fresh recovery operation without changing microphone
        // topology. That operation alone must rotate the reason-8 policy epoch.
        controller.transportBecameHealthy()
        let replacementPolicyEpoch =
            manager.debugRouteConfigurationChangePolicyEpochForTests
        XCTAssertNotEqual(
            replacementPolicyEpoch,
            ingressPolicyEpoch
        )
        XCTAssertGreaterThan(
            playback.recoverCount,
            recoveriesBeforeFreshPolicy
        )

        let recoveriesAfterFreshPolicy = playback.recoverCount
        manager.debugDeliverRouteConfigurationChangeDispositionForTests(
            .timedOut,
            registeredObservationGeneration: observationGeneration,
            notificationSequence: 1,
            audioPolicyEpoch: ingressPolicyEpoch,
            latestNotificationSequence: 1
        )
        XCTAssertEqual(
            playback.recoverCount,
            recoveriesAfterFreshPolicy,
            "A delayed fallback captured before the controller's replacement recovery must not enter the new policy."
        )

        manager.debugDeliverRouteConfigurationChangeDispositionForTests(
            .generic,
            registeredObservationGeneration: observationGeneration,
            notificationSequence: 2,
            audioPolicyEpoch: replacementPolicyEpoch,
            latestNotificationSequence: 2
        )
        XCTAssertEqual(
            playback.recoverCount,
            recoveriesAfterFreshPolicy + 1,
            "The current reason-8 fallback must still perform ordinary route recovery exactly once."
        )
    }

    func testAudioSessionManagerOldDeviceLossBypassesReasonEightArbitrationSynchronously() {
        let manager = AudioSessionManager()
        var returnedFromDelivery = false
        var routeMessages: [String] = []
        manager.onRouteChanged = {
            XCTAssertFalse(returnedFromDelivery)
            routeMessages.append($0)
        }

        manager.debugDeliverOrdinaryRouteChangeSynchronouslyForTests(
            reasonValue:
                AVAudioSession.RouteChangeReason
                    .oldDeviceUnavailable.rawValue
        )
        returnedFromDelivery = true

        XCTAssertEqual(
            routeMessages,
            ["Audio route changed: device unavailable"]
        )
        manager.debugDeliverOrdinaryRouteChangeSynchronouslyForTests(
            reasonValue:
                AVAudioSession.RouteChangeReason
                    .routeConfigurationChange.rawValue
        )
        XCTAssertEqual(routeMessages.count, 1)
    }

    func testAudioSessionManagerCategoryOperationRequiresExactOptions() {
        let manager = AudioSessionManager()
        let operationID = UUID()
        var receivedOperationIDs: [UUID?] = []
        manager.onCategoryChanged = {
            receivedOperationIDs.append($0.operationID)
        }
        manager.armCategoryChangeOperation(
            operationID,
            category: AVAudioSession.Category.playback.rawValue,
            mode: AVAudioSession.Mode.default.rawValue,
            categoryOptionsRawValue: 0
        )

        let mismatchedOperationID =
            manager.debugDeliverCategoryChangeSynchronouslyForTests(
                AudioSessionCategoryChange(
                    category:
                        AVAudioSession.Category.playback.rawValue,
                    mode: AVAudioSession.Mode.default.rawValue,
                    categoryOptionsRawValue:
                        AVAudioSession.CategoryOptions
                            .mixWithOthers.rawValue
                )
            )
        let matchedOperationID =
            manager.debugDeliverCategoryChangeSynchronouslyForTests(
                AudioSessionCategoryChange(
                    category:
                        AVAudioSession.Category.playback.rawValue,
                    mode: AVAudioSession.Mode.default.rawValue,
                    categoryOptionsRawValue: 0
                )
            )

        XCTAssertNil(mismatchedOperationID)
        XCTAssertEqual(matchedOperationID, operationID)
        XCTAssertEqual(receivedOperationIDs, [nil, operationID])
    }

    func testAudioSessionManagerDuplicateDeliveryCannotConsumeNewerSameTargetOperation() {
        let manager = AudioSessionManager()
        let firstOperationID = UUID()
        let secondOperationID = UUID()
        var receivedOperationIDs: [UUID?] = []
        var receivedAmbiguity: [Bool] = []
        var ambiguousPredecessorOperationIDs: [UUID?] = []
        var blockingTombstoneOperationIDs: [UUID?] = []
        let categoryChange = AudioSessionCategoryChange(
            category: AVAudioSession.Category.playAndRecord.rawValue,
            mode: AVAudioSession.Mode.default.rawValue
        )

        manager.onCategoryChanged = { [weak manager] change in
            receivedOperationIDs.append(change.operationID)
            receivedAmbiguity.append(
                change.operationIDIsAmbiguous
            )
            ambiguousPredecessorOperationIDs.append(
                change.ambiguousPredecessorOperationID
            )
            blockingTombstoneOperationIDs.append(
                change.blockingTombstoneOperationID
            )
            if receivedOperationIDs.count == 1 {
                manager?.armCategoryChangeOperation(
                    secondOperationID,
                    category: categoryChange.category,
                    mode: categoryChange.mode
                )
            }
        }
        manager.armCategoryChangeOperation(
            firstOperationID,
            category: categoryChange.category,
            mode: categoryChange.mode
        )

        let consumedFirstOperationID =
            manager.debugDeliverCategoryChangeSynchronouslyForTests(
                categoryChange
            )

        XCTAssertEqual(
            consumedFirstOperationID,
            firstOperationID
        )
        XCTAssertEqual(
            receivedOperationIDs,
            [firstOperationID]
        )

        let rejectedDuplicateOperationID =
            manager.debugDeliverCategoryChangeSynchronouslyForTests(
                categoryChange
            )

        XCTAssertNil(rejectedDuplicateOperationID)
        XCTAssertEqual(
            receivedOperationIDs,
            [firstOperationID, nil]
        )
        XCTAssertEqual(
            receivedAmbiguity,
            [false, true]
        )
        XCTAssertEqual(
            ambiguousPredecessorOperationIDs,
            [nil, nil],
            "A notification that entered only after delivery cannot borrow the delivered operation's predecessor identity."
        )
        XCTAssertEqual(
            blockingTombstoneOperationIDs,
            [nil, firstOperationID]
        )

        let consumedSecondOperationID =
            manager.debugDeliverCategoryChangeSynchronouslyForTests(
                categoryChange
            )

        XCTAssertEqual(
            consumedSecondOperationID,
            secondOperationID
        )
        XCTAssertEqual(
            receivedOperationIDs,
            [firstOperationID, nil, secondOperationID]
        )
        XCTAssertEqual(
            receivedAmbiguity,
            [false, true, false]
        )
        XCTAssertEqual(
            ambiguousPredecessorOperationIDs,
            [nil, nil, nil]
        )
        XCTAssertEqual(
            blockingTombstoneOperationIDs,
            [nil, firstOperationID, nil]
        )
    }

    func testAudioSessionManagerCancelledPredecessorWithoutIngressCannotClaimUnrelatedSameTargetNotification() {
        let manager = AudioSessionManager()
        let retiredOperationID = UUID()
        let currentOperationID = UUID()
        var receivedOperationIDs: [UUID?] = []
        var receivedAmbiguity: [Bool] = []
        var ambiguousPredecessorOperationIDs: [UUID?] = []
        var blockingTombstoneOperationIDs: [UUID?] = []
        manager.onCategoryChanged = {
            receivedOperationIDs.append($0.operationID)
            receivedAmbiguity.append(
                $0.operationIDIsAmbiguous
            )
            ambiguousPredecessorOperationIDs.append(
                $0.ambiguousPredecessorOperationID
            )
            blockingTombstoneOperationIDs.append(
                $0.blockingTombstoneOperationID
            )
        }
        let change = AudioSessionCategoryChange(
            category: AVAudioSession.Category.playback.rawValue,
            mode: AVAudioSession.Mode.default.rawValue,
            categoryOptionsRawValue: 0
        )

        manager.armCategoryChangeOperation(
            retiredOperationID,
            category: change.category,
            mode: change.mode,
            categoryOptionsRawValue:
                change.categoryOptionsRawValue
        )
        manager.cancelCategoryChangeOperation(
            retiredOperationID
        )
        manager.armCategoryChangeOperation(
            currentOperationID,
            category: change.category,
            mode: change.mode,
            categoryOptionsRawValue:
                change.categoryOptionsRawValue
        )

        XCTAssertNil(
            manager.debugDeliverCategoryChangeSynchronouslyForTests(
                change
            )
        )
        XCTAssertEqual(receivedOperationIDs, [nil])
        XCTAssertEqual(receivedAmbiguity, [true])
        XCTAssertEqual(
            ambiguousPredecessorOperationIDs,
            [nil],
            "No notification had entered before cancellation, so the tombstone cannot lend the retired operation's identity to a later same-target event."
        )
        XCTAssertEqual(
            blockingTombstoneOperationIDs,
            [retiredOperationID]
        )

        XCTAssertEqual(
            manager.debugDeliverCategoryChangeSynchronouslyForTests(
                change
            ),
            currentOperationID
        )
        XCTAssertEqual(
            receivedOperationIDs,
            [nil, currentOperationID]
        )
        XCTAssertEqual(
            receivedAmbiguity,
            [true, false]
        )
        XCTAssertEqual(
            ambiguousPredecessorOperationIDs,
            [nil, nil]
        )
        XCTAssertEqual(
            blockingTombstoneOperationIDs,
            [retiredOperationID, nil]
        )
    }

    func testAudioSessionManagerIngressBeforeCancellationRetainsExactPredecessorIdentity() {
        let manager = AudioSessionManager()
        let retiredOperationID = UUID()
        let currentOperationID = UUID()
        var receivedOperationIDs: [UUID?] = []
        var receivedAmbiguousPredecessors: [UUID?] = []
        var receivedBlockingTombstones: [UUID?] = []
        let change = AudioSessionCategoryChange(
            category: AVAudioSession.Category.playback.rawValue,
            mode: AVAudioSession.Mode.default.rawValue,
            categoryOptionsRawValue: 0
        )
        manager.onCategoryChanged = {
            receivedOperationIDs.append($0.operationID)
            receivedAmbiguousPredecessors.append(
                $0.ambiguousPredecessorOperationID
            )
            receivedBlockingTombstones.append(
                $0.blockingTombstoneOperationID
            )
        }

        manager.updateRouteConfigurationChangePolicyEpoch(10)
        manager.armCategoryChangeOperation(
            retiredOperationID,
            category: change.category,
            mode: change.mode,
            categoryOptionsRawValue:
                change.categoryOptionsRawValue
        )
        let queuedRetiredIngress =
            manager.debugCaptureCategoryChangeIngressForTests()
        manager.cancelCategoryChangeOperation(retiredOperationID)

        manager.updateRouteConfigurationChangePolicyEpoch(11)
        manager.armCategoryChangeOperation(
            currentOperationID,
            category: change.category,
            mode: change.mode,
            categoryOptionsRawValue:
                change.categoryOptionsRawValue
        )

        XCTAssertNil(
            manager.debugDeliverCategoryChangeSynchronouslyForTests(
                change,
                ingress: queuedRetiredIngress
            )
        )
        XCTAssertEqual(receivedOperationIDs, [nil])
        XCTAssertEqual(
            receivedAmbiguousPredecessors,
            [retiredOperationID],
            "Only the notification already admitted in the predecessor's policy epoch may carry its identity across cancellation."
        )
        XCTAssertEqual(receivedBlockingTombstones, [retiredOperationID])

        XCTAssertEqual(
            manager.debugDeliverCategoryChangeSynchronouslyForTests(
                change
            ),
            currentOperationID
        )
        XCTAssertEqual(
            receivedOperationIDs,
            [nil, currentOperationID]
        )
        XCTAssertEqual(
            receivedAmbiguousPredecessors,
            [retiredOperationID, nil]
        )
        XCTAssertEqual(
            receivedBlockingTombstones,
            [retiredOperationID, nil]
        )
    }

    func testAmbiguousCategoryEvidenceRequiresExactPredecessorIdentity() throws {
        for carriesExactPredecessor in [true, false] {
            let fixture = makeFixture()
            fixture.playback.requiresRuntimePlayoutProof = true
            var refreshCount = 0
            fixture.controller
                .onAmbiguousCategoryPlayoutProofRefreshRequested = { _ in
                refreshCount += 1
            }
            fixture.controller.prepare(serverName: "Mac mini")

            XCTAssertNotEqual(
                fixture.controller
                    .beginMicrophoneTopologyTransition(isEnabled: true),
                0
            )
            let predecessor = try XCTUnwrap(
                fixture.events.lastArmedCategoryChange?.operationID
            )
            XCTAssertNotEqual(
                fixture.controller
                    .beginMicrophoneTopologyTransition(isEnabled: false),
                0
            )
            let current = try XCTUnwrap(
                fixture.events.lastArmedCategoryChange
            )
            XCTAssertNotEqual(current.operationID, predecessor)
            let failClosedCountBeforeDelivery =
                fixture.playback.prepareManualAudioDisabledCount

            fixture.events.onCategoryChanged?(
                AudioSessionCategoryChange(
                    category: current.category,
                    mode: current.mode,
                    categoryOptionsRawValue:
                        current.categoryOptionsRawValue,
                    operationID: nil,
                    operationIDIsAmbiguous: true,
                    ambiguousPredecessorOperationID:
                        carriesExactPredecessor
                            ? predecessor
                            : UUID()
                )
            )

            if carriesExactPredecessor {
                XCTAssertEqual(refreshCount, 1)
                XCTAssertEqual(
                    fixture.playback
                        .prepareManualAudioDisabledCount,
                    failClosedCountBeforeDelivery
                )
                XCTAssertNil(fixture.controller.snapshot.errorText)
            } else {
                XCTAssertEqual(refreshCount, 0)
                XCTAssertEqual(
                    fixture.playback
                        .prepareManualAudioDisabledCount,
                    failClosedCountBeforeDelivery + 1
                )
                XCTAssertEqual(
                    fixture.controller.snapshot.stateText,
                    "Playback unavailable"
                )
            }
        }
    }

    func testBlockingTombstoneUsesOneNotificationThenExactClaimedProof() throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()

        XCTAssertNotEqual(
            fixture.controller.beginMicrophoneTopologyTransition(
                isEnabled: true
            ),
            0
        )
        let predecessor = try XCTUnwrap(
            fixture.events.lastArmedCategoryChange?.operationID
        )
        XCTAssertNotEqual(
            fixture.controller.beginMicrophoneTopologyTransition(
                isEnabled: false
            ),
            0
        )
        let current = try XCTUnwrap(
            fixture.events.lastArmedCategoryChange
        )
        var proofClaim: WorldwideAudioCategoryProofClaim?
        fixture.controller
            .onAmbiguousCategoryPlayoutProofRefreshRequested = {
                proofClaim = $0
            }

        fixture.events.onCategoryChanged?(
            AudioSessionCategoryChange(
                category: current.category,
                mode: current.mode,
                categoryOptionsRawValue:
                    current.categoryOptionsRawValue,
                operationID: nil,
                operationIDIsAmbiguous: true,
                ambiguousPredecessorOperationID: nil,
                blockingTombstoneOperationID: predecessor
            )
        )

        let claim = try XCTUnwrap(proofClaim)
        XCTAssertEqual(claim.operationID, current.operationID)
        XCTAssertEqual(claim.category, current.category)
        XCTAssertEqual(claim.mode, current.mode)
        XCTAssertEqual(
            claim.categoryOptionsRawValue,
            current.categoryOptionsRawValue
        )
        XCTAssertTrue(
            fixture.remoteAudio.isEnabled,
            "The decoded-track proof aperture stays open so RemoteIO can produce fresh evidence; published playback remains closed."
        )
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        XCTAssertNil(fixture.controller.snapshot.errorText)
        XCTAssertEqual(
            fixture.events.lastArmedCategoryChange?.operationID,
            current.operationID
        )

        fixture.events.onCategoryChanged?(
            AudioSessionCategoryChange(
                category: current.category,
                mode: current.mode,
                categoryOptionsRawValue:
                    current.categoryOptionsRawValue,
                operationID: current.operationID
            )
        )
        XCTAssertEqual(
            fixture.events.lastArmedCategoryChange?.operationID,
            current.operationID,
            "A later exact callback must not retire the transition while its claimed proof is pending."
        )
        fixture.controller.updateRuntimePlayout(isReady: true)
        XCTAssertEqual(
            fixture.events.lastArmedCategoryChange?.operationID,
            current.operationID,
            "The duplicate callback must not reopen ordinary unclaimed proof completion."
        )
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)

        let handle = viewModel
            .debugStartIOSPlayoutProofAttemptForTests(
                requestRecovery: false,
                categoryProofClaim: claim
            )
        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(
                    callbacks: 1,
                    frames: 480,
                    failures: 0
                ),
                handle: handle,
                source: .polling
            ),
            "The first exact native sample establishes the claimed proof's fresh counter floor."
        )
        XCTAssertTrue(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(
                    callbacks: 2,
                    frames: 960,
                    failures: 0
                ),
                handle: handle,
                source: .statistics
            ),
            "Fresh exact policy and RemoteIO evidence must complete the current transition without another OS notification."
        )

        XCTAssertNil(fixture.events.lastArmedCategoryChange)
        XCTAssertNil(fixture.controller.snapshot.errorText)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertTrue(fixture.controller.snapshot.isPlaying)
    }

    func testStaleOrMismatchedCategoryProofCannotResolveReplacement() throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()

        _ = fixture.controller.beginMicrophoneTopologyTransition(
            isEnabled: true
        )
        let predecessor = try XCTUnwrap(
            fixture.events.lastArmedCategoryChange?.operationID
        )
        _ = fixture.controller.beginMicrophoneTopologyTransition(
            isEnabled: false
        )
        let current = try XCTUnwrap(
            fixture.events.lastArmedCategoryChange
        )
        var staleClaim: WorldwideAudioCategoryProofClaim?
        fixture.controller
            .onAmbiguousCategoryPlayoutProofRefreshRequested = {
                staleClaim = $0
            }
        fixture.events.onCategoryChanged?(
            AudioSessionCategoryChange(
                category: current.category,
                mode: current.mode,
                categoryOptionsRawValue:
                    current.categoryOptionsRawValue,
                operationIDIsAmbiguous: true,
                blockingTombstoneOperationID: predecessor
            )
        )
        let retiredClaim = try XCTUnwrap(staleClaim)

        _ = fixture.controller.beginMicrophoneTopologyTransition(
            isEnabled: true
        )
        let replacement = try XCTUnwrap(
            fixture.events.lastArmedCategoryChange
        )
        let replacementStateBeforeStaleProof =
            fixture.controller.snapshot
        let replacementTrackGateBeforeStaleProof =
            fixture.remoteAudio.isEnabled
        fixture.controller.updateRuntimePlayout(
            isReady: true,
            categoryProofClaim: retiredClaim
        )

        XCTAssertEqual(
            fixture.events.lastArmedCategoryChange?.operationID,
            replacement.operationID
        )
        XCTAssertEqual(
            fixture.remoteAudio.isEnabled,
            replacementTrackGateBeforeStaleProof
        )
        XCTAssertEqual(
            fixture.controller.snapshot,
            replacementStateBeforeStaleProof
        )
    }

    func testOwnedCategoryProofTimeoutFailsClosedWithoutSecondNotification() throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        fixture.controller.prepare(serverName: "Mac mini")

        _ = fixture.controller.beginMicrophoneTopologyTransition(
            isEnabled: true
        )
        let predecessor = try XCTUnwrap(
            fixture.events.lastArmedCategoryChange?.operationID
        )
        _ = fixture.controller.beginMicrophoneTopologyTransition(
            isEnabled: false
        )
        let current = try XCTUnwrap(
            fixture.events.lastArmedCategoryChange
        )
        var proofClaim: WorldwideAudioCategoryProofClaim?
        fixture.controller
            .onAmbiguousCategoryPlayoutProofRefreshRequested = {
                proofClaim = $0
            }
        fixture.events.onCategoryChanged?(
            AudioSessionCategoryChange(
                category: current.category,
                mode: current.mode,
                categoryOptionsRawValue:
                    current.categoryOptionsRawValue,
                operationIDIsAmbiguous: true,
                blockingTombstoneOperationID: predecessor
            )
        )
        let claim = try XCTUnwrap(proofClaim)
        let failClosedCount =
            fixture.playback.prepareManualAudioDisabledCount
        let handle = viewModel
            .debugStartIOSPlayoutProofAttemptForTests(
                requestRecovery: false,
                categoryProofClaim: claim
            )

        viewModel.debugTimeoutIOSPlayoutProofForTests(
            handle: handle
        )

        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            failClosedCount + 1
        )
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Playback unavailable"
        )
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
    }

    func testClaimedCategoryProofRejectsMismatchedNativePolicyThroughProductionEvaluator()
        throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()

        _ = fixture.controller.beginMicrophoneTopologyTransition(
            isEnabled: true
        )
        let predecessor = try XCTUnwrap(
            fixture.events.lastArmedCategoryChange?.operationID
        )
        _ = fixture.controller.beginMicrophoneTopologyTransition(
            isEnabled: false
        )
        let current = try XCTUnwrap(
            fixture.events.lastArmedCategoryChange
        )
        var proofClaim: WorldwideAudioCategoryProofClaim?
        fixture.controller
            .onAmbiguousCategoryPlayoutProofRefreshRequested = {
                proofClaim = $0
            }
        fixture.events.onCategoryChanged?(
            AudioSessionCategoryChange(
                category: current.category,
                mode: current.mode,
                categoryOptionsRawValue:
                    current.categoryOptionsRawValue,
                operationIDIsAmbiguous: true,
                blockingTombstoneOperationID: predecessor
            )
        )
        let claim = try XCTUnwrap(proofClaim)
        let failClosedCount =
            fixture.playback.prepareManualAudioDisabledCount
        let handle = viewModel
            .debugStartIOSPlayoutProofAttemptForTests(
                requestRecovery: false,
                categoryProofClaim: claim
            )

        XCTAssertTrue(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(
                    callbacks: 1,
                    frames: 480,
                    failures: 0,
                    modeIsDefault: false
                ),
                handle: handle,
                source: .polling
            ),
            "A fresh counter sample with the wrong current AVAudioSession mode is a terminal claimed-proof failure."
        )

        XCTAssertNil(fixture.events.lastArmedCategoryChange)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            failClosedCount + 1
        )
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Playback unavailable"
        )
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        XCTAssertNotNil(fixture.controller.snapshot.errorText)
    }

    func testHostedRuntimeGateRequiresConsumedClaimAndExactPolicyID() throws {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        var hostedAuthorization:
            WebRTCIOSHostedCallPlayoutAuthorization?
        fixture.controller.onHostedCallPlayoutRecoveryRequested = {
            hostedAuthorization = $0
        }
        fixture.events.onInterruptionBegan?(.default)
        let authorization = try XCTUnwrap(hostedAuthorization)

        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        fixture.controller.updateHostedCallRuntimePlayout(
            policyID: authorization.policyID,
            isReady: false
        )
        XCTAssertFalse(
            fixture.remoteAudio.isEnabled,
            "The request itself must not open decoded remote audio."
        )

        XCTAssertTrue(
            authorization.performRecoveryIfValidForTesting {}
        )
        fixture.controller.updateHostedCallRuntimePlayout(
            policyID: UUID(),
            isReady: true
        )
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.controller.updateHostedCallRuntimePlayout(
            policyID: authorization.policyID,
            isReady: false
        )
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Starting playback"
        )

        fixture.controller.updateHostedCallRuntimePlayout(
            policyID: authorization.policyID,
            isReady: true
        )
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertTrue(fixture.controller.snapshot.isPlaying)

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 0,
            connectedNonEndedCallCount: 0
        )
        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.controller.updateHostedCallRuntimePlayout(
            policyID: authorization.policyID,
            isReady: true
        )
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
    }

    private func makeHostedCallFailureFixture(
        onAuthorization:
            @escaping (WebRTCIOSHostedCallPlayoutAuthorization) -> Void
    ) -> AudioLifecycleFixture {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        fixture.controller.onHostedCallPlayoutRecoveryRequested =
            onAuthorization
        return fixture
    }

    func testHostedRuntimeFailureAcceptsExactPendingAuthorizationAndFailsClosed() throws {
        var hostedAuthorization:
            WebRTCIOSHostedCallPlayoutAuthorization?
        let fixture = makeHostedCallFailureFixture {
            hostedAuthorization = $0
        }
        var proofInvalidations: [Bool] = []
        fixture.controller.onAudioProofInvalidated = {
            proofInvalidations.append($0)
        }

        fixture.events.onInterruptionBegan?(.default)
        let authorization = try XCTUnwrap(hostedAuthorization)
        let manualDisabledCount =
            fixture.playback.prepareManualAudioDisabledCount

        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(authorization.isRecoveryPending)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        proofInvalidations.removeAll()

        fixture.controller.failHostedCallRuntimePlayout(
            policyID: authorization.policyID,
            authorization: authorization,
            failureMessage: "Hosted playout failed.",
            diagnostic: "Pending hosted recovery timed out."
        )

        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            manualDisabledCount + 1
        )
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        XCTAssertEqual(
            fixture.controller.snapshot.errorText,
            "Hosted playout failed."
        )
        XCTAssertEqual(
            fixture.controller.snapshot.diagnosticText,
            "Pending hosted recovery timed out."
        )
        XCTAssertEqual(proofInvalidations, [true])
    }

    func testHostedRuntimeFailureAcceptsExactAuthorizationAlreadyInvalidatedByNativeCode() throws {
        var hostedAuthorization:
            WebRTCIOSHostedCallPlayoutAuthorization?
        let fixture = makeHostedCallFailureFixture {
            hostedAuthorization = $0
        }

        fixture.events.onInterruptionBegan?(.default)
        let authorization = try XCTUnwrap(hostedAuthorization)

        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(
            authorization.performRecoveryIfValidForTesting {}
        )
        XCTAssertFalse(authorization.isRecoveryPending)
        authorization.revoke()
        XCTAssertFalse(authorization.isValid)
        let manualDisabledCount =
            fixture.playback.prepareManualAudioDisabledCount

        fixture.controller.failHostedCallRuntimePlayout(
            policyID: authorization.policyID,
            authorization: authorization,
            failureMessage: "Native hosted playout was rejected.",
            diagnostic: "The native authorization was already invalid."
        )

        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            manualDisabledCount + 1
        )
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
    }

    func testHostedRuntimeFailureRejectsWrongPolicyIDAndDistinctAuthorizationWithSameID() throws {
        var hostedAuthorization:
            WebRTCIOSHostedCallPlayoutAuthorization?
        let fixture = makeHostedCallFailureFixture {
            hostedAuthorization = $0
        }

        fixture.events.onInterruptionBegan?(.default)
        let authorization = try XCTUnwrap(hostedAuthorization)
        let distinctAuthorization =
            WebRTCIOSHostedCallPlayoutAuthorization(
                policyID: authorization.policyID,
                origin: .interruption
            )
        let manualDisabledCount =
            fixture.playback.prepareManualAudioDisabledCount
        var snapshotPublicationCount = 0
        fixture.controller.onSnapshotChanged = { _ in
            snapshotPublicationCount += 1
        }

        fixture.controller.failHostedCallRuntimePlayout(
            policyID: UUID(),
            authorization: authorization,
            failureMessage: "Wrong policy.",
            diagnostic: nil
        )
        fixture.controller.failHostedCallRuntimePlayout(
            policyID: authorization.policyID,
            authorization: distinctAuthorization,
            failureMessage: "Wrong authorization.",
            diagnostic: nil
        )

        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(authorization.isRecoveryPending)
        XCTAssertTrue(distinctAuthorization.isValid)
        XCTAssertTrue(distinctAuthorization.isRecoveryPending)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            manualDisabledCount
        )
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(snapshotPublicationCount, 0)

        XCTAssertTrue(
            authorization.performRecoveryIfValidForTesting {}
        )
        fixture.controller.updateHostedCallRuntimePlayout(
            policyID: authorization.policyID,
            isReady: false
        )
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
    }

    func testDelayedStaleHostedRuntimeFailureCannotTouchReplacementPolicyOrGates() throws {
        var hostedAuthorizations:
            [WebRTCIOSHostedCallPlayoutAuthorization] = []
        let fixture = makeHostedCallFailureFixture {
            hostedAuthorizations.append($0)
        }

        fixture.events.onInterruptionBegan?(.default)
        let retiredAuthorization = try XCTUnwrap(
            hostedAuthorizations.first
        )
        fixture.events.onInterruptionBegan?(.default)
        XCTAssertEqual(hostedAuthorizations.count, 2)
        let replacementAuthorization = try XCTUnwrap(
            hostedAuthorizations.last
        )

        XCTAssertNotEqual(
            retiredAuthorization.policyID,
            replacementAuthorization.policyID
        )
        XCTAssertFalse(retiredAuthorization.isValid)
        XCTAssertTrue(replacementAuthorization.isValid)
        XCTAssertTrue(replacementAuthorization.isRecoveryPending)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.controller.failHostedCallRuntimePlayout(
            policyID: retiredAuthorization.policyID,
            authorization: retiredAuthorization,
            failureMessage: "Stale hosted failure.",
            diagnostic: "The retired policy completed late."
        )

        XCTAssertEqual(hostedAuthorizations.count, 2)
        XCTAssertTrue(replacementAuthorization.isValid)
        XCTAssertTrue(replacementAuthorization.isRecoveryPending)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        XCTAssertTrue(
            replacementAuthorization.performRecoveryIfValidForTesting {}
        )
        fixture.controller.updateHostedCallRuntimePlayout(
            policyID: replacementAuthorization.policyID,
            isReady: false
        )
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)

        fixture.controller.failHostedCallRuntimePlayout(
            policyID: retiredAuthorization.policyID,
            authorization: retiredAuthorization,
            failureMessage: "Stale hosted failure.",
            diagnostic: "The retired policy completed late."
        )

        XCTAssertEqual(hostedAuthorizations.count, 2)
        XCTAssertTrue(replacementAuthorization.isValid)
        XCTAssertFalse(replacementAuthorization.isRecoveryPending)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)

        fixture.controller.updateHostedCallRuntimePlayout(
            policyID: replacementAuthorization.policyID,
            isReady: true
        )
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertTrue(fixture.controller.snapshot.isPlaying)
    }

    func testRepeatedExactHostedRuntimeFailureIsIdempotentAndCannotReissuePolicy() throws {
        var hostedAuthorizations:
            [WebRTCIOSHostedCallPlayoutAuthorization] = []
        let fixture = makeHostedCallFailureFixture {
            hostedAuthorizations.append($0)
        }
        var proofInvalidations: [Bool] = []
        fixture.controller.onAudioProofInvalidated = {
            proofInvalidations.append($0)
        }
        var snapshotPublicationCount = 0
        fixture.controller.onSnapshotChanged = { _ in
            snapshotPublicationCount += 1
        }

        fixture.events.onInterruptionBegan?(.default)
        let authorization = try XCTUnwrap(
            hostedAuthorizations.first
        )
        proofInvalidations.removeAll()
        snapshotPublicationCount = 0

        fixture.controller.failHostedCallRuntimePlayout(
            policyID: authorization.policyID,
            authorization: authorization,
            failureMessage: "First hosted failure.",
            diagnostic: "First diagnostic."
        )

        let manualDisabledCount =
            fixture.playback.prepareManualAudioDisabledCount
        XCTAssertGreaterThan(snapshotPublicationCount, 0)
        let publicationCountAfterFirstFailure = snapshotPublicationCount
        XCTAssertEqual(proofInvalidations, [true])

        fixture.controller.failHostedCallRuntimePlayout(
            policyID: authorization.policyID,
            authorization: authorization,
            failureMessage: "Second hosted failure.",
            diagnostic: "Second diagnostic."
        )

        XCTAssertEqual(snapshotPublicationCount, publicationCountAfterFirstFailure)
        XCTAssertEqual(proofInvalidations, [true])
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            manualDisabledCount
        )
        XCTAssertEqual(
            fixture.controller.snapshot.errorText,
            "First hosted failure."
        )
        XCTAssertEqual(
            fixture.controller.snapshot.diagnosticText,
            "First diagnostic."
        )
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)

        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 2,
            connectedNonEndedCallCount: 1
        )

        XCTAssertEqual(hostedAuthorizations.count, 1)
        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
    }

    func testHostedPolicyRevokesAtEveryLifecycleBoundary() throws {
        enum Boundary: CaseIterable {
            case routeLoss
            case unexpectedCategory
            case mediaServicesLoss
            case mediaServicesReset
            case transportUncertainty
            case stop
            case microphoneTopology
            case newInterruption
            case intersectionLoss
            case genericFailure
        }

        for boundary in Boundary.allCases {
            let fixture = makeFixture()
            fixture.controller.prepare(serverName: "Mac mini")
            fixture.controller.remoteAudioBecameAvailable(
                fixture.remoteAudio
            )
            fixture.controller.transportBecameHealthy()
            fixture.callActivity.setCallSnapshot(
                nonEndedCallCount: 1,
                connectedNonEndedCallCount: 1
            )
            var hostedAuthorization:
                WebRTCIOSHostedCallPlayoutAuthorization?
            fixture.controller
                .onHostedCallPlayoutRecoveryRequested = {
                    hostedAuthorization = $0
                }
            fixture.events.onInterruptionBegan?(.default)
            let authorization = try XCTUnwrap(
                hostedAuthorization
            )

            switch boundary {
            case .routeLoss:
                fixture.events.onRouteChanged?(
                    "Audio route changed: device unavailable"
                )
            case .unexpectedCategory:
                let armedChange = try XCTUnwrap(
                    fixture.events.lastArmedCategoryChange
                )
                fixture.events.onCategoryChanged?(
                    AudioSessionCategoryChange(
                        category:
                            AVAudioSession.Category.playback.rawValue,
                        mode:
                            AVAudioSession.Mode.default.rawValue,
                        categoryOptionsRawValue: 0,
                        operationID: armedChange.operationID
                    )
                )
            case .mediaServicesLoss:
                fixture.events.onMediaServicesLost?()
            case .mediaServicesReset:
                fixture.events.onMediaServicesReset?()
            case .transportUncertainty:
                fixture.controller.transportBecameUncertain()
            case .stop:
                fixture.controller.stop()
            case .microphoneTopology:
                fixture.controller
                    .beginMicrophoneTopologyTransition(
                        isEnabled: true
                    )
            case .newInterruption:
                fixture.events.onInterruptionBegan?(
                    .other(rawValue: 2)
                )
            case .intersectionLoss:
                fixture.callActivity.setCallSnapshot(
                    nonEndedCallCount: 1,
                    connectedNonEndedCallCount: 0
                )
            case .genericFailure:
                XCTAssertTrue(
                    authorization
                        .performRecoveryIfValidForTesting {}
                )
                fixture.controller
                    .updateHostedCallRuntimePlayout(
                        policyID: authorization.policyID,
                        isReady: false,
                        failureMessage:
                            "Hosted playout failed.",
                        diagnostic:
                            "Synthetic hosted failure."
                    )
            }

            XCTAssertFalse(
                authorization.isValid,
                "Boundary \(boundary) retained hosted ownership."
            )
            XCTAssertFalse(fixture.remoteAudio.isEnabled)
        }
    }
    #endif

    func testEveryGateOpeningRecoveryInvalidatesProofBeforeNativeRecover() {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        let recoverCountBeforeEvent = fixture.playback.recoverCount
        let staleAuthorization = WebRTCIOSPlayoutRecoveryAuthorization()
        fixture.controller.onAudioProofInvalidated = { requiresFreshRecovery in
            XCTAssertFalse(requiresFreshRecovery)
            staleAuthorization.revoke()
        }
        fixture.playback.onRecover = {
            XCTAssertFalse(
                staleAuthorization.isValid,
                "Proof authorization must be revoked before the native gate can reopen."
            )
        }

        fixture.events.onEngineConfigurationChanged?()

        XCTAssertEqual(fixture.playback.recoverCount, recoverCountBeforeEvent + 1)
        XCTAssertFalse(staleAuthorization.isValid)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
    }

    func testInitialPlaybackCategoryTransitionIsExplicitlyOwned() {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        var invalidationCount = 0
        var refreshCount = 0
        fixture.controller.onAudioProofInvalidated = { requiresFreshRecovery in
            if requiresFreshRecovery {
                invalidationCount += 1
            }
        }
        fixture.controller.onPlayoutProofRefreshRequested = {
            refreshCount += 1
        }

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.events.deliverArmedCategoryChange(
            AudioSessionCategoryChange(
                category: AVAudioSession.Category.playback.rawValue,
                mode: AVAudioSession.Mode.default.rawValue
            )
        )

        XCTAssertEqual(invalidationCount, 0)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(fixture.playback.prepareManualAudioDisabledCount, 0)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Waiting for Mac audio"
        )
    }

    func testExpectedMicrophoneCategoryTransitionsRefreshProofWithoutRevocation() {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        fixture.controller.updateRuntimePlayout(isReady: true)
        let authorization = WebRTCIOSMicrophoneAuthorization()
        var invalidationCount = 0
        var refreshCount = 0
        fixture.controller.onAudioProofInvalidated = { _ in
            invalidationCount += 1
            authorization.revoke()
        }
        fixture.controller.onPlayoutProofRefreshRequested = {
            refreshCount += 1
        }

        fixture.controller.beginMicrophoneTopologyTransition(isEnabled: true)
        fixture.events.deliverArmedCategoryChange(
            AudioSessionCategoryChange(
                category: AVAudioSession.Category.playAndRecord.rawValue,
                mode: AVAudioSession.Mode.default.rawValue,
                categoryOptionsRawValue:
                    Self.iPhoneMicrophoneCategoryOptionsRawValue
            )
        )

        XCTAssertEqual(invalidationCount, 0)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Starting playback"
        )

        fixture.controller.updateRuntimePlayout(isReady: true)
        fixture.controller.beginMicrophoneTopologyTransition(isEnabled: false)
        fixture.events.deliverArmedCategoryChange(
            AudioSessionCategoryChange(
                category: AVAudioSession.Category.playback.rawValue,
                mode: AVAudioSession.Mode.default.rawValue
            )
        )

        XCTAssertEqual(invalidationCount, 0)
        XCTAssertEqual(refreshCount, 2)
        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Starting playback"
        )
    }

    func testMicrophoneTopologyCategoryTransitionRejectsEmptyOptionsWithExactOperationID() throws {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        var invalidationCount = 0
        fixture.controller.onAudioProofInvalidated = {
            requiresFreshRecovery in
            XCTAssertTrue(requiresFreshRecovery)
            invalidationCount += 1
            authorization.revoke()
        }

        fixture.controller.beginMicrophoneTopologyTransition(
            isEnabled: true
        )
        let armedChange = try XCTUnwrap(
            fixture.events.lastArmedCategoryChange
        )
        XCTAssertEqual(
            armedChange.categoryOptionsRawValue,
            Self.iPhoneMicrophoneCategoryOptionsRawValue
        )

        fixture.events.onCategoryChanged?(
            AudioSessionCategoryChange(
                category:
                    AVAudioSession.Category.playAndRecord.rawValue,
                mode: AVAudioSession.Mode.default.rawValue,
                categoryOptionsRawValue: 0,
                operationID: armedChange.operationID
            )
        )

        XCTAssertEqual(invalidationCount, 1)
        XCTAssertFalse(authorization.isValid)
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            1
        )
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Playback unavailable"
        )
    }

    func testDuplicateExpectedCategoryTransitionFailsClosedAfterOneUse() {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        fixture.controller.updateRuntimePlayout(isReady: true)
        let authorization = WebRTCIOSMicrophoneAuthorization()
        var invalidationCount = 0
        var refreshCount = 0
        fixture.controller.onAudioProofInvalidated = { requiresFreshRecovery in
            XCTAssertTrue(requiresFreshRecovery)
            invalidationCount += 1
            authorization.revoke()
        }
        fixture.controller.onPlayoutProofRefreshRequested = {
            refreshCount += 1
        }
        let categoryChange = AudioSessionCategoryChange(
            category: AVAudioSession.Category.playAndRecord.rawValue,
            mode: AVAudioSession.Mode.default.rawValue,
            categoryOptionsRawValue:
                Self.iPhoneMicrophoneCategoryOptionsRawValue
        )

        fixture.controller.beginMicrophoneTopologyTransition(isEnabled: true)
        fixture.events.deliverArmedCategoryChange(categoryChange)

        XCTAssertEqual(invalidationCount, 0)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Starting playback"
        )

        fixture.controller.updateRuntimePlayout(isReady: true)
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Playing")

        fixture.events.onCategoryChanged?(categoryChange)

        XCTAssertEqual(invalidationCount, 1)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertFalse(authorization.isValid)
        XCTAssertEqual(fixture.playback.prepareManualAudioDisabledCount, 1)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Playback unavailable"
        )
    }

    func testTopologyCategoryOwnershipExpiresOnTerminalProofWithoutNotification() {
        let terminalFailureMessages: [String?] = [
            nil,
            "Runtime playout proof failed"
        ]

        for failureMessage in terminalFailureMessages {
            let fixture = makeFixture()
            fixture.playback.requiresRuntimePlayoutProof = true
            fixture.controller.prepare(serverName: "Mac mini")
            fixture.controller.remoteAudioBecameAvailable(
                fixture.remoteAudio
            )
            fixture.controller.transportBecameHealthy()
            fixture.controller.updateRuntimePlayout(isReady: true)
            let authorization =
                WebRTCIOSMicrophoneAuthorization()
            var invalidationCount = 0
            fixture.controller.onAudioProofInvalidated = {
                requiresFreshRecovery in
                guard requiresFreshRecovery else { return }
                invalidationCount += 1
                authorization.revoke()
            }
            let categoryChange = AudioSessionCategoryChange(
                category:
                    AVAudioSession.Category.playAndRecord.rawValue,
                mode: AVAudioSession.Mode.default.rawValue,
                categoryOptionsRawValue:
                    Self.iPhoneMicrophoneCategoryOptionsRawValue
            )

            fixture.controller.beginMicrophoneTopologyTransition(
                isEnabled: true
            )
            fixture.controller.updateRuntimePlayout(
                isReady: failureMessage == nil,
                failureMessage: failureMessage
            )

            XCTAssertTrue(authorization.isValid)

            fixture.events.deliverArmedCategoryChange(
                categoryChange
            )

            XCTAssertEqual(invalidationCount, 1)
            XCTAssertFalse(authorization.isValid)
            XCTAssertEqual(
                fixture.playback.prepareManualAudioDisabledCount,
                1
            )
            XCTAssertFalse(fixture.playback.nativeAudioEnabled)
            XCTAssertFalse(fixture.remoteAudio.isEnabled)
        }
    }

    func testRecoveryCategoryOwnershipIsOneShotAndExpiresWithoutNotification() {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        fixture.controller.updateRuntimePlayout(isReady: true)

        var activeAuthorization =
            WebRTCIOSMicrophoneAuthorization()
        var invalidationCount = 0
        fixture.controller.onAudioProofInvalidated = {
            requiresFreshRecovery in
            guard requiresFreshRecovery else { return }
            invalidationCount += 1
            activeAuthorization.revoke()
        }

        fixture.events.onCategoryChanged?(
            AudioSessionCategoryChange(
                category:
                    AVAudioSession.Category.playAndRecord.rawValue,
                mode: AVAudioSession.Mode.voiceChat.rawValue
            )
        )

        XCTAssertEqual(invalidationCount, 1)
        XCTAssertFalse(activeAuthorization.isValid)
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            1
        )
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        let firstRecoveryCount = fixture.playback.recoverCount
        let recoveredAuthorization =
            WebRTCIOSMicrophoneAuthorization()
        activeAuthorization = recoveredAuthorization
        fixture.controller.resumePlayback()

        XCTAssertEqual(
            fixture.playback.recoverCount,
            firstRecoveryCount + 1
        )
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Starting playback"
        )

        let restoredCategory = AudioSessionCategoryChange(
            category: AVAudioSession.Category.playback.rawValue,
            mode: AVAudioSession.Mode.default.rawValue
        )
        fixture.events.deliverArmedCategoryChange(
            restoredCategory
        )

        XCTAssertEqual(invalidationCount, 1)
        XCTAssertTrue(recoveredAuthorization.isValid)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)

        fixture.controller.updateRuntimePlayout(isReady: true)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Playing"
        )

        fixture.events.onCategoryChanged?(restoredCategory)

        XCTAssertEqual(invalidationCount, 2)
        XCTAssertFalse(recoveredAuthorization.isValid)
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            2
        )
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        let noNotificationAuthorization =
            WebRTCIOSMicrophoneAuthorization()
        activeAuthorization = noNotificationAuthorization
        fixture.controller.resumePlayback()
        fixture.controller.updateRuntimePlayout(isReady: true)

        XCTAssertTrue(noNotificationAuthorization.isValid)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)

        fixture.events.onCategoryChanged?(restoredCategory)

        XCTAssertEqual(invalidationCount, 3)
        XCTAssertFalse(noNotificationAuthorization.isValid)
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            3
        )
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
    }

    func testUnexpectedCategoryChangeFailsClosedAndRevokesMicrophone() {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        var invalidationCount = 0
        fixture.controller.onAudioProofInvalidated = { requiresFreshRecovery in
            XCTAssertTrue(requiresFreshRecovery)
            invalidationCount += 1
            authorization.revoke()
        }
        fixture.controller.beginMicrophoneTopologyTransition(isEnabled: true)

        fixture.events.onCategoryChanged?(
            AudioSessionCategoryChange(
                category: AVAudioSession.Category.playAndRecord.rawValue,
                mode: AVAudioSession.Mode.voiceChat.rawValue
            )
        )

        XCTAssertEqual(invalidationCount, 1)
        XCTAssertFalse(authorization.isValid)
        XCTAssertEqual(fixture.playback.prepareManualAudioDisabledCount, 1)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Playback unavailable"
        )
        XCTAssertTrue(
            fixture.controller.snapshot.diagnosticText?
                .contains("Unexpected AVAudioSession") == true
        )
    }

    func testBareCallKitTransitionKeepsBothPlayoutGatesOpen() {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        let recoverCountBeforeCall = fixture.playback.recoverCount

        fixture.callActivity.setNonEndedCallCount(1)

        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(fixture.playback.prepareManualAudioDisabledCount, 0)
        XCTAssertEqual(fixture.playback.recoverCount, recoverCountBeforeCall)
        XCTAssertTrue(fixture.controller.snapshot.isPlaying)
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Playing — iPhone call may reduce quality"
        )

        fixture.callActivity.setNonEndedCallCount(0)

        XCTAssertEqual(
            fixture.playback.recoverCount,
            recoverCountBeforeCall + 1
        )
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Playing")
        XCTAssertTrue(fixture.controller.microphoneActivationIsAllowed())
    }

    func testCallStartPreservesAuthenticatedScreenControlAndPeer() async throws {
        let fixture = makeFixture()
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        let peer = try makeAudioRacePeer()
        let screen = viewModel.debugInstallActiveScreenPresentationForTests(peer: peer)
        let screenStateBeforeCall = viewModel.debugScreenPresentationState
        let sessionStateBeforeCall = viewModel.stateText

        XCTAssertTrue(viewModel.canViewScreen)
        XCTAssertTrue(viewModel.remoteInputIsAvailable(for: screen.lease))
        XCTAssertTrue(screen.authorization.isValid)

        fixture.callActivity.setNonEndedCallCount(1)

        XCTAssertTrue(viewModel.isRemoteAudioPlaying)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(viewModel.stateText, sessionStateBeforeCall)
        XCTAssertTrue(viewModel.isPeerConnected)
        XCTAssertTrue(viewModel.isControlChannelReady)
        XCTAssertTrue(viewModel.canViewScreen)
        XCTAssertTrue(viewModel.remoteInputIsAvailable(for: screen.lease))
        XCTAssertTrue(screen.authorization.isValid)
        let screenStateAfterCall = viewModel.debugScreenPresentationState
        XCTAssertEqual(screenStateAfterCall.sessionGeneration, screenStateBeforeCall.sessionGeneration)
        XCTAssertEqual(screenStateAfterCall.currentLease, screenStateBeforeCall.currentLease)
        XCTAssertEqual(screenStateAfterCall.activeLease, screenStateBeforeCall.activeLease)
        XCTAssertEqual(screenStateAfterCall.isScreenVisible, screenStateBeforeCall.isScreenVisible)
        XCTAssertEqual(screenStateAfterCall.inputAvailable, screenStateBeforeCall.inputAvailable)
        XCTAssertEqual(screenStateAfterCall.remoteHideRequired, screenStateBeforeCall.remoteHideRequired)
        XCTAssertEqual(screenStateAfterCall.pendingRequestKey, screenStateBeforeCall.pendingRequestKey)
        XCTAssertEqual(
            screenStateAfterCall.displacedPendingRequestCount,
            screenStateBeforeCall.displacedPendingRequestCount
        )
        XCTAssertEqual(screenStateAfterCall.hasActiveSession, screenStateBeforeCall.hasActiveSession)
        XCTAssertTrue(viewModel.debugScreenPeerIs(peer))

        viewModel.disconnect()
        await peer.close()
    }

    func testCallEndWaitsForInterruptionAndExplicitResumePolicy() {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        let recoverCountBeforeCall = fixture.playback.recoverCount

        fixture.callActivity.setNonEndedCallCount(1)
        fixture.events.onInterruptionBegan?(.unavailable)
        fixture.callActivity.setNonEndedCallCount(0)

        XCTAssertEqual(fixture.playback.recoverCount, recoverCountBeforeCall)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)

        fixture.events.onInterruptionEnded?(false)
        fixture.controller.appBecameActive()

        XCTAssertTrue(fixture.controller.snapshot.requiresExplicitResume)
        XCTAssertEqual(fixture.playback.recoverCount, recoverCountBeforeCall)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.controller.resumePlayback()

        XCTAssertEqual(fixture.playback.recoverCount, recoverCountBeforeCall + 1)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
    }

    func testBareCallEndRotatesProofAndCompletesFreshNativeOutputOnlyRecovery()
        async throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        let peer = try makeAudioRacePeer()
        let postCallRecoveryConsumed = expectation(
            description: "bare-call native recovery consumed"
        )
        let isPostCallRecovery = AudioMainActorFlag()
        let didObservePostCallRecovery = AudioMainActorFlag()

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        fixture.controller.updateRuntimePlayout(isReady: true)
        viewModel.debugInstallIOSPlayoutPeerForRaceTests(peer)
        installProductionShapedIOSRecoveryHarness(
            on: viewModel,
            peer: peer
        ) {
            guard isPostCallRecovery.value,
                  !didObservePostCallRecovery.value else { return }
            didObservePostCallRecovery.value = true
            postCallRecoveryConsumed.fulfill()
        }
        await viewModel.debugRefreshIOSPlayoutOracleForTests(from: peer)
        let preCallGeneration = viewModel.debugAudioPolicyGeneration
        let preCallOracle = try XCTUnwrap(
            viewModel.audioPlayoutOracle
        )
        XCTAssertEqual(
            preCallOracle.audioPolicyGeneration,
            preCallGeneration
        )

        fixture.callActivity.setNonEndedCallCount(1)
        XCTAssertEqual(viewModel.debugAudioPolicyGeneration, preCallGeneration)
        XCTAssertEqual(viewModel.audioPlayoutOracle, preCallOracle)

        let recoverCountBeforeCallEnd = fixture.playback.recoverCount
        isPostCallRecovery.value = true
        fixture.callActivity.setNonEndedCallCount(0)

        XCTAssertNotEqual(
            viewModel.debugAudioPolicyGeneration,
            preCallGeneration
        )
        XCTAssertNil(viewModel.audioPlayoutOracle)
        XCTAssertEqual(
            fixture.playback.recoverCount,
            recoverCountBeforeCallEnd + 1
        )
        await fulfillment(of: [postCallRecoveryConsumed], timeout: 2)
        for _ in 0..<40 {
            if fixture.controller
                .postCallMicrophoneRecoveryMilestone == nil,
               fixture.controller.snapshot.isPlaying {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertTrue(didObservePostCallRecovery.value)
        XCTAssertNil(
            fixture.controller
                .postCallMicrophoneRecoveryMilestone
        )
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Playing")
        XCTAssertTrue(fixture.controller.snapshot.isPlaying)

        viewModel.disconnect()
        await peer.close()
    }

    func testInterruptionWithoutResumeHintStaysMutedUntilExplicitResume() {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        let recoverCountBeforeInterruption = fixture.playback.recoverCount
        XCTAssertTrue(fixture.remoteAudio.isEnabled)

        fixture.events.onInterruptionBegan?(.unavailable)

        XCTAssertEqual(fixture.controller.snapshot.stateText, "Interrupted")
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        XCTAssertFalse(fixture.background.publications.last?.isPlaying ?? true)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.events.onInterruptionEnded?(false)

        XCTAssertEqual(fixture.playback.recoverCount, recoverCountBeforeInterruption)
        XCTAssertTrue(fixture.controller.snapshot.requiresExplicitResume)
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Paused — resume audio")
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.controller.appBecameActive()
        XCTAssertTrue(fixture.controller.snapshot.requiresExplicitResume)
        XCTAssertEqual(fixture.playback.recoverCount, recoverCountBeforeInterruption)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        let recoverCountAfterForeground = fixture.playback.recoverCount

        // More healthy network events are not user consent to resume after iOS declined it.
        fixture.controller.transportBecameHealthy()
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.controller.resumePlayback()

        XCTAssertEqual(fixture.playback.recoverCount, recoverCountAfterForeground + 1)
        XCTAssertFalse(fixture.controller.snapshot.requiresExplicitResume)
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Playing")
        XCTAssertTrue(fixture.background.publications.last?.isPlaying ?? false)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
    }

    func testInterruptionWithResumeHintRecoversAndUnmutes() {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        let recoverCountBeforeInterruption = fixture.playback.recoverCount

        fixture.events.onInterruptionBegan?(.unavailable)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.events.onInterruptionEnded?(true)

        XCTAssertEqual(fixture.playback.recoverCount, recoverCountBeforeInterruption + 1)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertTrue(fixture.controller.snapshot.isPlaying)
    }

    func testReentrantActivationBoundariesCannotCommitStaleOuterSuccess() {
        for boundary in ReentrantAudioBoundary.allCases {
            let fixture = makeFixture()
            var recoveryRequestCount = 0
            fixture.controller.onPlaybackRecoveryRequested = {
                recoveryRequestCount += 1
            }
            fixture.playback.onActivate = {
                fixture.playback.onActivate = nil
                self.deliverReentrantAudioBoundary(
                    boundary,
                    to: fixture
                )
            }

            fixture.controller.prepare(serverName: "Mac mini")

            let performsNestedRecovery =
                boundary == .route
                    || boundary == .mediaReset
            XCTAssertEqual(
                fixture.playback.recoverCount,
                performsNestedRecovery ? 1 : 0,
                "Unexpected nested recovery count for \(boundary)."
            )
            XCTAssertEqual(
                recoveryRequestCount,
                performsNestedRecovery ? 1 : 0,
                "The stale activation issued a follow-on recovery for \(boundary)."
            )
            XCTAssertFalse(
                fixture.playback.nativeAudioEnabled,
                "The stale activation reopened the native gate for \(boundary)."
            )
            XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        }
    }

    func testReentrantRecoveryBoundariesCannotCommitStaleOuterSuccess() {
        for boundary in ReentrantAudioBoundary.allCases {
            let fixture = makeFixture()
            fixture.controller.prepare(serverName: "Mac mini")
            fixture.controller.remoteAudioBecameAvailable(
                fixture.remoteAudio
            )
            var recoveryRequestCount = 0
            fixture.controller.onPlaybackRecoveryRequested = {
                recoveryRequestCount += 1
            }
            fixture.playback.onRecover = {
                fixture.playback.onRecover = nil
                self.deliverReentrantAudioBoundary(
                    boundary,
                    to: fixture
                )
            }

            fixture.controller.transportBecameHealthy()

            let performsNestedRecovery =
                boundary == .route
                    || boundary == .mediaReset
            XCTAssertEqual(
                fixture.playback.recoverCount,
                performsNestedRecovery ? 2 : 1,
                "Unexpected recovery count for \(boundary)."
            )
            XCTAssertEqual(
                recoveryRequestCount,
                performsNestedRecovery ? 1 : 0,
                "The stale outer recovery requested native work for \(boundary)."
            )
            XCTAssertFalse(
                fixture.playback.nativeAudioEnabled,
                "The stale recovery reopened the native gate for \(boundary)."
            )
            XCTAssertFalse(
                fixture.remoteAudio.isEnabled,
                "The stale recovery reopened decoded audio for \(boundary)."
            )
            XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        }
    }

    func testInitiallyUnavailableAudioRecoversAfterInterruptionEnds() {
        let fixture = makeFixture()
        fixture.playback.activateError = TestAudioError.activation
        fixture.playback.recoverError = TestAudioError.recovery
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Playback unavailable")
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.events.onInterruptionBegan?(.unavailable)
        fixture.playback.recoverError = nil
        fixture.events.onInterruptionEnded?(true)

        XCTAssertEqual(fixture.controller.snapshot.stateText, "Playing")
        XCTAssertNil(fixture.controller.snapshot.errorText)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
    }

    func testTransportUncertaintyDoesNotDeactivateAudioSession() {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        XCTAssertTrue(fixture.remoteAudio.isEnabled)

        fixture.controller.transportBecameUncertain()

        XCTAssertEqual(fixture.controller.snapshot.stateText, "Reconnecting audio")
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        XCTAssertEqual(fixture.playback.deactivateCount, 0)
        XCTAssertEqual(fixture.events.stopCount, 0)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.controller.transportBecameHealthy()
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Playing")
        XCTAssertEqual(fixture.playback.deactivateCount, 0)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
    }

    func testDisableTopologyArmedAfterTransportUncertaintyRemainsConsumable() {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        fixture.controller.updateRuntimePlayout(isReady: true)
        let authorization =
            WebRTCIOSMicrophoneAuthorization()
        var invalidationCount = 0
        var refreshCount = 0
        fixture.controller.onAudioProofInvalidated = {
            requiresFreshRecovery in
            guard requiresFreshRecovery else { return }
            invalidationCount += 1
            authorization.revoke()
        }
        fixture.controller.onPlayoutProofRefreshRequested = {
            refreshCount += 1
        }

        fixture.controller.beginMicrophoneTopologyTransition(
            isEnabled: true
        )
        fixture.controller.transportBecameUncertain()
        fixture.controller.beginMicrophoneTopologyTransition(
            isEnabled: false
        )
        fixture.events.deliverArmedCategoryChange(
            AudioSessionCategoryChange(
                category: AVAudioSession.Category.playback.rawValue,
                mode: AVAudioSession.Mode.default.rawValue
            )
        )

        XCTAssertEqual(invalidationCount, 0)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Reconnecting audio"
        )
    }

    func testPeerTransportUncertaintyReusesPublicDisableTokenAndExactStamp() async throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        fixture.controller.updateRuntimePlayout(isReady: true)

        let peer = try makeAudioRacePeer()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        let ownerEpoch = UUID()
        let outputOnlyToken = try XCTUnwrap(
            fixture.controller
                .beginIPhoneMicrophoneOutputOnlyTransition(
                    ownerEpoch: ownerEpoch
                )
        )
        let nativePolicies = AudioLockedValues<Bool>()
        let retirementContexts =
            AudioLockedValues<WebRTCIOSMicrophoneRetirementContext>()
        let publicDisableResults = AudioLockedValues<Bool>()
        await peer.debugInstallIPhoneMicrophonePolicyApplier { isEnabled in
            nativePolicies.append(isEnabled)
            return true
        }
        await peer
            .debugInstallIPhoneMicrophonePreSuspensionHandlerHook {
                context in
                retirementContexts.append(context)
                let result = await peer.disableIPhoneMicrophone(
                    authorization: authorization,
                    outputOnlyToken: outputOnlyToken
                )
                publicDisableResults.append(result)
            }
        await peer.installIPhoneMicrophoneTransportSuspensionHandler {
            context in
            fixture.controller.transportBecameUncertain()
            guard let executingToken = context.executingToken,
                  fixture.controller
                    .reuseIPhoneMicrophoneOutputOnlyTransition(
                        executingToken,
                        ownerEpoch: ownerEpoch
                    ) else {
                return nil
            }
            return executingToken
        }
        await peer
            .debugInstallIPhoneMicrophoneAuthorizationForTransportUncertainty(
                authorization
            )

        await peer.debugSimulateICETransportUncertainty()

        let retirementContext = try XCTUnwrap(
            retirementContexts.values.first
        )
        let policySnapshot =
            await peer.debugIPhoneMicrophonePolicySnapshot
        let completionStamp = try XCTUnwrap(
            policySnapshot.completionStamp
        )
        let peerIsClosed = await peer.isClosedForTesting

        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(peerIsClosed)
        XCTAssertEqual(publicDisableResults.values, [true])
        XCTAssertEqual(nativePolicies.values, [false])
        XCTAssertTrue(
            retirementContext.executingToken.map {
                $0 === outputOnlyToken
            } == true
        )
        XCTAssertEqual(outputOnlyToken.state, .succeeded)
        XCTAssertEqual(
            completionStamp.sequence,
            retirementContext.startSequence + 1
        )
        XCTAssertEqual(
            completionStamp.kind,
            .outputOnlyDisable
        )
        XCTAssertEqual(
            completionStamp.origin,
            .publicRequest
        )
        XCTAssertEqual(
            completionStamp.retirementID,
            retirementContext.retirementID
        )
        XCTAssertEqual(
            completionStamp.retiredAuthorizationIdentity,
            ObjectIdentifier(authorization)
        )
        XCTAssertEqual(
            completionStamp.tokenID,
            outputOnlyToken.tokenID
        )
        XCTAssertTrue(completionStamp.nativeResult)
        XCTAssertEqual(
            policySnapshot.sequence,
            completionStamp.sequence
        )
        XCTAssertNil(policySnapshot.activeAuthorizationIdentity)
        XCTAssertFalse(policySnapshot.trackIsEnabled)
        XCTAssertFalse(policySnapshot.nativeTeardownPending)
        XCTAssertEqual(
            fixture.events.armedCategoryChangeOperationIDs.filter {
                $0 == outputOnlyToken.operationID
            }.count,
            1
        )

        fixture.events.deliverArmedCategoryChange(
            AudioSessionCategoryChange(
                category: AVAudioSession.Category.playback.rawValue,
                mode: AVAudioSession.Mode.default.rawValue
            )
        )
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            0
        )

        await peer.close()
    }

    func testTransportHandlerRevokesArmedPublicTokenAndUsesSoleReplacementWriter() async throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        fixture.controller.updateRuntimePlayout(isReady: true)

        let peer = try makeAudioRacePeer()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        let ownerEpoch = UUID()
        let publicToken = try XCTUnwrap(
            fixture.controller
                .beginIPhoneMicrophoneOutputOnlyTransition(
                    ownerEpoch: ownerEpoch
                )
        )
        let nativePolicies = AudioLockedValues<Bool>()
        let transportTokens =
            AudioLockedValues<WebRTCIOSOutputOnlyMicrophoneToken>()
        let retirementContexts =
            AudioLockedValues<WebRTCIOSMicrophoneRetirementContext>()
        let handlerEntered = expectation(
            description: "transport replacement token selected"
        )
        let handlerGate = AudioNonCooperativeGate<Void>()

        await peer.debugInstallIPhoneMicrophonePolicyApplier {
            isEnabled in
            nativePolicies.append(isEnabled)
            return true
        }
        await peer.installIPhoneMicrophoneTransportSuspensionHandler {
            context in
            retirementContexts.append(context)
            fixture.controller.transportBecameUncertain()
            guard let transportToken =
                    fixture.controller
                        .beginIPhoneMicrophoneOutputOnlyTransition(
                            ownerEpoch: ownerEpoch
                        ) else {
                handlerEntered.fulfill()
                return nil
            }
            let selected = context.selectToken(transportToken)
            guard selected === transportToken else {
                handlerEntered.fulfill()
                return nil
            }
            transportTokens.append(transportToken)
            handlerEntered.fulfill()
            _ = await handlerGate.wait()
            return transportToken
        }
        await peer
            .debugInstallIPhoneMicrophoneAuthorizationForTransportUncertainty(
                authorization
            )

        let suspensionTask = Task {
            await peer.debugSimulateICETransportUncertainty()
        }
        await fulfillment(of: [handlerEntered], timeout: 2)

        let beforeQueuedDisable =
            await peer.debugIPhoneMicrophonePolicySnapshot
        let queuedDisableResult =
            await peer.disableIPhoneMicrophone(
                authorization: authorization,
                outputOnlyToken: publicToken
            )
        let afterQueuedDisable =
            await peer.debugIPhoneMicrophonePolicySnapshot

        XCTAssertFalse(queuedDisableResult)
        XCTAssertEqual(publicToken.state, .revoked)
        XCTAssertEqual(beforeQueuedDisable, afterQueuedDisable)
        XCTAssertTrue(nativePolicies.values.isEmpty)

        await handlerGate.open(())
        await suspensionTask.value

        let transportToken = try XCTUnwrap(
            transportTokens.values.first
        )
        let retirementContext = try XCTUnwrap(
            retirementContexts.values.first
        )
        let policySnapshot =
            await peer.debugIPhoneMicrophonePolicySnapshot
        let completionStamp = try XCTUnwrap(
            policySnapshot.completionStamp
        )

        XCTAssertEqual(nativePolicies.values, [false])
        XCTAssertEqual(transportToken.state, .succeeded)
        XCTAssertTrue(
            retirementContext.executingToken.map {
                $0 === transportToken
            } == true
        )
        XCTAssertEqual(
            completionStamp.origin,
            .transportSuspension
        )
        XCTAssertEqual(
            completionStamp.retirementID,
            retirementContext.retirementID
        )
        XCTAssertEqual(
            completionStamp.tokenID,
            transportToken.tokenID
        )

        fixture.events.deliverArmedCategoryChange(
            AudioSessionCategoryChange(
                category: AVAudioSession.Category.playback.rawValue,
                mode: AVAudioSession.Mode.default.rawValue
            )
        )
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            0
        )

        await peer.close()
    }

    func testRevokedReturnedTransportTokenFallsBackToSoleTerminalCleanupWriter() async throws {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        let peer = try makeAudioRacePeer()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        let ownerEpoch = UUID()
        let nativePolicies = AudioLockedValues<Bool>()
        let returnedTokens =
            AudioLockedValues<WebRTCIOSOutputOnlyMicrophoneToken>()
        let retirementContexts =
            AudioLockedValues<WebRTCIOSMicrophoneRetirementContext>()

        await peer.debugInstallIPhoneMicrophonePolicyApplier {
            isEnabled in
            nativePolicies.append(isEnabled)
            return true
        }
        await peer.installIPhoneMicrophoneTransportSuspensionHandler {
            context in
            retirementContexts.append(context)
            fixture.controller.transportBecameUncertain()
            guard let token =
                    fixture.controller
                        .beginIPhoneMicrophoneOutputOnlyTransition(
                            ownerEpoch: ownerEpoch
                        ) else {
                return nil
            }
            guard context.selectToken(token) === token else {
                return nil
            }
            returnedTokens.append(token)
            return token
        }
        await peer
            .debugInstallIPhoneMicrophonePostSuspensionHandlerHook {
                _, token in
                guard let token else { return }
                fixture.controller
                    .revokeIPhoneMicrophoneOutputOnlyTransition(
                        token
                    )
            }
        await peer
            .debugInstallIPhoneMicrophoneAuthorizationForTransportUncertainty(
                authorization
            )

        await peer.debugSimulateICETransportUncertainty()

        let token = try XCTUnwrap(returnedTokens.values.first)
        let context = try XCTUnwrap(
            retirementContexts.values.first
        )
        let policySnapshot =
            await peer.debugIPhoneMicrophonePolicySnapshot
        let completionStamp = try XCTUnwrap(
            policySnapshot.completionStamp
        )
        let peerIsClosed = await peer.isClosedForTesting

        XCTAssertEqual(token.state, .revoked)
        XCTAssertEqual(nativePolicies.values, [false])
        XCTAssertEqual(
            policySnapshot.sequence,
            context.startSequence + 1
        )
        XCTAssertEqual(
            completionStamp.kind,
            .outputOnlyDisable
        )
        XCTAssertEqual(
            completionStamp.origin,
            .terminalCleanup
        )
        XCTAssertNotNil(completionStamp.retirementID)
        XCTAssertNotEqual(
            completionStamp.retirementID,
            context.retirementID
        )
        XCTAssertEqual(
            completionStamp.retiredAuthorizationIdentity,
            ObjectIdentifier(authorization)
        )
        XCTAssertNotNil(completionStamp.tokenID)
        XCTAssertNotEqual(
            completionStamp.tokenID,
            token.tokenID
        )
        XCTAssertTrue(completionStamp.nativeResult)
        XCTAssertNil(policySnapshot.activeAuthorizationIdentity)
        XCTAssertFalse(policySnapshot.trackIsEnabled)
        XCTAssertFalse(policySnapshot.nativeTeardownPending)
        XCTAssertNil(
            policySnapshot.nativeTeardownAuthorizationIdentity
        )
        XCTAssertTrue(peerIsClosed)
    }

    func testPeerCloseReusesCompatibleRetirementTokenWithoutAwaitingHandler() async throws {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        let peer = try makeAudioRacePeer()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        let outputOnlyToken = try XCTUnwrap(
            fixture.controller
                .beginIPhoneMicrophoneOutputOnlyTransition(
                    ownerEpoch: UUID()
                )
        )
        let nativePolicies = AudioLockedValues<Bool>()
        let observedTokenStates =
            AudioLockedValues<
                WebRTCIOSOutputOnlyMicrophoneTokenState
            >()
        let retirementContexts =
            AudioLockedValues<
                WebRTCIOSMicrophoneRetirementContext
            >()
        let handlerEntered = expectation(
            description: "retirement handler remains suspended"
        )
        let handlerGate = AudioNonCooperativeGate<Void>()

        await peer.debugInstallIPhoneMicrophonePolicyApplier {
            isEnabled in
            nativePolicies.append(isEnabled)
            observedTokenStates.append(outputOnlyToken.state)
            return true
        }
        await peer.installIPhoneMicrophoneTransportSuspensionHandler {
            context in
            retirementContexts.append(context)
            guard context.selectToken(outputOnlyToken)
                    === outputOnlyToken else {
                handlerEntered.fulfill()
                return nil
            }
            handlerEntered.fulfill()
            _ = await handlerGate.wait()
            return outputOnlyToken
        }
        await peer
            .debugInstallIPhoneMicrophoneAuthorizationForTransportUncertainty(
                authorization
            )

        let suspensionTask = Task {
            await peer.debugSimulateICETransportUncertainty()
        }
        await fulfillment(of: [handlerEntered], timeout: 2)
        await handlerGate.waitUntilBlocked()

        await peer.close()

        let closeSnapshot =
            await peer.debugIPhoneMicrophonePolicySnapshot
        let peerIsClosed = await peer.isClosedForTesting

        await handlerGate.open(())
        await suspensionTask.value

        let retirementContext = try XCTUnwrap(
            retirementContexts.values.first
        )
        let completionStamp = try XCTUnwrap(
            closeSnapshot.completionStamp
        )

        XCTAssertFalse(authorization.isValid)
        XCTAssertEqual(nativePolicies.values, [false])
        XCTAssertEqual(observedTokenStates.values, [.executing])
        XCTAssertEqual(outputOnlyToken.state, .succeeded)
        XCTAssertEqual(
            completionStamp.sequence,
            retirementContext.startSequence + 1
        )
        XCTAssertEqual(
            completionStamp.kind,
            .outputOnlyDisable
        )
        XCTAssertEqual(
            completionStamp.origin,
            .terminalCleanup
        )
        XCTAssertEqual(
            completionStamp.retirementID,
            retirementContext.retirementID
        )
        XCTAssertEqual(
            completionStamp.retiredAuthorizationIdentity,
            ObjectIdentifier(authorization)
        )
        XCTAssertEqual(
            completionStamp.tokenID,
            outputOnlyToken.tokenID
        )
        XCTAssertTrue(completionStamp.nativeResult)
        XCTAssertEqual(
            closeSnapshot.sequence,
            completionStamp.sequence
        )
        XCTAssertNil(closeSnapshot.activeAuthorizationIdentity)
        XCTAssertFalse(closeSnapshot.trackIsEnabled)
        XCTAssertFalse(closeSnapshot.nativeTeardownPending)
        XCTAssertNil(
            closeSnapshot.nativeTeardownAuthorizationIdentity
        )
        XCTAssertNil(closeSnapshot.retirementID)
        XCTAssertTrue(peerIsClosed)
    }

    func testPeerCloseWithoutRetirementContextSynchronouslyAppliesTerminalOutputOnlyPolicy() async throws {
        let peer = try makeAudioRacePeer()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        let nativePolicies = AudioLockedValues<Bool>()

        await peer.debugInstallIPhoneMicrophonePolicyApplier {
            isEnabled in
            nativePolicies.append(isEnabled)
            return true
        }
        try await peer.debugEnableIPhoneMicrophoneIgnoringTransportForTests(
            authorization
        )

        let beforeClose =
            await peer.debugIPhoneMicrophonePolicySnapshot
        XCTAssertEqual(
            beforeClose.activeAuthorizationIdentity,
            ObjectIdentifier(authorization)
        )
        XCTAssertTrue(beforeClose.trackIsEnabled)
        XCTAssertFalse(beforeClose.nativeTeardownPending)
        XCTAssertNil(beforeClose.retirementID)
        XCTAssertEqual(
            beforeClose.completionStamp?.kind,
            .enable
        )
        XCTAssertEqual(nativePolicies.values, [true])

        await peer.close()

        let policySnapshot =
            await peer.debugIPhoneMicrophonePolicySnapshot
        let completionStamp = try XCTUnwrap(
            policySnapshot.completionStamp
        )
        let peerIsClosed = await peer.isClosedForTesting

        XCTAssertFalse(authorization.isValid)
        XCTAssertEqual(nativePolicies.values, [true, false])
        XCTAssertEqual(
            nativePolicies.values.filter { !$0 }.count,
            1
        )
        XCTAssertEqual(
            completionStamp.sequence,
            beforeClose.sequence + 1
        )
        XCTAssertEqual(
            completionStamp.kind,
            .outputOnlyDisable
        )
        XCTAssertEqual(
            completionStamp.origin,
            .terminalCleanup
        )
        XCTAssertNotNil(completionStamp.retirementID)
        XCTAssertEqual(
            completionStamp.retiredAuthorizationIdentity,
            ObjectIdentifier(authorization)
        )
        XCTAssertNotNil(completionStamp.tokenID)
        XCTAssertTrue(completionStamp.nativeResult)
        XCTAssertEqual(
            policySnapshot.sequence,
            completionStamp.sequence
        )
        XCTAssertNil(policySnapshot.activeAuthorizationIdentity)
        XCTAssertFalse(policySnapshot.trackIsEnabled)
        XCTAssertFalse(policySnapshot.nativeTeardownPending)
        XCTAssertNil(
            policySnapshot.nativeTeardownAuthorizationIdentity
        )
        XCTAssertNil(policySnapshot.retirementID)
        XCTAssertTrue(peerIsClosed)
    }

    func testPeerCloseTerminalMicrophoneFailureRetainsExactPendingIdentity() async throws {
        let peer = try makeAudioRacePeer()
        let authorization = WebRTCIOSMicrophoneAuthorization()

        await peer.debugInstallIPhoneMicrophonePolicyApplier { _ in
            true
        }
        try await peer.debugEnableIPhoneMicrophoneIgnoringTransportForTests(
            authorization
        )

        let nativePolicies = AudioLockedValues<Bool>()
        await peer.debugInstallIPhoneMicrophonePolicyApplier {
            isEnabled in
            nativePolicies.append(isEnabled)
            return false
        }
        let beforeClose =
            await peer.debugIPhoneMicrophonePolicySnapshot

        await peer.close()

        let policySnapshot =
            await peer.debugIPhoneMicrophonePolicySnapshot
        let completionStamp = try XCTUnwrap(
            policySnapshot.completionStamp
        )
        let peerIsClosed = await peer.isClosedForTesting

        XCTAssertFalse(authorization.isValid)
        XCTAssertEqual(nativePolicies.values, [false])
        XCTAssertEqual(
            completionStamp.sequence,
            beforeClose.sequence + 1
        )
        XCTAssertEqual(
            completionStamp.kind,
            .outputOnlyDisable
        )
        XCTAssertEqual(
            completionStamp.origin,
            .terminalCleanup
        )
        XCTAssertNotNil(completionStamp.retirementID)
        XCTAssertEqual(
            completionStamp.retiredAuthorizationIdentity,
            ObjectIdentifier(authorization)
        )
        XCTAssertNotNil(completionStamp.tokenID)
        XCTAssertFalse(completionStamp.nativeResult)
        XCTAssertEqual(
            policySnapshot.sequence,
            completionStamp.sequence
        )
        XCTAssertNil(policySnapshot.activeAuthorizationIdentity)
        XCTAssertFalse(policySnapshot.trackIsEnabled)
        XCTAssertTrue(policySnapshot.nativeTeardownPending)
        XCTAssertEqual(
            policySnapshot.nativeTeardownAuthorizationIdentity,
            ObjectIdentifier(authorization)
        )
        XCTAssertNil(policySnapshot.retirementID)
        XCTAssertTrue(peerIsClosed)
    }

    func testPeerCloseFailureReentrantEventLossAttemptsTerminalMicrophonePolicyOnlyOnce() async throws {
        let peer = try makeAudioRacePeer()
        let microphoneAuthorization =
            WebRTCIOSMicrophoneAuthorization()
        let nativePolicies = AudioLockedValues<Bool>()

        await peer.debugInstallIPhoneMicrophonePolicyApplier {
            isEnabled in
            nativePolicies.append(isEnabled)
            return isEnabled
        }
        try await peer
            .debugEnableIPhoneMicrophoneIgnoringTransportForTests(
                microphoneAuthorization
            )

        let enableSnapshot =
            await peer.debugIPhoneMicrophonePolicySnapshot
        let enableStamp = try XCTUnwrap(
            enableSnapshot.completionStamp
        )

        XCTAssertEqual(nativePolicies.values, [true])
        XCTAssertEqual(enableStamp.kind, .enable)
        XCTAssertEqual(enableStamp.origin, .publicRequest)
        XCTAssertTrue(enableStamp.nativeResult)
        XCTAssertEqual(
            enableSnapshot.activeAuthorizationIdentity,
            ObjectIdentifier(microphoneAuthorization)
        )
        XCTAssertTrue(enableSnapshot.trackIsEnabled)
        XCTAssertFalse(enableSnapshot.nativeTeardownPending)

        let inputAuthorization = WebRTCInputAuthorization()
        let inputCapability = WebRTCInputCapability(
            inputSessionID: UUID(),
            screenRequestID: 1,
            maxMessageBytes: WebRTCInputCapability.maximumMessageBytes,
            supportsPrimaryDrag: true
        )
        try await peer.installViewerInputSessionForTesting(
            capability: inputCapability,
            authorization: inputAuthorization
        )

        // With no stream consumer, these writes leave exactly two slots. `close()` fills them
        // before input invalidation produces the synchronous dropped yield that re-enters cleanup.
        for _ in 0..<254 {
            await peer.emitPublicEventForTesting()
        }

        await peer.close()

        let policySnapshot =
            await peer.debugIPhoneMicrophonePolicySnapshot
        let completionStamp = try XCTUnwrap(
            policySnapshot.completionStamp
        )
        let peerIsClosed = await peer.isClosedForTesting
        let remainingInputCapability =
            await peer.currentInputCapability()

        XCTAssertFalse(microphoneAuthorization.isValid)
        XCTAssertEqual(nativePolicies.values, [true, false])
        XCTAssertEqual(
            nativePolicies.values.filter { !$0 }.count,
            1
        )
        XCTAssertEqual(
            policySnapshot.sequence,
            enableSnapshot.sequence + 1,
            "Synchronous event-loss reentry must preserve the first failed terminal attempt."
        )
        XCTAssertEqual(
            completionStamp.sequence,
            enableSnapshot.sequence + 1
        )
        XCTAssertEqual(
            policySnapshot.sequence,
            completionStamp.sequence
        )
        XCTAssertEqual(
            completionStamp.kind,
            .outputOnlyDisable
        )
        XCTAssertEqual(
            completionStamp.origin,
            .terminalCleanup
        )
        XCTAssertNotNil(completionStamp.retirementID)
        XCTAssertEqual(
            completionStamp.retiredAuthorizationIdentity,
            ObjectIdentifier(microphoneAuthorization)
        )
        XCTAssertNotNil(completionStamp.tokenID)
        XCTAssertFalse(completionStamp.nativeResult)
        XCTAssertNil(policySnapshot.activeAuthorizationIdentity)
        XCTAssertFalse(policySnapshot.trackIsEnabled)
        XCTAssertTrue(policySnapshot.nativeTeardownPending)
        XCTAssertEqual(
            policySnapshot.nativeTeardownAuthorizationIdentity,
            ObjectIdentifier(microphoneAuthorization)
        )
        XCTAssertNil(policySnapshot.retirementID)
        XCTAssertFalse(inputAuthorization.isValid)
        XCTAssertNil(remainingInputCapability)
        XCTAssertTrue(peerIsClosed)
    }

    func testSynchronousCategoryCallbackObservesExecutingOutputOnlyToken() throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        fixture.controller.prepare(serverName: "Mac mini")
        let token = try XCTUnwrap(
            fixture.controller
                .beginIPhoneMicrophoneOutputOnlyTransition(
                    ownerEpoch: UUID()
                )
        )
        var observedState:
            WebRTCIOSOutputOnlyMicrophoneTokenState?

        let nativeResult = token.performOnce {
            observedState = token.state
            fixture.events.deliverArmedCategoryChange(
                AudioSessionCategoryChange(
                    category:
                        AVAudioSession.Category.playback.rawValue,
                    mode: AVAudioSession.Mode.default.rawValue
                )
            )
            return true
        }

        XCTAssertTrue(nativeResult)
        XCTAssertEqual(observedState, .executing)
        XCTAssertEqual(token.state, .succeeded)
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            0
        )
        XCTAssertTrue(
            fixture.events.armedCategoryChangeOperationIDs.filter {
                $0 == token.operationID
            }.count == 1
        )
    }

    func testCategoryNotificationAndCallEndInsideOutputOnlyWriteDeferRecoveryUntilTerminalReturn()
        throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        let token = try XCTUnwrap(
            fixture.controller
                .beginIPhoneMicrophoneOutputOnlyTransition(
                    ownerEpoch: UUID()
                )
        )
        let recoveryCountBeforeWrite = fixture.playback.recoverCount

        XCTAssertTrue(
            token.performOnce {
                fixture.events.deliverArmedCategoryChange(
                    AudioSessionCategoryChange(
                        category:
                            AVAudioSession.Category.playback.rawValue,
                        mode: AVAudioSession.Mode.default.rawValue
                    )
                )
                fixture.callActivity.setCallSnapshot(
                    nonEndedCallCount: 1,
                    connectedNonEndedCallCount: 1
                )
                fixture.callActivity.setCallSnapshot(
                    nonEndedCallCount: 0,
                    connectedNonEndedCallCount: 0
                )

                XCTAssertEqual(token.state, .executing)
                XCTAssertNotNil(
                    fixture.controller
                        .postCallMicrophoneRecoveryMilestone
                )
                XCTAssertEqual(
                    fixture.playback.recoverCount,
                    recoveryCountBeforeWrite,
                    "Call-end recovery overlapped the still-executing native write."
                )
                return true
            }
        )

        XCTAssertEqual(token.state, .succeeded)
        XCTAssertEqual(
            fixture.playback.recoverCount,
            recoveryCountBeforeWrite
        )
        fixture.controller
            .iPhoneMicrophoneOutputOnlyTransitionDidComplete(token)
        XCTAssertEqual(
            fixture.playback.recoverCount,
            recoveryCountBeforeWrite + 1
        )
    }

    func testPostCallRecoveryRetriesWhenExecutingOutputOnlyTransitionCompletes()
        async throws {
        for categoryNotificationArrived in [false, true] {
            let fixture = makeFixture()
            fixture.playback.requiresRuntimePlayoutProof = true
            fixture.controller.prepare(serverName: "Mac mini")
            fixture.controller.remoteAudioBecameAvailable(
                fixture.remoteAudio
            )
            fixture.controller.transportBecameHealthy()
            let token = try XCTUnwrap(
                fixture.controller
                    .beginIPhoneMicrophoneOutputOnlyTransition(
                        ownerEpoch: UUID()
                    )
            )
            let releaseNativeWrite = DispatchSemaphore(value: 0)
            let nativeWriteEntered = expectation(
                description: "output-only token entered native claim"
            )
            let nativeWriteEnteredBox = AudioTestExpectationBox(
                nativeWriteEntered
            )
            let nativeWrite = Task.detached {
                token.performOnce {
                    nativeWriteEnteredBox.fulfill()
                    releaseNativeWrite.wait()
                    return true
                }
            }

            await fulfillment(of: [nativeWriteEntered], timeout: 2)
            guard token.state == .executing else {
                releaseNativeWrite.signal()
                _ = await nativeWrite.value
                XCTFail("The output-only token never entered its native claim.")
                continue
            }

            let recoverCountBeforeCall = fixture.playback.recoverCount
            fixture.callActivity.setCallSnapshot(
                nonEndedCallCount: 1,
                connectedNonEndedCallCount: 1
            )
            fixture.callActivity.setCallSnapshot(
                nonEndedCallCount: 0,
                connectedNonEndedCallCount: 0
            )
            let milestone = try XCTUnwrap(
                fixture.controller
                    .postCallMicrophoneRecoveryMilestone
            )
            XCTAssertEqual(
                fixture.playback.recoverCount,
                recoverCountBeforeCall,
                "Call-end recovery must wait while the exact native token is executing."
            )

            releaseNativeWrite.signal()
            let nativeWriteSucceeded = await nativeWrite.value
            XCTAssertTrue(nativeWriteSucceeded)
            XCTAssertEqual(token.state, .succeeded)

            if categoryNotificationArrived {
                fixture.events.deliverArmedCategoryChange(
                    AudioSessionCategoryChange(
                        category:
                            AVAudioSession.Category.playback.rawValue,
                        mode: AVAudioSession.Mode.default.rawValue,
                        categoryOptionsRawValue: 0
                    )
                )
            }

            var recoveryRequestCount = 0
            fixture.controller.onPlaybackRecoveryRequested = {
                recoveryRequestCount += 1
            }
            fixture.controller
                .iPhoneMicrophoneOutputOnlyTransitionDidComplete(
                    token
                )

            XCTAssertEqual(
                fixture.playback.recoverCount,
                recoverCountBeforeCall + 1
            )
            XCTAssertEqual(recoveryRequestCount, 1)
            let recoveryChange = try XCTUnwrap(
                fixture.events.lastArmedCategoryChange
            )
            XCTAssertEqual(
                recoveryChange.category,
                AVAudioSession.Category.playback.rawValue
            )
            XCTAssertEqual(recoveryChange.categoryOptionsRawValue, 0)
            XCTAssertTrue(
                fixture.controller
                    .completePostCallMicrophoneRecovery(milestone)
            )
            XCTAssertNil(
                fixture.controller
                    .postCallMicrophoneRecoveryMilestone
            )
        }
    }

    func testOutputOnlyCategoryCallbacksFailClosedUnlessExactTokenIsExecutingOrSucceeded() throws {
        enum FailureVariant: CaseIterable {
            case armed
            case wrongID
            case wrongCategory
            case wrongMode
            case wrongOptions
            case revoked
            case failed
        }

        for variant in FailureVariant.allCases {
            let fixture = makeFixture()
            fixture.controller.prepare(serverName: "Mac mini")
            let token = try XCTUnwrap(
                fixture.controller
                    .beginIPhoneMicrophoneOutputOnlyTransition(
                        ownerEpoch: UUID()
                    )
            )

            switch variant {
            case .revoked:
                XCTAssertTrue(token.revoke())
            case .failed:
                XCTAssertFalse(token.performOnce { false })
                XCTAssertEqual(token.state, .failed)
            case .armed, .wrongID, .wrongCategory, .wrongMode,
                    .wrongOptions:
                break
            }

            let operationID: UUID? =
                variant == .wrongID ? UUID() : token.operationID
            let category =
                variant == .wrongCategory
                    ? AVAudioSession.Category.playAndRecord.rawValue
                    : AVAudioSession.Category.playback.rawValue
            let mode =
                variant == .wrongMode
                    ? AVAudioSession.Mode.voiceChat.rawValue
                    : AVAudioSession.Mode.default.rawValue
            let categoryOptionsRawValue =
                variant == .wrongOptions
                    ? Self.iPhoneMicrophoneCategoryOptionsRawValue
                    : 0

            fixture.events.onCategoryChanged?(
                AudioSessionCategoryChange(
                    category: category,
                    mode: mode,
                    categoryOptionsRawValue:
                        categoryOptionsRawValue,
                    operationID: operationID
                )
            )

            XCTAssertEqual(
                fixture.playback.prepareManualAudioDisabledCount,
                1,
                "Variant \(variant) did not fail closed."
            )
            XCTAssertFalse(
                fixture.playback.nativeAudioEnabled,
                "Variant \(variant) left the native gate open."
            )
            XCTAssertEqual(
                fixture.controller.snapshot.stateText,
                "Playback unavailable"
            )
        }
    }

    func testInterruptionDefersExecutingOutputOnlyMarkerUntilTerminalCompletion() throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        fixture.controller.updateRuntimePlayout(isReady: true)
        fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )
        var hostedAuthorization:
            WebRTCIOSHostedCallPlayoutAuthorization?
        fixture.controller.onHostedCallPlayoutRecoveryRequested = {
            hostedAuthorization = $0
        }
        let ownerEpoch = UUID()
        let token = try XCTUnwrap(
            fixture.controller
                .beginIPhoneMicrophoneOutputOnlyTransition(
                    ownerEpoch: ownerEpoch
                )
        )

        let nativeOperationSucceeded = token.performOnce {
            XCTAssertEqual(token.state, .executing)
            fixture.events.onInterruptionBegan?(.default)
            XCTAssertNil(
                hostedAuthorization,
                "Hosted recovery must not overlap the executing output-only write."
            )
            return true
        }

        XCTAssertTrue(nativeOperationSucceeded)
        XCTAssertEqual(token.state, .succeeded)
        fixture.controller
            .iPhoneMicrophoneOutputOnlyTransitionDidComplete(token)
        let authorization = try XCTUnwrap(
            hostedAuthorization
        )
        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(
            fixture.controller
                .reuseIPhoneMicrophoneOutputOnlyTransition(
                    token,
                    ownerEpoch: ownerEpoch
                ),
            "The terminally retired token remained reusable in the hosted interruption epoch."
        )

        // A late notification carrying the retired operation must not authorize or complete the
        // hosted operation that replaced it.
        fixture.events.onCategoryChanged?(
            AudioSessionCategoryChange(
                category: AVAudioSession.Category.playback.rawValue,
                mode: AVAudioSession.Mode.default.rawValue,
                categoryOptionsRawValue: 0,
                operationID: token.operationID
            )
        )

        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
    }

    func testInterruptionBeforeCallKitRetiresCompletedOutputOnlyMarkerWithoutNotification() throws {
        for nativeResult in [true, false] {
            let fixture = makeFixture()
            fixture.playback.requiresRuntimePlayoutProof = true
            fixture.controller.prepare(serverName: "Mac mini")
            fixture.controller.remoteAudioBecameAvailable(
                fixture.remoteAudio
            )
            fixture.controller.transportBecameHealthy()
            fixture.controller.updateRuntimePlayout(
                isReady: true
            )
            let ownerEpoch = UUID()
            let token = try XCTUnwrap(
                fixture.controller
                    .beginIPhoneMicrophoneOutputOnlyTransition(
                        ownerEpoch: ownerEpoch
                    )
            )
            XCTAssertEqual(
                token.performOnce { nativeResult },
                nativeResult
            )
            XCTAssertEqual(
                token.state,
                nativeResult ? .succeeded : .failed
            )
            var hostedAuthorization:
                WebRTCIOSHostedCallPlayoutAuthorization?
            fixture.controller
                .onHostedCallPlayoutRecoveryRequested = {
                    hostedAuthorization = $0
                }

            // No category notification is delivered for the completed output-only operation.
            fixture.events.onInterruptionBegan?(.default)
            XCTAssertNil(hostedAuthorization)

            fixture.callActivity.setCallSnapshot(
                nonEndedCallCount: 1,
                connectedNonEndedCallCount: 1
            )

            let authorization = try XCTUnwrap(
                hostedAuthorization
            )
            XCTAssertTrue(authorization.isValid)
            XCTAssertEqual(
                fixture.events.lastArmedCategoryChange?
                    .operationID,
                authorization.policyID
            )
            XCTAssertFalse(
                fixture.controller
                    .reuseIPhoneMicrophoneOutputOnlyTransition(
                        token,
                        ownerEpoch: ownerEpoch
                    )
            )
            XCTAssertFalse(fixture.remoteAudio.isEnabled)
        }
    }

    func testReplacementEnableDuringSuspensionIsNeverOverwrittenAndABADisableStampIsRejected() async throws {
        let firstFixture = makeFixture()
        firstFixture.controller.prepare(serverName: "Mac mini")
        let firstPeer = try makeAudioRacePeer()
        let firstAuthorization =
            WebRTCIOSMicrophoneAuthorization()
        let firstReplacement =
            WebRTCIOSMicrophoneAuthorization()
        let firstOwnerEpoch = UUID()
        let firstNativePolicies = AudioLockedValues<Bool>()
        let firstTransportTokens =
            AudioLockedValues<WebRTCIOSOutputOnlyMicrophoneToken>()

        await firstPeer.debugInstallIPhoneMicrophonePolicyApplier {
            isEnabled in
            firstNativePolicies.append(isEnabled)
            return true
        }
        await firstPeer
            .installIPhoneMicrophoneTransportSuspensionHandler {
                context in
                firstFixture.controller.transportBecameUncertain()
                guard let token =
                        firstFixture.controller
                            .beginIPhoneMicrophoneOutputOnlyTransition(
                                ownerEpoch: firstOwnerEpoch
                            ) else {
                    return nil
                }
                guard context.selectToken(token) === token else {
                    return nil
                }
                firstTransportTokens.append(token)
                return token
            }
        await firstPeer
            .debugInstallIPhoneMicrophonePostSuspensionHandlerHook {
                _, _ in
                try? await firstPeer
                    .debugEnableIPhoneMicrophoneIgnoringTransportForTests(
                        firstReplacement
                    )
            }
        await firstPeer
            .debugInstallIPhoneMicrophoneAuthorizationForTransportUncertainty(
                firstAuthorization
            )

        await firstPeer.debugSimulateICETransportUncertainty()

        let firstSnapshot =
            await firstPeer.debugIPhoneMicrophonePolicySnapshot
        let firstStamp = try XCTUnwrap(
            firstSnapshot.completionStamp
        )
        let firstPeerIsClosed =
            await firstPeer.isClosedForTesting
        let firstTransportToken = try XCTUnwrap(
            firstTransportTokens.values.first
        )

        XCTAssertEqual(firstNativePolicies.values, [true])
        XCTAssertEqual(firstStamp.kind, .enable)
        XCTAssertTrue(firstStamp.nativeResult)
        XCTAssertEqual(
            firstSnapshot.activeAuthorizationIdentity,
            ObjectIdentifier(firstReplacement)
        )
        XCTAssertTrue(firstSnapshot.trackIsEnabled)
        XCTAssertFalse(firstSnapshot.nativeTeardownPending)
        XCTAssertTrue(firstReplacement.isValid)
        XCTAssertEqual(firstTransportToken.state, .revoked)
        XCTAssertFalse(firstPeerIsClosed)

        let secondFixture = makeFixture()
        secondFixture.controller.prepare(serverName: "Mac mini")
        let secondPeer = try makeAudioRacePeer()
        let secondAuthorization =
            WebRTCIOSMicrophoneAuthorization()
        let secondReplacement =
            WebRTCIOSMicrophoneAuthorization()
        let secondOwnerEpoch = UUID()
        let secondNativePolicies = AudioLockedValues<Bool>()
        let secondRetirementContexts =
            AudioLockedValues<WebRTCIOSMicrophoneRetirementContext>()
        let secondTransportTokens =
            AudioLockedValues<WebRTCIOSOutputOnlyMicrophoneToken>()
        let unrelatedDisableTokens =
            AudioLockedValues<WebRTCIOSOutputOnlyMicrophoneToken>()
        let unrelatedDisableResults = AudioLockedValues<Bool>()

        await secondPeer.debugInstallIPhoneMicrophonePolicyApplier {
            isEnabled in
            secondNativePolicies.append(isEnabled)
            return true
        }
        await secondPeer
            .installIPhoneMicrophoneTransportSuspensionHandler {
                context in
                secondRetirementContexts.append(context)
                secondFixture.controller.transportBecameUncertain()
                guard let token =
                        secondFixture.controller
                            .beginIPhoneMicrophoneOutputOnlyTransition(
                                ownerEpoch: secondOwnerEpoch
                            ) else {
                    return nil
                }
                guard context.selectToken(token) === token else {
                    return nil
                }
                secondTransportTokens.append(token)
                return token
            }
        await secondPeer
            .debugInstallIPhoneMicrophonePostSuspensionHandlerHook {
                _, _ in
                try? await secondPeer
                    .debugEnableIPhoneMicrophoneIgnoringTransportForTests(
                        secondReplacement
                    )
                guard let unrelatedToken =
                        secondFixture.controller
                            .beginIPhoneMicrophoneOutputOnlyTransition(
                                ownerEpoch: secondOwnerEpoch
                            ) else {
                    return
                }
                unrelatedDisableTokens.append(unrelatedToken)
                let result =
                    await secondPeer.disableIPhoneMicrophone(
                        outputOnlyToken: unrelatedToken
                    )
                unrelatedDisableResults.append(result)
            }
        await secondPeer
            .debugInstallIPhoneMicrophoneAuthorizationForTransportUncertainty(
                secondAuthorization
            )

        await secondPeer.debugSimulateICETransportUncertainty()

        let secondContext = try XCTUnwrap(
            secondRetirementContexts.values.first
        )
        let secondTransportToken = try XCTUnwrap(
            secondTransportTokens.values.first
        )
        let unrelatedToken = try XCTUnwrap(
            unrelatedDisableTokens.values.first
        )
        let secondSnapshot =
            await secondPeer.debugIPhoneMicrophonePolicySnapshot
        let secondStamp = try XCTUnwrap(
            secondSnapshot.completionStamp
        )
        let secondPeerIsClosed =
            await secondPeer.isClosedForTesting

        XCTAssertEqual(secondNativePolicies.values, [true, false])
        XCTAssertEqual(unrelatedDisableResults.values, [true])
        XCTAssertEqual(secondTransportToken.state, .revoked)
        XCTAssertEqual(unrelatedToken.state, .succeeded)
        XCTAssertEqual(secondStamp.kind, .outputOnlyDisable)
        XCTAssertEqual(secondStamp.origin, .publicRequest)
        XCTAssertNil(secondStamp.retirementID)
        XCTAssertNotEqual(
            secondStamp.retirementID,
            secondContext.retirementID
        )
        XCTAssertEqual(
            secondStamp.retiredAuthorizationIdentity,
            ObjectIdentifier(secondReplacement)
        )
        XCTAssertEqual(
            secondStamp.tokenID,
            unrelatedToken.tokenID
        )
        XCTAssertTrue(secondPeerIsClosed)

        await firstPeer.close()
        await secondPeer.close()
    }

    func testStaleSpecificDisableDuringRetirementOnlyRevokesItsAuthorization() async throws {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        let peer = try makeAudioRacePeer()
        let retiringAuthorization =
            WebRTCIOSMicrophoneAuthorization()
        let staleAuthorization =
            WebRTCIOSMicrophoneAuthorization()
        let ownerEpoch = UUID()
        let nativePolicies = AudioLockedValues<Bool>()
        let handlerEntered = expectation(
            description: "retirement handler suspended"
        )
        let handlerGate = AudioNonCooperativeGate<Void>()

        await peer.debugInstallIPhoneMicrophonePolicyApplier {
            isEnabled in
            nativePolicies.append(isEnabled)
            return true
        }
        await peer.installIPhoneMicrophoneTransportSuspensionHandler {
            context in
            fixture.controller.transportBecameUncertain()
            guard let token =
                    fixture.controller
                        .beginIPhoneMicrophoneOutputOnlyTransition(
                            ownerEpoch: ownerEpoch
                        ) else {
                handlerEntered.fulfill()
                return nil
            }
            guard context.selectToken(token) === token else {
                handlerEntered.fulfill()
                return nil
            }
            handlerEntered.fulfill()
            _ = await handlerGate.wait()
            return token
        }
        await peer
            .debugInstallIPhoneMicrophoneAuthorizationForTransportUncertainty(
                retiringAuthorization
            )

        let suspensionTask = Task {
            await peer.debugSimulateICETransportUncertainty()
        }
        await fulfillment(of: [handlerEntered], timeout: 2)

        let beforeStaleDisable =
            await peer.debugIPhoneMicrophonePolicySnapshot
        let staleResult = await peer.disableIPhoneMicrophone(
            authorization: staleAuthorization
        )
        let afterStaleDisable =
            await peer.debugIPhoneMicrophonePolicySnapshot

        XCTAssertFalse(staleResult)
        XCTAssertFalse(staleAuthorization.isValid)
        XCTAssertEqual(beforeStaleDisable, afterStaleDisable)
        XCTAssertTrue(nativePolicies.values.isEmpty)

        await handlerGate.open(())
        await suspensionTask.value

        XCTAssertEqual(nativePolicies.values, [false])
        await peer.close()
    }

    func testRepeatedOutputOnlyDisableAndPeerCloseAreExactSuccessfulNoOps() async throws {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        let peer = try makeAudioRacePeer()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        let token = try XCTUnwrap(
            fixture.controller
                .beginIPhoneMicrophoneOutputOnlyTransition(
                    ownerEpoch: UUID()
                )
        )
        let nativePolicies = AudioLockedValues<Bool>()

        await peer.debugInstallIPhoneMicrophonePolicyApplier {
            isEnabled in
            nativePolicies.append(isEnabled)
            return true
        }
        await peer
            .debugInstallIPhoneMicrophoneAuthorizationForTransportUncertainty(
                authorization
            )

        let firstResult = await peer.disableIPhoneMicrophone(
            authorization: authorization,
            outputOnlyToken: token
        )
        let firstSnapshot =
            await peer.debugIPhoneMicrophonePolicySnapshot
        let firstStamp = try XCTUnwrap(
            firstSnapshot.completionStamp
        )

        let repeatedResult = await peer.disableIPhoneMicrophone(
            authorization: authorization,
            outputOnlyToken: token
        )
        let repeatedSnapshot =
            await peer.debugIPhoneMicrophonePolicySnapshot

        XCTAssertTrue(firstResult)
        XCTAssertTrue(repeatedResult)
        XCTAssertEqual(nativePolicies.values, [false])
        XCTAssertEqual(firstSnapshot, repeatedSnapshot)
        XCTAssertEqual(firstStamp.tokenID, token.tokenID)
        XCTAssertEqual(token.state, .succeeded)

        fixture.events.deliverArmedCategoryChange(
            AudioSessionCategoryChange(
                category: AVAudioSession.Category.playback.rawValue,
                mode: AVAudioSession.Mode.default.rawValue
            )
        )
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            0
        )

        await peer.close()

        let closedSnapshot =
            await peer.debugIPhoneMicrophonePolicySnapshot
        XCTAssertEqual(nativePolicies.values, [false])
        XCTAssertEqual(closedSnapshot, repeatedSnapshot)
        XCTAssertEqual(
            closedSnapshot.completionStamp,
            firstStamp
        )
    }

    func testPublicDisableClaimWhileHandlerRunsReusesOneTokenAndOperationMarker() async throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        fixture.controller.updateRuntimePlayout(isReady: true)

        let peer = try makeAudioRacePeer()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        let ownerEpoch = UUID()
        let token = try XCTUnwrap(
            fixture.controller
                .beginIPhoneMicrophoneOutputOnlyTransition(
                    ownerEpoch: ownerEpoch
                )
        )
        let nativePolicies = AudioLockedValues<Bool>()
        let handlerEntered = expectation(
            description: "handler running before public claim"
        )
        let handlerGate = AudioNonCooperativeGate<Void>()

        await peer.debugInstallIPhoneMicrophonePolicyApplier {
            isEnabled in
            nativePolicies.append(isEnabled)
            return true
        }
        await peer.installIPhoneMicrophoneTransportSuspensionHandler {
            context in
            handlerEntered.fulfill()
            _ = await handlerGate.wait()
            fixture.controller.transportBecameUncertain()
            guard let executingToken = context.executingToken,
                  executingToken === token,
                  fixture.controller
                    .reuseIPhoneMicrophoneOutputOnlyTransition(
                        executingToken,
                        ownerEpoch: ownerEpoch
                    ) else {
                return nil
            }
            return executingToken
        }
        await peer
            .debugInstallIPhoneMicrophoneAuthorizationForTransportUncertainty(
                authorization
            )

        let suspensionTask = Task {
            await peer.debugSimulateICETransportUncertainty()
        }
        await fulfillment(of: [handlerEntered], timeout: 2)

        let publicResult = await peer.disableIPhoneMicrophone(
            authorization: authorization,
            outputOnlyToken: token
        )
        XCTAssertTrue(publicResult)
        XCTAssertEqual(token.state, .succeeded)

        await handlerGate.open(())
        await suspensionTask.value

        let policySnapshot =
            await peer.debugIPhoneMicrophonePolicySnapshot
        let stamp = try XCTUnwrap(
            policySnapshot.completionStamp
        )
        let peerIsClosed = await peer.isClosedForTesting

        XCTAssertEqual(nativePolicies.values, [false])
        XCTAssertEqual(stamp.tokenID, token.tokenID)
        XCTAssertNotNil(stamp.retirementID)
        XCTAssertFalse(peerIsClosed)
        XCTAssertEqual(
            fixture.events.armedCategoryChangeOperationIDs.filter {
                $0 == token.operationID
            }.count,
            1
        )

        fixture.events.deliverArmedCategoryChange(
            AudioSessionCategoryChange(
                category: AVAudioSession.Category.playback.rawValue,
                mode: AVAudioSession.Mode.default.rawValue
            )
        )
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            0
        )

        await peer.close()
    }

    func testViewModelTransportSuspensionHandlerRearmsPlaybackWhenMicrophoneStateIsAlreadyClear() async throws {
        let fixture = makeFixture()
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        let peer = try makeAudioRacePeer()

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        fixture.controller.beginMicrophoneTopologyTransition(
            isEnabled: true
        )
        viewModel.debugInstallIOSPlayoutPeerForRaceTests(peer)

        let outputOnlyToken = try XCTUnwrap(
            viewModel
                .debugPrepareIPhoneMicrophoneForTransportSuspensionForTests(
                    peer: peer
                )
        )
        XCTAssertTrue(outputOnlyToken.performOnce { true })

        fixture.events.deliverArmedCategoryChange(
            AudioSessionCategoryChange(
                category: AVAudioSession.Category.playback.rawValue,
                mode: AVAudioSession.Mode.default.rawValue
            )
        )

        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            0
        )
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Reconnecting audio"
        )

        viewModel.disconnect()
        await peer.close()
    }

    func testValidMicrophoneTopologyRenderFailureUsesGenericPlayoutMessage() {
        let diagnostics = iosPlayoutDiagnostics(
            callbacks: 10,
            frames: 4_800,
            failures: 1,
            inputBusEnabled: true,
            categoryIsMediaPlayback: false,
            categoryIsMediaPlayAndRecord: true
        )

        XCTAssertEqual(
            WorldwideSessionViewModel.debugIOSPlayoutFailureMessage(
                inputPolicyMatches: true,
                diagnostics: diagnostics
            ),
            "The iPhone 48 kHz stereo render path could not start."
        )
    }

    func testPeerMicrophoneReplacementDoesNotInsertOutputOnlyPolicy() async throws {
        let peer = try makeAudioRacePeer()
        let policyCalls = AudioLockedValues<Bool>()
        await peer.debugInstallIPhoneMicrophonePolicyApplier { isEnabled in
            policyCalls.append(isEnabled)
            return true
        }

        let previous = WebRTCIOSMicrophoneAuthorization()
        await peer
            .debugInstallIPhoneMicrophoneAuthorizationForTransportUncertainty(
                previous
            )
        let replacement = WebRTCIOSMicrophoneAuthorization()

        try await peer.debugEnableIPhoneMicrophoneIgnoringTransportForTests(
            replacement
        )

        let microphoneIsEnabled =
            await peer.isIPhoneMicrophoneEnabledForTesting
        XCTAssertFalse(previous.isValid)
        XCTAssertTrue(replacement.isValid)
        XCTAssertTrue(microphoneIsEnabled)
        XCTAssertEqual(policyCalls.values, [true])

        await peer.close()
    }

    func testFailedPeerMicrophoneEnableRollsBackOnlyAfterDisablePolicyIsArmed() async throws {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.beginMicrophoneTopologyTransition(
            isEnabled: true
        )

        let peer = try makeAudioRacePeer()
        let policyCalls = AudioLockedValues<Bool>()
        await peer.debugInstallIPhoneMicrophonePolicyApplier { isEnabled in
            policyCalls.append(isEnabled)
            return !isEnabled
        }
        let authorization = WebRTCIOSMicrophoneAuthorization()

        do {
            try await peer.debugEnableIPhoneMicrophoneIgnoringTransportForTests(
                authorization
            )
            XCTFail("The injected native enable failure must propagate.")
        } catch {
            // Expected. Playback rollback has not yet been authorized.
        }

        XCTAssertFalse(authorization.isValid)
        XCTAssertEqual(policyCalls.values, [true])

        let outputOnlyToken = try XCTUnwrap(
            fixture.controller
                .beginIPhoneMicrophoneOutputOnlyTransition(
                    ownerEpoch: UUID()
                )
        )
        await peer.disableIPhoneMicrophone(
            authorization: authorization,
            outputOnlyToken: outputOnlyToken
        )

        let nativeTeardownIsPending =
            await peer.isIPhoneMicrophoneNativeTeardownPendingForTesting
        XCTAssertFalse(nativeTeardownIsPending)
        XCTAssertEqual(policyCalls.values, [true, false])

        fixture.events.deliverArmedCategoryChange(
            AudioSessionCategoryChange(
                category: AVAudioSession.Category.playback.rawValue,
                mode: AVAudioSession.Mode.default.rawValue
            )
        )
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            0
        )

        await peer.close()
    }

    func testHeadphoneRemovalStaysMutedUntilExplicitResume() {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        let recoverCountBeforeRemoval = fixture.playback.recoverCount

        fixture.events.onRouteChanged?("Audio route changed: device unavailable")

        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.controller.snapshot.requiresExplicitResume)
        XCTAssertEqual(fixture.playback.recoverCount, recoverCountBeforeRemoval)

        XCTAssertFalse(
            fixture.controller.requestAutomaticRuntimeAudioRecovery(),
            "Automatic liveness recovery must not cross the private-route explicit-resume boundary."
        )
        XCTAssertTrue(fixture.controller.snapshot.requiresExplicitResume)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(fixture.playback.recoverCount, recoverCountBeforeRemoval)

        fixture.events.onRouteChanged?("Audio route changed: new device")
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.controller.appBecameActive()
        XCTAssertTrue(fixture.controller.snapshot.requiresExplicitResume)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.controller.resumePlayback()
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.controller.snapshot.requiresExplicitResume)
    }

    func testAutomaticRuntimeAudioRecoveryRebuildsAnEligibleOrdinaryPath() {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        let recoverCount = fixture.playback.recoverCount
        let gateCloseCount =
            fixture.playback.prepareManualAudioDisabledCount

        XCTAssertTrue(
            fixture.controller.requestAutomaticRuntimeAudioRecovery()
        )
        XCTAssertEqual(
            fixture.playback.prepareManualAudioDisabledCount,
            gateCloseCount + 1
        )
        XCTAssertEqual(
            fixture.playback.recoverCount,
            recoverCount + 1
        )
        XCTAssertFalse(fixture.controller.snapshot.requiresExplicitResume)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
    }

    func testAutomaticRuntimeAudioRecoveryReportsFailureAndRemainsRetryable() {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(
            fixture.remoteAudio
        )
        fixture.controller.transportBecameHealthy()
        let recoverCount = fixture.playback.recoverCount
        fixture.playback.recoverError = TestAudioError.recovery

        XCTAssertFalse(
            fixture.controller.requestAutomaticRuntimeAudioRecovery()
        )
        XCTAssertEqual(fixture.playback.recoverCount, recoverCount + 1)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.playback.recoverError = nil
        XCTAssertTrue(
            fixture.controller.requestAutomaticRuntimeAudioRecovery()
        )
        XCTAssertEqual(fixture.playback.recoverCount, recoverCount + 2)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
    }

    func testRecoveryFailureIsVisibleButSessionRemainsPreparedForRetry() {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.playback.recoverError = TestAudioError.recovery

        fixture.controller.transportBecameHealthy()

        XCTAssertEqual(fixture.controller.snapshot.stateText, "Playback unavailable")
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        XCTAssertEqual(fixture.playback.deactivateCount, 0)
        XCTAssertNotNil(fixture.controller.snapshot.errorText)
        XCTAssertTrue(
            fixture.controller.snapshot.diagnosticText?.contains(
                "Audio transport recovery failed"
            ) ?? false
        )
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.playback.recoverError = nil
        fixture.controller.appBecameActive()
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Playing")
        XCTAssertTrue(fixture.controller.snapshot.isPlaying)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertNil(fixture.controller.snapshot.errorText)
        XCTAssertNil(
            fixture.controller.snapshot.diagnosticText,
            "A successful retry must clear the obsolete live failure diagnostic."
        )
    }

    func testActivationFailureKeepsLifecyclePreparedForIndependentConnectionAndRetry() {
        let fixture = makeFixture()
        fixture.playback.activateError = TestAudioError.activation

        fixture.controller.prepare(serverName: "Mac mini")
        XCTAssertEqual(fixture.playback.activateCount, 1)
        XCTAssertEqual(fixture.playback.deactivateCount, 1)
        XCTAssertEqual(fixture.events.startCount, 1)
        XCTAssertEqual(fixture.background.clearCount, 0)
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Playback unavailable")
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        XCTAssertNotNil(fixture.controller.snapshot.errorText)
        XCTAssertTrue(
            fixture.controller.snapshot.diagnosticText?.contains("activation failed") ?? false
        )

        fixture.playback.activateError = nil
        fixture.events.onEngineConfigurationChanged?()

        XCTAssertEqual(fixture.playback.recoverCount, 1)
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Waiting for Mac audio")
        XCTAssertNil(fixture.controller.snapshot.errorText)

        fixture.controller.stop()
        XCTAssertEqual(fixture.playback.deactivateCount, 2)
        XCTAssertEqual(fixture.events.stopCount, 1)
        XCTAssertEqual(fixture.controller.snapshot, inactiveSnapshot)
    }

    func testWorldwideConnectionContinuesWhenAudioPreparationIsUnavailable() throws {
        let fixture = makeFixture()
        fixture.playback.activateError = TestAudioError.activation
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        let invitation = try RemoteInvitationCode.generate()

        XCTAssertTrue(
            viewModel.debugConnectWithInvitationForTests(
                invitationCode: invitation.exportedCode,
                debugEndpointOverride: "ws://127.0.0.1:9"
            )
        )
        XCTAssertTrue(viewModel.hasActiveSession)
        XCTAssertEqual(viewModel.stateText, "Connecting securely")
        XCTAssertEqual(viewModel.audioStateText, "Playback unavailable")
        XCTAssertTrue(viewModel.canResumeAudioPlayback)
        XCTAssertTrue(viewModel.audioError?.contains("Screen and control") ?? false)
        XCTAssertEqual(viewModel.audioRecoveryButtonTitle, "Retry Audio")
        XCTAssertTrue(viewModel.audioDiagnostic?.contains("activation failed") ?? false)
        XCTAssertNil(viewModel.lastError)

        viewModel.disconnect()
        XCTAssertFalse(viewModel.hasActiveSession)
    }

    func testReplacementConnectionWaitsForRetiredPeerCloseBeforeAudioActivation() async throws {
        let fixture = makeFixture()
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        let oldPeer = try makeAudioRacePeer()
        let retirementReached = expectation(
            description: "retired peer close reached"
        )
        let retirementGate = AudioNonCooperativeGate<Void>()
        var retirementHookCount = 0

        fixture.controller.prepare(serverName: "Old Mac")
        viewModel.debugInstallScreenSessionForTests(peer: oldPeer)
        viewModel.debugInstallBeforeRetiredPeerClose {
            retirementHookCount += 1
            if retirementHookCount == 1 {
                retirementReached.fulfill()
            }
            await retirementGate.wait()
        }
        viewModel.disconnect()
        await fulfillment(of: [retirementReached], timeout: 2)

        let activationCountBeforeReplacement =
            fixture.playback.activateCount
        let invitation = try RemoteInvitationCode.generate()
        XCTAssertTrue(
            viewModel.debugConnectWithInvitationForTests(
                invitationCode: invitation.exportedCode,
                debugEndpointOverride: "ws://127.0.0.1:9"
            )
        )
        XCTAssertTrue(viewModel.hasActiveSession)
        XCTAssertEqual(
            fixture.playback.activateCount,
            activationCountBeforeReplacement,
            "The replacement must not open the process-global audio gate while the old peer can still reconfigure it."
        )

        await retirementGate.open(())
        for _ in 0..<100 {
            if fixture.playback.activateCount
                > activationCountBeforeReplacement {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            fixture.playback.activateCount,
            activationCountBeforeReplacement + 1
        )

        viewModel.disconnect()
        await oldPeer.close()
    }

    func testFreshPreparationWaitsForExactRetiredPeerClose() async throws {
        let fixture = makeFixture()
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        let oldPeer = try makeAudioRacePeer()
        let retirementReached = expectation(description: "retirement reached exact peer close")
        let retirementGate = AudioNonCooperativeGate<Void>()
        viewModel.debugInstallScreenSessionForTests(peer: oldPeer)
        viewModel.debugInstallBeforeRetiredPeerClose {
            retirementReached.fulfill()
            await retirementGate.wait()
        }
        viewModel.disconnect()
        await fulfillment(of: [retirementReached], timeout: 2)

        let admission = Task { @MainActor in
            await viewModel.admitFreshConnectionPreparation()
        }
        for _ in 0..<4 { await Task.yield() }
        XCTAssertFalse(admission.isCancelled)

        await retirementGate.open(())
        let admittedAfterRetirement = await admission.value
        XCTAssertTrue(admittedAfterRetirement)
        await oldPeer.close()
    }

    func testFreshPreparationRejectsActiveAndRecoveringMediaOwnership() async throws {
        let fixture = makeFixture()
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        let peer = try makeAudioRacePeer()
        let screen = viewModel.debugInstallActiveScreenPresentationForTests(peer: peer)

        let admittedWhileActive = await viewModel.admitFreshConnectionPreparation()
        XCTAssertFalse(admittedWhileActive)
        viewModel.debugMarkViewerTransportUncertainForAutomaticMicrophoneTests()
        XCTAssertTrue(viewModel.screenPresentationShouldRemainMounted(screen.lease))
        let admittedWhileRecovering = await viewModel.admitFreshConnectionPreparation()
        XCTAssertFalse(admittedWhileRecovering)

        viewModel.disconnect()
        await peer.close()
    }

    func testCancelledFreshPreparationNeverEscapesRetirementBarrier() async throws {
        let fixture = makeFixture()
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        let oldPeer = try makeAudioRacePeer()
        let retirementReached = expectation(description: "cancelled admission reached retirement")
        let retirementGate = AudioNonCooperativeGate<Void>()
        viewModel.debugInstallScreenSessionForTests(peer: oldPeer)
        viewModel.debugInstallBeforeRetiredPeerClose {
            retirementReached.fulfill()
            await retirementGate.wait()
        }
        viewModel.disconnect()
        await fulfillment(of: [retirementReached], timeout: 2)

        let admission = Task { @MainActor in
            await viewModel.admitFreshConnectionPreparation()
        }
        for _ in 0..<4 { await Task.yield() }
        admission.cancel()
        await retirementGate.open(())

        let admittedAfterCancellation = await admission.value
        XCTAssertFalse(admittedAfterCancellation)
        await oldPeer.close()
    }

    func testIdentityUpdateRepublishesNowPlayingMetadata() {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")

        fixture.controller.updateServerName("  Studio Mac  ")

        XCTAssertEqual(fixture.background.publications.last?.serverName, "Studio Mac")
    }

    func testProductionPlaybackWaitsForLiveRemoteIOProofAndSurfacesDeviceFailure() {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()

        XCTAssertTrue(
            fixture.remoteAudio.isEnabled,
            "The decoded track must open so RemoteIO can produce runtime proof."
        )
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Starting playback")
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)

        fixture.controller.updateRuntimePlayout(isReady: true)

        XCTAssertEqual(fixture.controller.snapshot.stateText, "Playing")
        XCTAssertTrue(fixture.controller.snapshot.isPlaying)

        fixture.controller.updateRuntimePlayout(
            isReady: false,
            failureMessage: "The iPhone audio output could not start.",
            diagnostic: "RemoteIO start failed (-50)."
        )

        XCTAssertEqual(fixture.controller.snapshot.stateText, "Playback unavailable")
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(
            fixture.controller.snapshot.errorText,
            "The iPhone audio output could not start."
        )
        XCTAssertEqual(
            fixture.controller.snapshot.diagnosticText,
            "RemoteIO start failed (-50)."
        )
    }

    func testRetiredPollingProofCannotApplyHealthyDiagnosticsToReplacementAudio() async throws {
        try await assertRetiredPollingProofCannotMutateReplacement(
            diagnostics: healthyIOSPlayoutDiagnostics()
        )
    }

    func testRetiredPollingProofCannotApplyTerminalDiagnosticsToReplacementAudio() async throws {
        try await assertRetiredPollingProofCannotMutateReplacement(
            diagnostics: terminalIOSPlayoutDiagnostics()
        )
    }

    func testRetiredRefreshCannotApplyTerminalDiagnosticsToReplacementAudio() async throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        let oldPeer = try makeAudioRacePeer()
        let replacementPeer = try makeAudioRacePeer()
        let readStarted = expectation(description: "retired refresh suspended in diagnostics")
        let refreshFinished = expectation(description: "retired refresh returned")
        let diagnosticsGate = AudioNonCooperativeGate<WebRTCIOSPlayoutDiagnostics>()
        viewModel.debugInstallIOSPlayoutDiagnosticsReader { peer in
            XCTAssertTrue(peer === oldPeer)
            readStarted.fulfill()
            return await diagnosticsGate.wait()
        }

        fixture.controller.prepare(serverName: "Old Mac")
        viewModel.debugInstallIOSPlayoutPeerForRaceTests(oldPeer)
        _ = viewModel.debugStartIOSPlayoutProofAttemptForTests(
            requestRecovery: false,
            expectedPeer: oldPeer
        )
        let refreshTask = Task { @MainActor in
            await viewModel.debugRefreshIOSPlayoutProofForRaceTests()
            refreshFinished.fulfill()
        }
        await fulfillment(of: [readStarted], timeout: 2)
        await diagnosticsGate.waitUntilBlocked()

        viewModel.disconnect()
        prepareReplacementAudio(fixture.controller)
        viewModel.debugInstallIOSPlayoutPeerForRaceTests(replacementPeer)
        let replacementBeforeResume = PublishedAudioState(viewModel)

        await diagnosticsGate.open(terminalIOSPlayoutDiagnostics())
        await fulfillment(of: [refreshFinished], timeout: 2)
        await refreshTask.value

        XCTAssertEqual(PublishedAudioState(viewModel), replacementBeforeResume)
        viewModel.disconnect()
        await oldPeer.close()
        await replacementPeer.close()
    }

    func testRetiredRecoveryAuthorizationBlocksDelayedNativeSideEffect() async throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        let oldPeer = try makeAudioRacePeer()
        let replacementPeer = try makeAudioRacePeer()
        let requestStarted = expectation(description: "retired recovery request suspended")
        let proofFinished = expectation(description: "retired recovery proof returned")
        let requestGate = AudioNonCooperativeGate<Void>()
        let nativeRecoveryCount = AudioLockedInteger()
        viewModel.debugInstallIOSPlayoutRecoveryRequester { peer, authorization in
            XCTAssertTrue(peer === oldPeer)
            requestStarted.fulfill()
            await requestGate.wait()
            authorization.performIfValidForTesting {
                nativeRecoveryCount.increment()
            }
        }

        fixture.controller.prepare(serverName: "Old Mac")
        viewModel.debugInstallIOSPlayoutPeerForRaceTests(oldPeer)
        let oldProof = try XCTUnwrap(
            viewModel.debugBeginIOSPlayoutProofForRaceTests(requestRecovery: true)
        )
        Task { @MainActor in
            await oldProof.value
            proofFinished.fulfill()
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        XCTAssertTrue(viewModel.debugIOSPlayoutRecoveryIsAuthorized)

        viewModel.disconnect()
        XCTAssertFalse(viewModel.debugIOSPlayoutRecoveryIsAuthorized)
        prepareReplacementAudio(fixture.controller)
        viewModel.debugInstallIOSPlayoutPeerForRaceTests(replacementPeer)
        let replacementBeforeResume = PublishedAudioState(viewModel)

        await requestGate.open(())
        await fulfillment(of: [proofFinished], timeout: 2)

        XCTAssertEqual(nativeRecoveryCount.value, 0)
        XCTAssertEqual(PublishedAudioState(viewModel), replacementBeforeResume)
        viewModel.disconnect()
        await oldPeer.close()
        await replacementPeer.close()
    }

    func testRecoveryCapturesFailureFloorBeforeQueueingAndBlocksPendingReads() async throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        let peer = try makeAudioRacePeer()
        let baselineRead = expectation(description: "pre-request failure floor captured")
        let requestQueued = expectation(description: "native recovery request queued")
        let proofFinished = expectation(description: "retired recovery proof finished")
        var queuedAuthorization: WebRTCIOSPlayoutRecoveryAuthorization?
        var diagnosticReadCount = 0

        viewModel.debugInstallIOSPlayoutDiagnosticsReader { requestedPeer in
            XCTAssertTrue(requestedPeer === peer)
            diagnosticReadCount += 1
            if diagnosticReadCount == 1 {
                baselineRead.fulfill()
            }
            return iosPlayoutDiagnostics(
                callbacks: 10,
                frames: 4_800,
                failures: 2
            )
        }
        viewModel.debugInstallIOSPlayoutRecoveryRequester { requestedPeer, authorization in
            XCTAssertTrue(requestedPeer === peer)
            if diagnosticReadCount == 0 {
                XCTFail("Recovery was authorized before its exact pre-request failure floor was captured.")
                // Let the defective implementation retire deterministically instead of waiting on
                // a still-valid authorization after the ordering assertion has already failed.
                _ = authorization.performIfValidForTesting {}
            }
            XCTAssertEqual(diagnosticReadCount, 1)
            queuedAuthorization = authorization
            requestQueued.fulfill()
        }

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        viewModel.debugInstallIOSPlayoutPeerForRaceTests(peer)
        let proof = try XCTUnwrap(
            viewModel.debugBeginIOSPlayoutProofForRaceTests(requestRecovery: true)
        )
        Task { @MainActor in
            await proof.value
            proofFinished.fulfill()
        }

        await fulfillment(of: [baselineRead, requestQueued], timeout: 2)
        let authorization = try XCTUnwrap(queuedAuthorization)
        XCTAssertTrue(authorization.isValid)
        XCTAssertEqual(diagnosticReadCount, 1)

        await viewModel.debugRefreshIOSPlayoutProofForRaceTests()
        XCTAssertEqual(
            diagnosticReadCount,
            1,
            "Statistics refresh must not evaluate counters while exact recovery authorization is pending."
        )

        viewModel.disconnect()
        XCTAssertFalse(authorization.isValid)
        await fulfillment(of: [proofFinished], timeout: 2)
        await peer.close()
    }

    func testProductionProofStartSynchronouslyPublishesStartingPlayback() async throws {
        let (viewModel, _) = makePreparedProofViewModel()
        let peer = try makeAudioRacePeer()
        viewModel.debugInstallIOSPlayoutPeerForRaceTests(peer)

        XCTAssertEqual(viewModel.audioStateText, "Playing")
        XCTAssertTrue(viewModel.isRemoteAudioPlaying)

        guard let proof = viewModel.debugBeginIOSPlayoutProofForRaceTests(
            requestRecovery: false
        ) else {
            XCTFail("The production proof-start path did not create a proof task.")
            viewModel.disconnect()
            await peer.close()
            return
        }

        XCTAssertEqual(viewModel.audioStateText, "Starting playback")
        XCTAssertFalse(viewModel.isRemoteAudioPlaying)

        viewModel.disconnect()
        await proof.value
        await peer.close()
    }

    func testOngoingPlayoutOraclePublishesAdvancingNativeCountersWithoutProofAttempt() async throws {
        let (viewModel, _) = makePreparedProofViewModel()
        let peer = try makeAudioRacePeer()
        viewModel.debugInstallIOSPlayoutPeerForRaceTests(peer)

        let diagnostics = AudioPlayoutDiagnosticsBox(
            iosPlayoutDiagnostics(
                callbacks: 10,
                frames: 4_800,
                failures: 0
            )
        )
        let policyGeneration = viewModel.debugAudioPolicyGeneration
        viewModel.debugInstallIOSPlayoutDiagnosticsReader { requestedPeer in
            XCTAssertTrue(requestedPeer === peer)
            return diagnostics.value
        }

        XCTAssertNil(viewModel.audioPlayoutOracle)
        await viewModel.debugRefreshIOSPlayoutOracleForTests(from: peer)
        let first = try XCTUnwrap(viewModel.audioPlayoutOracle)
        XCTAssertEqual(first.callbackCount, 10)
        XCTAssertEqual(first.frameCount, 4_800)
        XCTAssertEqual(first.failureCount, 0)
        XCTAssertTrue(first.fullQualityInvariantsHold)
        XCTAssertEqual(
            first.audioPolicyGeneration,
            policyGeneration
        )

        diagnostics.set(
            iosPlayoutDiagnostics(
                callbacks: 11,
                frames: 5_280,
                failures: 0
            )
        )
        await viewModel.debugRefreshIOSPlayoutOracleForTests(from: peer)
        let second = try XCTUnwrap(viewModel.audioPlayoutOracle)
        XCTAssertEqual(second.sessionGeneration, first.sessionGeneration)
        XCTAssertEqual(
            second.audioPolicyGeneration,
            policyGeneration
        )
        XCTAssertGreaterThan(second.callbackCount, first.callbackCount)
        XCTAssertGreaterThan(second.frameCount, first.frameCount)
        XCTAssertEqual(second.failureCount, first.failureCount)
        XCTAssertTrue(second.fullQualityInvariantsHold)

        diagnostics.set(
            iosPlayoutDiagnostics(
                callbacks: 10,
                frames: 4_800,
                failures: 0
            )
        )
        await viewModel.debugRefreshIOSPlayoutOracleForTests(from: peer)
        XCTAssertEqual(
            viewModel.audioPlayoutOracle,
            second,
            "An older same-generation snapshot must not overwrite advancing proof."
        )

        viewModel.debugRotateAudioPolicyForTests()
        let replacementPolicy = viewModel.debugAudioPolicyGeneration
        XCTAssertNotEqual(replacementPolicy, policyGeneration)
        diagnostics.set(
            iosPlayoutDiagnostics(
                callbacks: 1,
                frames: 480,
                failures: 0
            )
        )
        await viewModel.debugRefreshIOSPlayoutOracleForTests(from: peer)
        let replacementFloor = try XCTUnwrap(
            viewModel.audioPlayoutOracle
        )
        XCTAssertEqual(
            replacementFloor.sessionGeneration,
            second.sessionGeneration
        )
        XCTAssertEqual(
            replacementFloor.audioPolicyGeneration,
            replacementPolicy
        )
        XCTAssertEqual(replacementFloor.callbackCount, 1)
        XCTAssertEqual(replacementFloor.frameCount, 480)

        viewModel.disconnect()
        XCTAssertNil(viewModel.audioPlayoutOracle)
        await peer.close()
    }

    func testStatsReadCannotPublishAcrossBareCallEndRecoveryGeneration()
        async throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        let peer = try makeAudioRacePeer()
        let readStarted = expectation(description: "statistics read suspended before call")
        let readFinished = expectation(description: "stale statistics read returned")
        let diagnosticsGate = AudioNonCooperativeGate<WebRTCIOSPlayoutDiagnostics>()
        viewModel.debugInstallIOSPlayoutDiagnosticsReader { requestedPeer in
            XCTAssertTrue(requestedPeer === peer)
            readStarted.fulfill()
            return await diagnosticsGate.wait()
        }
        // Isolate the suspended read fence. Native recovery is covered by the production-shaped
        // bare-call test; this callback intentionally avoids starting a competing diagnostics read.
        fixture.controller.onPlaybackRecoveryRequested = {}

        fixture.controller.prepare(serverName: "Mac mini")
        viewModel.debugInstallIOSPlayoutPeerForRaceTests(peer)
        let preCallGeneration = viewModel.debugAudioPolicyGeneration
        let refreshTask = Task { @MainActor in
            await viewModel.debugRefreshIOSPlayoutOracleForTests(from: peer)
            readFinished.fulfill()
        }
        await fulfillment(of: [readStarted], timeout: 2)
        await diagnosticsGate.waitUntilBlocked()

        fixture.callActivity.setNonEndedCallCount(1)
        XCTAssertEqual(
            viewModel.debugAudioPolicyGeneration,
            preCallGeneration
        )
        fixture.callActivity.setNonEndedCallCount(0)
        XCTAssertNotEqual(
            viewModel.debugAudioPolicyGeneration,
            preCallGeneration
        )
        await diagnosticsGate.open(healthyIOSPlayoutDiagnostics())
        await fulfillment(of: [readFinished], timeout: 2)
        await refreshTask.value

        XCTAssertNil(viewModel.audioPlayoutOracle)
        XCTAssertTrue(viewModel.hasActiveSession)
        XCTAssertEqual(fixture.playback.prepareManualAudioDisabledCount, 0)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)

        viewModel.disconnect()
        await peer.close()
    }

    func testBareCallDoesNotRevokeQueuedNativePlayoutRecovery() async throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        let peer = try makeAudioRacePeer()
        let requestStarted = expectation(description: "native recovery request suspended")
        let proofFinished = expectation(description: "call-retired proof returned")
        let requestGate = AudioNonCooperativeGate<Void>()
        let nativeRecoveryCount = AudioLockedInteger()
        var postRecoveryDiagnosticsReadCount = 0
        viewModel.debugInstallIOSPlayoutDiagnosticsReader { requestedPeer in
            XCTAssertTrue(requestedPeer === peer)
            guard nativeRecoveryCount.value > 0 else {
                return iosPlayoutDiagnostics(
                    callbacks: 10,
                    frames: 4_800,
                    failures: 0
                )
            }
            postRecoveryDiagnosticsReadCount += 1
            if postRecoveryDiagnosticsReadCount == 1 {
                return iosPlayoutDiagnostics(
                    callbacks: 10,
                    frames: 4_800,
                    failures: 0
                )
            }
            return iosPlayoutDiagnostics(
                callbacks: 11,
                frames: 5_280,
                failures: 0
            )
        }
        viewModel.debugInstallIOSPlayoutRecoveryRequester { requestedPeer, authorization in
            XCTAssertTrue(requestedPeer === peer)
            requestStarted.fulfill()
            await requestGate.wait()
            authorization.performIfValidForTesting {
                nativeRecoveryCount.increment()
            }
        }

        fixture.controller.prepare(serverName: "Mac mini")
        viewModel.debugInstallIOSPlayoutPeerForRaceTests(peer)
        let proof = try XCTUnwrap(
            viewModel.debugBeginIOSPlayoutProofForRaceTests(requestRecovery: true)
        )
        Task { @MainActor in
            await proof.value
            proofFinished.fulfill()
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        let authorization = try XCTUnwrap(
            viewModel.debugIOSPlayoutRecoveryAuthorizationForTests
        )
        XCTAssertTrue(authorization.isValid)

        fixture.callActivity.setNonEndedCallCount(1)

        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(viewModel.debugIOSPlayoutRecoveryIsAuthorized)
        XCTAssertTrue(viewModel.hasActiveSession)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)

        await requestGate.open(())
        await fulfillment(of: [proofFinished], timeout: 2)
        XCTAssertEqual(nativeRecoveryCount.value, 1)
        XCTAssertGreaterThanOrEqual(
            postRecoveryDiagnosticsReadCount,
            2
        )

        viewModel.disconnect()
        await peer.close()
    }

    func testActiveCallAllowsPlayoutProofButNotMicrophoneAuthorization() async throws {
        let fixture = makeFixture(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 0
        )
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        let peer = try makeAudioRacePeer()
        var diagnosticReadCount = 0
        var nativeRecoveryRequestCount = 0
        viewModel.debugInstallIOSPlayoutDiagnosticsReader { requestedPeer in
            XCTAssertTrue(requestedPeer === peer)
            diagnosticReadCount += 1
            return healthyIOSPlayoutDiagnostics()
        }
        viewModel.debugInstallIOSPlayoutRecoveryRequester { requestedPeer, _ in
            XCTAssertTrue(requestedPeer === peer)
            nativeRecoveryRequestCount += 1
        }

        fixture.controller.prepare(serverName: "Mac mini")
        viewModel.debugInstallIOSPlayoutPeerForRaceTests(peer)
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        XCTAssertNotNil(
            viewModel.debugBeginIOSPlayoutProofForRaceTests(
                requestRecovery: false
            )
        )
        await viewModel.debugRefreshIOSPlayoutProofForRaceTests()
        await viewModel.debugRefreshIOSPlayoutOracleForTests(from: peer)

        XCTAssertGreaterThan(diagnosticReadCount, 0)
        XCTAssertEqual(nativeRecoveryRequestCount, 0)
        XCTAssertFalse(fixture.controller.microphoneActivationIsAllowed())
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertTrue(viewModel.hasActiveSession)

        viewModel.disconnect()
        await peer.close()
    }

    func testInterruptionBeforeCallKitRevokesQueuedNativeRecovery() async throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        let peer = try makeAudioRacePeer()
        let requestStarted = expectation(description: "native recovery request suspended")
        let proofFinished = expectation(description: "interruption-retired proof returned")
        let requestGate = AudioNonCooperativeGate<Void>()
        let nativeRecoveryCount = AudioLockedInteger()
        viewModel.debugInstallIOSPlayoutDiagnosticsReader { requestedPeer in
            XCTAssertTrue(requestedPeer === peer)
            return iosPlayoutDiagnostics(callbacks: 10, frames: 4_800, failures: 0)
        }
        viewModel.debugInstallIOSPlayoutRecoveryRequester { requestedPeer, authorization in
            XCTAssertTrue(requestedPeer === peer)
            requestStarted.fulfill()
            await requestGate.wait()
            authorization.performIfValidForTesting {
                nativeRecoveryCount.increment()
            }
        }

        fixture.controller.prepare(serverName: "Mac mini")
        viewModel.debugInstallIOSPlayoutPeerForRaceTests(peer)
        let proof = try XCTUnwrap(
            viewModel.debugBeginIOSPlayoutProofForRaceTests(requestRecovery: true)
        )
        Task { @MainActor in
            await proof.value
            proofFinished.fulfill()
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        let authorization = try XCTUnwrap(
            viewModel.debugIOSPlayoutRecoveryAuthorizationForTests
        )
        XCTAssertTrue(authorization.isValid)

        // AVAudioSession can report the interruption before CallKit reports the call. The first
        // signal must already close native playout and revoke the exact queued side effect.
        fixture.events.onInterruptionBegan?(.unavailable)

        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(viewModel.debugIOSPlayoutRecoveryIsAuthorized)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(viewModel.hasActiveSession)

        fixture.callActivity.setNonEndedCallCount(1)
        await requestGate.open(())
        await fulfillment(of: [proofFinished], timeout: 2)
        XCTAssertEqual(nativeRecoveryCount.value, 0)
        XCTAssertNil(viewModel.audioPlayoutOracle)

        viewModel.disconnect()
        await peer.close()
    }

    func testHostedCallProofHarnessInstallsDeterministicGenerationAndObservesRevocation() async throws {
        try await withHostedCallProofHarness { harness in
            let start = try await beginHostedCallProof(harness)
            let installedGeneration = try XCTUnwrap(
                harness.recovery.installedSystemAudioGeneration
            )

            XCTAssertEqual(installedGeneration, harness.systemAudioGeneration)
            XCTAssertEqual(
                start.authorization.systemAudioGeneration,
                harness.systemAudioGeneration
            )
            XCTAssertEqual(harness.revocationRecorder.count, 0)

            start.authorization.revoke()
            XCTAssertFalse(start.authorization.isValid)
            XCTAssertFalse(start.authorization.isRecoveryPending)
            XCTAssertEqual(harness.revocationRecorder.count, 1)

            start.authorization.revoke()
            XCTAssertEqual(harness.revocationRecorder.count, 1)
        }
    }

    func testHostedCallProofRequiresExactFreshAudibleNativeAndInboundEvidence() async throws {
        try await withHostedCallProofHarness { harness in
            let start = try await beginHostedCallProof(harness)
            let authorization = start.authorization
            let initial = start.initialProjection
            let recovered = start.recoveredProjection
            let armedChange = try XCTUnwrap(
                harness.fixture.events.lastArmedCategoryChange
            )

            XCTAssertEqual(initial.stage, "awaiting-native-quiescence")
            XCTAssertEqual(initial.pollOrdinal, 0)
            XCTAssertNil(initial.timeoutPhase)
            XCTAssertNil(initial.timeoutID)
            XCTAssertFalse(initial.proofDeadlineIsArmed)
            XCTAssertFalse(initial.steadyMonitorIsArmed)
            XCTAssertNil(initial.runtimeGateAdmittedAt)
            XCTAssertNil(initial.evidenceFloor)
            XCTAssertNil(initial.steadyFloor)
            XCTAssertTrue(initial.authorizationIsValid)
            XCTAssertTrue(initial.authorizationIsRecoveryPending)
            XCTAssertEqual(initial.authorizationSystemAudioGeneration, 0)
            XCTAssertEqual(initial.authorizationIdentity, ObjectIdentifier(authorization))
            XCTAssertEqual(initial.policyID, authorization.policyID)
            XCTAssertEqual(initial.sessionGeneration, harness.generation)
            XCTAssertEqual(initial.expectedPeerIdentity, ObjectIdentifier(harness.peer))
            XCTAssertEqual(armedChange.operationID, authorization.policyID)
            XCTAssertEqual(authorization.origin, .interruption)
            XCTAssertFalse(harness.fixture.remoteAudio.isEnabled)
            XCTAssertNil(harness.viewModel.audioPlayoutOracle)
            XCTAssertNil(harness.viewModel.worldwideHostedCallPlayoutOracle)

            XCTAssertEqual(recovered.stage, "awaiting-native-recovery")
            XCTAssertEqual(recovered.proofAttemptID, initial.proofAttemptID)
            XCTAssertEqual(recovered.counterWindowID, initial.counterWindowID)
            XCTAssertEqual(recovered.audioPolicyGeneration, initial.audioPolicyGeneration)
            XCTAssertEqual(recovered.pollOrdinal, 1)
            XCTAssertEqual(recovered.recoveryRequestCount, 1)
            XCTAssertEqual(recovered.nextRecoveryRequestPollOrdinal, 5)
            let setupTimeoutID = try XCTUnwrap(recovered.timeoutID)
            XCTAssertEqual(recovered.timeoutPhase, "setup")
            XCTAssertTrue(recovered.proofDeadlineIsArmed)
            XCTAssertTrue(authorization.isValid)
            XCTAssertFalse(authorization.isRecoveryPending)
            XCTAssertGreaterThan(authorization.systemAudioGeneration, 0)
            XCTAssertEqual(
                recovered.authorizationSystemAudioGeneration,
                authorization.systemAudioGeneration
            )
            XCTAssertEqual(harness.recovery.requestCount, 1)
            XCTAssertNil(harness.viewModel.audioPlayoutOracle)
            XCTAssertNil(harness.viewModel.worldwideHostedCallPlayoutOracle)

            let admitted = try await admitHostedCallDecodedAudio(harness)
            let evidenceTimeoutID = try XCTUnwrap(admitted.timeoutID)
            XCTAssertEqual(admitted.stage, "awaiting-evidence-floor")
            XCTAssertEqual(admitted.pollOrdinal, 2)
            XCTAssertEqual(admitted.runtimeGateAdmittedAt, harness.admittedAt)
            XCTAssertEqual(admitted.timeoutPhase, "evidence")
            XCTAssertNotEqual(evidenceTimeoutID, setupTimeoutID)
            XCTAssertTrue(admitted.proofDeadlineIsArmed)
            XCTAssertFalse(admitted.steadyMonitorIsArmed)
            XCTAssertNil(admitted.evidenceFloor)
            XCTAssertNil(admitted.steadyFloor)
            XCTAssertTrue(harness.fixture.remoteAudio.isEnabled)
            XCTAssertTrue(harness.viewModel.isRemoteAudioAvailable)
            XCTAssertFalse(harness.viewModel.isRemoteAudioPlaying)
            XCTAssertEqual(harness.viewModel.audioStateText, "Starting playback")
            XCTAssertNil(harness.viewModel.audioPlayoutOracle)
            XCTAssertNil(harness.viewModel.worldwideHostedCallPlayoutOracle)

            let installed = harness.diagnostics.value
            XCTAssertTrue(installed.playoutInitialized)
            XCTAssertTrue(installed.playing)
            XCTAssertTrue(installed.sessionActive)
            XCTAssertTrue(installed.ownsSessionActivation)
            XCTAssertTrue(installed.remoteIOCreated)
            XCTAssertFalse(installed.inputBusEnabled)
            XCTAssertTrue(installed.outputBusEnabled)
            XCTAssertTrue(installed.categoryIsMediaPlayback)
            XCTAssertFalse(installed.categoryIsMediaPlayAndRecord)
            XCTAssertFalse(installed.categoryOptionsAreEmpty)
            XCTAssertTrue(installed.categoryOptionsAreMixWithOthers)
            XCTAssertTrue(installed.hostedCallMode)
            XCTAssertTrue(installed.hostedCallAuthorizationValid)
            XCTAssertFalse(installed.hostedCallRecoveryPending)
            XCTAssertEqual(installed.systemAudioGeneration, authorization.systemAudioGeneration)
            XCTAssertEqual(
                installed.hostedCallAuthorizationGeneration,
                authorization.systemAudioGeneration
            )
            XCTAssertEqual(installed.audioUnitSubType, kAudioUnitSubType_RemoteIO)

            let floorSnapshot = hostedCallStatisticsSnapshot(
                collectedAt: harness.admittedAt.addingTimeInterval(1),
                bytes: 1_000,
                packets: 10,
                jitterBufferEmittedCount: 100,
                totalSamplesReceived: 4_800,
                totalAudioEnergy: 1.0,
                totalSamplesDuration: 0.1
            )
            await harness.viewModel.debugDriveIOSHostedCallStatisticsForTests(
                floorSnapshot,
                from: harness.peer,
                generation: harness.generation
            )
            let floorProjection = try XCTUnwrap(
                harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
            )
            let floor = try XCTUnwrap(floorProjection.evidenceFloor)
            XCTAssertEqual(floorProjection.stage, "awaiting-fresh-evidence")
            XCTAssertEqual(try XCTUnwrap(floorProjection.timeoutID), evidenceTimeoutID)
            XCTAssertTrue(floorProjection.proofDeadlineIsArmed)
            XCTAssertNil(floorProjection.steadyFloor)
            XCTAssertEqual(floor.callbackCount, 10)
            XCTAssertEqual(floor.frameCount, 4_800)
            XCTAssertEqual(floor.pcmNonzeroSampleCount, 9_600)
            XCTAssertEqual(floor.pcmAbsoluteSampleSum, 9_600_000)
            XCTAssertEqual(floor.statisticsCollectedAt, floorSnapshot.collectedAt)
            XCTAssertEqual(floor.inboundBytes, 1_000)
            XCTAssertEqual(floor.inboundPackets, 10)
            XCTAssertEqual(floor.inboundJitterBufferEmittedCount, 100)
            XCTAssertEqual(floor.inboundTotalSamplesReceived, 4_800)
            XCTAssertEqual(harness.viewModel.statistics, floorSnapshot)
            XCTAssertFalse(harness.viewModel.isRemoteAudioPlaying)
            XCTAssertEqual(harness.viewModel.audioStateText, "Starting playback")
            XCTAssertNil(harness.viewModel.audioPlayoutOracle)
            XCTAssertNil(harness.viewModel.worldwideHostedCallPlayoutOracle)

            harness.diagnostics.set(
                hostedCallIOSPlayoutDiagnostics(
                    authorization: authorization,
                    callbacks: 11,
                    frames: 5_280,
                    pcmNonzeroSampleCount: 9_601,
                    pcmAbsoluteSampleSum: 9_601_000
                )
            )
            let readySnapshot = hostedCallStatisticsSnapshot(
                collectedAt: harness.admittedAt.addingTimeInterval(2),
                bytes: 1_100,
                packets: 11,
                jitterBufferEmittedCount: 110,
                totalSamplesReceived: 5_280,
                totalAudioEnergy: 1.1,
                totalSamplesDuration: 0.11
            )
            await harness.viewModel.debugDriveIOSHostedCallStatisticsForTests(
                readySnapshot,
                from: harness.peer,
                generation: harness.generation
            )
            try await requireAudioWaiterBlocked(
                harness.steadyTimeoutWaiter,
                ordinal: 1,
                description: "the first hosted-call steady timeout to arm"
            )
            let ready = try XCTUnwrap(
                harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
            )
            let steady = try XCTUnwrap(ready.steadyFloor)
            let steadyTimeoutID = try XCTUnwrap(ready.timeoutID)
            XCTAssertEqual(ready.stage, "ready")
            XCTAssertEqual(ready.proofAttemptID, initial.proofAttemptID)
            XCTAssertEqual(ready.counterWindowID, initial.counterWindowID)
            XCTAssertEqual(ready.policyID, authorization.policyID)
            XCTAssertEqual(ready.authorizationIdentity, ObjectIdentifier(authorization))
            XCTAssertEqual(try XCTUnwrap(ready.evidenceFloor), floor)
            XCTAssertEqual(steady.callbackCount, 11)
            XCTAssertEqual(steady.frameCount, 5_280)
            XCTAssertEqual(steady.pcmNonzeroSampleCount, 9_601)
            XCTAssertEqual(steady.pcmAbsoluteSampleSum, 9_601_000)
            XCTAssertEqual(steady.statisticsCollectedAt, readySnapshot.collectedAt)
            XCTAssertEqual(steady.inboundBytes, 1_100)
            XCTAssertEqual(ready.timeoutPhase, "steady")
            XCTAssertNotEqual(steadyTimeoutID, evidenceTimeoutID)
            XCTAssertFalse(ready.proofDeadlineIsArmed)
            XCTAssertTrue(ready.steadyMonitorIsArmed)
            XCTAssertFalse(ready.pollingTaskIsRetained)
            XCTAssertTrue(authorization.isValid)
            XCTAssertFalse(authorization.isRecoveryPending)
            XCTAssertTrue(harness.fixture.remoteAudio.isEnabled)
            XCTAssertTrue(harness.viewModel.isRemoteAudioPlaying)
            XCTAssertEqual(harness.viewModel.audioStateText, "Playing — iPhone call may reduce quality")
            XCTAssertEqual(harness.viewModel.statistics, readySnapshot)
            XCTAssertNil(harness.viewModel.audioPlayoutOracle)
            let oracle = try XCTUnwrap(
                harness.viewModel.worldwideHostedCallPlayoutOracle
            )
            XCTAssertEqual(oracle.sessionGeneration, harness.generation)
            XCTAssertEqual(oracle.policyID, authorization.policyID)
            XCTAssertEqual(oracle.origin, .interruption)
            XCTAssertEqual(oracle.audioPolicyGeneration, ready.audioPolicyGeneration)
            XCTAssertEqual(
                oracle.systemAudioGeneration,
                authorization.systemAudioGeneration
            )
            XCTAssertEqual(
                oracle.authorizationGeneration,
                authorization.systemAudioGeneration
            )
            XCTAssertEqual(
                oracle.nativeAuthorizationGeneration,
                authorization.systemAudioGeneration
            )
            XCTAssertEqual(oracle.callbackCount, 11)
            XCTAssertEqual(oracle.frameCount, 5_280)
            XCTAssertEqual(oracle.failureCount, 0)
            XCTAssertEqual(oracle.pcmNonzeroSampleCount, 9_601)
            XCTAssertEqual(oracle.pcmAbsoluteSampleSum, 9_601_000)
            XCTAssertEqual(oracle.unexpectedRecordingRequestCount, 0)
            XCTAssertEqual(oracle.inboundBytes, 1_100)
            XCTAssertEqual(oracle.inboundPackets, 11)
            XCTAssertEqual(oracle.inboundJitterBufferEmittedCount, 110)
            XCTAssertEqual(oracle.inboundTotalSamplesReceived, 5_280)
            XCTAssertEqual(oracle.inboundAudioEnergy, 1.1)
            XCTAssertEqual(oracle.inboundSamplesDuration, 0.11)
            XCTAssertTrue(oracle.outputBusEnabled)
            XCTAssertFalse(oracle.inputBusEnabled)
            XCTAssertTrue(oracle.categoryIsMediaPlayback)
            XCTAssertTrue(oracle.modeIsDefault)
            XCTAssertTrue(oracle.categoryOptionsAreMixWithOthers)
            XCTAssertTrue(oracle.remoteIOCreated)
            XCTAssertTrue(oracle.audioUnitIsRemoteIO)
            XCTAssertTrue(oracle.activeSessionOwnership)
            XCTAssertTrue(oracle.hostedCallMode)
            XCTAssertTrue(oracle.authorizationIsValid)
            XCTAssertTrue(oracle.authorizationIsConsumed)
            XCTAssertTrue(oracle.nativeAuthorizationIsValid)
            XCTAssertTrue(oracle.nativeAuthorizationIsConsumed)
            XCTAssertTrue(oracle.authorizationPolicyMatches)
            XCTAssertTrue(oracle.authorizationGenerationMatches)
            XCTAssertTrue(oracle.connectedCallKitSnapshot)
            XCTAssertEqual(
                oracle.accessibilityValue,
                [
                    "v=2",
                    "origin=interruption",
                    "session=\(harness.generation.uuidString.lowercased())",
                    "policy=\(authorization.policyID.uuidString.lowercased())",
                    "audioPolicy=\(ready.audioPolicyGeneration.uuidString.lowercased())",
                    "systemAudioGeneration=\(authorization.systemAudioGeneration)",
                    "authorizationGeneration=\(authorization.systemAudioGeneration)",
                    "nativeAuthorizationGeneration=\(authorization.systemAudioGeneration)",
                    "callbacks=11",
                    "frames=5280",
                    "failures=0",
                    "pcmNonzero=9601",
                    "pcmAbs=9601000",
                    "recordRequests=0",
                    "inboundBytes=1100",
                    "inboundPackets=11",
                    "inboundJitterEmitted=110",
                    "inboundSamples=5280",
                    "inboundEnergy=1.1",
                    "inboundDuration=0.11",
                    "output=1",
                    "input=0",
                    "playback=1",
                    "defaultMode=1",
                    "mixWithOthers=1",
                    "remoteIOCreated=1",
                    "remoteIOSubtype=1",
                    "activeOwnership=1",
                    "hostedMode=1",
                    "authorizationValid=1",
                    "authorizationConsumed=1",
                    "nativeAuthorizationValid=1",
                    "nativeAuthorizationConsumed=1",
                    "authorizationPolicyMatches=1",
                    "authorizationGenerationMatches=1",
                    "callKitConnected=1",
                ].joined(separator: "|")
            )
            await harness.evidenceTimeoutWaiter.release(1)
        }
    }

    func testHostedCallProofDoesNotTreatInitialSilenceAsReady() async throws {
        try await withHostedCallProofHarness(
            installedPCMNonzeroSampleCount: 0,
            installedPCMAbsoluteSampleSum: 0
        ) { harness in
            let start = try await beginHostedCallProof(harness)
            let authorization = start.authorization
            _ = try await admitHostedCallDecodedAudio(harness)

            let floorSnapshot = hostedCallStatisticsSnapshot(
                collectedAt: harness.admittedAt.addingTimeInterval(1),
                bytes: 2_000,
                packets: 20,
                jitterBufferEmittedCount: 200,
                totalSamplesReceived: 4_800,
                totalAudioEnergy: 0,
                totalSamplesDuration: 0.1
            )
            await harness.viewModel.debugDriveIOSHostedCallStatisticsForTests(
                floorSnapshot,
                from: harness.peer,
                generation: harness.generation
            )
            let floorProjection = try XCTUnwrap(
                harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
            )
            let evidenceTimeoutID = try XCTUnwrap(floorProjection.timeoutID)
            XCTAssertEqual(floorProjection.stage, "awaiting-fresh-evidence")
            XCTAssertEqual(floorProjection.evidenceFloor?.pcmNonzeroSampleCount, 0)
            XCTAssertEqual(floorProjection.evidenceFloor?.pcmAbsoluteSampleSum, 0)

            harness.diagnostics.set(
                hostedCallIOSPlayoutDiagnostics(
                    authorization: authorization,
                    callbacks: 11,
                    frames: 5_280,
                    pcmNonzeroSampleCount: 0,
                    pcmAbsoluteSampleSum: 0
                )
            )
            let silentSnapshot = hostedCallStatisticsSnapshot(
                collectedAt: harness.admittedAt.addingTimeInterval(2),
                bytes: 2_100,
                packets: 21,
                jitterBufferEmittedCount: 210,
                totalSamplesReceived: 5_280,
                totalAudioEnergy: 0,
                totalSamplesDuration: 0.11
            )
            await harness.viewModel.debugDriveIOSHostedCallStatisticsForTests(
                silentSnapshot,
                from: harness.peer,
                generation: harness.generation
            )
            let silentProjection = try XCTUnwrap(
                harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
            )
            XCTAssertEqual(
                silentProjection.stage,
                "awaiting-fresh-evidence",
                "Callback/frame/RTP advancement without audible PCM must not certify readiness."
            )
            XCTAssertEqual(silentProjection.evidenceFloor, floorProjection.evidenceFloor)
            XCTAssertNil(silentProjection.steadyFloor)
            XCTAssertEqual(try XCTUnwrap(silentProjection.timeoutID), evidenceTimeoutID)
            XCTAssertFalse(
                harness.viewModel.isRemoteAudioPlaying,
                "Initial silence must not publish Playing."
            )
            XCTAssertEqual(harness.viewModel.audioStateText, "Starting playback")
            XCTAssertTrue(harness.fixture.remoteAudio.isEnabled)
            XCTAssertEqual(harness.viewModel.statistics, silentSnapshot)
            XCTAssertTrue(authorization.isValid)
            XCTAssertEqual(
                silentProjection.authorizationIdentity,
                ObjectIdentifier(authorization)
            )
            XCTAssertNil(harness.viewModel.audioPlayoutOracle)
            XCTAssertNil(harness.viewModel.worldwideHostedCallPlayoutOracle)

            harness.diagnostics.set(
                hostedCallIOSPlayoutDiagnostics(
                    authorization: authorization,
                    callbacks: 12,
                    frames: 5_760,
                    pcmNonzeroSampleCount: 1,
                    pcmAbsoluteSampleSum: 1_000
                )
            )
            let audibleSnapshot = hostedCallStatisticsSnapshot(
                collectedAt: harness.admittedAt.addingTimeInterval(3),
                bytes: 2_200,
                packets: 22,
                jitterBufferEmittedCount: 220,
                totalSamplesReceived: 5_760,
                totalAudioEnergy: 0.25,
                totalSamplesDuration: 0.12
            )
            await harness.viewModel.debugDriveIOSHostedCallStatisticsForTests(
                audibleSnapshot,
                from: harness.peer,
                generation: harness.generation
            )
            try await requireAudioWaiterBlocked(
                harness.steadyTimeoutWaiter,
                ordinal: 1,
                description: "the first hosted-call steady timeout to arm"
            )
            let ready = try XCTUnwrap(
                harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
            )
            XCTAssertEqual(ready.stage, "ready")
            XCTAssertEqual(ready.steadyFloor?.pcmNonzeroSampleCount, 1)
            XCTAssertEqual(ready.steadyFloor?.pcmAbsoluteSampleSum, 1_000)
            XCTAssertTrue(harness.viewModel.isRemoteAudioPlaying)
            XCTAssertEqual(harness.viewModel.audioStateText, "Playing — iPhone call may reduce quality")
            XCTAssertTrue(authorization.isValid)
            XCTAssertEqual(ready.authorizationIdentity, ObjectIdentifier(authorization))
            XCTAssertNil(harness.viewModel.audioPlayoutOracle)
            XCTAssertNotNil(harness.viewModel.worldwideHostedCallPlayoutOracle)
            await harness.evidenceTimeoutWaiter.release(1)
        }
    }

    func testHostedCallSteadyMonitoringAcceptsLegitimateSilenceAndRearms() async throws {
        try await withHostedCallProofHarness { harness in
            let state = try await driveHostedCallProofToReady(harness)
            let authorization = state.start.authorization
            let before = state.readyProjection
            let beforeTimeoutID = try XCTUnwrap(before.timeoutID)
            let beforeFloor = try XCTUnwrap(before.steadyFloor)
            let beforeOracle = try XCTUnwrap(
                harness.viewModel.worldwideHostedCallPlayoutOracle
            )

            harness.diagnostics.set(
                hostedCallIOSPlayoutDiagnostics(
                    authorization: authorization,
                    callbacks: beforeFloor.callbackCount + 1,
                    frames: beforeFloor.frameCount + 480,
                    pcmNonzeroSampleCount: beforeFloor.pcmNonzeroSampleCount,
                    pcmAbsoluteSampleSum: beforeFloor.pcmAbsoluteSampleSum
                )
            )
            let silentSnapshot = hostedCallStatisticsSnapshot(
                collectedAt: beforeFloor.statisticsCollectedAt.addingTimeInterval(1),
                bytes: try XCTUnwrap(beforeFloor.inboundBytes) + 100,
                packets: try XCTUnwrap(beforeFloor.inboundPackets) + 1,
                jitterBufferEmittedCount:
                    try XCTUnwrap(beforeFloor.inboundJitterBufferEmittedCount) + 10,
                totalSamplesReceived:
                    try XCTUnwrap(beforeFloor.inboundTotalSamplesReceived) + 480,
                totalAudioEnergy:
                    try XCTUnwrap(beforeFloor.inboundTotalAudioEnergy) + 0.1,
                totalSamplesDuration:
                    try XCTUnwrap(beforeFloor.inboundTotalSamplesDuration) + 0.01
            )
            await harness.viewModel.debugDriveIOSHostedCallStatisticsForTests(
                silentSnapshot,
                from: harness.peer,
                generation: harness.generation
            )
            try await requireAudioWaiterBlocked(
                harness.steadyTimeoutWaiter,
                ordinal: 2,
                description: "the rearmed hosted-call steady timeout to block"
            )
            let after = try XCTUnwrap(
                harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
            )
            let afterFloor = try XCTUnwrap(after.steadyFloor)
            XCTAssertEqual(after.stage, "ready")
            XCTAssertEqual(after.authorizationIdentity, ObjectIdentifier(authorization))
            XCTAssertTrue(authorization.isValid)
            XCTAssertFalse(authorization.isRecoveryPending)
            XCTAssertEqual(afterFloor.callbackCount, beforeFloor.callbackCount + 1)
            XCTAssertEqual(afterFloor.frameCount, beforeFloor.frameCount + 480)
            XCTAssertEqual(
                afterFloor.pcmNonzeroSampleCount,
                beforeFloor.pcmNonzeroSampleCount,
                "Post-ready silence must remain healthy without new nonzero PCM."
            )
            XCTAssertEqual(
                afterFloor.pcmAbsoluteSampleSum,
                beforeFloor.pcmAbsoluteSampleSum
            )
            XCTAssertEqual(afterFloor.statisticsCollectedAt, silentSnapshot.collectedAt)
            XCTAssertNotEqual(
                try XCTUnwrap(after.timeoutID),
                beforeTimeoutID,
                "Healthy silent cadence and RTP advancement must rearm the steady watchdog."
            )
            XCTAssertTrue(after.steadyMonitorIsArmed)
            XCTAssertTrue(harness.viewModel.isRemoteAudioPlaying)
            XCTAssertEqual(harness.viewModel.audioStateText, "Playing — iPhone call may reduce quality")
            XCTAssertEqual(harness.viewModel.statistics, silentSnapshot)
            XCTAssertNil(harness.viewModel.audioPlayoutOracle)
            let afterOracle = try XCTUnwrap(
                harness.viewModel.worldwideHostedCallPlayoutOracle
            )
            XCTAssertEqual(afterOracle.sessionGeneration, beforeOracle.sessionGeneration)
            XCTAssertEqual(afterOracle.policyID, beforeOracle.policyID)
            XCTAssertEqual(
                afterOracle.audioPolicyGeneration,
                beforeOracle.audioPolicyGeneration
            )
            XCTAssertEqual(afterOracle.callbackCount, beforeFloor.callbackCount + 1)
            XCTAssertEqual(afterOracle.frameCount, beforeFloor.frameCount + 480)
            XCTAssertEqual(
                afterOracle.pcmNonzeroSampleCount,
                beforeOracle.pcmNonzeroSampleCount
            )
            XCTAssertEqual(
                afterOracle.pcmAbsoluteSampleSum,
                beforeOracle.pcmAbsoluteSampleSum
            )
            XCTAssertEqual(afterOracle.failureCount, beforeOracle.failureCount)
            XCTAssertEqual(
                afterOracle.unexpectedRecordingRequestCount,
                beforeOracle.unexpectedRecordingRequestCount
            )
            XCTAssertEqual(
                afterOracle.inboundBytes,
                silentSnapshot.inboundAudio?.bytes
            )
            XCTAssertEqual(
                afterOracle.inboundPackets,
                silentSnapshot.inboundAudio?.packets
            )
            XCTAssertEqual(
                afterOracle.inboundJitterBufferEmittedCount,
                silentSnapshot.inboundAudio?.jitterBufferEmittedCount
            )
            XCTAssertEqual(
                afterOracle.inboundTotalSamplesReceived,
                silentSnapshot.inboundAudio?.totalSamplesReceived
            )
            XCTAssertEqual(
                afterOracle.inboundAudioEnergy,
                silentSnapshot.inboundAudio?.totalAudioEnergy
            )
            XCTAssertEqual(
                afterOracle.inboundSamplesDuration,
                silentSnapshot.inboundAudio?.totalSamplesDuration
            )
            XCTAssertNotEqual(afterOracle.accessibilityValue, beforeOracle.accessibilityValue)

            await harness.steadyTimeoutWaiter.release(1)
            for _ in 0..<4 {
                await Task.yield()
            }
            XCTAssertEqual(
                try XCTUnwrap(
                    harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
                ),
                after,
                "The canceled pre-rearm timeout must not retire the ready attempt."
            )
        }
    }

    func testHostedCallSteadyStallFailsClosedWithCadenceAndRTPDiagnostic() async throws {
        try await withHostedCallProofHarness { harness in
            let state = try await driveHostedCallProofToReady(harness)
            let authorization = state.start.authorization
            let before = state.readyProjection
            let floor = try XCTUnwrap(before.steadyFloor)
            XCTAssertNotNil(harness.viewModel.worldwideHostedCallPlayoutOracle)

            let stalledSnapshot = hostedCallStatisticsSnapshot(
                collectedAt: floor.statisticsCollectedAt.addingTimeInterval(1),
                bytes: try XCTUnwrap(floor.inboundBytes),
                packets: try XCTUnwrap(floor.inboundPackets),
                jitterBufferEmittedCount:
                    try XCTUnwrap(floor.inboundJitterBufferEmittedCount),
                totalSamplesReceived:
                    try XCTUnwrap(floor.inboundTotalSamplesReceived),
                totalAudioEnergy: try XCTUnwrap(floor.inboundTotalAudioEnergy),
                totalSamplesDuration:
                    try XCTUnwrap(floor.inboundTotalSamplesDuration)
            )
            await harness.viewModel.debugDriveIOSHostedCallStatisticsForTests(
                stalledSnapshot,
                from: harness.peer,
                generation: harness.generation
            )
            let stalled = try XCTUnwrap(
                harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
            )
            XCTAssertEqual(stalled.stage, "ready")
            XCTAssertEqual(
                stalled.timeoutID,
                before.timeoutID,
                "A true steady stall must not rearm its existing timeout."
            )
            XCTAssertEqual(stalled.steadyFloor, before.steadyFloor)
            XCTAssertTrue(harness.viewModel.isRemoteAudioPlaying)
            XCTAssertEqual(harness.viewModel.statistics, stalledSnapshot)

            await harness.steadyTimeoutWaiter.release(1)
            for _ in 0..<20 {
                if harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests() == nil {
                    break
                }
                await Task.yield()
            }

            XCTAssertNil(harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests())
            XCTAssertFalse(authorization.isValid)
            XCTAssertFalse(harness.fixture.remoteAudio.isEnabled)
            XCTAssertTrue(
                harness.viewModel.isRemoteAudioAvailable,
                "Track availability is distinct from the disabled decoded-audio gate."
            )
            XCTAssertFalse(harness.viewModel.isRemoteAudioPlaying)
            XCTAssertEqual(
                harness.viewModel.audioStateText,
                "Interrupted",
                "An active interruption takes precedence over playback readiness."
            )
            XCTAssertEqual(
                harness.viewModel.audioError,
                "The iPhone could not start call-compatible WebRTC playback."
            )
            XCTAssertTrue(
                harness.viewModel.audioDiagnostic?.contains(
                    "native callback/frame cadence and inbound RTP advancement"
                ) == true
            )
            XCTAssertTrue(harness.viewModel.hasActiveSession)
            XCTAssertNil(harness.viewModel.audioPlayoutOracle)
            XCTAssertNil(harness.viewModel.worldwideHostedCallPlayoutOracle)
        }
    }

    func testHostedCallStaleStatisticsAreTotalNoOpForPeerAndGenerationMismatch() async throws {
        try await withHostedCallProofHarness { harness in
            let state = try await driveHostedCallProofToReady(harness)
            let authorization = state.start.authorization
            let beforeProjection = state.readyProjection
            let beforeStatistics = harness.viewModel.statistics
            let beforePublished = PublishedAudioState(harness.viewModel)
            let beforeRemoteAudioEnabled = harness.fixture.remoteAudio.isEnabled
            let beforeOracle = try XCTUnwrap(
                harness.viewModel.worldwideHostedCallPlayoutOracle
            )
            let authorizationGeneration = authorization.systemAudioGeneration
            let floor = try XCTUnwrap(beforeProjection.steadyFloor)

            harness.diagnostics.set(
                hostedCallIOSPlayoutDiagnostics(
                    authorization: authorization,
                    callbacks: floor.callbackCount + 10,
                    frames: floor.frameCount + 4_800,
                    pcmNonzeroSampleCount: floor.pcmNonzeroSampleCount + 100,
                    pcmAbsoluteSampleSum: floor.pcmAbsoluteSampleSum + 100_000
                )
            )
            let wrongPeerSnapshot = hostedCallStatisticsSnapshot(
                collectedAt: floor.statisticsCollectedAt.addingTimeInterval(1),
                bytes: try XCTUnwrap(floor.inboundBytes) + 1_000,
                packets: try XCTUnwrap(floor.inboundPackets) + 100,
                jitterBufferEmittedCount:
                    try XCTUnwrap(floor.inboundJitterBufferEmittedCount) + 1_000,
                totalSamplesReceived:
                    try XCTUnwrap(floor.inboundTotalSamplesReceived) + 4_800,
                totalAudioEnergy:
                    try XCTUnwrap(floor.inboundTotalAudioEnergy) + 1,
                totalSamplesDuration:
                    try XCTUnwrap(floor.inboundTotalSamplesDuration) + 0.1
            )
            let wrongGenerationSnapshot = hostedCallStatisticsSnapshot(
                collectedAt: floor.statisticsCollectedAt.addingTimeInterval(2),
                bytes: try XCTUnwrap(floor.inboundBytes) + 2_000,
                packets: try XCTUnwrap(floor.inboundPackets) + 200,
                jitterBufferEmittedCount:
                    try XCTUnwrap(floor.inboundJitterBufferEmittedCount) + 2_000,
                totalSamplesReceived:
                    try XCTUnwrap(floor.inboundTotalSamplesReceived) + 9_600,
                totalAudioEnergy:
                    try XCTUnwrap(floor.inboundTotalAudioEnergy) + 2,
                totalSamplesDuration:
                    try XCTUnwrap(floor.inboundTotalSamplesDuration) + 0.2
            )
            let stalePeer = try makeAudioRacePeer()
            do {
                await harness.viewModel.debugDriveIOSHostedCallStatisticsForTests(
                    wrongPeerSnapshot,
                    from: stalePeer,
                    generation: harness.generation
                )
                let afterWrongPeer = try XCTUnwrap(
                    harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
                )
                XCTAssertEqual(
                    harness.viewModel.statistics,
                    beforeStatistics,
                    "Statistics from a different peer must not be published."
                )
                XCTAssertEqual(afterWrongPeer, beforeProjection)
                XCTAssertEqual(afterWrongPeer.timeoutID, beforeProjection.timeoutID)
                XCTAssertEqual(afterWrongPeer.steadyFloor, beforeProjection.steadyFloor)
                XCTAssertEqual(PublishedAudioState(harness.viewModel), beforePublished)
                XCTAssertEqual(harness.fixture.remoteAudio.isEnabled, beforeRemoteAudioEnabled)
                XCTAssertEqual(harness.viewModel.worldwideHostedCallPlayoutOracle, beforeOracle)
                XCTAssertTrue(authorization.isValid)
                XCTAssertFalse(authorization.isRecoveryPending)
                XCTAssertEqual(authorization.systemAudioGeneration, authorizationGeneration)

                let wrongGeneration = UUID(
                    uuidString: "22222222-2222-2222-2222-222222222222"
                )!
                XCTAssertNotEqual(wrongGeneration, harness.generation)
                await harness.viewModel.debugDriveIOSHostedCallStatisticsForTests(
                    wrongGenerationSnapshot,
                    from: harness.peer,
                    generation: wrongGeneration
                )
                let afterWrongGeneration = try XCTUnwrap(
                    harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
                )
                XCTAssertEqual(
                    harness.viewModel.statistics,
                    beforeStatistics,
                    "Statistics from the wrong session generation must not be published."
                )
                XCTAssertEqual(afterWrongGeneration, beforeProjection)
                XCTAssertEqual(afterWrongGeneration.timeoutID, beforeProjection.timeoutID)
                XCTAssertEqual(afterWrongGeneration.steadyFloor, beforeProjection.steadyFloor)
                XCTAssertEqual(PublishedAudioState(harness.viewModel), beforePublished)
                XCTAssertEqual(harness.fixture.remoteAudio.isEnabled, beforeRemoteAudioEnabled)
                XCTAssertEqual(harness.viewModel.worldwideHostedCallPlayoutOracle, beforeOracle)
                XCTAssertTrue(authorization.isValid)
                XCTAssertFalse(authorization.isRecoveryPending)
                XCTAssertEqual(authorization.systemAudioGeneration, authorizationGeneration)
                XCTAssertEqual(harness.recovery.requestCount, 1)
                XCTAssertNil(harness.viewModel.audioPlayoutOracle)

                let staleOwnedSnapshot = hostedCallStatisticsSnapshot(
                    collectedAt: floor.statisticsCollectedAt,
                    bytes: try XCTUnwrap(floor.inboundBytes) + 3_000,
                    packets: try XCTUnwrap(floor.inboundPackets) + 300,
                    jitterBufferEmittedCount:
                        try XCTUnwrap(floor.inboundJitterBufferEmittedCount) + 3_000,
                    totalSamplesReceived:
                        try XCTUnwrap(floor.inboundTotalSamplesReceived) + 14_400,
                    totalAudioEnergy:
                        try XCTUnwrap(floor.inboundTotalAudioEnergy) + 3,
                    totalSamplesDuration:
                        try XCTUnwrap(floor.inboundTotalSamplesDuration) + 0.3
                )
                await harness.viewModel.debugDriveIOSHostedCallStatisticsForTests(
                    staleOwnedSnapshot,
                    from: harness.peer,
                    generation: harness.generation
                )
                XCTAssertEqual(
                    harness.viewModel.worldwideHostedCallPlayoutOracle,
                    beforeOracle,
                    "An owned statistics sample with a non-fresh timestamp must not replace the oracle."
                )
                XCTAssertEqual(
                    try XCTUnwrap(
                        harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
                    ),
                    beforeProjection
                )
                XCTAssertTrue(authorization.isValid)
                XCTAssertFalse(authorization.isRecoveryPending)
                XCTAssertEqual(
                    authorization.systemAudioGeneration,
                    authorizationGeneration
                )
            } catch {
                await stalePeer.close()
                throw error
            }
            await stalePeer.close()
        }
    }

    func testHostedCallOracleClearsSynchronouslyOnCallEndRevocationAndDisconnect() async throws {
        try await withHostedCallProofHarness { harness in
            let state = try await driveHostedCallProofToReady(harness)
            let authorization = state.start.authorization
            let hostedPolicyGeneration =
                state.readyProjection.audioPolicyGeneration
            XCTAssertNotNil(harness.viewModel.worldwideHostedCallPlayoutOracle)

            harness.fixture.callActivity.setCallSnapshot(
                nonEndedCallCount: 0,
                connectedNonEndedCallCount: 0
            )
            harness.fixture.events.onInterruptionEnded?(true)

            XCTAssertNil(harness.viewModel.worldwideHostedCallPlayoutOracle)
            XCTAssertNil(
                harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
            )
            XCTAssertFalse(authorization.isValid)
            XCTAssertNotEqual(
                harness.viewModel.debugAudioPolicyGeneration,
                hostedPolicyGeneration,
                "Final ordinary recovery must rotate beyond the hosted-call policy."
            )
        }

        try await withHostedCallProofHarness { harness in
            let state = try await driveHostedCallProofToReady(harness)
            let authorization = state.start.authorization
            XCTAssertNotNil(harness.viewModel.worldwideHostedCallPlayoutOracle)

            harness.viewModel.disconnect()

            XCTAssertNil(harness.viewModel.worldwideHostedCallPlayoutOracle)
            XCTAssertNil(
                harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
            )
            XCTAssertFalse(authorization.isValid)
        }
    }

    func testPhysicalSnapshotMapsEveryNativeContentAndContinuityCounter() throws {
        let diagnostics = iosPlayoutDiagnostics(
            callbacks: 20,
            frames: 9_600,
            failures: 0,
            pcmClippedSampleCount: 3,
            explicitSilenceCallbackCount: 4,
            callbackGapViolationCount: 5,
            maximumCallbackGapNanoseconds: 300_000_000,
            nearSilenceCallbackCount: 6,
            currentConsecutiveNearSilenceFrameCount: 480,
            maximumConsecutiveNearSilenceFrameCount: 960,
            pcmLeftZeroCrossingCount: 398,
            pcmRightZeroCrossingCount: 598,
            pcmEnvelopeTransitionCount: 8,
            pcmShapeAnomalyCallbackCount: 9,
            pcmBoundaryDiscontinuityCallbackCount: 10,
            lastCallbackMeanMagnitude: 1_234,
            recoveryRebuildCount: 7
        )
        let audioPolicyGeneration = UUID()
        let snapshot = WorldwideAudioPlayoutOracleSnapshot(
            sessionGeneration: UUID(),
            audioPolicyGeneration: audioPolicyGeneration,
            diagnostics: diagnostics,
            inboundAudio: WebRTCAudioStatistics(
                totalAudioEnergy: 0.05,
                totalSamplesDuration: 0.2
            )
        )
        let parsed = try XCTUnwrap(
            PhysicalAudioPlayoutSnapshot(accessibilityValue: snapshot.accessibilityValue)
        )
        XCTAssertEqual(
            parsed.audioPolicyGeneration,
            audioPolicyGeneration
        )
        XCTAssertEqual(parsed.callbackCount, diagnostics.playoutCallbackCount)
        XCTAssertEqual(parsed.frameCount, diagnostics.playoutFrameCount)
        XCTAssertEqual(parsed.pcmSampleCount, diagnostics.playoutPCMSampleCount)
        XCTAssertEqual(
            parsed.pcmNonzeroSampleCount,
            diagnostics.playoutPCMNonzeroSampleCount
        )
        XCTAssertEqual(parsed.pcmAbsoluteSampleSum, diagnostics.playoutPCMAbsoluteSampleSum)
        XCTAssertEqual(
            parsed.pcmLeftAbsoluteSampleSum,
            diagnostics.playoutPCMLeftAbsoluteSampleSum
        )
        XCTAssertEqual(
            parsed.pcmRightAbsoluteSampleSum,
            diagnostics.playoutPCMRightAbsoluteSampleSum
        )
        XCTAssertEqual(
            parsed.pcmStereoDifferenceAbsoluteSampleSum,
            diagnostics.playoutPCMStereoDifferenceAbsoluteSampleSum
        )
        XCTAssertEqual(parsed.pcmClippedSampleCount, 3)
        XCTAssertEqual(parsed.explicitSilenceCallbackCount, 4)
        XCTAssertEqual(parsed.callbackGapViolationCount, 5)
        XCTAssertEqual(parsed.maximumCallbackGapNanoseconds, 300_000_000)
        XCTAssertEqual(parsed.nearSilenceCallbackCount, 6)
        XCTAssertEqual(parsed.currentConsecutiveNearSilenceFrameCount, 480)
        XCTAssertEqual(parsed.maximumConsecutiveNearSilenceFrameCount, 960)
        XCTAssertEqual(parsed.pcmLeftZeroCrossingCount, 398)
        XCTAssertEqual(parsed.pcmRightZeroCrossingCount, 598)
        XCTAssertEqual(parsed.pcmEnvelopeTransitionCount, 8)
        XCTAssertEqual(parsed.pcmShapeAnomalyCallbackCount, 9)
        XCTAssertEqual(parsed.pcmBoundaryDiscontinuityCallbackCount, 10)
        XCTAssertEqual(parsed.lastCallbackMeanMagnitude, 1_234)
        XCTAssertEqual(parsed.recoveryRebuildCount, 7)
        XCTAssertEqual(parsed.lastPeakMagnitude, diagnostics.lastPlayoutPeakMagnitude)
        XCTAssertEqual(parsed.inboundAudioEnergy, 0.05)
        XCTAssertEqual(parsed.inboundSamplesDuration, 0.2)
    }

    func testPhysicalFullQualityPredicateRejectsEveryOneFieldMutation() {
        let sessionGeneration = UUID()
        let inboundAudio = WebRTCAudioStatistics(
            totalAudioEnergy: 0.025,
            totalSamplesDuration: 0.1
        )
        let healthy = iosPlayoutDiagnostics(callbacks: 10, frames: 4_800, failures: 0)
        XCTAssertTrue(WorldwideAudioPlayoutOracleSnapshot.fullQualityInvariantsHold(healthy))
        let healthySnapshot = WorldwideAudioPlayoutOracleSnapshot(
            sessionGeneration: sessionGeneration,
            audioPolicyGeneration: UUID(),
            diagnostics: healthy,
            inboundAudio: inboundAudio
        )
        XCTAssertTrue(healthySnapshot.fullQualityInvariantsHold)
        XCTAssertTrue(
            PhysicalAudioPlayoutSnapshot(
                accessibilityValue: healthySnapshot.accessibilityValue
            )?.fullQualityInvariantsHold == true
        )

        let mutants: [String: WebRTCIOSPlayoutDiagnostics] = [
            "not-initialized": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0, initialized: false
            ),
            "playout-not-initialized": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0, playoutInitialized: false
            ),
            "not-playing": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0, playing: false
            ),
            "session-inactive": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0, sessionActive: false
            ),
            "activation-not-owned": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0, ownsSessionActivation: false
            ),
            "remote-io-missing": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0, remoteIOCreated: false
            ),
            "input-bus-enabled": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0, inputBusEnabled: true
            ),
            "output-bus-disabled": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0, outputBusEnabled: false
            ),
            "recovery-required": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0, recoveryRequired: true
            ),
            "resume-required": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0, explicitResumeRequired: true
            ),
            "call-category": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0,
                categoryIsMediaPlayback: false
            ),
            "call-mode": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0, modeIsDefault: false
            ),
            "category-options": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0,
                categoryOptionsAreEmpty: false
            ),
            "route-sharing-policy": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0,
                routeSharingPolicyIsDefault: false
            ),
            "sample-rate": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0, sampleRate: 44_100
            ),
            "high-latency-buffer": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0,
                outputIOBufferDuration: 0.100
            ),
            "mono": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0, outputChannelCount: 1
            ),
            "voice-processing-io": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0,
                audioUnitSubType: kAudioUnitSubType_VoiceProcessingIO
            ),
            "lifecycle-failure-code": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0,
                failureCode: 1, lastLifecycleStatus: noErr
            ),
            "lifecycle-status": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0,
                lastLifecycleStatus: -50
            ),
            "render-status": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0, lastStatus: -50
            ),
            "historical-render-failure": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 1
            ),
            "recording-request": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0,
                unexpectedRecordingRequests: 1
            ),
            "zero-last-render": iosPlayoutDiagnostics(
                callbacks: 10, frames: 4_800, failures: 0,
                lastPlayoutFrameCount: 0
            ),
        ]
        let expectedNames: Set<String> = [
            "not-initialized", "playout-not-initialized", "not-playing",
            "session-inactive", "activation-not-owned", "remote-io-missing",
            "input-bus-enabled", "output-bus-disabled", "recovery-required",
            "resume-required", "call-category", "call-mode", "category-options",
            "route-sharing-policy", "sample-rate", "high-latency-buffer", "mono",
            "voice-processing-io",
            "lifecycle-failure-code", "lifecycle-status", "render-status",
            "historical-render-failure", "recording-request", "zero-last-render",
        ]
        XCTAssertEqual(Set(mutants.keys), expectedNames)
        XCTAssertEqual(mutants.count, expectedNames.count)
        for name in expectedNames.sorted() {
            let mutant = mutants[name]!
            XCTAssertFalse(
                WorldwideAudioPlayoutOracleSnapshot.fullQualityInvariantsHold(mutant),
                "Full-quality route mutant escaped: \(name)"
            )
            let productionSnapshot = WorldwideAudioPlayoutOracleSnapshot(
                sessionGeneration: sessionGeneration,
                audioPolicyGeneration: UUID(),
                diagnostics: mutant,
                inboundAudio: inboundAudio
            )
            XCTAssertFalse(
                productionSnapshot.fullQualityInvariantsHold,
                "Snapshot initializer ignored route mutant: \(name)"
            )
            XCTAssertFalse(
                PhysicalAudioPlayoutSnapshot(
                    accessibilityValue: productionSnapshot.accessibilityValue
                )?.fullQualityInvariantsHold ?? true,
                "Serialized/parser pipeline ignored route mutant: \(name)"
            )
        }
    }

    func testPhysicalFullQualityPredicateAcceptsMicrophoneTopologyAndRejectsOmittedMutants() {
        let sessionGeneration = UUID()
        let inboundAudio = WebRTCAudioStatistics(
            totalAudioEnergy: 0.025,
            totalSamplesDuration: 0.1
        )
        let healthy = iosPlayoutDiagnostics(
            callbacks: 10,
            frames: 4_800,
            failures: 0,
            inputBusEnabled: true,
            categoryIsMediaPlayback: false,
            categoryIsMediaPlayAndRecord: true
        )

        XCTAssertTrue(
            WorldwideAudioPlayoutOracleSnapshot.fullQualityInvariantsHold(
                healthy
            )
        )
        let healthySnapshot = WorldwideAudioPlayoutOracleSnapshot(
            sessionGeneration: sessionGeneration,
            audioPolicyGeneration: UUID(),
            diagnostics: healthy,
            inboundAudio: inboundAudio
        )
        XCTAssertTrue(healthySnapshot.fullQualityInvariantsHold)
        XCTAssertTrue(
            PhysicalAudioPlayoutSnapshot(
                accessibilityValue: healthySnapshot.accessibilityValue
            )?.fullQualityInvariantsHold == true
        )

        let mutants: [String: WebRTCIOSPlayoutDiagnostics] = [
            "playback-category-also-true": iosPlayoutDiagnostics(
                callbacks: 10,
                frames: 4_800,
                failures: 0,
                inputBusEnabled: true,
                categoryIsMediaPlayback: true,
                categoryIsMediaPlayAndRecord: true
            ),
            "play-and-record-category-missing": iosPlayoutDiagnostics(
                callbacks: 10,
                frames: 4_800,
                failures: 0,
                inputBusEnabled: true,
                categoryIsMediaPlayback: false,
                categoryIsMediaPlayAndRecord: false
            ),
            "empty-options-also-true": iosPlayoutDiagnostics(
                callbacks: 10,
                frames: 4_800,
                failures: 0,
                inputBusEnabled: true,
                categoryIsMediaPlayback: false,
                categoryIsMediaPlayAndRecord: true,
                categoryOptionsAreEmpty: true
            ),
            "exact-microphone-options-missing": iosPlayoutDiagnostics(
                callbacks: 10,
                frames: 4_800,
                failures: 0,
                inputBusEnabled: true,
                categoryIsMediaPlayback: false,
                categoryIsMediaPlayAndRecord: true,
                categoryOptionsAreIPhoneMicrophoneRouting: false
            ),
            "mix-options-also-true": iosPlayoutDiagnostics(
                callbacks: 10,
                frames: 4_800,
                failures: 0,
                inputBusEnabled: true,
                categoryIsMediaPlayback: false,
                categoryIsMediaPlayAndRecord: true,
                categoryOptionsAreMixWithOthers: true
            ),
            "zero-buffer-duration": iosPlayoutDiagnostics(
                callbacks: 10,
                frames: 4_800,
                failures: 0,
                inputBusEnabled: true,
                categoryIsMediaPlayback: false,
                categoryIsMediaPlayAndRecord: true,
                outputIOBufferDuration: 0
            ),
            "high-latency-buffer": iosPlayoutDiagnostics(
                callbacks: 10,
                frames: 4_800,
                failures: 0,
                inputBusEnabled: true,
                categoryIsMediaPlayback: false,
                categoryIsMediaPlayAndRecord: true,
                outputIOBufferDuration: 0.100
            ),
            "voice-processing-io": iosPlayoutDiagnostics(
                callbacks: 10,
                frames: 4_800,
                failures: 0,
                inputBusEnabled: true,
                categoryIsMediaPlayback: false,
                categoryIsMediaPlayAndRecord: true,
                audioUnitSubType: kAudioUnitSubType_VoiceProcessingIO
            ),
            "recording-request": iosPlayoutDiagnostics(
                callbacks: 10,
                frames: 4_800,
                failures: 0,
                unexpectedRecordingRequests: 1,
                inputBusEnabled: true,
                categoryIsMediaPlayback: false,
                categoryIsMediaPlayAndRecord: true
            ),
            "zero-last-render": iosPlayoutDiagnostics(
                callbacks: 10,
                frames: 4_800,
                failures: 0,
                inputBusEnabled: true,
                categoryIsMediaPlayback: false,
                categoryIsMediaPlayAndRecord: true,
                lastPlayoutFrameCount: 0
            ),
        ]

        for name in mutants.keys.sorted() {
            let mutant = mutants[name]!
            XCTAssertFalse(
                WorldwideAudioPlayoutOracleSnapshot
                    .fullQualityInvariantsHold(mutant),
                "Microphone full-quality route mutant escaped: \(name)"
            )
            let productionSnapshot = WorldwideAudioPlayoutOracleSnapshot(
                sessionGeneration: sessionGeneration,
                audioPolicyGeneration: UUID(),
                diagnostics: mutant,
                inboundAudio: inboundAudio
            )
            XCTAssertFalse(
                productionSnapshot.fullQualityInvariantsHold,
                "Microphone snapshot initializer ignored route mutant: \(name)"
            )
            XCTAssertFalse(
                PhysicalAudioPlayoutSnapshot(
                    accessibilityValue: productionSnapshot.accessibilityValue
                )?.fullQualityInvariantsHold ?? true,
                "Microphone serialized/parser pipeline ignored route mutant: \(name)"
            )
        }
    }

    func testHistoricalCallbackCannotProveANewCounterWindow() {
        let (viewModel, _) = makePreparedProofViewModel()
        let handle = viewModel.debugStartIOSPlayoutProofAttemptForTests(
            requestRecovery: false
        )

        XCTAssertEqual(viewModel.audioStateText, "Starting playback")
        XCTAssertFalse(viewModel.isRemoteAudioPlaying)
        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 10, frames: 4_800, failures: 0),
                handle: handle,
                source: .polling
            )
        )
        XCTAssertEqual(viewModel.debugIOSPlayoutProofState.callbackFloor, 10)
        XCTAssertEqual(viewModel.debugIOSPlayoutProofState.frameFloor, 4_800)
        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 10, frames: 4_800, failures: 0),
                handle: handle,
                source: .statistics
            )
        )
        XCTAssertTrue(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 11, frames: 5_280, failures: 0),
                handle: handle,
                source: .polling
            )
        )
        XCTAssertEqual(viewModel.audioStateText, "Playing")
        XCTAssertTrue(viewModel.isRemoteAudioPlaying)
    }

    func testHistoricalFailureRecoveryUsesCapturedFailureFloor() throws {
        let (viewModel, _) = makePreparedProofViewModel()
        let preRecovery = iosPlayoutDiagnostics(
            callbacks: 20,
            frames: 9_600,
            failures: 4
        )
        let handle = viewModel.debugStartIOSPlayoutProofAttemptForTests(
            requestRecovery: true,
            preRecoveryDiagnostics: preRecovery
        )
        let authorization = try XCTUnwrap(
            viewModel.debugIOSPlayoutRecoveryAuthorizationForTests
        )

        XCTAssertEqual(viewModel.debugIOSPlayoutProofState.permittedFailureFloor, 4)
        XCTAssertEqual(
            viewModel.debugIOSPlayoutProofState.stage,
            .awaitingRecoveryAuthorization
        )
        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 21, frames: 10_080, failures: 4),
                handle: handle,
                source: .statistics
            )
        )
        XCTAssertNil(viewModel.debugIOSPlayoutProofState.callbackFloor)
        XCTAssertTrue(authorization.performIfValidForTesting {})

        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 22, frames: 10_560, failures: 4),
                handle: handle,
                source: .polling
            )
        )
        XCTAssertEqual(viewModel.debugIOSPlayoutProofState.callbackFloor, 22)
        XCTAssertEqual(viewModel.debugIOSPlayoutProofState.frameFloor, 10_560)
        XCTAssertEqual(
            viewModel.debugIOSPlayoutProofState.stage,
            .awaitingFreshEvidence
        )
        XCTAssertTrue(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 23, frames: 11_040, failures: 4),
                handle: handle,
                source: .statistics
            )
        )
        XCTAssertEqual(viewModel.audioStateText, "Playing")
    }

    func testNewRecoveryFailureCannotBecomeTheCapturedFloor() throws {
        let (viewModel, _) = makePreparedProofViewModel()
        let handle = viewModel.debugStartIOSPlayoutProofAttemptForTests(
            requestRecovery: true,
            preRecoveryDiagnostics: iosPlayoutDiagnostics(
                callbacks: 30,
                frames: 14_400,
                failures: 7
            )
        )
        let authorization = try XCTUnwrap(
            viewModel.debugIOSPlayoutRecoveryAuthorizationForTests
        )
        XCTAssertEqual(
            viewModel.debugIOSPlayoutProofState.permittedFailureFloor,
            7,
            "The pre-request failure count is the immutable recovery window floor."
        )
        XCTAssertTrue(authorization.performIfValidForTesting {})

        XCTAssertTrue(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(
                    callbacks: 31,
                    frames: 14_880,
                    failures: 8
                ),
                handle: handle,
                source: .polling
            )
        )
        XCTAssertEqual(viewModel.audioStateText, "Playback unavailable")
        XCTAssertFalse(viewModel.isRemoteAudioPlaying)
        XCTAssertNil(viewModel.debugIOSPlayoutProofState.handle)
        XCTAssertFalse(authorization.isValid)
    }

    func testFirstPostAuthorizationSnapshotIsFloorEvenForIdempotentRecovery() throws {
        let (viewModel, _) = makePreparedProofViewModel()
        let handle = viewModel.debugStartIOSPlayoutProofAttemptForTests(
            requestRecovery: true,
            preRecoveryDiagnostics: iosPlayoutDiagnostics(
                callbacks: 100,
                frames: 48_000,
                failures: 0
            )
        )
        let authorization = try XCTUnwrap(
            viewModel.debugIOSPlayoutRecoveryAuthorizationForTests
        )
        XCTAssertTrue(authorization.performIfValidForTesting {})

        let firstPostAuthorization = iosPlayoutDiagnostics(
            callbacks: 101,
            frames: 48_480,
            failures: 0
        )
        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                firstPostAuthorization,
                handle: handle,
                source: .polling
            )
        )
        XCTAssertEqual(viewModel.debugIOSPlayoutProofState.callbackFloor, 101)
        XCTAssertEqual(viewModel.debugIOSPlayoutProofState.frameFloor, 48_480)
        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                firstPostAuthorization,
                handle: handle,
                source: .statistics
            )
        )
        XCTAssertTrue(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(
                    callbacks: 102,
                    frames: 48_960,
                    failures: 0
                ),
                handle: handle,
                source: .statistics
            )
        )
    }

    func testPendingRecoveryAuthorizationBlocksAllCounterEvaluation() throws {
        let (viewModel, _) = makePreparedProofViewModel()
        let handle = viewModel.debugStartIOSPlayoutProofAttemptForTests(
            requestRecovery: true,
            preRecoveryDiagnostics: iosPlayoutDiagnostics(
                callbacks: 40,
                frames: 19_200,
                failures: 2
            )
        )
        let authorization = try XCTUnwrap(
            viewModel.debugIOSPlayoutRecoveryAuthorizationForTests
        )

        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(
                    callbacks: 41,
                    frames: 19_680,
                    failures: 3,
                    lastStatus: -50
                ),
                handle: handle,
                source: .statistics
            )
        )
        XCTAssertTrue(authorization.isValid)
        XCTAssertNil(viewModel.debugIOSPlayoutProofState.callbackFloor)
        XCTAssertNil(viewModel.debugIOSPlayoutProofState.lastCallbackCount)
        XCTAssertEqual(viewModel.audioStateText, "Starting playback")
        XCTAssertFalse(viewModel.isRemoteAudioPlaying)
    }

    func testTimedOutProofSynchronouslyRevokesExactAuthorization() async throws {
        let (viewModel, _) = makePreparedProofViewModel()
        let handle = viewModel.debugStartIOSPlayoutProofAttemptForTests(
            requestRecovery: true,
            preRecoveryDiagnostics: iosPlayoutDiagnostics(
                callbacks: 50,
                frames: 24_000,
                failures: 0
            )
        )
        let authorization = try XCTUnwrap(
            viewModel.debugIOSPlayoutRecoveryAuthorizationForTests
        )
        let authorizationIdentity = ObjectIdentifier(authorization)
        let queuedRecoveryGate = AudioNonCooperativeGate<Void>()
        let delayedNativeRecoveryCount = AudioLockedInteger()
        let delayedNativeRecovery = Task {
            await queuedRecoveryGate.wait()
            _ = authorization.performIfValidForTesting {
                delayedNativeRecoveryCount.increment()
            }
        }
        await queuedRecoveryGate.waitUntilBlocked()
        XCTAssertEqual(
            viewModel.debugIOSPlayoutProofState.recoveryAuthorizationIdentity,
            authorizationIdentity
        )

        viewModel.debugTimeoutIOSPlayoutProofForTests(handle: handle)

        XCTAssertFalse(authorization.isValid)
        XCTAssertNil(viewModel.debugIOSPlayoutProofState.handle)
        XCTAssertNil(viewModel.debugIOSPlayoutProofState.recoveryAuthorizationIdentity)
        XCTAssertEqual(viewModel.audioStateText, "Playback unavailable")

        await queuedRecoveryGate.open(())
        await delayedNativeRecovery.value
        XCTAssertEqual(
            delayedNativeRecoveryCount.value,
            0,
            "A timed-out authorization must not rebuild later when queued native work resumes."
        )
    }

    func testStaleSameSessionProofAttemptCannotRefreshCurrentAttempt() {
        let (viewModel, _) = makePreparedProofViewModel()
        let attemptA = viewModel.debugStartIOSPlayoutProofAttemptForTests(
            requestRecovery: false
        )
        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 60, frames: 28_800, failures: 0),
                handle: attemptA,
                source: .polling
            )
        )

        let attemptB = viewModel.debugStartIOSPlayoutProofAttemptForTests(
            requestRecovery: false
        )
        XCTAssertNotEqual(attemptA.proofAttemptID, attemptB.proofAttemptID)
        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 61, frames: 29_280, failures: 0),
                handle: attemptA,
                source: .statistics
            )
        )
        XCTAssertEqual(viewModel.debugIOSPlayoutProofState.handle, attemptB)
        XCTAssertNil(viewModel.debugIOSPlayoutProofState.callbackFloor)
        XCTAssertEqual(viewModel.audioStateText, "Starting playback")
        XCTAssertFalse(viewModel.isRemoteAudioPlaying)
    }

    func testProofAttemptIdentityFencesSameCounterWindow() {
        let (viewModel, _) = makePreparedProofViewModel()
        let handle = viewModel.debugStartIOSPlayoutProofAttemptForTests(
            requestRecovery: false
        )
        let wrongAttempt = WorldwideIOSPlayoutProofDebugHandle(
            proofAttemptID: UUID(),
            counterWindowID: handle.counterWindowID,
            sessionGeneration: handle.sessionGeneration,
            audioPolicyGeneration: handle.audioPolicyGeneration
        )

        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 65, frames: 31_200, failures: 0),
                handle: wrongAttempt,
                source: .statistics
            )
        )
        let wrongPolicy = WorldwideIOSPlayoutProofDebugHandle(
            proofAttemptID: handle.proofAttemptID,
            counterWindowID: handle.counterWindowID,
            sessionGeneration: handle.sessionGeneration,
            audioPolicyGeneration: UUID()
        )
        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 65, frames: 31_200, failures: 0),
                handle: wrongPolicy,
                source: .statistics
            )
        )
        XCTAssertEqual(viewModel.debugIOSPlayoutProofState.handle, handle)
        XCTAssertNil(viewModel.debugIOSPlayoutProofState.callbackFloor)
        XCTAssertNil(viewModel.debugIOSPlayoutProofState.frameFloor)
        XCTAssertEqual(viewModel.audioStateText, "Starting playback")
        XCTAssertFalse(viewModel.isRemoteAudioPlaying)
    }

    func testCounterWindowIdentityFencesSameProofAttempt() {
        let (viewModel, _) = makePreparedProofViewModel()
        let handle = viewModel.debugStartIOSPlayoutProofAttemptForTests(
            requestRecovery: false
        )
        let wrongWindow = WorldwideIOSPlayoutProofDebugHandle(
            proofAttemptID: handle.proofAttemptID,
            counterWindowID: UUID(),
            sessionGeneration: handle.sessionGeneration,
            audioPolicyGeneration: handle.audioPolicyGeneration
        )

        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 66, frames: 31_680, failures: 0),
                handle: wrongWindow,
                source: .statistics
            )
        )
        XCTAssertEqual(viewModel.debugIOSPlayoutProofState.handle, handle)
        XCTAssertNil(viewModel.debugIOSPlayoutProofState.callbackFloor)
        XCTAssertNil(viewModel.debugIOSPlayoutProofState.frameFloor)
        XCTAssertNil(viewModel.debugIOSPlayoutProofState.lastCallbackCount)
        XCTAssertEqual(viewModel.audioStateText, "Starting playback")
        XCTAssertFalse(viewModel.isRemoteAudioPlaying)
    }

    func testStatisticsRefreshUsesExactCounterWindow() {
        let (viewModel, _) = makePreparedProofViewModel()
        let handle = viewModel.debugStartIOSPlayoutProofAttemptForTests(
            requestRecovery: false
        )
        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 70, frames: 33_600, failures: 0),
                handle: handle,
                source: .polling
            )
        )
        let wrongWindow = WorldwideIOSPlayoutProofDebugHandle(
            proofAttemptID: handle.proofAttemptID,
            counterWindowID: UUID(),
            sessionGeneration: handle.sessionGeneration,
            audioPolicyGeneration: handle.audioPolicyGeneration
        )
        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 71, frames: 34_080, failures: 0),
                handle: wrongWindow,
                source: .statistics
            )
        )
        XCTAssertEqual(viewModel.debugIOSPlayoutProofState.lastCallbackCount, 70)
        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 70, frames: 33_600, failures: 0),
                handle: handle,
                source: .statistics
            )
        )
        XCTAssertTrue(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 71, frames: 34_080, failures: 0),
                handle: handle,
                source: .statistics
            )
        )
    }

    func testCounterRegressionFailsCurrentWindowClosed() {
        let (viewModel, _) = makePreparedProofViewModel()
        let handle = viewModel.debugStartIOSPlayoutProofAttemptForTests(
            requestRecovery: false
        )
        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 80, frames: 38_400, failures: 0),
                handle: handle,
                source: .polling
            )
        )
        XCTAssertTrue(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 79, frames: 37_920, failures: 0),
                handle: handle,
                source: .statistics
            )
        )
        XCTAssertEqual(viewModel.audioStateText, "Playback unavailable")
        XCTAssertFalse(viewModel.isRemoteAudioPlaying)
        XCTAssertTrue(
            viewModel.audioDiagnostic?.contains("regressed") == true,
            viewModel.audioDiagnostic ?? "Missing counter-regression diagnostic"
        )
        XCTAssertEqual(
            viewModel.audioDiagnostic,
            "RemoteIO callback counter regressed from 80 to 79."
        )
    }

    func testFrameCounterRegressionFailsCurrentWindowClosed() {
        let (viewModel, _) = makePreparedProofViewModel()
        let handle = viewModel.debugStartIOSPlayoutProofAttemptForTests(
            requestRecovery: false
        )
        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 80, frames: 38_400, failures: 0),
                handle: handle,
                source: .polling
            )
        )
        XCTAssertTrue(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 81, frames: 37_920, failures: 0),
                handle: handle,
                source: .statistics
            )
        )
        XCTAssertEqual(viewModel.audioStateText, "Playback unavailable")
        XCTAssertFalse(viewModel.isRemoteAudioPlaying)
        XCTAssertEqual(
            viewModel.audioDiagnostic,
            "RemoteIO frame counter regressed from 38400 to 37920."
        )
    }

    func testFailureCounterRegressionFailsRecoveryWindowClosed() throws {
        let (viewModel, _) = makePreparedProofViewModel()
        let handle = viewModel.debugStartIOSPlayoutProofAttemptForTests(
            requestRecovery: true,
            preRecoveryDiagnostics: iosPlayoutDiagnostics(
                callbacks: 90,
                frames: 43_200,
                failures: 3
            )
        )
        let authorization = try XCTUnwrap(
            viewModel.debugIOSPlayoutRecoveryAuthorizationForTests
        )
        XCTAssertTrue(authorization.performIfValidForTesting {})
        XCTAssertFalse(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 91, frames: 43_680, failures: 3),
                handle: handle,
                source: .polling
            )
        )

        XCTAssertTrue(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 92, frames: 44_160, failures: 2),
                handle: handle,
                source: .statistics
            )
        )
        XCTAssertEqual(viewModel.audioStateText, "Playback unavailable")
        XCTAssertFalse(viewModel.isRemoteAudioPlaying)
        XCTAssertEqual(
            viewModel.audioDiagnostic,
            "RemoteIO failure counter regressed from 3 to 2."
        )
    }

    func testRecoveryCounterRegressionAgainstPreRequestSnapshotFailsClosed() throws {
        let (viewModel, _) = makePreparedProofViewModel()
        let handle = viewModel.debugStartIOSPlayoutProofAttemptForTests(
            requestRecovery: true,
            preRecoveryDiagnostics: iosPlayoutDiagnostics(
                callbacks: 90,
                frames: 43_200,
                failures: 3
            )
        )
        let authorization = try XCTUnwrap(
            viewModel.debugIOSPlayoutRecoveryAuthorizationForTests
        )
        XCTAssertTrue(authorization.performIfValidForTesting {})

        XCTAssertTrue(
            viewModel.debugEvaluateIOSPlayoutDiagnosticsForTests(
                iosPlayoutDiagnostics(callbacks: 0, frames: 0, failures: 3),
                handle: handle,
                source: .polling
            )
        )
        XCTAssertEqual(viewModel.audioStateText, "Playback unavailable")
        XCTAssertFalse(viewModel.isRemoteAudioPlaying)
        XCTAssertTrue(
            viewModel.audioDiagnostic?.contains("regressed") == true,
            viewModel.audioDiagnostic ?? "Missing recovery counter-regression diagnostic"
        )
    }

    // MARK: - Audio lifecycle fixtures

    private enum ReentrantAudioBoundary: CaseIterable {
        case interruption
        case route
        case mediaReset
        case mediaLoss
    }

    private func deliverReentrantAudioBoundary(
        _ boundary: ReentrantAudioBoundary,
        to fixture: AudioLifecycleFixture
    ) {
        switch boundary {
        case .interruption:
            fixture.events.onInterruptionBegan?(.unavailable)
        case .route:
            fixture.events.onRouteChanged?(
                "Audio route changed: override"
            )
        case .mediaReset:
            fixture.events.onMediaServicesReset?()
        case .mediaLoss:
            fixture.events.onMediaServicesLost?()
        }
    }

    private func assertRetiredPollingProofCannotMutateReplacement(
        diagnostics: WebRTCIOSPlayoutDiagnostics,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        let oldPeer = try makeAudioRacePeer()
        let replacementPeer = try makeAudioRacePeer()
        let readStarted = expectation(description: "retired polling proof suspended")
        let proofFinished = expectation(description: "retired polling proof returned")
        let diagnosticsGate = AudioNonCooperativeGate<WebRTCIOSPlayoutDiagnostics>()
        viewModel.debugInstallIOSPlayoutDiagnosticsReader { peer in
            XCTAssertTrue(peer === oldPeer, file: file, line: line)
            readStarted.fulfill()
            return await diagnosticsGate.wait()
        }

        fixture.controller.prepare(serverName: "Old Mac")
        viewModel.debugInstallIOSPlayoutPeerForRaceTests(oldPeer)
        let oldProof = try XCTUnwrap(
            viewModel.debugBeginIOSPlayoutProofForRaceTests(requestRecovery: false),
            file: file,
            line: line
        )
        Task { @MainActor in
            await oldProof.value
            proofFinished.fulfill()
        }
        await fulfillment(of: [readStarted], timeout: 2)

        viewModel.disconnect()
        prepareReplacementAudio(fixture.controller)
        viewModel.debugInstallIOSPlayoutPeerForRaceTests(replacementPeer)
        let replacementBeforeResume = PublishedAudioState(viewModel)

        await diagnosticsGate.open(diagnostics)
        await fulfillment(of: [proofFinished], timeout: 2)

        XCTAssertEqual(
            PublishedAudioState(viewModel),
            replacementBeforeResume,
            file: file,
            line: line
        )
        viewModel.disconnect()
        await oldPeer.close()
        await replacementPeer.close()
    }

    private func rawMicrophoneSenderStatisticsForTests(
        sample: UInt64,
        counterSample: UInt64? = nil,
        recordingGeneration: UInt64,
        captureRouteIsBuiltInMicrophone: Bool = true,
        captureRouteProofGeneration: UInt64 = 13
    ) -> WebRTCIPhoneMicrophoneSenderStatistics {
        let counterSample = counterSample ?? sample
        let callbacks = counterSample * 100
        let frames = counterSample * 48_000
        let sender =
            WebRTCIPhoneMicrophoneSenderDiagnostics(
                peerEpoch: UUID(
                    uuidString:
                        "eeeeeeee-ffff-0000-0000-000000000001"
                )!,
                bindingGeneration: 3,
                negotiationEpoch: 5,
                trackGeneration: 7,
                microphonePolicyGeneration: 11,
                senderOwnsMID: true,
                senderOwnsLocalTrack: true,
                transceiverIsStopped: false,
                preferredDirectionIncludesSending: true,
                currentDirectionIncludesSending: true,
                trackIsEnabled: true,
                rawProcessingIsLive: true,
                transportIsHealthy: true,
                authorizationIsCurrent: true,
                authorizationIsValid: true,
                senderIsAdmitted: true,
                nativeDeviceIsOpen: true,
                nativeDeviceGateIsOpen: true,
                nativeAuthorizationGateIsOpen: true,
                categoryIsPlayAndRecord: true,
                modeIsDefault: true,
                usesRemoteIO: true,
                inputBusEnabled: true,
                captureRouteIsBuiltInMicrophone:
                    captureRouteIsBuiltInMicrophone,
                captureRouteProofGeneration:
                    captureRouteProofGeneration,
                outputBusEnabled: true,
                categoryOptionsAreEmpty: false,
                categoryOptionsAreIPhoneMicrophoneRouting: true,
                routeSharingPolicyIsDefault: true,
                hasOutputRoute: true,
                sampleRateIs48k: true,
                ioBufferDurationIsBounded: true,
                outputChannelCountIsStereo: true,
                recoveryRequired: false,
                explicitResumeRequired: false,
                hostedCallMode: false,
                failureCode: 0,
                lastLifecycleStatus: 0,
                recordingGeneration: recordingGeneration,
                approvedRecordingGeneration:
                    recordingGeneration,
                realtimeAdmissionCount: callbacks,
                deliveryCallbackCount: callbacks,
                deliveredFrameCount: frames
            )
        return WebRTCIPhoneMicrophoneSenderStatistics(
            collectedAt:
                Date(timeIntervalSince1970: TimeInterval(sample)),
            sender: sender,
            packetsSent: counterSample * 50,
            bytesSent: counterSample * 8_000,
            totalAudioEnergy: Double(counterSample) * 0.25,
            totalSamplesDuration: Double(counterSample),
            sourceReportWasLinked: true
        )
    }

    private func prepareReplacementAudio(_ controller: WorldwideAudioLifecycleController) {
        controller.prepare(serverName: "Replacement Mac")
        controller.updateRuntimePlayout(
            isReady: false,
            failureMessage: "Replacement sentinel failure",
            diagnostic: "Replacement sentinel diagnostic"
        )
    }

    #if DEBUG
    private func makeAutomaticMicrophonePolicyFixture(
        provenance: WorldwideSessionViewModel.MediaSessionProvenance,
        installsRemoteAudioTrack: Bool = true
    ) throws -> (
        viewModel: WorldwideSessionViewModel,
        fixture: AudioLifecycleFixture,
        peer: WebRTCPeer
    ) {
        let fixture = makeFixture()
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        let peer = try makeAudioRacePeer()
        fixture.controller.prepare(serverName: "Mac mini")
        if installsRemoteAudioTrack {
            fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        }
        viewModel.debugInstallScreenSessionForTests(
            peer: peer,
            provenance: provenance
        )
        return (viewModel: viewModel, fixture: fixture, peer: peer)
    }
    #endif

    private struct HostedCallProofHarness {
        let fixture: AudioLifecycleFixture
        let viewModel: WorldwideSessionViewModel
        let peer: WebRTCPeer
        let generation: UUID
        let systemAudioGeneration: UInt64
        let admittedAt: Date
        let diagnostics: AudioPlayoutDiagnosticsBox
        let recovery: HostedCallRecoveryRecorder
        let recoveryRequestCompletedExpectation: XCTestExpectation
        let revocationRecorder: HostedCallProofRevocationRecorder
        let recoveryPreflightWaiter: AudioManualContinuationStepper
        let installedDiagnosticsGate: HostedCallDiagnosticsReadGate
        let installedDiagnosticsWaiter: AudioManualContinuationStepper
        let pollWaiter: AudioManualContinuationStepper
        let setupTimeoutWaiter: AudioManualContinuationStepper
        let evidenceTimeoutWaiter: AudioManualContinuationStepper
        let steadyTimeoutWaiter: AudioManualContinuationStepper
    }

    private struct HostedCallProofStart {
        let authorization: WebRTCIOSHostedCallPlayoutAuthorization
        let initialProjection: WorldwideIOSHostedCallPlayoutDebugProjection
        let recoveredProjection: WorldwideIOSHostedCallPlayoutDebugProjection
    }

    private struct HostedCallReadyState {
        let start: HostedCallProofStart
        let admittedProjection: WorldwideIOSHostedCallPlayoutDebugProjection
        let floorSnapshot: WebRTCStatisticsSnapshot
        let floorProjection: WorldwideIOSHostedCallPlayoutDebugProjection
        let readySnapshot: WebRTCStatisticsSnapshot
        let readyProjection: WorldwideIOSHostedCallPlayoutDebugProjection
    }

    private func withHostedCallProofHarness(
        installedPCMNonzeroSampleCount: UInt64 = 9_600,
        installedPCMAbsoluteSampleSum: UInt64 = 9_600_000,
        _ body: @MainActor (HostedCallProofHarness) async throws -> Void
    ) async throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        let peer = try makeAudioRacePeer()
        let generation = UUID(
            uuidString: "11111111-1111-1111-1111-111111111111"
        )!
        let systemAudioGeneration: UInt64 = 0xCA11_0001
        let admittedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let diagnostics = AudioPlayoutDiagnosticsBox(
            hostedCallIOSPlayoutDiagnostics()
        )
        let recovery = HostedCallRecoveryRecorder()
        let recoveryRequestCompletedExpectation = expectation(
            description: "the hosted-call native recovery requester to complete"
        )
        recoveryRequestCompletedExpectation.assertForOverFulfill = true
        let recoveryRequestCompleted = AudioTestExpectationBox(
            recoveryRequestCompletedExpectation
        )
        let revocationRecorder = HostedCallProofRevocationRecorder()
        let recoveryPreflightWaiter = AudioManualContinuationStepper()
        let installedDiagnosticsGate = HostedCallDiagnosticsReadGate()
        let installedDiagnosticsWaiter = AudioManualContinuationStepper()
        let pollWaiter = AudioManualContinuationStepper()
        let setupTimeoutWaiter = AudioManualContinuationStepper()
        let evidenceTimeoutWaiter = AudioManualContinuationStepper()
        let steadyTimeoutWaiter = AudioManualContinuationStepper()

        viewModel.debugInstallIOSPlayoutDiagnosticsReader { requestedPeer in
            XCTAssertTrue(requestedPeer === peer)
            if installedDiagnosticsGate.isEnabled {
                await installedDiagnosticsWaiter.wait()
            }
            return diagnostics.value
        }
        viewModel.debugInstallIOSHostedCallPlayoutRequestPreflightWaiter {
            await recoveryPreflightWaiter.wait()
        }
        viewModel.debugInstallIOSHostedCallPlayoutPollWaiter {
            await pollWaiter.wait()
        }
        viewModel.debugInstallIOSHostedCallPlayoutSetupTimeoutWaiter {
            await setupTimeoutWaiter.wait()
        }
        viewModel.debugInstallIOSHostedCallPlayoutEvidenceTimeoutWaiter {
            await evidenceTimeoutWaiter.wait()
        }
        viewModel.debugInstallIOSHostedCallPlayoutSteadyTimeoutWaiter {
            await steadyTimeoutWaiter.wait()
        }
        viewModel.debugInstallIOSHostedCallPlayoutClock {
            admittedAt
        }
        viewModel.debugInstallIOSHostedCallPlayoutRecoveryRequester {
            requestedPeer, authorization in
            XCTAssertTrue(requestedPeer === peer)
            defer {
                recovery.didCompleteRequest = true
                recoveryRequestCompleted.fulfill()
            }
            recovery.requestCount += 1
            if let recorded = recovery.authorization {
                XCTAssertTrue(recorded === authorization)
            } else {
                recovery.authorization = authorization
            }
            let installed = authorization.performRecoveryIfValidForTesting(
                systemAudioGeneration: systemAudioGeneration,
                revocationHandler: { revocationRecorder.record() }
            ) {}
            guard installed else {
                XCTFail(
                    "The hosted-call testing recovery seam did not install its deterministic generation and revocation handler."
                )
                return
            }
            XCTAssertTrue(authorization.isValid)
            XCTAssertFalse(authorization.isRecoveryPending)
            XCTAssertEqual(
                authorization.systemAudioGeneration,
                systemAudioGeneration
            )
            recovery.installedSystemAudioGeneration =
                authorization.systemAudioGeneration
            diagnostics.set(
                hostedCallIOSPlayoutDiagnostics(
                    authorization: authorization,
                    callbacks: 10,
                    frames: 4_800,
                    pcmNonzeroSampleCount: installedPCMNonzeroSampleCount,
                    pcmAbsoluteSampleSum: installedPCMAbsoluteSampleSum
                )
            )
        }

        fixture.controller.prepare(serverName: "Mac mini")
        viewModel.debugInstallScreenSessionForTests(
            peer: peer,
            generation: generation
        )
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()

        let harness = HostedCallProofHarness(
            fixture: fixture,
            viewModel: viewModel,
            peer: peer,
            generation: generation,
            systemAudioGeneration: systemAudioGeneration,
            admittedAt: admittedAt,
            diagnostics: diagnostics,
            recovery: recovery,
            recoveryRequestCompletedExpectation: recoveryRequestCompletedExpectation,
            revocationRecorder: revocationRecorder,
            recoveryPreflightWaiter: recoveryPreflightWaiter,
            installedDiagnosticsGate: installedDiagnosticsGate,
            installedDiagnosticsWaiter: installedDiagnosticsWaiter,
            pollWaiter: pollWaiter,
            setupTimeoutWaiter: setupTimeoutWaiter,
            evidenceTimeoutWaiter: evidenceTimeoutWaiter,
            steadyTimeoutWaiter: steadyTimeoutWaiter
        )
        do {
            try await body(harness)
        } catch {
            await closeHostedCallProofHarness(harness)
            throw error
        }
        await closeHostedCallProofHarness(harness)
    }

    private func closeHostedCallProofHarness(
        _ harness: HostedCallProofHarness
    ) async {
        harness.viewModel.disconnect()
        harness.installedDiagnosticsGate.isEnabled = false
        await harness.recoveryPreflightWaiter.releaseAll()
        await harness.installedDiagnosticsWaiter.releaseAll()
        await harness.pollWaiter.releaseAll()
        await harness.setupTimeoutWaiter.releaseAll()
        await harness.evidenceTimeoutWaiter.releaseAll()
        await harness.steadyTimeoutWaiter.releaseAll()
        for _ in 0..<4 {
            await Task.yield()
        }
        await harness.peer.close()
    }

    private func requireAudioWaiterBlocked(
        _ waiter: AudioManualContinuationStepper,
        ordinal: Int,
        description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let arrivalExpectation = expectation(description: description)
        arrivalExpectation.assertForOverFulfill = true
        await waiter.fulfillOnArrival(
            ordinal,
            expectation: AudioTestExpectationBox(arrivalExpectation)
        )
        await fulfillment(of: [arrivalExpectation], timeout: 2)
        let arrived = await waiter.hasArrived(ordinal)
        _ = try XCTUnwrap(
            arrived ? ordinal : nil,
            "The exact hosted-call milestone did not arrive: \(description).",
            file: file,
            line: line
        )
    }

    private func beginHostedCallProof(
        _ harness: HostedCallProofHarness
    ) async throws -> HostedCallProofStart {
        let ordinaryGeneration =
            harness.viewModel.debugAudioPolicyGeneration
        harness.fixture.callActivity.setCallSnapshot(
            nonEndedCallCount: 1,
            connectedNonEndedCallCount: 1
        )

        harness.fixture.events.onInterruptionBegan?(.default)
        let interruptionGeneration =
            harness.viewModel.debugAudioPolicyGeneration
        XCTAssertNotEqual(
            interruptionGeneration,
            ordinaryGeneration,
            "The native interruption boundary must own a distinct policy generation."
        )

        let initial = try XCTUnwrap(
            harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
        )
        XCTAssertEqual(
            initial.audioPolicyGeneration,
            interruptionGeneration
        )
        XCTAssertTrue(initial.authorizationIsValid)
        XCTAssertTrue(initial.authorizationIsRecoveryPending)
        XCTAssertNil(initial.timeoutID)
        XCTAssertEqual(harness.recovery.requestCount, 0)
        XCTAssertNil(harness.recovery.authorization)

        harness.fixture.events.onInterruptionEnded?(true)
        try await requireAudioWaiterBlocked(
            harness.setupTimeoutWaiter,
            ordinal: 1,
            description: "the hosted-call setup timeout to arm"
        )
        try await requireAudioWaiterBlocked(
            harness.recoveryPreflightWaiter,
            ordinal: 1,
            description: "the hosted-call recovery preflight to block"
        )
        let quiesced = try XCTUnwrap(
            harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
        )
        XCTAssertEqual(quiesced.stage, "awaiting-native-recovery")
        XCTAssertEqual(quiesced.proofAttemptID, initial.proofAttemptID)
        XCTAssertEqual(quiesced.counterWindowID, initial.counterWindowID)
        XCTAssertEqual(quiesced.policyID, initial.policyID)
        XCTAssertEqual(quiesced.authorizationIdentity, initial.authorizationIdentity)
        XCTAssertEqual(quiesced.pollOrdinal, 1)
        XCTAssertEqual(quiesced.recoveryRequestCount, 0)
        XCTAssertTrue(quiesced.authorizationIsValid)
        XCTAssertTrue(quiesced.authorizationIsRecoveryPending)
        XCTAssertNotNil(quiesced.timeoutID)
        XCTAssertEqual(harness.recovery.requestCount, 0)
        XCTAssertNil(harness.recovery.authorization)
        await harness.recoveryPreflightWaiter.releaseAll()
        await fulfillment(
            of: [harness.recoveryRequestCompletedExpectation],
            timeout: 2
        )
        let authorization = try XCTUnwrap(
            harness.recovery.didCompleteRequest
                ? harness.recovery.authorization
                : nil,
            "The hosted-call recovery requester did not complete."
        )
        let installedSystemAudioGeneration = try XCTUnwrap(
            harness.recovery.installedSystemAudioGeneration,
            "The hosted-call recovery requester did not install its generation."
        )
        XCTAssertEqual(
            installedSystemAudioGeneration,
            harness.systemAudioGeneration
        )
        XCTAssertTrue(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertEqual(
            authorization.systemAudioGeneration,
            installedSystemAudioGeneration
        )
        try await requireAudioWaiterBlocked(
            harness.pollWaiter,
            ordinal: 1,
            description: "the post-recovery hosted-call poll to block"
        )
        let recovered = try XCTUnwrap(
            harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
        )
        return HostedCallProofStart(
            authorization: authorization,
            initialProjection: initial,
            recoveredProjection: recovered
        )
    }

    private func admitHostedCallDecodedAudio(
        _ harness: HostedCallProofHarness
    ) async throws -> WorldwideIOSHostedCallPlayoutDebugProjection {
        harness.installedDiagnosticsGate.isEnabled = true
        await harness.pollWaiter.release(1)
        try await requireAudioWaiterBlocked(
            harness.installedDiagnosticsWaiter,
            ordinal: 1,
            description: "the installed hosted-call diagnostics read to block"
        )
        let installing = try XCTUnwrap(
            harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
        )
        XCTAssertEqual(installing.stage, "awaiting-native-recovery")
        XCTAssertEqual(installing.pollOrdinal, 2)
        XCTAssertEqual(installing.recoveryRequestCount, 1)
        XCTAssertTrue(installing.authorizationIsValid)
        XCTAssertFalse(installing.authorizationIsRecoveryPending)
        XCTAssertNil(installing.runtimeGateAdmittedAt)
        XCTAssertNil(installing.evidenceFloor)
        XCTAssertNil(installing.steadyFloor)
        XCTAssertEqual(installing.timeoutPhase, "setup")
        harness.installedDiagnosticsGate.isEnabled = false
        await harness.installedDiagnosticsWaiter.releaseAll()
        try await requireAudioWaiterBlocked(
            harness.evidenceTimeoutWaiter,
            ordinal: 1,
            description: "the hosted-call evidence timeout to arm"
        )
        let projection = try XCTUnwrap(
            harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
        )
        await harness.setupTimeoutWaiter.release(1)
        return projection
    }

    private func driveHostedCallProofToReady(
        _ harness: HostedCallProofHarness
    ) async throws -> HostedCallReadyState {
        let start = try await beginHostedCallProof(harness)
        let admitted = try await admitHostedCallDecodedAudio(harness)
        let floorSnapshot = hostedCallStatisticsSnapshot(
            collectedAt: harness.admittedAt.addingTimeInterval(1),
            bytes: 1_000,
            packets: 10,
            jitterBufferEmittedCount: 100,
            totalSamplesReceived: 4_800,
            totalAudioEnergy: 1.0,
            totalSamplesDuration: 0.1
        )
        await harness.viewModel.debugDriveIOSHostedCallStatisticsForTests(
            floorSnapshot,
            from: harness.peer,
            generation: harness.generation
        )
        let floorProjection = try XCTUnwrap(
            harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
        )

        harness.diagnostics.set(
            hostedCallIOSPlayoutDiagnostics(
                authorization: start.authorization,
                callbacks: 11,
                frames: 5_280,
                pcmNonzeroSampleCount: 9_601,
                pcmAbsoluteSampleSum: 9_601_000
            )
        )
        let readySnapshot = hostedCallStatisticsSnapshot(
            collectedAt: harness.admittedAt.addingTimeInterval(2),
            bytes: 1_100,
            packets: 11,
            jitterBufferEmittedCount: 110,
            totalSamplesReceived: 5_280,
            totalAudioEnergy: 1.1,
            totalSamplesDuration: 0.11
        )
        await harness.viewModel.debugDriveIOSHostedCallStatisticsForTests(
            readySnapshot,
            from: harness.peer,
            generation: harness.generation
        )
        await harness.steadyTimeoutWaiter.waitUntilBlocked(1)
        let readyProjection = try XCTUnwrap(
            harness.viewModel.debugIOSHostedCallPlayoutProjectionForTests()
        )
        await harness.evidenceTimeoutWaiter.release(1)
        return HostedCallReadyState(
            start: start,
            admittedProjection: admitted,
            floorSnapshot: floorSnapshot,
            floorProjection: floorProjection,
            readySnapshot: readySnapshot,
            readyProjection: readyProjection
        )
    }

    private func makeAudioRacePeer() throws -> WebRTCPeer {
        try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [])
        )
    }

    private func makePreparedProofViewModel() -> (
        viewModel: WorldwideSessionViewModel,
        fixture: AudioLifecycleFixture
    ) {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        fixture.controller.updateRuntimePlayout(isReady: true)
        return (viewModel, fixture)
    }

    private func installProductionShapedIOSRecoveryHarness(
        on viewModel: WorldwideSessionViewModel,
        peer: WebRTCPeer,
        recoveryWasConsumed: @escaping @MainActor () -> Void = {}
    ) {
        var diagnosticsOrdinal: UInt64 = 10
        viewModel.debugInstallIOSPlayoutDiagnosticsReader {
            requestedPeer in
            XCTAssertTrue(requestedPeer === peer)
            diagnosticsOrdinal &+= 1
            let microphoneIsAuthorized =
                viewModel
                    .debugIPhoneMicrophoneAuthorizationForTests?
                    .isValid == true
            return iosPlayoutDiagnostics(
                callbacks: diagnosticsOrdinal,
                frames: diagnosticsOrdinal * 480,
                failures: 0,
                inputBusEnabled: microphoneIsAuthorized,
                categoryIsMediaPlayback:
                    !microphoneIsAuthorized,
                categoryIsMediaPlayAndRecord:
                    microphoneIsAuthorized
            )
        }
        viewModel.debugInstallIOSPlayoutRecoveryRequester {
            requestedPeer,
            authorization in
            XCTAssertTrue(requestedPeer === peer)
            XCTAssertTrue(authorization.isValid)
            XCTAssertTrue(
                authorization.performIfValidForTesting {}
            )
            recoveryWasConsumed()
        }
    }

    private enum StaleMicrophoneCleanupTerminalBoundary {
        case permissionDenial
        case disconnect
    }

    private func assertStaleMicrophoneCleanupDoesNotReenable(
        after boundary: StaleMicrophoneCleanupTerminalBoundary
    ) async throws {
        let fixture = makeFixture()
        let viewModel = WorldwideSessionViewModel(
            audioLifecycle: fixture.controller
        )
        let peer = try makeAudioRacePeer()
        let firstEnableFailed = expectation(
            description: "terminal-boundary first enable failed"
        )
        let cleanupEntered = expectation(
            description: "terminal-boundary cleanup entered"
        )
        let cleanupReturned = expectation(
            description: "terminal-boundary cleanup returned"
        )
        let cleanupGate = AudioNonCooperativeGate<Bool>()
        var enableCount = 0
        var didBlockCleanup = false

        viewModel.debugInstallScreenSessionForTests(
            peer: peer,
            provenance: .authenticatedPairedCoordinatorHandoff
        )
        viewModel.debugCacheIPhoneMicrophonePermissionForTests()
        viewModel.debugInstallIPhoneMicrophoneNativeHandlers(
            enable: { _ in
                enableCount += 1
                if enableCount == 1 {
                    firstEnableFailed.fulfill()
                    throw TestAudioError.activation
                }
            },
            disable: { authorization, _ in
                guard !didBlockCleanup,
                      authorization != nil else {
                    return true
                }
                didBlockCleanup = true
                cleanupEntered.fulfill()
                let result = await cleanupGate.wait()
                cleanupReturned.fulfill()
                return result
            }
        )

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.transportBecameHealthy()
        viewModel.handleAppBecameActive()
        await fulfillment(
            of: [firstEnableFailed, cleanupEntered],
            timeout: 2
        )
        XCTAssertTrue(
            viewModel.isMicrophoneAdmissionCleanupInProgress
        )

        switch boundary {
        case .permissionDenial:
            viewModel.debugDenyIPhoneMicrophonePermissionForTests()
        case .disconnect:
            viewModel.disconnect()
        }
        XCTAssertFalse(viewModel.microphoneIntentEnabled)

        await cleanupGate.open(true)
        await fulfillment(of: [cleanupReturned], timeout: 2)
        for _ in 0..<10
        where viewModel.isMicrophoneAdmissionCleanupInProgress {
            await Task.yield()
        }

        XCTAssertFalse(
            viewModel.isMicrophoneAdmissionCleanupInProgress
        )
        XCTAssertEqual(enableCount, 1)
        XCTAssertFalse(viewModel.isMicrophoneSending)
        XCTAssertNil(
            viewModel.debugIPhoneMicrophoneAuthorizationForTests
        )

        if case .permissionDenial = boundary {
            viewModel.disconnect()
        }
        await peer.close()
    }

    private var inactiveSnapshot: WorldwideAudioLifecycleSnapshot {
        WorldwideAudioLifecycleSnapshot(
            stateText: "Inactive",
            isRemoteAudioAvailable: false,
            isPlaying: false,
            requiresExplicitResume: false,
            errorText: nil,
            diagnosticText: nil
        )
    }

    private func makeFixture(
        nonEndedCallCount: Int = 0,
        connectedNonEndedCallCount: Int? = nil
    ) -> AudioLifecycleFixture {
        let playback = AudioPlaybackStub()
        let background = BackgroundPlaybackStub()
        let events = AudioSessionEventsStub()
        let callActivity = CallActivityStub(
            nonEndedCallCount: nonEndedCallCount,
            connectedNonEndedCallCount:
                connectedNonEndedCallCount
        )
        let remoteAudio = RemoteAudioStub()
        let controller = WorldwideAudioLifecycleController(
            playback: playback,
            backgroundPlayback: background,
            events: events,
            callActivity: callActivity
        )
        return AudioLifecycleFixture(
            controller: controller,
            playback: playback,
            background: background,
            events: events,
            callActivity: callActivity,
            remoteAudio: remoteAudio
        )
    }
}

// MARK: - Deterministic lifecycle doubles

/// Minimal published state captured at policy boundaries instead of asserting transient call order.
@MainActor
private struct PublishedAudioState: Equatable {
    let stateText: String
    let isAvailable: Bool
    let isPlaying: Bool
    let requiresResume: Bool
    let error: String?
    let diagnostic: String?

    init(_ viewModel: WorldwideSessionViewModel) {
        stateText = viewModel.audioStateText
        isAvailable = viewModel.isRemoteAudioAvailable
        isPlaying = viewModel.isRemoteAudioPlaying
        requiresResume = viewModel.audioRequiresExplicitResume
        error = viewModel.audioError
        diagnostic = viewModel.audioDiagnostic
    }
}

@MainActor
private final class HostedCallRecoveryRecorder {
    var authorization: WebRTCIOSHostedCallPlayoutAuthorization?
    var requestCount = 0
    var didCompleteRequest = false
    var installedSystemAudioGeneration: UInt64?
}

@MainActor
private final class HostedCallDiagnosticsReadGate {
    var isEnabled = false
}

@MainActor
private final class AudioMainActorFlag {
    var value: Bool

    init(_ value: Bool = false) {
        self.value = value
    }
}

private final class HostedCallProofRevocationRecorder: @unchecked Sendable {
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

private final class AudioTestExpectationBox: @unchecked Sendable {
    private let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfill() {
        expectation.fulfill()
    }
}

private actor AudioManualContinuationStepper {
    private var nextOrdinal = 0
    private var blocked: [Int: CheckedContinuation<Void, Never>] = [:]
    private var arrivedOrdinals: Set<Int> = []
    private var completedOrdinals: Set<Int> = []
    private var releasedBeforeArrival: Set<Int> = []
    private var arrivalWaiters:
        [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var completionWaiters:
        [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var arrivalExpectations:
        [Int: [AudioTestExpectationBox]] = [:]
    private var isClosed = false

    func wait() async {
        guard !isClosed else { return }

        nextOrdinal += 1
        let ordinal = nextOrdinal

        if releasedBeforeArrival.remove(ordinal) != nil {
            markArrived(ordinal)
            markCompleted(ordinal)
            return
        }

        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            blocked[ordinal] = continuation
            markArrived(ordinal)
        }
        markCompleted(ordinal)
    }

    func waitUntilBlocked(_ ordinal: Int) async {
        if isClosed || arrivedOrdinals.contains(ordinal) { return }
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            arrivalWaiters[ordinal, default: []].append(continuation)
        }
    }

    func fulfillOnArrival(
        _ ordinal: Int,
        expectation: AudioTestExpectationBox
    ) {
        if isClosed || arrivedOrdinals.contains(ordinal) {
            expectation.fulfill()
            return
        }
        arrivalExpectations[ordinal, default: []].append(expectation)
    }

    func hasArrived(_ ordinal: Int) -> Bool {
        arrivedOrdinals.contains(ordinal)
    }

    func release(_ ordinal: Int) async {
        guard !isClosed else { return }
        if completedOrdinals.contains(ordinal) { return }

        if let continuation = blocked.removeValue(forKey: ordinal) {
            continuation.resume()
            await waitUntilCompleted(ordinal)
            return
        }

        if arrivedOrdinals.contains(ordinal) {
            await waitUntilCompleted(ordinal)
            return
        }

        releasedBeforeArrival.insert(ordinal)
    }

    func releaseAll() async {
        guard !isClosed else { return }
        isClosed = true

        let blockedContinuations = blocked
        blocked.removeAll(keepingCapacity: false)
        releasedBeforeArrival.removeAll(keepingCapacity: false)
        let arrivalContinuations = arrivalWaiters.values.flatMap { $0 }
        arrivalWaiters.removeAll(keepingCapacity: false)
        let pendingArrivalExpectations =
            arrivalExpectations.values.flatMap { $0 }
        arrivalExpectations.removeAll(keepingCapacity: false)

        for continuation in blockedContinuations.values {
            continuation.resume()
        }
        for continuation in arrivalContinuations {
            continuation.resume()
        }
        for expectation in pendingArrivalExpectations {
            expectation.fulfill()
        }

        for ordinal in blockedContinuations.keys {
            await waitUntilCompleted(ordinal)
        }

        let abandonedCompletionContinuations =
            completionWaiters.values.flatMap { $0 }
        completionWaiters.removeAll(keepingCapacity: false)
        for continuation in abandonedCompletionContinuations {
            continuation.resume()
        }
    }

    private func markArrived(_ ordinal: Int) {
        arrivedOrdinals.insert(ordinal)
        let expectations =
            arrivalExpectations.removeValue(forKey: ordinal) ?? []
        let pending = arrivalWaiters.removeValue(forKey: ordinal) ?? []
        for waiter in pending {
            waiter.resume()
        }
        for expectation in expectations {
            expectation.fulfill()
        }
    }

    private func markCompleted(_ ordinal: Int) {
        guard completedOrdinals.insert(ordinal).inserted else { return }
        let pending = completionWaiters.removeValue(forKey: ordinal) ?? []
        for waiter in pending {
            waiter.resume()
        }
    }

    private func waitUntilCompleted(_ ordinal: Int) async {
        if completedOrdinals.contains(ordinal) { return }
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            completionWaiters[ordinal, default: []].append(continuation)
        }
    }
}

private actor AudioNonCooperativeGate<Value: Sendable> {
    private var value: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []
    private var waiterArrivalContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async -> Value {
        if let value { return value }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            let arrivals = waiterArrivalContinuations
            waiterArrivalContinuations.removeAll(keepingCapacity: false)
            for arrival in arrivals {
                arrival.resume()
            }
        }
    }

    func waitUntilBlocked() async {
        guard value == nil, waiters.isEmpty else { return }
        await withCheckedContinuation { continuation in
            waiterArrivalContinuations.append(continuation)
        }
    }

    func open(_ value: Value) {
        guard self.value == nil else { return }
        self.value = value
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume(returning: value)
        }
    }
}

private final class AudioLockedInteger: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class AudioLockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ value: Value) {
        lock.withLock {
            storage.append(value)
        }
    }
}

private final class AudioLockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    func set(_ value: Value) {
        lock.withLock { storage = value }
    }
}

private final class AudioSynchronousBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var hasEntered = false
    private var isReleased = false
    private var entryWaiters:
        [CheckedContinuation<Void, Never>] = []

    func enterAndWait() {
        condition.lock()
        hasEntered = true
        let waiters = entryWaiters
        entryWaiters.removeAll(keepingCapacity: false)
        condition.unlock()

        for waiter in waiters {
            waiter.resume()
        }

        condition.lock()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if hasEntered {
                condition.unlock()
                continuation.resume()
                return
            }
            entryWaiters.append(continuation)
            condition.unlock()
        }
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class AudioPlayoutDiagnosticsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: WebRTCIOSPlayoutDiagnostics

    init(_ value: WebRTCIOSPlayoutDiagnostics) {
        storage = value
    }

    var value: WebRTCIOSPlayoutDiagnostics {
        lock.withLock { storage }
    }

    func set(_ value: WebRTCIOSPlayoutDiagnostics) {
        lock.withLock { storage = value }
    }
}

private func hostedCallIOSPlayoutDiagnostics(
    authorization: WebRTCIOSHostedCallPlayoutAuthorization? = nil,
    callbacks: UInt64 = 0,
    frames: UInt64 = 0,
    pcmNonzeroSampleCount: UInt64 = 0,
    pcmAbsoluteSampleSum: UInt64 = 0
) -> WebRTCIOSPlayoutDiagnostics {
    guard let authorization else {
        return iosPlayoutDiagnostics(
            callbacks: callbacks,
            frames: frames,
            failures: 0,
            playoutInitialized: false,
            playing: false,
            sessionActive: false,
            ownsSessionActivation: false,
            remoteIOCreated: false,
            inputBusEnabled: false,
            outputBusEnabled: false,
            recoveryRequired: true,
            explicitResumeRequired: false,
            hasOutputRoute: true,
            pcmNonzeroSampleCount: pcmNonzeroSampleCount,
            pcmAbsoluteSampleSum: pcmAbsoluteSampleSum
        )
    }

    return iosPlayoutDiagnostics(
        callbacks: callbacks,
        frames: frames,
        failures: 0,
        categoryOptionsAreEmpty: false,
        categoryOptionsAreMixWithOthers: true,
        hasOutputRoute: true,
        hostedCallMode: true,
        hostedCallAuthorizationValid: authorization.isValid,
        hostedCallRecoveryPending: authorization.isRecoveryPending,
        hostedCallOrigin: authorization.origin,
        systemAudioGeneration: authorization.systemAudioGeneration,
        hostedCallAuthorizationGeneration: authorization.systemAudioGeneration,
        pcmNonzeroSampleCount: pcmNonzeroSampleCount,
        pcmAbsoluteSampleSum: pcmAbsoluteSampleSum
    )
}

private func hostedCallStatisticsSnapshot(
    collectedAt: Date,
    bytes: UInt64,
    packets: UInt64,
    jitterBufferEmittedCount: UInt64,
    totalSamplesReceived: UInt64,
    totalAudioEnergy: Double,
    totalSamplesDuration: Double
) -> WebRTCStatisticsSnapshot {
    WebRTCStatisticsSnapshot(
        collectedAt: collectedAt,
        inboundAudio: WebRTCAudioStatistics(
            bytes: bytes,
            packets: packets,
            jitterBufferEmittedCount: jitterBufferEmittedCount,
            totalSamplesReceived: totalSamplesReceived,
            totalAudioEnergy: totalAudioEnergy,
            totalSamplesDuration: totalSamplesDuration
        )
    )
}

private func ordinaryLivenessOracle(
    sessionGeneration: UUID,
    audioPolicyGeneration: UUID,
    callbacks: UInt64,
    frames: UInt64,
    pcmNonzero: UInt64,
    pcmAbsolute: UInt64,
    inboundEnergy: Double
) -> WorldwideAudioPlayoutOracleSnapshot {
    WorldwideAudioPlayoutOracleSnapshot(
        sessionGeneration: sessionGeneration,
        audioPolicyGeneration: audioPolicyGeneration,
        diagnostics: iosPlayoutDiagnostics(
            callbacks: callbacks,
            frames: frames,
            failures: 0,
            pcmNonzeroSampleCount: pcmNonzero,
            pcmAbsoluteSampleSum: pcmAbsolute
        ),
        inboundAudio: WebRTCAudioStatistics(
            totalAudioEnergy: inboundEnergy,
            totalSamplesDuration: Double(frames) / 48_000
        )
    )
}

private func iosPlayoutDiagnostics(
    callbacks: UInt64,
    frames: UInt64,
    failures: UInt64,
    lastStatus: Int32 = noErr,
    failureCode: Int = 0,
    lastLifecycleStatus: Int32? = nil,
    unexpectedRecordingRequests: UInt64 = 0,
    initialized: Bool = true,
    playoutInitialized: Bool = true,
    playing: Bool = true,
    sessionActive: Bool = true,
    ownsSessionActivation: Bool = true,
    remoteIOCreated: Bool = true,
    inputBusEnabled: Bool = false,
    outputBusEnabled: Bool = true,
    recoveryRequired: Bool = false,
    explicitResumeRequired: Bool = false,
    categoryIsMediaPlayback: Bool = true,
    categoryIsMediaPlayAndRecord: Bool = false,
    modeIsDefault: Bool = true,
    categoryOptionsAreEmpty: Bool? = nil,
    categoryOptionsAreIPhoneMicrophoneRouting: Bool? = nil,
    categoryOptionsAreMixWithOthers: Bool = false,
    routeSharingPolicyIsDefault: Bool = true,
    hasOutputRoute: Bool = true,
    hostedCallMode: Bool = false,
    hostedCallAuthorizationValid: Bool = false,
    hostedCallRecoveryPending: Bool = false,
    hostedCallOrigin: WebRTCIOSHostedCallPlayoutOrigin? = nil,
    systemAudioGeneration: UInt64 = 0,
    hostedCallAuthorizationGeneration: UInt64 = 0,
    sampleRate: Double = 48_000,
    outputIOBufferDuration: TimeInterval = 0.01,
    outputChannelCount: Int = 2,
    audioUnitSubType: UInt32 = kAudioUnitSubType_RemoteIO,
    failureMessage: String? = nil,
    pcmSampleCount: UInt64? = nil,
    pcmNonzeroSampleCount: UInt64? = nil,
    pcmAbsoluteSampleSum: UInt64? = nil,
    pcmLeftAbsoluteSampleSum: UInt64? = nil,
    pcmRightAbsoluteSampleSum: UInt64? = nil,
    pcmStereoDifferenceAbsoluteSampleSum: UInt64? = nil,
    pcmClippedSampleCount: UInt64 = 0,
    explicitSilenceCallbackCount: UInt64 = 0,
    callbackGapViolationCount: UInt64 = 0,
    maximumCallbackGapNanoseconds: UInt64 = 10_000_000,
    nearSilenceCallbackCount: UInt64 = 0,
    currentConsecutiveNearSilenceFrameCount: UInt64 = 0,
    maximumConsecutiveNearSilenceFrameCount: UInt64 = 0,
    pcmLeftZeroCrossingCount: UInt64? = nil,
    pcmRightZeroCrossingCount: UInt64? = nil,
    pcmEnvelopeTransitionCount: UInt64? = nil,
    pcmShapeAnomalyCallbackCount: UInt64 = 0,
    pcmBoundaryDiscontinuityCallbackCount: UInt64 = 0,
    lastCallbackMeanMagnitude: UInt32? = nil,
    recoveryRebuildCount: UInt64 = 0,
    lastPeakMagnitude: UInt32? = nil,
    lastPlayoutFrameCount: UInt32? = nil
) -> WebRTCIOSPlayoutDiagnostics {
    let effectiveCategoryOptionsAreEmpty =
        categoryOptionsAreEmpty ?? !inputBusEnabled
    let effectiveCategoryOptionsAreIPhoneMicrophoneRouting =
        categoryOptionsAreIPhoneMicrophoneRouting ?? inputBusEnabled
    let renderedSamples = pcmSampleCount ?? frames.multipliedReportingOverflow(by: 2).partialValue
    let nonzeroSamples = pcmNonzeroSampleCount ?? renderedSamples
    let absoluteSum = pcmAbsoluteSampleSum ?? nonzeroSamples * 1_000
    let leftAbsoluteSum = pcmLeftAbsoluteSampleSum ?? absoluteSum / 2
    let rightAbsoluteSum = pcmRightAbsoluteSampleSum ?? absoluteSum - leftAbsoluteSum
    return WebRTCIOSPlayoutDiagnostics(
        initialized: initialized,
        playoutInitialized: playoutInitialized,
        playing: playing,
        sessionActive: sessionActive,
        ownsSessionActivation: ownsSessionActivation,
        remoteIOCreated: remoteIOCreated,
        inputBusEnabled: inputBusEnabled,
        outputBusEnabled: outputBusEnabled,
        recoveryRequired: recoveryRequired,
        explicitResumeRequired: explicitResumeRequired,
        categoryIsMediaPlayback: categoryIsMediaPlayback,
        categoryIsMediaPlayAndRecord: categoryIsMediaPlayAndRecord,
        modeIsDefault: modeIsDefault,
        categoryOptionsAreEmpty: effectiveCategoryOptionsAreEmpty,
        categoryOptionsAreIPhoneMicrophoneRouting:
            effectiveCategoryOptionsAreIPhoneMicrophoneRouting,
        categoryOptionsAreMixWithOthers: categoryOptionsAreMixWithOthers,
        routeSharingPolicyIsDefault: routeSharingPolicyIsDefault,
        hasOutputRoute: hasOutputRoute,
        hostedCallMode: hostedCallMode,
        hostedCallAuthorizationValid: hostedCallAuthorizationValid,
        hostedCallRecoveryPending: hostedCallRecoveryPending,
        hostedCallOrigin: hostedCallOrigin,
        systemAudioGeneration: systemAudioGeneration,
        hostedCallAuthorizationGeneration: hostedCallAuthorizationGeneration,
        sampleRate: sampleRate,
        outputIOBufferDuration: outputIOBufferDuration,
        outputChannelCount: outputChannelCount,
        audioUnitSubType: audioUnitSubType,
        failureCode: failureCode,
        lastLifecycleStatus:
            lastLifecycleStatus ?? (failureCode == 0 ? noErr : lastStatus),
        failureMessage:
            failureCode == 0
                ? nil
                : (failureMessage ?? "Synthetic lifecycle failure"),
        playoutCallbackCount: callbacks,
        playoutFrameCount: frames,
        playoutFailureCount: failures,
        playoutPCMSampleCount: renderedSamples,
        playoutPCMNonzeroSampleCount: nonzeroSamples,
        playoutPCMAbsoluteSampleSum: absoluteSum,
        playoutPCMLeftAbsoluteSampleSum: leftAbsoluteSum,
        playoutPCMRightAbsoluteSampleSum: rightAbsoluteSum,
        playoutPCMStereoDifferenceAbsoluteSampleSum:
            pcmStereoDifferenceAbsoluteSampleSum ?? absoluteSum / 3,
        playoutPCMClippedSampleCount: pcmClippedSampleCount,
        playoutExplicitSilenceCallbackCount: explicitSilenceCallbackCount,
        unexpectedRecordingRequestCount: unexpectedRecordingRequests,
        recoveryRequestCount: 0,
        recoveryAuthorizationRejectionCount: 0,
        recoveryRebuildCount: recoveryRebuildCount,
        lastPlayoutFrameCount:
            lastPlayoutFrameCount ?? (callbacks == 0 ? 0 : 480),
        lastPlayoutPeakMagnitude:
            lastPeakMagnitude ?? (nonzeroSamples == 0 ? 0 : 8_000),
        lastPlayoutStatus: lastStatus,
        playoutCallbackGapViolationCount: callbackGapViolationCount,
        playoutMaximumCallbackGapNanoseconds: maximumCallbackGapNanoseconds,
        playoutNearSilenceCallbackCount: nearSilenceCallbackCount,
        playoutCurrentConsecutiveNearSilenceFrameCount:
            currentConsecutiveNearSilenceFrameCount,
        playoutMaximumConsecutiveNearSilenceFrameCount:
            maximumConsecutiveNearSilenceFrameCount,
        playoutPCMLeftZeroCrossingCount:
            pcmLeftZeroCrossingCount ?? frames * 9_000 / 48_000,
        playoutPCMRightZeroCrossingCount:
            pcmRightZeroCrossingCount ?? frames * 12_502 / 48_000,
        playoutPCMEnvelopeTransitionCount:
            pcmEnvelopeTransitionCount ?? frames / 24_000,
        playoutPCMShapeAnomalyCallbackCount: pcmShapeAnomalyCallbackCount,
        playoutPCMBoundaryDiscontinuityCallbackCount:
            pcmBoundaryDiscontinuityCallbackCount,
        playoutLastCallbackMeanMagnitude:
            lastCallbackMeanMagnitude ?? (nonzeroSamples == 0 ? 0 : 1_000)
    )
}

private func healthyIOSPlayoutDiagnostics() -> WebRTCIOSPlayoutDiagnostics {
    iosPlayoutDiagnostics(callbacks: 1, frames: 480, failures: 0)
}

private func terminalIOSPlayoutDiagnostics() -> WebRTCIOSPlayoutDiagnostics {
    iosPlayoutDiagnostics(
        callbacks: 0,
        frames: 0,
        failures: 1,
        lastStatus: -50,
        failureCode: 19,
        playoutInitialized: false,
        playing: false,
        sessionActive: false,
        ownsSessionActivation: false,
        remoteIOCreated: false,
        outputBusEnabled: false,
        recoveryRequired: true,
        explicitResumeRequired: true,
        lastPlayoutFrameCount: 0
    )
}

@MainActor
private struct AudioLifecycleFixture {
    let controller: WorldwideAudioLifecycleController
    let playback: AudioPlaybackStub
    let background: BackgroundPlaybackStub
    let events: AudioSessionEventsStub
    let callActivity: CallActivityStub
    let remoteAudio: RemoteAudioStub
}

@MainActor
private final class RemoteAudioStub: WorldwideRemoteAudioControlling {
    private let initiallyEnabled: Bool
    private(set) var enabledValues: [Bool] = []

    init(initiallyEnabled: Bool = false) {
        self.initiallyEnabled = initiallyEnabled
    }

    var isEnabled: Bool {
        enabledValues.last ?? initiallyEnabled
    }

    func setEnabled(_ enabled: Bool) {
        enabledValues.append(enabled)
    }
}

@MainActor
private final class AudioPlaybackStub: WorldwideAudioPlaybackManaging {
    var requiresRuntimePlayoutProof = false
    var activateError: (any Error)?
    var recoverError: (any Error)?
    var onActivate: (() -> Void)?
    var onRecover: (() -> Void)?
    private(set) var activateCount = 0
    private(set) var recoverCount = 0
    private(set) var prepareForHostedCallInterruptionCount = 0
    private(set) var prepareManualAudioDisabledCount = 0
    private(set) var activateArmedHostedCallPlayoutCount = 0
    private(set) var deactivateCount = 0
    private(set) var nativeAudioEnabled = false

    func activate() throws {
        activateCount += 1
        onActivate?()
        if let activateError { throw activateError }
        nativeAudioEnabled = true
    }

    func recover() throws {
        recoverCount += 1
        onRecover?()
        if let recoverError { throw recoverError }
        nativeAudioEnabled = true
    }

    func prepareForHostedCallInterruption() {
        prepareForHostedCallInterruptionCount += 1
    }

    func prepareManualAudioDisabled() {
        prepareManualAudioDisabledCount += 1
        nativeAudioEnabled = false
    }

    func activateArmedHostedCallPlayout() {
        activateArmedHostedCallPlayoutCount += 1
        nativeAudioEnabled = true
    }

    func deactivate() {
        deactivateCount += 1
        nativeAudioEnabled = false
    }
}

@MainActor
private final class CrossLayerWebRTCAudioSessionStub:
    WebRTCAudioSessionControlling {
    var isActive = false
    var isAudioEnabled = false
    private(set) var configuredModes: [String] = []
    private(set) var setActiveValues: [Bool] = []
    private(set) var prepareCount = 0
    private(set) var lockCount = 0
    private(set) var unlockCount = 0

    func prepareForManualAudio() {
        prepareCount += 1
    }

    func lockForConfiguration() {
        lockCount += 1
    }

    func unlockForConfiguration() {
        unlockCount += 1
    }

    func configurePlayback(mode: AVAudioSession.Mode) throws {
        configuredModes.append(mode.rawValue)
    }

    func setActive(_ active: Bool) throws {
        setActiveValues.append(active)
        isActive = active
    }
}

@MainActor
private final class CrossLayerBackgroundPlaybackStub:
    BackgroundPlaybackCoordinating {
    func beginTransitionTask() {}
    func endTransitionTask() {}
    func publishLiveStream(serverName: String?, isPlaying: Bool) {}
    func clear() {}
}

@MainActor
private final class CrossLayerAudioSessionEventMonitorStub:
    AudioSessionEventMonitoring {
    var onInterruptionBegan:
        ((AudioSessionInterruptionBeganReason) -> Void)?
    var onInterruptionEnded: ((Bool) -> Void)?
    var onRouteChanged: ((String) -> Void)?
    var onCategoryChanged: ((AudioSessionCategoryChange) -> Void)?
    var onEngineConfigurationChanged: (() -> Void)?
    var onMediaServicesLost: (() -> Void)?
    var onMediaServicesReset: (() -> Void)?

    func startObserving() {}
    func stopObserving() {}
    func updateRouteConfigurationChangePolicyEpoch(_ epoch: UInt64) {}

    func armCategoryChangeOperation(
        _ operationID: UUID,
        category: String,
        mode: String,
        categoryOptionsRawValue: UInt
    ) {}

    func cancelCategoryChangeOperation(_ operationID: UUID) {}
}

@MainActor
private final class CallActivityStub: WorldwideCallActivityObserving {
    private(set) var snapshot: WorldwideCallActivitySnapshot
    private var stagedLiveSnapshot:
        WorldwideCallActivitySnapshot?
    var liveSnapshot: WorldwideCallActivitySnapshot {
        stagedLiveSnapshot ?? snapshot
    }
    var onSnapshotChanged:
        ((WorldwideCallActivitySnapshot) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var isObserving = false

    init(
        nonEndedCallCount: Int = 0,
        connectedNonEndedCallCount: Int? = nil
    ) {
        snapshot = WorldwideCallActivitySnapshot(
            nonEndedCallCount: nonEndedCallCount,
            connectedNonEndedCallCount:
                connectedNonEndedCallCount
                ?? nonEndedCallCount,
            membershipRevision: nonEndedCallCount > 0 ? 1 : 0
        )
    }

    func startObserving() {
        startCount += 1
        isObserving = true
    }

    func stopObserving() {
        stopCount += 1
        isObserving = false
        stagedLiveSnapshot = nil
        snapshot = .inactive
    }

    func setNonEndedCallCount(_ count: Int) {
        setCallSnapshot(
            nonEndedCallCount: count,
            connectedNonEndedCallCount: count
        )
    }

    func setCallSnapshot(
        nonEndedCallCount: Int,
        connectedNonEndedCallCount: Int,
        revision: UInt64? = nil,
        membershipRevision: UInt64? = nil
    ) {
        let defaultMembershipRevision =
            nonEndedCallCount == self.snapshot.nonEndedCallCount
                ? self.snapshot.membershipRevision
                : self.snapshot.membershipRevision &+ 1
        let snapshot = WorldwideCallActivitySnapshot(
            nonEndedCallCount: nonEndedCallCount,
            connectedNonEndedCallCount:
                connectedNonEndedCallCount,
            revision: revision ?? self.snapshot.revision,
            membershipRevision:
                membershipRevision ?? defaultMembershipRevision
        )
        stagedLiveSnapshot = nil
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        if isObserving {
            onSnapshotChanged?(snapshot)
        }
    }

    func replaceCallKeepingCurrentAggregate() {
        setCallSnapshot(
            nonEndedCallCount: snapshot.nonEndedCallCount,
            connectedNonEndedCallCount:
                snapshot.connectedNonEndedCallCount,
            revision: snapshot.revision &+ 1,
            membershipRevision:
                snapshot.membershipRevision &+ 1
        )
    }

    func stageLiveCallReplacementKeepingCurrentAggregateWithoutCallback() {
        stagedLiveSnapshot = WorldwideCallActivitySnapshot(
            nonEndedCallCount: snapshot.nonEndedCallCount,
            connectedNonEndedCallCount:
                snapshot.connectedNonEndedCallCount,
            revision: snapshot.revision &+ 1,
            membershipRevision:
                snapshot.membershipRevision &+ 1
        )
    }

    func stageLiveNonEndedCallCountWithoutCallback(_ count: Int) {
        stagedLiveSnapshot = WorldwideCallActivitySnapshot(
            nonEndedCallCount: count,
            connectedNonEndedCallCount: count,
            membershipRevision:
                count == snapshot.nonEndedCallCount
                    ? snapshot.membershipRevision
                    : snapshot.membershipRevision &+ 1
        )
    }
}

@MainActor
private final class BackgroundPlaybackStub: BackgroundPlaybackCoordinating {
    struct Publication {
        let serverName: String?
        let isPlaying: Bool
    }

    private(set) var beginCount = 0
    private(set) var endCount = 0
    private(set) var clearCount = 0
    private(set) var publications: [Publication] = []

    func beginTransitionTask() {
        beginCount += 1
    }

    func endTransitionTask() {
        endCount += 1
    }

    func publishLiveStream(serverName: String?, isPlaying: Bool) {
        publications.append(Publication(serverName: serverName, isPlaying: isPlaying))
    }

    func clear() {
        clearCount += 1
    }
}

@MainActor
private final class AudioSessionEventsStub: AudioSessionEventMonitoring {
    var onInterruptionBegan:
        ((AudioSessionInterruptionBeganReason) -> Void)?
    var onInterruptionEnded: ((Bool) -> Void)?
    var onRouteChanged: ((String) -> Void)?
    var onCategoryChanged: ((AudioSessionCategoryChange) -> Void)?
    var onEngineConfigurationChanged: (() -> Void)?
    var onMediaServicesLost: (() -> Void)?
    var onMediaServicesReset: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var routeConfigurationChangePolicyEpochs: [UInt64] = []
    private struct ArmedCategoryChangeOperation {
        let operationID: UUID
        let category: String
        let mode: String
        let categoryOptionsRawValue: UInt
    }
    private var armedCategoryChangeOperations:
        [ArmedCategoryChangeOperation] = []
    private(set) var armedCategoryChangeOperationIDs:
        [UUID] = []
    var onArmCategoryChangeOperation:
        ((AudioSessionCategoryChange) -> Void)?

    var lastArmedCategoryChange: AudioSessionCategoryChange? {
        guard let operation = armedCategoryChangeOperations.last
        else {
            return nil
        }
        return AudioSessionCategoryChange(
            category: operation.category,
            mode: operation.mode,
            categoryOptionsRawValue:
                operation.categoryOptionsRawValue,
            operationID: operation.operationID
        )
    }

    func startObserving() {
        startCount += 1
    }

    func stopObserving() {
        stopCount += 1
        armedCategoryChangeOperations.removeAll(
            keepingCapacity: false
        )
    }

    func updateRouteConfigurationChangePolicyEpoch(_ epoch: UInt64) {
        routeConfigurationChangePolicyEpochs.append(epoch)
    }

    func armCategoryChangeOperation(
        _ operationID: UUID,
        category: String,
        mode: String,
        categoryOptionsRawValue: UInt
    ) {
        armedCategoryChangeOperations.removeAll {
            $0.operationID == operationID
        }
        armedCategoryChangeOperations.append(
            ArmedCategoryChangeOperation(
                operationID: operationID,
                category: category,
                mode: mode,
                categoryOptionsRawValue:
                    categoryOptionsRawValue
            )
        )
        armedCategoryChangeOperationIDs.append(operationID)
        onArmCategoryChangeOperation?(
            AudioSessionCategoryChange(
                category: category,
                mode: mode,
                categoryOptionsRawValue:
                    categoryOptionsRawValue,
                operationID: operationID
            )
        )
    }

    func cancelCategoryChangeOperation(_ operationID: UUID) {
        armedCategoryChangeOperations.removeAll {
            $0.operationID == operationID
        }
    }

    func deliverArmedCategoryChange(
        _ change: AudioSessionCategoryChange
    ) {
        let operationID: UUID?
        if let index = armedCategoryChangeOperations.lastIndex(
            where: {
                $0.category == change.category
                    && $0.mode == change.mode
                    && $0.categoryOptionsRawValue
                        == change.categoryOptionsRawValue
            }
        ) {
            operationID = armedCategoryChangeOperations
                .remove(at: index)
                .operationID
        } else {
            operationID = nil
        }
        onCategoryChanged?(
            AudioSessionCategoryChange(
                category: change.category,
                mode: change.mode,
                categoryOptionsRawValue:
                    change.categoryOptionsRawValue,
                operationID: operationID
            )
        )
    }
}

private enum TestAudioError: LocalizedError {
    case activation
    case recovery

    var errorDescription: String? {
        switch self {
        case .activation:
            "activation failed"
        case .recovery:
            "recovery failed"
        }
    }
}
