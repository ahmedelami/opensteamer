import CaptureCore
import Foundation
import Network
import Streaming

final class ClientConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let logger: Logger
    private let authToken: String?
    private let onClose: @Sendable (ClientConnection) -> Void
    private var isAuthorized: Bool
    private var headerSent = false
    private var pendingHeader: PCMStreamHeader?
    private var sendQueue: [Data] = []
    private var isSending = false
    private var authTimeoutWorkItem: DispatchWorkItem?
    private let maxQueuedPackets = 10
    private(set) var bytesSent: Int64 = 0
    private(set) var packetsSent: Int64 = 0

    var queuedPackets: Int {
        sendQueue.count
    }

    init(
        connection: NWConnection,
        logger: Logger,
        authToken: String?,
        onClose: @escaping @Sendable (ClientConnection) -> Void
    ) {
        self.connection = connection
        self.logger = logger
        self.authToken = authToken
        self.isAuthorized = authToken == nil
        self.onClose = onClose
    }

    func start(on queue: DispatchQueue) {
        logger.info("Client connected: \(connection.endpoint)")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                self.logger.error("Client failed: \(error.localizedDescription)")
                self.onClose(self)
            case .cancelled:
                self.logger.info("Client disconnected")
                self.onClose(self)
            default:
                break
            }
        }
        connection.start(queue: queue)
        if authToken != nil {
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, !self.isAuthorized else { return }
                self.cancel(reason: "authentication timeout")
            }
            authTimeoutWorkItem = timeout
            queue.asyncAfter(deadline: .now() + .seconds(5), execute: timeout)
            receiveAuthHeader()
        }
    }

    func sendHeader(_ header: PCMStreamHeader) {
        pendingHeader = header
        sendPendingHeaderIfPossible()
    }

    func sendPacket(metadata: PCMPacketMetadata, pcmBytes: Data) {
        guard isAuthorized else { return }
        sendPendingHeaderIfPossible()
        guard headerSent else { return }
        enqueue(PacketFramer.makePacket(metadata: metadata, pcmBytes: pcmBytes), countsAsPacket: true)
    }

    func cancel(reason: String) {
        logger.info("Closing client: \(reason)")
        authTimeoutWorkItem?.cancel()
        authTimeoutWorkItem = nil
        connection.cancel()
    }

    private func receiveAuthHeader() {
        connection.receive(
            minimumIncompleteLength: PCMAuthProtocol.headerByteCount,
            maximumLength: PCMAuthProtocol.headerByteCount
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.logger.error("Authentication read failed: \(error.localizedDescription)")
                self.cancel(reason: "authentication read failure")
                return
            }
            guard let data, !data.isEmpty, !isComplete else {
                self.cancel(reason: "authentication connection closed")
                return
            }

            do {
                let tokenLength = try PCMAuthProtocol.tokenLength(fromHeader: data)
                self.receiveAuthToken(byteCount: tokenLength)
            } catch {
                self.logger.error("Authentication header rejected: \(error.localizedDescription)")
                self.cancel(reason: "authentication header rejected")
            }
        }
    }

    private func receiveAuthToken(byteCount: Int) {
        connection.receive(minimumIncompleteLength: byteCount, maximumLength: byteCount) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.logger.error("Authentication token read failed: \(error.localizedDescription)")
                self.cancel(reason: "authentication token read failure")
                return
            }
            guard let data, !data.isEmpty, !isComplete else {
                self.cancel(reason: "authentication connection closed")
                return
            }

            do {
                let token = try PCMAuthProtocol.parseToken(data)
                guard let authToken = self.authToken,
                      Self.constantTimeEquals(Array(token.utf8), Array(authToken.utf8)) else {
                    self.cancel(reason: "authentication failed")
                    return
                }

                self.logger.info("Client authenticated")
                self.authTimeoutWorkItem?.cancel()
                self.authTimeoutWorkItem = nil
                self.isAuthorized = true
                self.sendPendingHeaderIfPossible()
            } catch {
                self.logger.error("Authentication token rejected: \(error.localizedDescription)")
                self.cancel(reason: "authentication token rejected")
            }
        }
    }

    private func sendPendingHeaderIfPossible() {
        guard isAuthorized, !headerSent, let pendingHeader else { return }
        headerSent = true
        self.pendingHeader = nil
        enqueue(PacketFramer.makeHeader(pendingHeader), countsAsPacket: false)
    }

    private static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }

        var diff: UInt8 = 0
        for index in lhs.indices {
            diff |= lhs[index] ^ rhs[index]
        }
        return diff == 0
    }

    private func enqueue(_ data: Data, countsAsPacket: Bool) {
        if sendQueue.count >= maxQueuedPackets {
            cancel(reason: "client send queue exceeded \(maxQueuedPackets) packets")
            return
        }

        sendQueue.append(data)
        if countsAsPacket {
            packetsSent += 1
        }
        pump()
    }

    private func pump() {
        guard !isSending, !sendQueue.isEmpty else { return }
        isSending = true
        let data = sendQueue.removeFirst()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.isSending = false
            if let error {
                self.logger.error("Send failed: \(error.localizedDescription)")
                self.cancel(reason: "send failure")
                return
            }
            self.bytesSent += Int64(data.count)
            self.pump()
        })
    }
}
