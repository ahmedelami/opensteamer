import ClientCore
import Foundation
import Network

/// Coordinates the legacy local/relay PCM stream, AVAudioSession, discovery, and diagnostics UI.
///
/// A connection generation invalidates every prior retry loop. Credentials remain in memory only
/// for the selected session and are never included in errors, metrics, or Now Playing metadata.
@MainActor
final class StreamSessionViewModel: ObservableObject {
    @Published private(set) var servers: [ServerInfo] = []
    @Published private(set) var stateText = "Idle"
    @Published private(set) var selectedServer: ServerInfo?
    @Published private(set) var metrics = StreamMetrics()
    @Published private(set) var lastError: String?
    @Published private(set) var audioRouteText = "Inactive"
    @Published private(set) var audioSessionSnapshot = AudioSessionSnapshot.inactive
    @Published private(set) var rendererStateText = "Unavailable"

    private let browser = BonjourBrowser()
    private let audioSession = AudioSessionManager()
    private let backgroundPlayback = BackgroundPlaybackCoordinator()
    private var streamSession: StreamSession?
    private var connectTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var reconnectAfterInterruption = false
    private var appIsInBackground = false
    private var connectionGeneration = UUID()
    private var selectedAuthToken: String?
    private var selectedRelayURL: URL?

    var screenVideoConnectionDescriptor: ScreenVideoConnectionDescriptor? {
        // The legacy screen side channel exists only beside a direct TCP audio endpoint. Relay
        // sessions do not imply a reachable adjacent port and therefore expose no descriptor.
        guard selectedRelayURL == nil, let selectedServer else { return nil }

        let screenEndpoint: NWEndpoint
        switch selectedServer.endpoint {
        case .service(let name, _, let domain, let interface):
            screenEndpoint = .service(
                name: name,
                type: "_mcap-screen._tcp",
                domain: domain,
                interface: interface
            )
        case .hostPort(let host, let audioPort):
            guard audioPort.rawValue < UInt16.max,
                  let screenPort = NWEndpoint.Port(rawValue: audioPort.rawValue + 1) else {
                return nil
            }
            screenEndpoint = .hostPort(host: host, port: screenPort)
        default:
            return nil
        }

        return ScreenVideoConnectionDescriptor(
            endpoint: screenEndpoint,
            authToken: selectedAuthToken,
            displayName: selectedServer.name
        )
    }

    init() {
        audioSession.onInterruptionBegan = { [weak self] in
            self?.handleInterruptionBegan()
        }
        audioSession.onInterruptionEnded = { [weak self] shouldResume in
            self?.handleInterruptionEnded(shouldResume: shouldResume)
        }
        audioSession.onRouteChanged = { [weak self] message in
            self?.lastError = message
            self?.audioRouteText = self?.audioSession.currentRouteDescription ?? "Unknown"
        }
        audioSession.onEngineConfigurationChanged = { [weak self] in
            self?.handleEngineConfigurationChanged()
        }
        audioSession.onMediaServicesReset = { [weak self] in
            self?.handleMediaServicesReset()
        }
        audioSession.onSnapshotChanged = { [weak self] snapshot in
            self?.audioSessionSnapshot = snapshot
            self?.audioRouteText = snapshot.outputRoute
        }
    }

    func startBrowsing() {
        browser.onServersChanged = { [weak self] servers in
            Task { @MainActor in
                self?.servers = servers
            }
        }
        browser.onError = { [weak self] message in
            Task { @MainActor in
                self?.lastError = message
                self?.stateText = "Discovery failed"
            }
        }
        browser.start()
    }

    func stopBrowsing() {
        browser.stop()
    }

    func connect(host: String, port: UInt16, authToken: String?) {
        guard let server = ServerInfo(host: host, port: port) else {
            stateText = "Invalid endpoint"
            lastError = "Enter a valid host and port"
            return
        }

        connect(to: server, authToken: authToken)
    }

    func connect(relayURLString: String, authToken: String?) {
        guard let relayURL = Self.normalizedWebSocketURL(from: relayURLString) else {
            stateText = "Invalid relay URL"
            lastError = "Enter a valid ws://, wss://, http://, or https:// URL"
            return
        }

        disconnect()
        selectedServer = ServerInfo(relayURL: relayURL)
        selectedRelayURL = relayURL
        selectedAuthToken = authToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        lastError = nil
        metrics = StreamMetrics()
        stateText = "Connecting"
        audioSession.startObserving()
        audioRouteText = audioSession.currentRouteDescription
        publishPlaybackState(isPlaying: false)
        connectionGeneration = UUID()
        let generation = connectionGeneration
        let token = selectedAuthToken

        connectTask = Task { [weak self] in
            await self?.runConnectionLoop(
                server: ServerInfo(relayURL: relayURL),
                relayURL: relayURL,
                authToken: token,
                generation: generation
            )
        }
    }

    func connect(to server: ServerInfo, authToken: String? = nil) {
        disconnect()
        selectedServer = server
        selectedRelayURL = nil
        selectedAuthToken = authToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        lastError = nil
        metrics = StreamMetrics()

        guard server.isCompatible else {
            stateText = "Incompatible"
            lastError = server.compatibility.message
            return
        }

        stateText = "Connecting"
        audioSession.startObserving()
        audioRouteText = audioSession.currentRouteDescription
        publishPlaybackState(isPlaying: false)
        connectionGeneration = UUID()
        let generation = connectionGeneration
        let authToken = selectedAuthToken

        connectTask = Task { [weak self] in
            await self?.runConnectionLoop(
                server: server,
                relayURL: nil,
                authToken: authToken,
                generation: generation
            )
        }
    }

    func disconnect() {
        // Rotate the generation before cancellation so an already-enqueued callback is stale even
        // if its underlying task or transport does not observe cancellation immediately.
        connectionGeneration = UUID()
        connectTask?.cancel()
        metricsTask?.cancel()
        streamSession?.disconnect()
        audioSession.stopObserving()
        audioSession.deactivate()
        backgroundPlayback.clear()
        connectTask = nil
        metricsTask = nil
        streamSession = nil
        reconnectAfterInterruption = false
        selectedAuthToken = nil
        selectedRelayURL = nil
        selectedServer = nil
        metrics = StreamMetrics()
        audioRouteText = "Inactive"
        audioSessionSnapshot = .inactive
        rendererStateText = "Unavailable"
        stateText = "Idle"
    }

    func resumeConnectionIfNeeded() {
        guard connectTask == nil, let selectedServer else { return }

        stateText = "Reconnecting"
        audioSession.startObserving()
        audioRouteText = audioSession.currentRouteDescription
        connectionGeneration = UUID()
        let generation = connectionGeneration
        let authToken = selectedAuthToken
        let relayURL = selectedRelayURL

        connectTask = Task { [weak self] in
            await self?.runConnectionLoop(
                server: selectedServer,
                relayURL: relayURL,
                authToken: authToken,
                generation: generation
            )
        }
    }

    func handleAppBecameActive() {
        appIsInBackground = false
        backgroundPlayback.endTransitionTask()
        startBrowsing()
        resumeConnectionIfNeeded()
        publishPlaybackState(isPlaying: connectTask != nil && streamSession != nil)
    }

    func handleAppBecameInactive() {
        guard selectedServer != nil else { return }

        backgroundPlayback.beginTransitionTask()
        publishPlaybackState(isPlaying: connectTask != nil && streamSession != nil)
    }

    func handleAppEnteredBackground() {
        appIsInBackground = true
        stopBrowsing()

        guard selectedServer != nil else {
            backgroundPlayback.endTransitionTask()
            return
        }

        backgroundPlayback.beginTransitionTask()
        do {
            try audioSession.activate()
            audioRouteText = audioSession.currentRouteDescription
            try streamSession?.resumeRendering()
            rendererStateText = streamSession?.rendererStateDescription ?? "Unavailable"
            publishPlaybackState(isPlaying: connectTask != nil && streamSession != nil)
        } catch {
            lastError = "Background audio recovery failed: \(error.localizedDescription)"
            publishPlaybackState(isPlaying: false)
        }
    }

    private func runConnectionLoop(server: ServerInfo, relayURL: URL?, authToken: String?, generation: UUID) async {
        defer {
            if generation == connectionGeneration {
                connectTask = nil
                publishPlaybackState(isPlaying: false)
            }
        }

        var attempt = 0

        while !Task.isCancelled, generation == connectionGeneration {
            // A StreamSession is single-use. Reconnects create a fresh renderer/transport rather
            // than attempting to revive state that may have failed inside AudioToolbox.
            let session = StreamSession()
            streamSession = session
            startMetricsPolling(session: session)

            do {
                try audioSession.activate()
                audioRouteText = audioSession.currentRouteDescription
                publishPlaybackState(isPlaying: true)
                stateText = attempt == 0 ? "Connecting" : "Reconnecting"
                if let relayURL {
                    _ = try await session.run(
                        webSocketURL: relayURL,
                        authToken: authToken,
                        duration: nil,
                        latencyMilliseconds: 150,
                        maxPackets: nil
                    )
                } else {
                    _ = try await session.run(
                        endpoint: server.endpoint,
                        authToken: authToken,
                        duration: nil,
                        latencyMilliseconds: 80,
                        maxPackets: nil
                    )
                }

                if !Task.isCancelled {
                    stateText = "Disconnected"
                    publishPlaybackState(isPlaying: false)
                }
                break
            } catch is CancellationError {
                break
            } catch {
                metricsTask?.cancel()
                session.disconnect()

                guard !Task.isCancelled, !reconnectAfterInterruption else {
                    break
                }

                attempt += 1
                let delaySeconds = reconnectDelay(for: attempt)
                lastError = error.localizedDescription
                stateText = StreamState.reconnecting(
                    attempt: attempt,
                    delaySeconds: delaySeconds
                ).displayText
                publishPlaybackState(isPlaying: false)
                if appIsInBackground {
                    backgroundPlayback.beginTransitionTask()
                }

                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                guard generation == connectionGeneration else {
                    break
                }
            }
        }
    }

    private func startMetricsPolling(session: StreamSession) {
        // Polling reads the thread-safe core snapshot off actor, then publishes one coherent group
        // of values on MainActor for SwiftUI.
        metricsTask?.cancel()
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = session.snapshot()
                let state = session.state
                let rendererState = session.rendererStateDescription
                await MainActor.run {
                    self?.metrics = snapshot
                    self?.stateText = state.displayText
                    self?.rendererStateText = rendererState
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func handleInterruptionBegan() {
        guard let streamSession else { return }
        reconnectAfterInterruption = selectedServer != nil
        streamSession.pauseRendering()
        rendererStateText = streamSession.rendererStateDescription
        stateText = StreamState.paused.displayText
        publishPlaybackState(isPlaying: false)
    }

    private func handleInterruptionEnded(shouldResume: Bool) {
        guard reconnectAfterInterruption, let selectedServer else { return }
        reconnectAfterInterruption = false

        if !shouldResume {
            lastError = "Audio interruption ended without the system resume flag; trying to resume because streaming was active."
        }

        do {
            try audioSession.activate()
            audioRouteText = audioSession.currentRouteDescription
            try streamSession?.resumeRendering()
            rendererStateText = streamSession?.rendererStateDescription ?? "Unavailable"
            publishPlaybackState(isPlaying: true)
        } catch {
            lastError = error.localizedDescription
            if streamSession == nil || connectTask == nil {
                let authToken = selectedAuthToken
                let relayURL = selectedRelayURL
                if let relayURL {
                    connect(relayURLString: relayURL.absoluteString, authToken: authToken)
                } else {
                    connect(to: selectedServer, authToken: authToken)
                }
            }
        }
    }

    private func handleEngineConfigurationChanged() {
        recoverRendererAfterAudioServiceEvent(prefix: "Audio engine configuration recovery failed")
    }

    private func handleMediaServicesReset() {
        recoverRendererAfterAudioServiceEvent(prefix: "Media services reset recovery failed")
    }

    private func recoverRendererAfterAudioServiceEvent(prefix: String) {
        guard streamSession != nil else { return }
        do {
            try audioSession.activate()
            try streamSession?.restartRendering()
            rendererStateText = streamSession?.rendererStateDescription ?? "Unavailable"
            publishPlaybackState(isPlaying: true)
        } catch {
            lastError = "\(prefix): \(error.localizedDescription)"
        }
    }

    private func publishPlaybackState(isPlaying: Bool) {
        guard let selectedServer else {
            backgroundPlayback.clear()
            return
        }

        backgroundPlayback.publishLiveStream(serverName: selectedServer.name, isPlaying: isPlaying)
    }

    private func reconnectDelay(for attempt: Int) -> TimeInterval {
        min(pow(2, Double(max(attempt - 1, 0))), 30)
    }

    private static func normalizedWebSocketURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components = URLComponents(string: trimmed)
        switch components?.scheme?.lowercased() {
        case "wss", "ws":
            break
        case "https":
            components?.scheme = "wss"
        case "http":
            components?.scheme = "ws"
        default:
            return nil
        }

        if components?.path.isEmpty == true || components?.path == "/" {
            components?.path = "/stream"
        }
        guard let url = components?.url, url.host != nil else {
            return nil
        }
        return url
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension StreamState {
    var displayText: String {
        switch self {
        case .idle:
            "Idle"
        case .connecting:
            "Connecting"
        case .buffering(let bufferedFrames, let targetFrames):
            "Buffering \(bufferedFrames)/\(targetFrames)"
        case .playing:
            "Playing"
        case .reconnecting(let attempt, let delaySeconds):
            "Reconnecting \(attempt) in \(Int(delaySeconds))s"
        case .paused:
            "Paused"
        case .disconnected:
            "Disconnected"
        case .failed(let message):
            "Failed: \(message)"
        }
    }
}
