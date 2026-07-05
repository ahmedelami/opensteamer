import ClientCore
import Foundation
import Network

@MainActor
final class StreamSessionViewModel: ObservableObject {
    @Published private(set) var servers: [ServerInfo] = []
    @Published private(set) var stateText = "Idle"
    @Published private(set) var selectedServer: ServerInfo?
    @Published private(set) var metrics = StreamMetrics()
    @Published private(set) var lastError: String?
    @Published private(set) var audioRouteText = "Inactive"

    private let browser = BonjourBrowser()
    private let audioSession = AudioSessionManager()
    private var streamSession: StreamSession?
    private var connectTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var reconnectAfterInterruption = false
    private var connectionGeneration = UUID()
    private var selectedAuthToken: String?
    private var selectedRelayURL: URL?

    init() {
        audioSession.onInterruptionBegan = { [weak self] in
            self?.handleInterruptionBegan()
        }
        audioSession.onInterruptionEnded = { [weak self] in
            self?.handleInterruptionEnded()
        }
        audioSession.onRouteChanged = { [weak self] message in
            self?.lastError = message
            self?.audioRouteText = self?.audioSession.currentRouteDescription ?? "Unknown"
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
        connectionGeneration = UUID()
        connectTask?.cancel()
        metricsTask?.cancel()
        streamSession?.disconnect()
        audioSession.stopObserving()
        audioSession.deactivate()
        connectTask = nil
        metricsTask = nil
        streamSession = nil
        reconnectAfterInterruption = false
        selectedAuthToken = nil
        selectedRelayURL = nil
        selectedServer = nil
        metrics = StreamMetrics()
        audioRouteText = "Inactive"
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

    private func runConnectionLoop(server: ServerInfo, relayURL: URL?, authToken: String?, generation: UUID) async {
        defer {
            if generation == connectionGeneration {
                connectTask = nil
            }
        }

        var attempt = 0

        while !Task.isCancelled, generation == connectionGeneration {
            let session = StreamSession()
            streamSession = session
            startMetricsPolling(session: session)

            do {
                try audioSession.activate()
                audioRouteText = audioSession.currentRouteDescription
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

                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                guard generation == connectionGeneration else {
                    break
                }
            }
        }
    }

    private func startMetricsPolling(session: StreamSession) {
        metricsTask?.cancel()
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = session.snapshot()
                let state = session.state
                await MainActor.run {
                    self?.metrics = snapshot
                    self?.stateText = state.displayText
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func handleInterruptionBegan() {
        guard connectTask != nil else { return }
        connectionGeneration = UUID()
        reconnectAfterInterruption = selectedServer != nil
        connectTask?.cancel()
        metricsTask?.cancel()
        streamSession?.disconnect()
        connectTask = nil
        metricsTask = nil
        streamSession = nil
        stateText = StreamState.paused.displayText
    }

    private func handleInterruptionEnded() {
        guard reconnectAfterInterruption, let selectedServer else { return }
        let authToken = selectedAuthToken
        let relayURL = selectedRelayURL
        reconnectAfterInterruption = false
        if let relayURL {
            connect(relayURLString: relayURL.absoluteString, authToken: authToken)
        } else {
            connect(to: selectedServer, authToken: authToken)
        }
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
