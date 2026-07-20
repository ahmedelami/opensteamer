import AVFAudio
import AudioToolbox
import RemoteSessionCore
import XCTest
@testable import WebRTCTransport

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
}

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
