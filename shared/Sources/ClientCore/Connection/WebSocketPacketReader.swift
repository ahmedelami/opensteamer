import Foundation
import Streaming

/// Reads the legacy PCM wire format carried in binary WebSocket messages.
///
/// WebSocket message boundaries need not match protocol packet boundaries, so received bytes are
/// retained until the fixed-width header or declared frame length is complete.
public final class WebSocketPacketReader: @unchecked Sendable {
    private let url: URL
    private let authToken: String?
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private var bufferedData = Data()

    /// Creates a reader for a WebSocket endpoint and optional legacy activation token.
    public init(url: URL, authToken: String? = nil) {
        self.url = url
        self.authToken = authToken?.nilIfEmpty
        self.session = URLSession(configuration: .default)
        self.task = session.webSocketTask(with: url)
    }

    /// Resumes the underlying WebSocket task.
    public func start() async throws {
        task.resume()
    }

    /// Closes the task and invalidates its URL session.
    public func cancel() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    /// Sends the JSON authentication message before binary stream data is consumed.
    public func authenticateIfNeeded() async throws {
        guard let authToken else { return }
        let auth = WebSocketAuthMessage(type: "auth", token: authToken)
        let data = try JSONEncoder().encode(auth)
        let text = String(decoding: data, as: UTF8.self)
        try await send(.string(text))
    }

    /// Reads and validates the fixed-width PCM stream header.
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
        while bufferedData.count < byteCount {
            let chunk = try await receiveBinaryMessage()
            if chunk.isEmpty {
                throw WebSocketPacketReaderError.connectionClosed
            }
            bufferedData.append(chunk)
        }

        let data = Data(bufferedData.prefix(byteCount))
        bufferedData.removeFirst(byteCount)
        return data
    }

    private func receiveBinaryMessage() async throws -> Data {
        let message = try await receive()
        switch message {
        case .data(let data):
            return data
        case .string(let text):
            throw WebSocketPacketReaderError.serverMessage(text)
        @unknown default:
            throw WebSocketPacketReaderError.unsupportedMessage
        }
    }

    private func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            task.receive { result in
                switch result {
                case .success(let message):
                    continuation.resume(returning: message)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.send(message) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

/// Framing and server-message errors specific to the WebSocket transport.
public enum WebSocketPacketReaderError: LocalizedError {
    case connectionClosed
    case serverMessage(String)
    case unsupportedMessage

    public var errorDescription: String? {
        switch self {
        case .connectionClosed:
            "Relay connection closed"
        case .serverMessage(let message):
            "Relay error: \(message)"
        case .unsupportedMessage:
            "Relay sent an unsupported message"
        }
    }
}

private struct WebSocketAuthMessage: Encodable {
    let type: String
    let token: String
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
