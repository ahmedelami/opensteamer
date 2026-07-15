import Foundation
import Network
import Streaming

enum ScreenVideoClientEvent: Sendable {
    case connected
    case configuration(ScreenVideoConfiguration, generation: UInt32)
    case frame(ScreenVideoPacket, disposition: ScreenVideoFrameDisposition)
}

final class ScreenVideoFrameDisposition: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Bool) -> Void)?

    init(handler: @escaping @Sendable (Bool) -> Void) {
        self.handler = handler
    }

    func resolve(accepted: Bool) {
        let handler = lock.withLock {
            let handler = self.handler
            self.handler = nil
            return handler
        }
        handler?(accepted)
    }
}

final class ScreenVideoClient: @unchecked Sendable {
    private let connection: NWConnection
    private let authToken: String?
    private let queue = DispatchQueue(label: "AudioStreamer.ScreenVideoClient")
    private let sendQueue = DispatchQueue(label: "AudioStreamer.ScreenVideoClient.Send")
    private let stateLock = NSLock()
    private var configuredGeneration: UInt32?
    private var expectedSequence: UInt32?
    private var waitingForKeyFrame = true
    private var controlsEnabled = false
    private var pendingKeyFrameRequest = false
    private var cancelled = false

    init(descriptor: ScreenVideoConnectionDescriptor) {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 5
        tcpOptions.keepaliveInterval = 2
        tcpOptions.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        self.connection = NWConnection(to: descriptor.endpoint, using: parameters)
        self.authToken = descriptor.authToken?.nilIfEmpty
    }

    func run(onEvent: @escaping @Sendable (ScreenVideoClientEvent) -> Void) async throws {
        try Task.checkCancellation()
        try await startConnection()
        if let authToken {
            try await send(try PCMAuthProtocol.makeRequest(token: authToken))
        }

        let preambleData = try await receiveExact(ScreenVideoProtocol.preambleByteCount)
        _ = try ScreenVideoFraming.parsePreamble(preambleData)
        let shouldSendPendingKeyFrameRequest = stateLock.withLock {
            controlsEnabled = true
            let pending = pendingKeyFrameRequest
            pendingKeyFrameRequest = false
            return pending
        }
        if shouldSendPendingKeyFrameRequest {
            requestKeyFrame()
        }
        onEvent(.connected)

        while !Task.isCancelled, !isCancelled {
            let headerData = try await receiveExact(ScreenVideoProtocol.packetHeaderByteCount)
            let header = try ScreenVideoFraming.parsePacketHeader(headerData)
            let payload = try await receiveExact(Int(header.payloadByteCount))
            var packetData = headerData
            packetData.append(payload)
            let packet = try ScreenVideoFraming.parsePacket(packetData)
            try await handle(packet, onEvent: onEvent)
        }
        throw CancellationError()
    }

    func cancel() {
        stateLock.lock()
        cancelled = true
        controlsEnabled = false
        pendingKeyFrameRequest = false
        stateLock.unlock()
        connection.cancel()
    }

    func requestKeyFrame() {
        let packet = stateLock.withLock { () -> ScreenVideoPacket? in
            waitingForKeyFrame = true
            guard !cancelled else { return nil }
            guard controlsEnabled else {
                pendingKeyFrameRequest = true
                return nil
            }
            pendingKeyFrameRequest = false
            return ScreenVideoPacket(
                type: .keyFrameRequest,
                generation: configuredGeneration ?? 0,
                sequence: expectedSequence ?? 0,
                presentationTimestampNanoseconds: 0
            )
        }
        guard let packet else { return }
        sendControl(packet)
    }

    private var isCancelled: Bool {
        stateLock.withLock { cancelled }
    }

    private func startConnection() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let resumeOnce = ScreenVideoResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce.resume()
                case .failed(let error):
                    resumeOnce.resume(throwing: error)
                case .cancelled:
                    resumeOnce.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func handle(
        _ packet: ScreenVideoPacket,
        onEvent: @escaping @Sendable (ScreenVideoClientEvent) -> Void
    ) async throws {
        switch packet.type {
        case .configuration:
            let configuration = try ScreenVideoFraming.parseConfiguration(packet.payload)
            stateLock.withLock {
                configuredGeneration = packet.generation
                expectedSequence = packet.sequence
                waitingForKeyFrame = true
            }
            onEvent(.configuration(configuration, generation: packet.generation))
        case .frame:
            let canAccept = stateLock.withLock { () -> Bool in
                guard configuredGeneration == packet.generation,
                      expectedSequence == packet.sequence,
                      !waitingForKeyFrame || packet.flags.contains(.keyFrame) else {
                    waitingForKeyFrame = true
                    return false
                }
                expectedSequence = packet.sequence &+ 1
                if packet.flags.contains(.keyFrame) {
                    waitingForKeyFrame = false
                }
                return true
            }
            guard canAccept else {
                requestKeyFrame()
                return
            }
            let disposition = ScreenVideoFrameDisposition { [weak self] accepted in
                guard let self else { return }
                if accepted {
                    self.sendControl(
                        ScreenVideoPacket(
                            type: .acknowledgement,
                            generation: packet.generation,
                            sequence: packet.sequence,
                            presentationTimestampNanoseconds: packet.presentationTimestampNanoseconds
                        )
                    )
                } else {
                    self.requestKeyFrame()
                }
            }
            onEvent(.frame(packet, disposition: disposition))
        case .end:
            cancel()
            throw ScreenVideoClientError.serverEndedStream
        case .acknowledgement, .keyFrameRequest:
            throw ScreenVideoClientError.invalidServerPacket(packet.type)
        }
    }

    private func sendControl(_ packet: ScreenVideoPacket) {
        guard stateLock.withLock({ controlsEnabled && !cancelled }) else { return }
        do {
            let data = try ScreenVideoFraming.makePacket(packet)
            sendQueue.async { [weak self] in
                guard let self,
                      self.stateLock.withLock({ self.controlsEnabled && !self.cancelled }) else {
                    return
                }
                self.connection.send(content: data, completion: .contentProcessed { _ in })
            }
        } catch {
            cancel()
        }
    }

    private func receiveExact(_ byteCount: Int) async throws -> Data {
        guard byteCount > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(byteCount)
        while result.count < byteCount {
            try Task.checkCancellation()
            let data = try await receive(maximumByteCount: byteCount - result.count)
            guard !data.isEmpty else {
                throw ScreenVideoClientError.connectionClosed
            }
            result.append(data)
        }
        return result
    }

    private func receive(maximumByteCount: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maximumByteCount
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(throwing: ScreenVideoClientError.connectionClosed)
                }
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

private enum ScreenVideoClientError: LocalizedError {
    case connectionClosed
    case serverEndedStream
    case invalidServerPacket(ScreenVideoPacketType)

    var errorDescription: String? {
        switch self {
        case .connectionClosed:
            "The Mac closed the screen video connection"
        case .serverEndedStream:
            "The Mac ended the screen video stream"
        case .invalidServerPacket(let type):
            "The Mac sent an invalid screen video packet type \(type)"
        }
    }
}

private final class ScreenVideoResumeOnce: @unchecked Sendable {
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
        lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
