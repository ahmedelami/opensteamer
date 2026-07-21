import Foundation
import Network
import Streaming

/// Reads the legacy length-prefixed PCM stream from a TCP connection.
///
/// This transport is retained for trusted LAN and diagnostic use; worldwide sessions use the
/// authenticated WebRTC path instead.
public final class PacketReader: @unchecked Sendable {
    private let connection: NWConnection
    private let authToken: String?
    private let queue = DispatchQueue(label: "MacCaptureVerifier.ClientCore.PacketReader")

    /// Creates a reader for a host and numeric TCP port.
    public init(host: String, port: UInt16, authToken: String? = nil) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw PacketReaderError.invalidPort(port)
        }
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.authToken = authToken?.nilIfEmpty
    }

    /// Creates a reader for an already-discovered Network framework endpoint.
    public init(endpoint: NWEndpoint, authToken: String? = nil) {
        self.connection = NWConnection(to: endpoint, using: .tcp)
        self.authToken = authToken?.nilIfEmpty
    }

    /// Starts the connection and returns once Network.framework reports it ready.
    public func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let resumeOnce = ResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce.resume()
                case .failed(let error):
                    resumeOnce.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Cancels any pending network work.
    public func cancel() {
        connection.cancel()
    }

    /// Sends the legacy pre-stream authentication request when a token was configured.
    public func authenticateIfNeeded() async throws {
        guard let authToken else { return }
        let request = try PCMAuthProtocol.makeRequest(token: authToken)
        try await send(request)
    }

    /// Reads and validates the fixed-width stream header.
    public func readHeader() async throws -> PCMStreamHeader {
        let headerData = try await receiveExact(PCMStreamProtocol.headerByteCount)
        return try PacketParser.parseHeader(headerData)
    }

    /// Reads one complete frame and validates its declared payload size against `header`.
    public func readFrame(header: PCMStreamHeader) async throws -> PCMFrame {
        let lengthData = try await receiveExact(4)
        let packetLength = try PacketParser.packetLength(lengthData)
        let remainder = try await receiveExact(Int(packetLength) - 4)
        var packetHeader = Data(capacity: PCMStreamProtocol.packetHeaderByteCount)
        packetHeader.append(lengthData)
        packetHeader.append(remainder.prefix(PCMStreamProtocol.packetHeaderByteCount - 4))

        let metadata = try PacketParser.parsePacketHeader(packetHeader)
        try PacketParser.validatePayloadByteCount(
            packetLength: packetLength,
            metadata: metadata,
            channels: header.channels
        )

        let payloadStart = PCMStreamProtocol.packetHeaderByteCount - 4
        let payload = Data(remainder.suffix(remainder.count - payloadStart))
        return PCMFrame(metadata: metadata, pcmBytes: payload, packetLength: packetLength)
    }

    private func receiveExact(_ byteCount: Int) async throws -> Data {
        var data = Data()
        data.reserveCapacity(byteCount)

        while data.count < byteCount {
            let chunk = try await receive(minimum: 1, maximum: byteCount - data.count)
            if chunk.isEmpty {
                throw PacketReaderError.connectionClosed
            }
            data.append(chunk)
        }

        return data
    }

    private func receive(minimum: Int, maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let data {
                    continuation.resume(returning: data)
                    return
                }

                if isComplete {
                    continuation.resume(returning: Data())
                    return
                }

                continuation.resume(throwing: PacketReaderError.connectionClosed)
            }
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

/// Framing and lifecycle errors specific to the TCP packet reader.
public enum PacketReaderError: LocalizedError {
    case invalidPort(UInt16)
    case connectionClosed

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            "Invalid TCP port \(port)"
        case .connectionClosed:
            "Connection closed before requested bytes were received"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

/// Makes the many-state Network.framework callback safe for a single Swift continuation.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func resume() {
        take()?.resume()
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Void, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = continuation
        self.continuation = nil
        return continuation
    }
}
