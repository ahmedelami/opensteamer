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

            let server = try TCPServer(
                host: options.host,
                port: options.port,
                bonjourName: options.bonjourName,
                authToken: options.authToken,
                logger: logger
            )
            try server.start()

            let monitor = Task {
                await monitorServer(server: server, logger: logger)
            }

            let manager = StreamingCaptureManager(
                duration: options.duration,
                displayID: options.displayID,
                captureMode: options.captureMode,
                sink: server,
                logger: logger
            )

            let report = try await manager.run()
            monitor.cancel()
            server.stop()
            print(report.render())
            let snapshot = server.snapshot()
            print("")
            print("Server report")
            print("-------------")
            print("Connected clients: \(snapshot.connectedClients)")
            print("Reconnects: \(snapshot.reconnects)")
            print("Packets sent: \(snapshot.packetsSent)")
            print("Bytes sent: \(snapshot.bytesSent)")
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func monitorServer(server: TCPServer, logger: Logger) async {
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
            } catch {
                return
            }
        }
    }
}
