import CaptureCore
import Foundation
import Network
import Streaming

final class VideoClientConnection: @unchecked Sendable {
    private struct PendingSend {
        let data: Data
        let countsAsPacket: Bool
    }

    private let connection: NWConnection
    private let logger: Logger
    private let authToken: String?
    private let onAuthorized: @Sendable (VideoClientConnection) -> Void
    private let onControlPacket: @Sendable (VideoClientConnection, ScreenVideoPacket) -> Void
    private let onClose: @Sendable (VideoClientConnection) -> Void
    private var sendQueue: [PendingSend] = []
    private var isSending = false
    private var authTimeoutWorkItem: DispatchWorkItem?
    private var didReportClose = false
    private(set) var isAuthorized: Bool
    private(set) var bytesSent: Int64 = 0
    private(set) var packetsSent: Int64 = 0

    var queuedPackets: Int {
        sendQueue.filter(\.countsAsPacket).count
    }

    init(
        connection: NWConnection,
        logger: Logger,
        authToken: String?,
        onAuthorized: @escaping @Sendable (VideoClientConnection) -> Void,
        onControlPacket: @escaping @Sendable (VideoClientConnection, ScreenVideoPacket) -> Void,
        onClose: @escaping @Sendable (VideoClientConnection) -> Void
    ) {
        self.connection = connection
        self.logger = logger
        self.authToken = authToken
        self.isAuthorized = authToken == nil
        self.onAuthorized = onAuthorized
        self.onControlPacket = onControlPacket
        self.onClose = onClose
    }

    func start(on queue: DispatchQueue) {
        logger.info("Screen viewer connected: \(connection.endpoint)")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                if self.isExpectedDisconnect(error) {
                    self.logger.info("Screen viewer disconnected")
                } else {
                    self.logger.error("Screen viewer failed: \(error.localizedDescription)")
                }
                self.reportCloseOnce()
            case .cancelled:
                self.logger.info("Screen viewer disconnected")
                self.reportCloseOnce()
            default:
                break
            }
        }
        connection.start(queue: queue)

        if authToken == nil {
            authorize()
        } else {
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, !self.isAuthorized else { return }
                self.cancel(reason: "screen authentication timeout")
            }
            authTimeoutWorkItem = timeout
            queue.asyncAfter(deadline: .now() + .seconds(5), execute: timeout)
            receiveExact(byteCount: PCMAuthProtocol.headerByteCount) { [weak self] result in
                self?.handleAuthHeader(result)
            }
        }
    }

    func sendPacket(_ packet: ScreenVideoPacket) throws {
        guard isAuthorized else { return }
        enqueue(try ScreenVideoFraming.makePacket(packet), countsAsPacket: true)
    }

    func cancel(reason: String) {
        logger.info("Closing screen viewer: \(reason)")
        authTimeoutWorkItem?.cancel()
        authTimeoutWorkItem = nil
        connection.cancel()
    }

    private func authorize() {
        guard !isAuthorized || authToken == nil else { return }
        isAuthorized = true
        authTimeoutWorkItem?.cancel()
        authTimeoutWorkItem = nil
        enqueue(ScreenVideoFraming.makePreamble(), countsAsPacket: false)
        logger.info("Screen viewer authenticated")
        onAuthorized(self)
        receiveControlPacketHeader()
    }

    private func handleAuthHeader(_ result: Result<Data, Error>) {
        do {
            let header = try result.get()
            let tokenByteCount = try PCMAuthProtocol.tokenLength(fromHeader: header)
            receiveExact(byteCount: tokenByteCount) { [weak self] tokenResult in
                self?.handleAuthToken(tokenResult)
            }
        } catch {
            logger.error("Screen authentication header rejected: \(error.localizedDescription)")
            cancel(reason: "screen authentication header rejected")
        }
    }

    private func handleAuthToken(_ result: Result<Data, Error>) {
        do {
            let token = try PCMAuthProtocol.parseToken(result.get())
            guard let authToken,
                  Self.constantTimeEquals(Array(token.utf8), Array(authToken.utf8)) else {
                cancel(reason: "screen authentication failed")
                return
            }
            authorize()
        } catch {
            logger.error("Screen authentication token rejected: \(error.localizedDescription)")
            cancel(reason: "screen authentication token rejected")
        }
    }

    private func receiveControlPacketHeader() {
        receiveExact(byteCount: ScreenVideoProtocol.packetHeaderByteCount) { [weak self] result in
            guard let self else { return }
            do {
                let headerData = try result.get()
                let header = try ScreenVideoFraming.parsePacketHeader(headerData)
                guard header.type == .acknowledgement || header.type == .keyFrameRequest else {
                    throw VideoClientConnectionError.invalidControlPacket(header.type)
                }
                guard header.payloadByteCount == 0 else {
                    throw VideoClientConnectionError.controlPacketHasPayload(header.payloadByteCount)
                }
                self.receiveControlPacketPayload(header: header, headerData: headerData)
            } catch {
                if self.isConnectionClosed(error) {
                    self.reportCloseOnce()
                    return
                }
                self.logger.error("Screen control header rejected: \(error.localizedDescription)")
                self.cancel(reason: "invalid screen control header")
            }
        }
    }

    private func receiveControlPacketPayload(
        header: ScreenVideoPacketHeader,
        headerData: Data
    ) {
        let finish: @Sendable (Result<Data, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            do {
                var packetData = headerData
                packetData.append(try result.get())
                let packet = try ScreenVideoFraming.parsePacket(packetData)
                guard packet.type == .acknowledgement || packet.type == .keyFrameRequest else {
                    throw VideoClientConnectionError.invalidControlPacket(packet.type)
                }
                self.onControlPacket(self, packet)
                self.receiveControlPacketHeader()
            } catch {
                if self.isConnectionClosed(error) {
                    self.reportCloseOnce()
                    return
                }
                self.logger.error("Screen control packet rejected: \(error.localizedDescription)")
                self.cancel(reason: "invalid screen control packet")
            }
        }

        if header.payloadByteCount == 0 {
            finish(.success(Data()))
        } else {
            receiveExact(byteCount: Int(header.payloadByteCount), completion: finish)
        }
    }

    private func receiveExact(
        byteCount: Int,
        accumulated: Data = Data(),
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        guard accumulated.count < byteCount else {
            completion(.success(accumulated))
            return
        }

        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: byteCount - accumulated.count
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            guard let data, !data.isEmpty else {
                completion(.failure(VideoClientConnectionError.connectionClosed))
                if isComplete {
                    self.reportCloseOnce()
                }
                return
            }

            var next = accumulated
            next.append(data)
            self.receiveExact(byteCount: byteCount, accumulated: next, completion: completion)
        }
    }

    private func enqueue(_ data: Data, countsAsPacket: Bool) {
        let maximumQueuedWrites = 4
        guard sendQueue.count < maximumQueuedWrites else {
            cancel(reason: "screen send queue exceeded \(maximumQueuedWrites) writes")
            return
        }

        sendQueue.append(PendingSend(data: data, countsAsPacket: countsAsPacket))
        pump()
    }

    private func pump() {
        guard !isSending, !sendQueue.isEmpty else { return }
        isSending = true
        let pending = sendQueue.removeFirst()
        connection.send(content: pending.data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.isSending = false
            if let error {
                self.logger.error("Screen send failed: \(error.localizedDescription)")
                self.cancel(reason: "screen send failure")
                return
            }
            self.bytesSent += Int64(pending.data.count)
            if pending.countsAsPacket {
                self.packetsSent += 1
            }
            self.pump()
        })
    }

    private func reportCloseOnce() {
        guard !didReportClose else { return }
        didReportClose = true
        authTimeoutWorkItem?.cancel()
        authTimeoutWorkItem = nil
        onClose(self)
    }

    private func isConnectionClosed(_ error: Error) -> Bool {
        if let connectionError = error as? VideoClientConnectionError,
           case .connectionClosed = connectionError {
            return true
        }

        if error is CancellationError || error is NWError {
            return true
        }

        return false
    }

    private func isExpectedDisconnect(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        guard let networkError = error as? NWError else { return false }
        switch networkError {
        case .posix(.ECANCELED),
             .posix(.ECONNABORTED),
             .posix(.ECONNRESET),
             .posix(.ENOTCONN),
             .posix(.EPIPE):
            return true
        default:
            return false
        }
    }

    private static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

private enum VideoClientConnectionError: LocalizedError {
    case connectionClosed
    case invalidControlPacket(ScreenVideoPacketType)
    case controlPacketHasPayload(UInt32)

    var errorDescription: String? {
        switch self {
        case .connectionClosed:
            "The screen viewer closed the connection"
        case .invalidControlPacket(let type):
            "Packet type \(type) is not a valid viewer control packet"
        case .controlPacketHasPayload(let byteCount):
            "Viewer control packets must not contain a payload (received \(byteCount) bytes)"
        }
    }
}
