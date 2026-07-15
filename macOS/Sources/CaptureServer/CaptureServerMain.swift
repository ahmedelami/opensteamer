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

            let worldwideScreenService: WorldwideScreenService?
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
                let service = try WorldwideScreenService(
                    endpoint: rendezvousURL,
                    forceRelay: options.forceRelay,
                    displayID: options.displayID,
                    maximumWidth: options.screenMaximumWidth,
                    framesPerSecond: options.screenFramesPerSecond,
                    maximumVideoBitrate: Int(options.screenBitrate),
                    remoteInputController: remoteInputController,
                    logger: logger
                )
                let invitationCode = try await service.start()
                worldwideScreenService = service

                // This is the sole intentional presentation of the pairing capability.
                // Routine diagnostics must never repeat it or include its derived channel.
                print("")
                print("Worldwide one-time connection code")
                print("----------------------------------")
                print(invitationCode)
                print("Enter this code on the iPhone before it expires.")
                print("")
            } else {
                worldwideScreenService = nil
            }

            let monitor: Task<Void, Never>?
            if let server {
                monitor = Task {
                    await monitorServer(server: server, screenService: screenService, logger: logger)
                }
            } else {
                monitor = nil
            }

            let report: StreamingCaptureReport?
            do {
                if let server {
                    let manager = StreamingCaptureManager(
                        duration: options.duration,
                        displayID: options.displayID,
                        captureMode: options.captureMode,
                        sink: server,
                        logger: logger
                    )
                    report = try await manager.run()
                } else if let worldwideScreenService {
                    try await waitForWorldwideService(
                        worldwideScreenService,
                        duration: options.duration
                    )
                    report = nil
                } else {
                    throw CaptureServerMainError.noEnabledService
                }
            } catch {
                monitor?.cancel()
                await worldwideScreenService?.stop()
                await screenService?.stop()
                server?.stop()
                throw error
            }
            monitor?.cancel()
            await worldwideScreenService?.stop()
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

    private static func waitForWorldwideService(
        _ service: WorldwideScreenService,
        duration: TimeInterval?
    ) async throws {
        guard let duration else {
            for await _ in service.completion {
                return
            }
            return
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in service.completion {
                    return
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(duration))
            }
            _ = try await group.next()
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

private enum CaptureServerMainError: LocalizedError {
    case noEnabledService

    var errorDescription: String? {
        "No capture service is enabled."
    }
}
