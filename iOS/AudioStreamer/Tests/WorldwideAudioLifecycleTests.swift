import AVFAudio
import RemoteSessionCore
import XCTest
@testable import AudioStreamer
@testable import WebRTCTransport

@MainActor
final class WorldwideAudioLifecycleTests: XCTestCase {
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

    func testActiveCallAtStartupNeverOpensNativeAudioGate() {
        let fixture = makeFixture(nonEndedCallCount: 1)

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        fixture.controller.appBecameActive()
        fixture.events.onRouteChanged?("Audio route changed: category")
        fixture.events.onEngineConfigurationChanged?()
        fixture.events.onMediaServicesReset?()

        XCTAssertEqual(fixture.callActivity.startCount, 1)
        XCTAssertEqual(fixture.playback.activateCount, 0)
        XCTAssertEqual(fixture.playback.recoverCount, 0)
        XCTAssertEqual(fixture.playback.prepareManualAudioDisabledCount, 1)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Audio paused — iPhone call active"
        )
        XCTAssertTrue(fixture.controller.snapshot.errorText?.contains("Screen and control") == true)
    }

    func testEnabledTrackArrivingDuringActiveCallIsImmediatelyDisabled() {
        let fixture = makeFixture(nonEndedCallCount: 1)
        let arrivingTrack = RemoteAudioStub(initiallyEnabled: true)

        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(arrivingTrack)

        XCTAssertEqual(arrivingTrack.enabledValues, [false])
        XCTAssertFalse(arrivingTrack.isEnabled)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.controller.snapshot.isRemoteAudioAvailable)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Audio paused — iPhone call active"
        )
    }

    func testLiveCallPreflightBeatsQueuedCallKitCallbackBeforeRecovery() {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        let recoverCountBeforeCall = fixture.playback.recoverCount
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)

        // Model CXCallObserver.calls changing before its main-queue delegate callback arrives.
        fixture.callActivity.stageLiveNonEndedCallCountWithoutCallback(1)
        fixture.controller.appBecameActive()

        XCTAssertEqual(fixture.playback.recoverCount, recoverCountBeforeCall)
        XCTAssertEqual(fixture.playback.prepareManualAudioDisabledCount, 1)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(
            fixture.controller.snapshot.stateText,
            "Audio paused — iPhone call active"
        )
    }

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

    func testCallWhilePlayingClosesBothAudioGatesUntilFinalCallEnds() {
        let fixture = makeFixture()
        fixture.controller.prepare(serverName: "Mac mini")
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        let recoverCountBeforeCall = fixture.playback.recoverCount

        fixture.callActivity.setNonEndedCallCount(1)

        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(fixture.playback.prepareManualAudioDisabledCount, 1)
        XCTAssertEqual(fixture.playback.recoverCount, recoverCountBeforeCall)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)

        // A second overlapping call and every ordinary recovery stimulus must remain fail-closed.
        fixture.callActivity.setNonEndedCallCount(2)
        fixture.controller.appBecameActive()
        fixture.controller.appEnteredBackground()
        fixture.events.onRouteChanged?("Audio route changed: category")
        fixture.events.onEngineConfigurationChanged?()
        fixture.events.onMediaServicesReset?()
        fixture.callActivity.setNonEndedCallCount(1)

        XCTAssertEqual(fixture.playback.recoverCount, recoverCountBeforeCall)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.callActivity.setNonEndedCallCount(0)

        XCTAssertEqual(fixture.playback.recoverCount, recoverCountBeforeCall + 1)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Playing")
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

        XCTAssertFalse(viewModel.isRemoteAudioPlaying)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
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
        fixture.events.onInterruptionBegan?()
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

    func testFinalCallEndRequiresFreshAdvancingProofBeforePlaying() async throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        let peer = try makeAudioRacePeer()
        let recoveryRequested = expectation(description: "post-call native recovery requested")
        let floorReadStarted = expectation(description: "post-call floor read started")
        let advanceReadStarted = expectation(description: "post-call advance read started")
        let floorGate = AudioNonCooperativeGate<WebRTCIOSPlayoutDiagnostics>()
        let advanceGate = AudioNonCooperativeGate<WebRTCIOSPlayoutDiagnostics>()
        var diagnosticsReadCount = 0

        viewModel.debugInstallIOSPlayoutDiagnosticsReader { requestedPeer in
            XCTAssertTrue(requestedPeer === peer)
            diagnosticsReadCount += 1
            switch diagnosticsReadCount {
            case 1:
                return iosPlayoutDiagnostics(callbacks: 9, frames: 4_320, failures: 0)
            case 2:
                floorReadStarted.fulfill()
                return await floorGate.wait()
            default:
                advanceReadStarted.fulfill()
                return await advanceGate.wait()
            }
        }
        viewModel.debugInstallIOSPlayoutRecoveryRequester { requestedPeer, authorization in
            XCTAssertTrue(requestedPeer === peer)
            XCTAssertTrue(authorization.performIfValidForTesting {})
            authorization.revoke()
            recoveryRequested.fulfill()
        }

        fixture.controller.prepare(serverName: "Mac mini")
        viewModel.debugInstallIOSPlayoutPeerForRaceTests(peer)
        fixture.controller.remoteAudioBecameAvailable(fixture.remoteAudio)
        fixture.controller.transportBecameHealthy()
        fixture.controller.updateRuntimePlayout(isReady: true)
        let recoverCountBeforeCall = fixture.playback.recoverCount
        let preCallGeneration = viewModel.debugAudioPolicyGeneration
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Playing")

        fixture.callActivity.setNonEndedCallCount(1)
        let activeCallGeneration = viewModel.debugAudioPolicyGeneration
        XCTAssertNotEqual(activeCallGeneration, preCallGeneration)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)

        fixture.callActivity.setNonEndedCallCount(0)
        let postCallGeneration = viewModel.debugAudioPolicyGeneration
        XCTAssertNotEqual(postCallGeneration, activeCallGeneration)
        XCTAssertNotEqual(postCallGeneration, preCallGeneration)

        XCTAssertEqual(fixture.playback.recoverCount, recoverCountBeforeCall + 1)
        XCTAssertTrue(fixture.playback.nativeAudioEnabled)
        XCTAssertTrue(
            fixture.remoteAudio.isEnabled,
            "The decoded track must open only to let RemoteIO produce fresh proof."
        )
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Starting playback")
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        XCTAssertTrue(viewModel.debugAudioPolicyRequiresFreshRecovery)

        await fulfillment(of: [recoveryRequested, floorReadStarted], timeout: 2)
        let handle = try XCTUnwrap(viewModel.debugIOSPlayoutProofState.handle)
        XCTAssertEqual(
            handle.audioPolicyGeneration,
            postCallGeneration
        )
        let floor = iosPlayoutDiagnostics(callbacks: 10, frames: 4_800, failures: 0)
        await floorGate.open(floor)
        await fulfillment(of: [advanceReadStarted], timeout: 2)
        XCTAssertEqual(viewModel.debugIOSPlayoutProofState.handle, handle)
        XCTAssertEqual(viewModel.debugIOSPlayoutProofState.stage, .awaitingFreshEvidence)
        XCTAssertEqual(viewModel.debugIOSPlayoutProofState.callbackFloor, 10)
        XCTAssertEqual(viewModel.debugIOSPlayoutProofState.frameFloor, 4_800)
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Starting playback")
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)

        await advanceGate.open(
            iosPlayoutDiagnostics(callbacks: 11, frames: 5_280, failures: 0)
        )
        let deadline = ContinuousClock.now + .seconds(1)
        while !fixture.controller.snapshot.isPlaying,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Playing")
        XCTAssertTrue(fixture.controller.snapshot.isPlaying)
        XCTAssertFalse(viewModel.debugAudioPolicyRequiresFreshRecovery)
        XCTAssertNil(viewModel.debugIOSPlayoutProofState.handle)

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

        fixture.events.onInterruptionBegan?()

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

        fixture.events.onInterruptionBegan?()
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.events.onInterruptionEnded?(true)

        XCTAssertEqual(fixture.playback.recoverCount, recoverCountBeforeInterruption + 1)
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertTrue(fixture.controller.snapshot.isPlaying)
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

        fixture.events.onInterruptionBegan?()
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

        fixture.events.onRouteChanged?("Audio route changed: new device")
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.controller.appBecameActive()
        XCTAssertTrue(fixture.controller.snapshot.requiresExplicitResume)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.controller.resumePlayback()
        XCTAssertTrue(fixture.remoteAudio.isEnabled)
        XCTAssertFalse(fixture.controller.snapshot.requiresExplicitResume)
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
        fixture.events.onRouteChanged?("Audio route changed: category")

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

        viewModel.disconnect()
        XCTAssertNil(viewModel.audioPlayoutOracle)
        await peer.close()
    }

    func testCallPolicyGenerationRejectsStatsReadAcrossCallStartAndEnd() async throws {
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

        fixture.controller.prepare(serverName: "Mac mini")
        viewModel.debugInstallIOSPlayoutPeerForRaceTests(peer)
        let refreshTask = Task { @MainActor in
            await viewModel.debugRefreshIOSPlayoutOracleForTests(from: peer)
            readFinished.fulfill()
        }
        await fulfillment(of: [readStarted], timeout: 2)
        await diagnosticsGate.waitUntilBlocked()

        // A Boolean-only guard would be false again when the suspended read resumes and would
        // incorrectly publish this pre-call green snapshot. Both transitions must rotate policy.
        fixture.callActivity.setNonEndedCallCount(1)
        fixture.callActivity.setNonEndedCallCount(0)
        await diagnosticsGate.open(healthyIOSPlayoutDiagnostics())
        await fulfillment(of: [readFinished], timeout: 2)
        await refreshTask.value

        XCTAssertNil(viewModel.audioPlayoutOracle)
        XCTAssertTrue(viewModel.hasActiveSession)
        XCTAssertEqual(fixture.playback.prepareManualAudioDisabledCount, 1)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)

        viewModel.disconnect()
        await peer.close()
    }

    func testCallStartRevokesQueuedNativeRecoveryWithoutDisconnectingPeer() async throws {
        let fixture = makeFixture()
        fixture.playback.requiresRuntimePlayoutProof = true
        let viewModel = WorldwideSessionViewModel(audioLifecycle: fixture.controller)
        let peer = try makeAudioRacePeer()
        let requestStarted = expectation(description: "native recovery request suspended")
        let proofFinished = expectation(description: "call-retired proof returned")
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

        fixture.callActivity.setNonEndedCallCount(1)

        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(viewModel.debugIOSPlayoutRecoveryIsAuthorized)
        XCTAssertTrue(viewModel.hasActiveSession)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)

        await requestGate.open(())
        await fulfillment(of: [proofFinished], timeout: 2)
        XCTAssertEqual(nativeRecoveryCount.value, 0)
        XCTAssertNil(viewModel.audioPlayoutOracle)

        viewModel.disconnect()
        await peer.close()
    }

    func testCallBlockedCallbacksCannotCreateProofReadOrAuthorization() async throws {
        let fixture = makeFixture(nonEndedCallCount: 1)
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
        fixture.controller.appBecameActive()
        fixture.controller.appEnteredBackground()
        fixture.events.onRouteChanged?("Audio route changed: category")
        fixture.events.onEngineConfigurationChanged?()
        fixture.events.onMediaServicesReset?()

        XCTAssertNil(viewModel.debugBeginIOSPlayoutProofForRaceTests(requestRecovery: false))
        XCTAssertNil(viewModel.debugBeginIOSPlayoutProofForRaceTests(requestRecovery: true))
        await viewModel.debugRefreshIOSPlayoutProofForRaceTests()
        await viewModel.debugRefreshIOSPlayoutOracleForTests(from: peer)

        XCTAssertEqual(diagnosticReadCount, 0)
        XCTAssertEqual(nativeRecoveryRequestCount, 0)
        XCTAssertNil(viewModel.debugIOSPlayoutProofState.handle)
        XCTAssertFalse(viewModel.debugIOSPlayoutRecoveryIsAuthorized)
        XCTAssertNil(viewModel.audioPlayoutOracle)
        XCTAssertFalse(fixture.playback.nativeAudioEnabled)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)
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
        fixture.events.onInterruptionBegan?()

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
        let snapshot = WorldwideAudioPlayoutOracleSnapshot(
            sessionGeneration: UUID(),
            diagnostics: diagnostics,
            inboundAudio: WebRTCAudioStatistics(
                totalAudioEnergy: 0.05,
                totalSamplesDuration: 0.2
            )
        )
        let parsed = try XCTUnwrap(
            PhysicalAudioPlayoutSnapshot(accessibilityValue: snapshot.accessibilityValue)
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

    private func prepareReplacementAudio(_ controller: WorldwideAudioLifecycleController) {
        controller.prepare(serverName: "Replacement Mac")
        controller.updateRuntimePlayout(
            isReady: false,
            failureMessage: "Replacement sentinel failure",
            diagnostic: "Replacement sentinel diagnostic"
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

    private func makeFixture(nonEndedCallCount: Int = 0) -> AudioLifecycleFixture {
        let playback = AudioPlaybackStub()
        let background = BackgroundPlaybackStub()
        let events = AudioSessionEventsStub()
        let callActivity = CallActivityStub(nonEndedCallCount: nonEndedCallCount)
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
    modeIsDefault: Bool = true,
    categoryOptionsAreEmpty: Bool = true,
    routeSharingPolicyIsDefault: Bool = true,
    sampleRate: Double = 48_000,
    outputIOBufferDuration: TimeInterval = 0.01,
    outputChannelCount: Int = 2,
    audioUnitSubType: UInt32 = kAudioUnitSubType_RemoteIO,
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
        modeIsDefault: modeIsDefault,
        categoryOptionsAreEmpty: categoryOptionsAreEmpty,
        routeSharingPolicyIsDefault: routeSharingPolicyIsDefault,
        sampleRate: sampleRate,
        outputIOBufferDuration: outputIOBufferDuration,
        outputChannelCount: outputChannelCount,
        audioUnitSubType: audioUnitSubType,
        failureCode: failureCode,
        lastLifecycleStatus:
            lastLifecycleStatus ?? (failureCode == 0 ? noErr : lastStatus),
        failureMessage: failureCode == 0 ? nil : "Synthetic lifecycle failure",
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
    var onRecover: (() -> Void)?
    private(set) var activateCount = 0
    private(set) var recoverCount = 0
    private(set) var prepareManualAudioDisabledCount = 0
    private(set) var deactivateCount = 0
    private(set) var nativeAudioEnabled = false

    func activate() throws {
        activateCount += 1
        if let activateError { throw activateError }
        nativeAudioEnabled = true
    }

    func recover() throws {
        recoverCount += 1
        onRecover?()
        if let recoverError { throw recoverError }
        nativeAudioEnabled = true
    }

    func prepareManualAudioDisabled() {
        prepareManualAudioDisabledCount += 1
        nativeAudioEnabled = false
    }

    func deactivate() {
        deactivateCount += 1
        nativeAudioEnabled = false
    }
}

@MainActor
private final class CallActivityStub: WorldwideCallActivityObserving {
    private(set) var nonEndedCallCount: Int
    private var stagedLiveNonEndedCallCount: Int?
    var liveNonEndedCallCount: Int {
        stagedLiveNonEndedCallCount ?? nonEndedCallCount
    }
    var onNonEndedCallCountChanged: ((Int) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var isObserving = false

    init(nonEndedCallCount: Int = 0) {
        self.nonEndedCallCount = max(0, nonEndedCallCount)
    }

    func startObserving() {
        startCount += 1
        isObserving = true
    }

    func stopObserving() {
        stopCount += 1
        isObserving = false
        nonEndedCallCount = 0
    }

    func setNonEndedCallCount(_ count: Int) {
        let normalized = max(0, count)
        stagedLiveNonEndedCallCount = nil
        guard normalized != nonEndedCallCount else { return }
        nonEndedCallCount = normalized
        if isObserving {
            onNonEndedCallCountChanged?(normalized)
        }
    }

    func stageLiveNonEndedCallCountWithoutCallback(_ count: Int) {
        stagedLiveNonEndedCallCount = max(0, count)
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
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: ((Bool) -> Void)?
    var onRouteChanged: ((String) -> Void)?
    var onEngineConfigurationChanged: (() -> Void)?
    var onMediaServicesReset: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func startObserving() {
        startCount += 1
    }

    func stopObserving() {
        stopCount += 1
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
