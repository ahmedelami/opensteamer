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
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.events.onInterruptionEnded?(false)

        XCTAssertEqual(fixture.playback.recoverCount, recoverCountBeforeInterruption)
        XCTAssertTrue(fixture.controller.snapshot.requiresExplicitResume)
        XCTAssertEqual(fixture.controller.snapshot.stateText, "Paused — resume audio")
        XCTAssertFalse(fixture.controller.snapshot.isPlaying)
        XCTAssertFalse(fixture.remoteAudio.isEnabled)

        fixture.controller.appBecameActive()
        XCTAssertTrue(fixture.controller.snapshot.requiresExplicitResume)
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

    private func makeFixture() -> AudioLifecycleFixture {
        let playback = AudioPlaybackStub()
        let background = BackgroundPlaybackStub()
        let events = AudioSessionEventsStub()
        let remoteAudio = RemoteAudioStub()
        let controller = WorldwideAudioLifecycleController(
            playback: playback,
            backgroundPlayback: background,
            events: events
        )
        return AudioLifecycleFixture(
            controller: controller,
            playback: playback,
            background: background,
            events: events,
            remoteAudio: remoteAudio
        )
    }
}

@MainActor
private struct AudioLifecycleFixture {
    let controller: WorldwideAudioLifecycleController
    let playback: AudioPlaybackStub
    let background: BackgroundPlaybackStub
    let events: AudioSessionEventsStub
    let remoteAudio: RemoteAudioStub
}

@MainActor
private final class RemoteAudioStub: WorldwideRemoteAudioControlling {
    private(set) var enabledValues: [Bool] = []

    var isEnabled: Bool {
        enabledValues.last ?? false
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
    private(set) var activateCount = 0
    private(set) var recoverCount = 0
    private(set) var deactivateCount = 0

    func activate() throws {
        activateCount += 1
        if let activateError { throw activateError }
    }

    func recover() throws {
        recoverCount += 1
        if let recoverError { throw recoverError }
    }

    func deactivate() {
        deactivateCount += 1
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
