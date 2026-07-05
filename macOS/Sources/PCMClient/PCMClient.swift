import Foundation
import Network
import Streaming

final class PCMClient {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let authToken: String?
    private let queue = DispatchQueue(label: "MacCaptureVerifier.PCMClient")

    init(host: String, port: UInt16, authToken: String? = nil) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw PCMClientError.invalidPort(port)
        }
        self.host = NWEndpoint.Host(host)
        self.port = nwPort
        self.authToken = authToken?.nilIfEmpty
    }

    func run(maxPackets: Int) async throws -> PCMClientReport {
        let connection = NWConnection(host: host, port: port, using: .tcp)
        try await startAndWaitUntilReady(connection)
        try await sendAuthIfNeeded(connection)

        let startedAt = Date()
        let headerData = try await receiveExact(PCMStreamProtocol.headerByteCount, from: connection)
        let header = try PacketParser.parseHeader(headerData)

        var lastSequence: UInt32?
        var lastTimestamp: UInt64?
        var packets = 0
        var bytes = 0
        var framingErrors = 0
        var timestampErrors = 0
        var sequenceErrors = 0

        while packets < maxPackets {
            let lengthData = try await receiveExact(4, from: connection)
            let packetLength = try PacketParser.packetLength(lengthData)
            let remainder = try await receiveExact(Int(packetLength) - 4, from: connection)
            var packetHeader = Data(capacity: PCMStreamProtocol.packetHeaderByteCount)
            packetHeader.append(lengthData)
            packetHeader.append(remainder.prefix(PCMStreamProtocol.packetHeaderByteCount - 4))
            let metadata = try PacketParser.parsePacketHeader(packetHeader)

            do {
                try PacketParser.validatePayloadByteCount(
                    packetLength: packetLength,
                    metadata: metadata,
                    channels: header.channels
                )
            } catch {
                framingErrors += 1
            }

            if let lastSequence, metadata.sequence != lastSequence &+ 1 {
                sequenceErrors += 1
            }

            if let lastTimestamp, metadata.presentationTimestampNanoseconds < lastTimestamp {
                timestampErrors += 1
            }

            lastSequence = metadata.sequence
            lastTimestamp = metadata.presentationTimestampNanoseconds
            packets += 1
            bytes += Int(packetLength)
        }

        connection.cancel()

        return PCMClientReport(
            sampleRate: header.sampleRate,
            channels: header.channels,
            packets: packets,
            bytes: bytes,
            duration: Date().timeIntervalSince(startedAt),
            framingErrors: framingErrors,
            sequenceErrors: sequenceErrors,
            timestampErrors: timestampErrors
        )
    }

    private func startAndWaitUntilReady(_ connection: NWConnection) async throws {
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

    private func receiveExact(_ byteCount: Int, from connection: NWConnection) async throws -> Data {
        var data = Data()
        data.reserveCapacity(byteCount)

        while data.count < byteCount {
            let chunk = try await receive(minimum: 1, maximum: byteCount - data.count, from: connection)
            if chunk.isEmpty {
                throw PCMClientError.connectionClosed
            }
            data.append(chunk)
        }

        return data
    }

    private func receive(minimum: Int, maximum: Int, from connection: NWConnection) async throws -> Data {
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

                continuation.resume(throwing: PCMClientError.connectionClosed)
            }
        }
    }

    private func sendAuthIfNeeded(_ connection: NWConnection) async throws {
        guard let authToken else { return }
        let request = try PCMAuthProtocol.makeRequest(token: authToken)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: request, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

struct PCMClientReport {
    let sampleRate: UInt32
    let channels: UInt16
    let packets: Int
    let bytes: Int
    let duration: TimeInterval
    let framingErrors: Int
    let sequenceErrors: Int
    let timestampErrors: Int

    func render() -> String {
        var lines: [String] = []
        lines.append("PCM client report")
        lines.append("-----------------")
        lines.append("Sample rate: \(sampleRate)")
        lines.append("Channels: \(channels)")
        lines.append("Packets: \(packets)")
        lines.append("Bytes: \(bytes)")
        lines.append("Duration: \(String(format: "%.2f", duration)) s")
        lines.append("Approx throughput: \(String(format: "%.0f", Double(bytes) / max(duration, 0.001))) bytes/s")
        lines.append("Framing errors: \(framingErrors)")
        lines.append("Sequence errors: \(sequenceErrors)")
        lines.append("Timestamp errors: \(timestampErrors)")
        return lines.joined(separator: "\n")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum PCMClientError: LocalizedError {
    case invalidPort(UInt16)
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            "Invalid TCP port \(port)"
        case .connectionClosed:
            "Connection closed before requested bytes were received"
        }
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
