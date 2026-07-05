import Foundation
import Network
import Streaming

public final class PacketReader: @unchecked Sendable {
    private let connection: NWConnection
    private let authToken: String?
    private let queue = DispatchQueue(label: "MacCaptureVerifier.ClientCore.PacketReader")

    public init(host: String, port: UInt16, authToken: String? = nil) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw PacketReaderError.invalidPort(port)
        }
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.authToken = authToken?.nilIfEmpty
    }

    public init(endpoint: NWEndpoint, authToken: String? = nil) {
        self.connection = NWConnection(to: endpoint, using: .tcp)
        self.authToken = authToken?.nilIfEmpty
    }

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

    public func cancel() {
        connection.cancel()
    }

    public func authenticateIfNeeded() async throws {
        guard let authToken else { return }
        let request = try PCMAuthProtocol.makeRequest(token: authToken)
        try await send(request)
    }

    public func readHeader() async throws -> PCMStreamHeader {
        let headerData = try await receiveExact(PCMStreamProtocol.headerByteCount)
        return try PacketParser.parseHeader(headerData)
    }

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
