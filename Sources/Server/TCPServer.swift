import CaptureCore
import Foundation
import Network
import Streaming

public final class TCPServer: @unchecked Sendable, PCMFrameSink {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let bonjourName: String?
    private let authToken: String?
    private let logger: Logger
    private let queue = DispatchQueue(label: "MacCaptureVerifier.TCPServer")

    private var listener: NWListener?
    private var client: ClientConnection?
    private var header: PCMStreamHeader?
    private var reconnects = 0
    private var closedClientBytesSent: Int64 = 0
    private var closedClientPacketsSent: Int64 = 0

    public init(host: String, port: UInt16, bonjourName: String?, authToken: String? = nil, logger: Logger) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TCPServerError.invalidPort(port)
        }
        self.host = NWEndpoint.Host(host)
        self.port = nwPort
        self.bonjourName = bonjourName
        self.authToken = authToken
        self.logger = logger
    }

    public func start() throws {
        let listener = try NWListener(using: .tcp, on: port)
        if let bonjourName {
            listener.service = NWListener.Service(
                name: bonjourName,
                type: "_mcap._tcp",
                txtRecord: NWTXTRecord([
                    "version": "\(PCMStreamProtocol.version)",
                    "rate": "48000",
                    "channels": "2",
                    "format": "pcm16le"
                ])
            )
            logger.info("Advertising Bonjour service \(bonjourName)._mcap._tcp")
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.logger.info("TCP listener state: \(state)")
        }
        listener.start(queue: queue)
        self.listener = listener
        logger.info("Listening on \(host):\(port.rawValue)")
        if authToken != nil {
            logger.info("Client authentication is required")
        }
    }

    public func stop() {
        queue.sync {
            client?.cancel(reason: "server stopping")
            client = nil
            listener?.cancel()
            listener = nil
        }
    }

    public func configureStream(_ header: PCMStreamHeader) {
        queue.async {
            self.header = header
            self.client?.sendHeader(header)
        }
    }

    public func sendPCMFrame(metadata: PCMPacketMetadata, pcmBytes: Data) {
        queue.async {
            guard let client = self.client else { return }
            if let header = self.header {
                client.sendHeader(header)
            }
            client.sendPacket(metadata: metadata, pcmBytes: pcmBytes)
        }
    }

    public func snapshot() -> TCPServerSnapshot {
        queue.sync {
            TCPServerSnapshot(
                connectedClients: client == nil ? 0 : 1,
                reconnects: reconnects,
                queuedPackets: client?.queuedPackets ?? 0,
                bytesSent: closedClientBytesSent + (client?.bytesSent ?? 0),
                packetsSent: closedClientPacketsSent + (client?.packetsSent ?? 0)
            )
        }
    }

    private func accept(_ connection: NWConnection) {
        queue.async {
            if self.client != nil {
                self.logger.info("Rejecting extra client \(connection.endpoint)")
                connection.cancel()
                return
            }

            self.reconnects += 1
            let client = ClientConnection(
                connection: connection,
                logger: self.logger,
                authToken: self.authToken
            ) { [weak self] closedClient in
                guard let server = self else { return }
                server.queue.async {
                    if server.client === closedClient {
                        server.closedClientBytesSent += closedClient.bytesSent
                        server.closedClientPacketsSent += closedClient.packetsSent
                        server.client = nil
                    }
                }
            }
            self.client = client
            client.start(on: self.queue)
            if let header = self.header {
                client.sendHeader(header)
            }
        }
    }
}

public struct TCPServerSnapshot: Sendable {
    public let connectedClients: Int
    public let reconnects: Int
    public let queuedPackets: Int
    public let bytesSent: Int64
    public let packetsSent: Int64
}

public enum TCPServerError: LocalizedError {
    case invalidPort(UInt16)

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            "Invalid TCP port \(port)"
        }
    }
}
