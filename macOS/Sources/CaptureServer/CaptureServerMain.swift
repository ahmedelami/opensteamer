import CaptureCore
import Foundation
import Server

@main
struct CaptureServerMain {
    static func main() async {
        do {
            let options = try CaptureServerOptions.parse(CommandLine.arguments)
            if options.showHelp {
                print(CaptureServerOptions.usage)
                return
            }

            let logger = ConsoleLogger(verbose: options.verbose)
            if options.listDisplays {
                try await ShareableContentLister(logger: logger).printDisplays()
                return
            }

            if options.verifyRouting {
                let health = try BlackHoleRouteVerifier.verifyCurrentRoute()
                print(health.render())
                if !health.isHealthy {
                    exit(2)
                }
                return
            }

            let worldwideHostProcessLock: WorldwideHostProcessLock?
            if options.worldwideEnabled {
                worldwideHostProcessLock = try WorldwideHostProcessLock.acquire()
            } else {
                worldwideHostProcessLock = nil
            }
            defer { worldwideHostProcessLock?.release() }

            let server: TCPServer?
            if options.lanEnabled {
                let lanServer = try TCPServer(
                    host: options.host,
                    port: options.port,
                    bonjourName: options.bonjourName,
                    authToken: options.authToken,
                    logger: logger
                )
                try lanServer.start()
                server = lanServer
            } else {
                server = nil
                logger.info("Legacy LAN audio and screen listeners are disabled")
            }

            let screenService: ScreenVideoService?
            if options.lanEnabled, options.screenEnabled {
                if options.authToken == nil {
                    logger.info(
                        "SECURITY: screen video is unauthenticated and plaintext; " +
                        "use only on a trusted LAN or set MCAP_TOKEN"
                    )
                }
                let service = try ScreenVideoService(
                    host: options.host,
                    port: options.screenPort,
                    bonjourName: options.bonjourName,
                    authToken: options.authToken,
                    displayID: options.displayID,
                    maximumWidth: options.screenMaximumWidth,
                    framesPerSecond: options.screenFramesPerSecond,
                    bitrate: options.screenBitrate,
                    logger: logger
                )
                try service.start()
                screenService = service
            } else {
                screenService = nil
            }

            let worldwideHostCoordinator: WorldwideHostCoordinator?
            if options.worldwideEnabled, let rendezvousURL = options.rendezvousURL {
                let remoteInputController = MacRemoteInputController(
                    allowRemoteControl: options.allowRemoteControl
                )
                if options.allowRemoteControl {
                    let permission = remoteInputController.permissionStatus(promptIfNeeded: true)
                    if permission.isAuthorized {
                        logger.info("Worldwide remote input is enabled")
                    } else {
                        logger.info(
                            "Worldwide remote input was requested but remains view-only until " +
                            "Accessibility and event-posting permissions are granted"
                        )
                    }
                }
                let coordinator = WorldwideHostCoordinator(
                    endpoint: rendezvousURL,
                    forceRelay: options.forceRelay,
                    displayID: options.displayID,
                    maximumWidth: options.screenMaximumWidth,
                    framesPerSecond: options.screenFramesPerSecond,
                    maximumVideoBitrate: Int(options.screenBitrate),
                    remoteInputController: remoteInputController,
                    logger: logger
                )
                let startResult = try await coordinator.start(
                    resetPairing: options.resetWorldwidePairing
                )
                worldwideHostCoordinator = coordinator

                switch startResult {
                case .invitation(let invitationCode):
                    // This is the sole intentional presentation of the pairing capability.
                    // Routine diagnostics must never repeat it or include derived channels.
                    print("")
                    print("Worldwide one-time pairing code")
                    print("-------------------------------")
                    print(invitationCode)
                    print("Enter this code on the iPhone before it expires.")
                    print("")
                case .paired(let remoteDisplayName):
                    let name = remoteDisplayName ?? "paired iPhone"
                    logger.info("Worldwide host is available for \(name)")
                }
            } else {
                worldwideHostCoordinator = nil
            }

            let monitor: Task<Void, Never>?
            if let server {
                monitor = Task {
                    await monitorServer(server: server, screenService: screenService, logger: logger)
                }
            } else {
                monitor = nil
            }

            // Leave LAN-only signal behavior untouched. Worldwide mode needs a short async cleanup
            // window so its persistent availability WebSocket cannot outlive a replaced host.
            let terminationSignals = worldwideHostCoordinator.map { _ in
                ProcessTerminationSignalMonitor()
            }
            defer { terminationSignals?.cancel() }

            let report: StreamingCaptureReport?
            do {
                if let server {
                    let terminationTask = makeCoexistenceTerminationTask(
                        coordinator: worldwideHostCoordinator,
                        terminationSignals: terminationSignals
                    )
                    defer { terminationTask?.cancel() }
                    let manager = StreamingCaptureManager(
                        duration: options.duration,
                        displayID: options.displayID,
                        captureMode: options.captureMode,
                        sink: server,
                        logger: logger
                    )
                    report = try await manager.run()
                } else if let worldwideHostCoordinator, let terminationSignals {
                    try await waitForWorldwideHost(
                        worldwideHostCoordinator,
                        duration: options.duration,
                        terminationSignals: terminationSignals.events
                    )
                    report = nil
                } else {
                    throw CaptureServerMainError.noEnabledService
                }
            } catch {
                monitor?.cancel()
                await worldwideHostCoordinator?.stop()
                await screenService?.stop()
                server?.stop()
                throw error
            }
            monitor?.cancel()
            await worldwideHostCoordinator?.stop()
            await screenService?.stop()
            server?.stop()
            if let report, let server {
                print(report.render())
                let snapshot = server.snapshot()
                print("")
                print("Server report")
                print("-------------")
                print("Connected clients: \(snapshot.connectedClients)")
                print("Reconnects: \(snapshot.reconnects)")
                print("Packets sent: \(snapshot.packetsSent)")
                print("Bytes sent: \(snapshot.bytesSent)")
            }
            if let screenService {
                let screenSnapshot = screenService.snapshot()
                print("")
                print("Screen video report")
                print("-------------------")
                print("Connected viewers: \(screenSnapshot.connectedClients)")
                print("Viewer reconnects: \(screenSnapshot.reconnects)")
                print("Frames sent: \(screenSnapshot.framesSent)")
                print("Bytes sent: \(screenSnapshot.bytesSent)")
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func makeCoexistenceTerminationTask(
        coordinator: WorldwideHostCoordinator?,
        terminationSignals: ProcessTerminationSignalMonitor?
    ) -> Task<Void, Never>? {
        guard let coordinator, let terminationSignals else { return nil }
        return Task {
            for await signalNumber in terminationSignals.events {
                guard !Task.isCancelled else { return }
                await coordinator.stop()
                terminationSignals.resumeDefaultHandlingAndReraise(signalNumber)
            }
        }
    }

    private static func waitForWorldwideHost(
        _ coordinator: WorldwideHostCoordinator,
        duration: TimeInterval?,
        terminationSignals: AsyncStream<Int32>
    ) async throws {
        try await withThrowingTaskGroup(of: WorldwideHostWaitOutcome.self) { group in
            group.addTask {
                for try await _ in coordinator.completion {
                    return .coordinatorEnded
                }
                return .coordinatorEnded
            }
            group.addTask {
                for await _ in terminationSignals {
                    try Task.checkCancellation()
                    return .terminationSignal
                }
                return .terminationSignal
            }
            if let duration {
                group.addTask {
                    try await Task.sleep(for: .seconds(duration))
                    return .durationElapsed
                }
            }

            let outcome = try await group.next()
            if outcome == .terminationSignal {
                // Close the availability socket before process replacement so stale exchange state
                // does not outlive this host instance.
                await coordinator.stop()
            }
            group.cancelAll()
        }
    }

    private static func monitorServer(
        server: TCPServer,
        screenService: ScreenVideoService?,
        logger: Logger
    ) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let snapshot = server.snapshot()
                logger.info(
                    "clients=\(snapshot.connectedClients) " +
                    "queued=\(snapshot.queuedPackets) " +
                    "packetsSent=\(snapshot.packetsSent) " +
                    "bytesSent=\(snapshot.bytesSent) " +
                    "reconnects=\(snapshot.reconnects)"
                )
                if let screenService {
                    let video = screenService.snapshot()
                    logger.info(
                        "screenClients=\(video.connectedClients) " +
                        "screenQueued=\(video.queuedPackets) " +
                        "screenFrames=\(video.framesSent) " +
                        "screenBytes=\(video.bytesSent) " +
                        "screenAwaitingAck=\(video.framesAwaitingAcknowledgement)"
                    )
                }
            } catch {
                return
            }
        }
    }
}

private enum WorldwideHostWaitOutcome: Equatable {
    case coordinatorEnded
    case durationElapsed
    case terminationSignal
}

private enum CaptureServerMainError: LocalizedError {
    case noEnabledService

    var errorDescription: String? {
        "No capture service is enabled."
    }
}
