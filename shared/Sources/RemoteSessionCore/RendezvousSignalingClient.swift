import Foundation

public enum RendezvousSignalingError: Error, Equatable, LocalizedError, Sendable {
    case invalidEndpoint
    case alreadyConnected
    case notConnected
    case connectionFailed
    case connectionClosed
    case sendFailed
    case invalidServerMessage
    case eventBufferOverflow

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The rendezvous endpoint is invalid."
        case .alreadyConnected:
            "The rendezvous session is already connected."
        case .notConnected:
            "The rendezvous session is not connected."
        case .connectionFailed:
            "The rendezvous connection could not be established."
        case .connectionClosed:
            "The rendezvous connection closed."
        case .sendFailed:
            "The signaling message could not be sent."
        case .invalidServerMessage:
            "The rendezvous service sent an invalid message."
        case .eventBufferOverflow:
            "The rendezvous event buffer is full."
        }
    }
}

public enum RendezvousServerError: Equatable, Sendable {
    case peerUnavailable
    case rateLimited
    case invitationUnavailable
    case invitationExpired
    case roleConflict
    case requestRejected
}

public enum RendezvousSignalingEvent: Equatable, Sendable {
    case waiting(invitationExpiresAt: Date)
    case ready(
        role: RemotePeerRole,
        invitationExpiresAt: Date,
        iceServers: [RemoteICEServer]
    )
    case signal(RemoteSignalPayload)
    case peerLeft(RemotePeerRole)
    case serverError(RendezvousServerError)
}

internal enum RendezvousSocketMessage: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

internal protocol RendezvousSocketTransport: Sendable {
    func connect(
        to url: URL,
        channelID: RendezvousChannelID,
        role: RemotePeerRole,
        admissionProof: RendezvousAdmissionProof
    ) async throws
    func send(text: String) async throws
    func receive() async throws -> RendezvousSocketMessage
    func close() async
}

/// A one-use WebSocket signaling client. The invitation secret is used only for local
/// key derivation. Routing, role, and a separately derived proof are carried in bounded
/// WebSocket upgrade headers so the public URL contains no session material.
public actor RendezvousSignalingClient {
    public typealias EventStream = AsyncThrowingStream<RendezvousSignalingEvent, Error>

    private enum State {
        case idle
        case connected
        case closed
    }

    private enum Limits {
        static let maximumWireMessageBytes = 90_000
        static let maximumEnvelopeBytes = 65_536
        static let maximumSequence: UInt64 = 2_147_483_647
        static let maximumEventBufferCount = 256
        static let maximumICEServerCount = 16
        static let maximumURLsPerICEServer = 8
        static let maximumICEURLBytes = 2_048
        static let maximumCredentialBytes = 1_024
        static let maximumSDPBytes = 40_000
        static let maximumCandidateBytes = 8_192
        static let maximumICEUsernameFragmentBytes = 256
        static let maximumDisplayNameBytes = 256
        static let maximumPublicKeyBytes = 1_024
    }

    private let role: RemotePeerRole
    private let rendezvousURL: URL
    private let channelID: RendezvousChannelID
    private let admissionProof: RendezvousAdmissionProof
    private let transport: any RendezvousSocketTransport
    private let sender: RemoteSignalingSender
    private let receiver: RemoteSignalingReceiver

    private var state = State.idle
    private var continuation: EventStream.Continuation?
    private var receiveTask: Task<Void, Never>?

    public init(
        endpoint: URL,
        invitation: RemoteInvitationCode,
        role: RemotePeerRole
    ) throws {
        let cipher = RemoteSignalingCipher(invitation: invitation, role: role)
        self.role = role
        channelID = cipher.channelID
        admissionProof = cipher.admissionProof
        rendezvousURL = try Self.makeRendezvousURL(endpoint: endpoint)
        transport = URLSessionRendezvousSocketTransport()
        sender = RemoteSignalingSender(cipher: cipher)
        receiver = RemoteSignalingReceiver(cipher: cipher)
    }

    internal init(
        endpoint: URL,
        invitation: RemoteInvitationCode,
        role: RemotePeerRole,
        transport: any RendezvousSocketTransport
    ) throws {
        let cipher = RemoteSignalingCipher(invitation: invitation, role: role)
        self.role = role
        channelID = cipher.channelID
        admissionProof = cipher.admissionProof
        rendezvousURL = try Self.makeRendezvousURL(endpoint: endpoint)
        self.transport = transport
        sender = RemoteSignalingSender(cipher: cipher)
        receiver = RemoteSignalingReceiver(cipher: cipher)
    }

    /// Connects exactly once and starts a bounded event stream.
    public func connect() async throws -> EventStream {
        guard state == .idle else {
            throw RendezvousSignalingError.alreadyConnected
        }

        do {
            try await transport.connect(
                to: rendezvousURL,
                channelID: channelID,
                role: role,
                admissionProof: admissionProof
            )
        } catch {
            state = .closed
            await transport.close()
            throw RendezvousSignalingError.connectionFailed
        }

        let pair = EventStream.makeStream(
            bufferingPolicy: .bufferingOldest(Limits.maximumEventBufferCount)
        )
        continuation = pair.continuation
        state = .connected

        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.close()
            }
        }
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        return pair.stream
    }

    public func send(_ payload: RemoteSignalPayload) async throws {
        guard state == .connected else {
            throw RendezvousSignalingError.notConnected
        }

        try Self.validate(payload: payload, identityRole: role)
        let envelope = try await sender.seal(payload)
        guard envelope.sequence <= Limits.maximumSequence else {
            await finish(throwing: RemoteSessionCoreError.sequenceExhausted)
            throw RemoteSessionCoreError.sequenceExhausted
        }

        let wireText: String
        do {
            wireText = try Self.encodedWireText(for: envelope)
        } catch let error as RemoteSessionCoreError {
            // The sequence is already allocated, so the session cannot safely retry it.
            await finish(throwing: error)
            throw error
        } catch {
            await finish(throwing: RemoteSessionCoreError.invalidSignalPayload)
            throw RemoteSessionCoreError.invalidSignalPayload
        }

        do {
            try await transport.send(text: wireText)
        } catch {
            await finish(throwing: RendezvousSignalingError.connectionClosed)
            throw RendezvousSignalingError.sendFailed
        }
    }

    public func close() async {
        await finish(throwing: nil)
    }

    private func receiveLoop() async {
        while state == .connected, !Task.isCancelled {
            let message: RendezvousSocketMessage
            do {
                message = try await transport.receive()
            } catch {
                if state == .connected {
                    await finish(throwing: RendezvousSignalingError.connectionClosed)
                }
                return
            }

            guard case .text(let text) = message else {
                await finish(throwing: RendezvousSignalingError.invalidServerMessage)
                return
            }

            do {
                let event = try await parse(text: text)
                guard let continuation else { return }
                switch continuation.yield(event) {
                case .enqueued:
                    break
                case .dropped:
                    await finish(throwing: RendezvousSignalingError.eventBufferOverflow)
                    return
                case .terminated:
                    await finish(throwing: nil)
                    return
                @unknown default:
                    await finish(throwing: RendezvousSignalingError.eventBufferOverflow)
                    return
                }
            } catch let error as RemoteSessionCoreError {
                await finish(throwing: error)
                return
            } catch let error as RendezvousSignalingError {
                await finish(throwing: error)
                return
            } catch {
                await finish(throwing: RendezvousSignalingError.invalidServerMessage)
                return
            }
        }
    }

    private func finish(throwing error: (any Error)?) async {
        guard state != .closed else { return }
        state = .closed

        let activeContinuation = continuation
        continuation = nil
        let activeReceiveTask = receiveTask
        receiveTask = nil
        activeReceiveTask?.cancel()
        await transport.close()

        if let error {
            activeContinuation?.finish(throwing: error)
        } else {
            activeContinuation?.finish()
        }
    }

    private func parse(text: String) async throws -> RendezvousSignalingEvent {
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= Limits.maximumWireMessageBytes else {
            throw RendezvousSignalingError.invalidServerMessage
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw RendezvousSignalingError.invalidServerMessage
        }
        guard let dictionary = object as? [String: Any],
              let type = dictionary["type"] as? String,
              type.utf8.count <= 32 else {
            throw RendezvousSignalingError.invalidServerMessage
        }

        switch type {
        case "waiting":
            try Self.requireExactKeys(dictionary, ["type", "invitationExpiresAt"])
            let wire = try Self.decode(WaitingWire.self, from: data)
            return .waiting(invitationExpiresAt: try Self.parseDate(wire.invitationExpiresAt))

        case "ready":
            try Self.requireExactKeys(
                dictionary,
                ["type", "role", "invitationExpiresAt", "iceServers"]
            )
            guard wireArrayCount(dictionary["iceServers"]) <= Limits.maximumICEServerCount else {
                throw RendezvousSignalingError.invalidServerMessage
            }
            try Self.validateICEServerSchemas(dictionary["iceServers"])
            let wire = try Self.decode(ReadyWire.self, from: data)
            guard wire.role == role else {
                throw RendezvousSignalingError.invalidServerMessage
            }
            let iceServers = try wire.iceServers.map(Self.validatedICEServer(from:))
            return .ready(
                role: wire.role,
                invitationExpiresAt: try Self.parseDate(wire.invitationExpiresAt),
                iceServers: iceServers
            )

        case "signal":
            try Self.requireExactKeys(dictionary, ["type", "from", "seq", "envelope"])
            let wire = try Self.decode(InboundSignalWire.self, from: data)
            guard wire.from == role.opposite,
                  wire.seq <= Limits.maximumSequence else {
                throw RendezvousSignalingError.invalidServerMessage
            }
            let envelopeData = try Self.decodeBase64URL(
                wire.envelope,
                maximumDecodedBytes: Limits.maximumEnvelopeBytes
            )
            try Self.validateEnvelopeSchema(envelopeData)
            let envelope = try Self.decode(SealedSignalingEnvelope.self, from: envelopeData)
            guard envelope.sequence == wire.seq else {
                throw RendezvousSignalingError.invalidServerMessage
            }
            let payload = try await receiver.open(envelope)
            try Self.validate(payload: payload, identityRole: role.opposite)
            return .signal(payload)

        case "peer-left":
            try Self.requireExactKeys(dictionary, ["type", "role"])
            let wire = try Self.decode(PeerLeftWire.self, from: data)
            guard wire.role == role.opposite else {
                throw RendezvousSignalingError.invalidServerMessage
            }
            return .peerLeft(wire.role)

        case "error":
            try Self.requireExactKeys(dictionary, ["type", "error"])
            let wire = try Self.decode(ServerErrorWire.self, from: data)
            guard !wire.error.isEmpty,
                  wire.error.utf8.count <= 64,
                  wire.error.utf8.allSatisfy(Self.isSafeErrorByte) else {
                throw RendezvousSignalingError.invalidServerMessage
            }
            return .serverError(Self.serverError(for: wire.error))

        default:
            throw RendezvousSignalingError.invalidServerMessage
        }
    }

    private static func makeRendezvousURL(endpoint: URL) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw RendezvousSignalingError.invalidEndpoint
        }

        switch scheme {
        case "wss":
            break
        case "ws":
            guard isLoopback(host: host) else {
                throw RendezvousSignalingError.invalidEndpoint
            }
        default:
            throw RendezvousSignalingError.invalidEndpoint
        }

        components.scheme = scheme
        components.path = "/v1/rendezvous"
        guard let result = components.url else {
            throw RendezvousSignalingError.invalidEndpoint
        }
        return result
    }

    private static func isLoopback(host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if normalized == "localhost"
            || normalized.hasSuffix(".localhost")
            || normalized == "::1"
            || normalized == "[::1]" {
            return true
        }

        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4,
              components.first == "127",
              components.allSatisfy({ part in
                  guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = UInt8(part) else {
                      return false
                  }
                  return String(value) == part || part == "0"
              }) else {
            return false
        }
        return true
    }

    private static func parseDate(_ value: String) throws -> Date {
        guard !value.isEmpty, value.utf8.count <= 64 else {
            throw RendezvousSignalingError.invalidServerMessage
        }
        do {
            return try Date(
                value,
                strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            )
        } catch {
            throw RendezvousSignalingError.invalidServerMessage
        }
    }

    private static func validatedICEServer(from wire: ICEServerWire) throws -> RemoteICEServer {
        guard !wire.urls.isEmpty,
              wire.urls.count <= Limits.maximumURLsPerICEServer else {
            throw RendezvousSignalingError.invalidServerMessage
        }
        for url in wire.urls {
            guard !url.isEmpty,
                  url.utf8.count <= Limits.maximumICEURLBytes,
                  !url.contains(where: \.isWhitespace),
                  !url.contains("@"),
                  ["stun", "stuns", "turn", "turns"].contains(Self.scheme(of: url)) else {
                throw RendezvousSignalingError.invalidServerMessage
            }
        }
        if let username = wire.username {
            guard !username.isEmpty, username.utf8.count <= Limits.maximumCredentialBytes else {
                throw RendezvousSignalingError.invalidServerMessage
            }
        }
        if let credential = wire.credential {
            guard !credential.isEmpty, credential.utf8.count <= Limits.maximumCredentialBytes else {
                throw RendezvousSignalingError.invalidServerMessage
            }
        }
        guard wire.credentialType == nil || wire.credentialType == "password" else {
            throw RendezvousSignalingError.invalidServerMessage
        }

        let containsTURN = wire.urls.contains {
            let scheme = Self.scheme(of: $0)
            return scheme == "turn" || scheme == "turns"
        }
        if containsTURN {
            guard wire.username != nil,
                  wire.credential != nil,
                  wire.credentialType == "password" else {
                throw RendezvousSignalingError.invalidServerMessage
            }
        } else if wire.username != nil || wire.credential != nil || wire.credentialType != nil {
            throw RendezvousSignalingError.invalidServerMessage
        }

        return RemoteICEServer(
            urls: wire.urls,
            username: wire.username,
            credential: wire.credential
        )
    }

    private static func validateICEServerSchemas(_ value: Any?) throws {
        guard let servers = value as? [Any] else {
            throw RendezvousSignalingError.invalidServerMessage
        }
        for server in servers {
            guard let dictionary = server as? [String: Any] else {
                throw RendezvousSignalingError.invalidServerMessage
            }
            let keys = Set(dictionary.keys)
            let stunKeys: Set<String> = ["urls"]
            let turnKeys: Set<String> = ["urls", "username", "credential", "credentialType"]
            guard keys == stunKeys || keys == turnKeys else {
                throw RendezvousSignalingError.invalidServerMessage
            }
        }
    }

    private static func validateEnvelopeSchema(_ data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw RendezvousSignalingError.invalidServerMessage
        }
        guard let dictionary = object as? [String: Any] else {
            throw RendezvousSignalingError.invalidServerMessage
        }
        try requireExactKeys(
            dictionary,
            ["version", "channelID", "direction", "sequence", "ciphertext"]
        )
        guard let channel = dictionary["channelID"] as? String,
              channel.utf8.count <= 128,
              let direction = dictionary["direction"] as? String,
              direction.utf8.count <= 32,
              let ciphertext = dictionary["ciphertext"] as? String,
              ciphertext.utf8.count <= Limits.maximumEnvelopeBytes * 2 else {
            throw RendezvousSignalingError.invalidServerMessage
        }
    }

    private static func validate(
        payload: RemoteSignalPayload,
        identityRole: RemotePeerRole
    ) throws {
        let valid: Bool
        switch payload {
        case .offer(let sdp), .answer(let sdp):
            valid = !sdp.isEmpty && sdp.utf8.count <= Limits.maximumSDPBytes
        case .candidate(let candidate):
            valid = !candidate.sdp.isEmpty
                && candidate.sdp.utf8.count <= Limits.maximumCandidateBytes
                && (candidate.sdpMid?.utf8.count ?? 0) <= 128
                && candidate.sdpMLineIndex.map { $0 >= 0 && $0 <= 65_535 } != false
                && candidate.usernameFragment.map {
                    !$0.isEmpty
                        && $0.utf8.count <= Limits.maximumICEUsernameFragmentBytes
                        && !$0.contains(where: \.isWhitespace)
                } != false
        case .end, .control:
            valid = true
        case .identity(let identity):
            valid = identity.role == identityRole
                && identity.publicKey.count > 0
                && identity.publicKey.count <= Limits.maximumPublicKeyBytes
                && (identity.displayName?.utf8.count ?? 0) <= Limits.maximumDisplayNameBytes
        case .iceRestartRequest(let request):
            valid = identityRole == .viewer
                && request.protocolVersion == RemoteICERestartRequest.currentProtocolVersion
                && request.requestID > 0
        }
        guard valid else {
            throw RemoteSessionCoreError.invalidSignalPayload
        }
    }

    private static func requireExactKeys(_ dictionary: [String: Any], _ keys: Set<String>) throws {
        guard Set(dictionary.keys) == keys else {
            throw RendezvousSignalingError.invalidServerMessage
        }
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw RendezvousSignalingError.invalidServerMessage
        }
    }

    private static func encodedWireText(for envelope: SealedSignalingEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let envelopeData: Data
        do {
            envelopeData = try encoder.encode(envelope)
        } catch {
            throw RemoteSessionCoreError.invalidSignalPayload
        }
        guard envelopeData.count <= Limits.maximumEnvelopeBytes else {
            throw RemoteSessionCoreError.invalidSignalPayload
        }

        let wire = OutboundSignalWire(
            type: "signal",
            seq: envelope.sequence,
            envelope: base64URLEncoded(envelopeData)
        )
        let wireData: Data
        do {
            wireData = try encoder.encode(wire)
        } catch {
            throw RemoteSessionCoreError.invalidSignalPayload
        }
        guard wireData.count <= Limits.maximumWireMessageBytes,
              let wireText = String(data: wireData, encoding: .utf8) else {
            throw RemoteSessionCoreError.invalidSignalPayload
        }
        return wireText
    }

    private static func decodeBase64URL(
        _ value: String,
        maximumDecodedBytes: Int
    ) throws -> Data {
        let maximumEncodedBytes = ((maximumDecodedBytes + 2) / 3) * 4
        guard !value.isEmpty,
              value.utf8.count <= maximumEncodedBytes,
              value.utf8.count % 4 != 1,
              value.utf8.allSatisfy({ byte in
                  switch byte {
                  case 45, 48...57, 65...90, 95, 97...122:
                      true
                  default:
                      false
                  }
              }) else {
            throw RendezvousSignalingError.invalidServerMessage
        }

        var standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard.append(String(repeating: "=", count: (4 - standard.count % 4) % 4))
        guard let decoded = Data(base64Encoded: standard),
              decoded.count <= maximumDecodedBytes,
              base64URLEncoded(decoded) == value else {
            throw RendezvousSignalingError.invalidServerMessage
        }
        return decoded
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func serverError(for value: String) -> RendezvousServerError {
        switch value {
        case "peer_unavailable": .peerUnavailable
        case "rate_limited": .rateLimited
        case "invitation_unavailable": .invitationUnavailable
        case "invitation_expired": .invitationExpired
        case "role_already_claimed": .roleConflict
        default: .requestRejected
        }
    }

    private static func isSafeErrorByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 95, 97...122:
            true
        default:
            false
        }
    }

    private static func scheme(of value: String) -> String? {
        guard let separator = value.firstIndex(of: ":") else { return nil }
        return String(value[..<separator]).lowercased()
    }
}

private actor URLSessionRendezvousSocketTransport: RendezvousSocketTransport {
    private enum Header {
        static let channel = "X-AudioStreamer-Channel"
        static let role = "X-AudioStreamer-Role"
        static let admission = "X-AudioStreamer-Admission"
    }

    private let delegate: RendezvousWebSocketDelegate
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.urlCache = nil
        let delegate = RendezvousWebSocketDelegate()
        self.delegate = delegate
        session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    func connect(
        to url: URL,
        channelID: RendezvousChannelID,
        role: RemotePeerRole,
        admissionProof: RendezvousAdmissionProof
    ) async throws {
        guard task == nil else {
            throw RendezvousSignalingError.alreadyConnected
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(channelID.wireValue, forHTTPHeaderField: Header.channel)
        request.setValue(role.rawValue, forHTTPHeaderField: Header.role)
        request.setValue(admissionProof.wireValue, forHTTPHeaderField: Header.admission)
        let newTask = session.webSocketTask(with: request)
        task = newTask
        newTask.resume()
        do {
            try await delegate.waitUntilOpen()
        } catch {
            newTask.cancel(with: .goingAway, reason: nil)
            task = nil
            throw RendezvousSignalingError.connectionFailed
        }
    }

    func send(text: String) async throws {
        guard let task else {
            throw RendezvousSignalingError.notConnected
        }
        try await task.send(.string(text))
    }

    func receive() async throws -> RendezvousSocketMessage {
        guard let task else {
            throw RendezvousSignalingError.notConnected
        }
        switch try await task.receive() {
        case .string(let text):
            return .text(text)
        case .data(let data):
            return .binary(data)
        @unknown default:
            throw RendezvousSignalingError.invalidServerMessage
        }
    }

    func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session.invalidateAndCancel()
    }
}

private final class RendezvousWebSocketDelegate: NSObject, URLSessionWebSocketDelegate,
    @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, RendezvousSignalingError>?
    private var waiter: CheckedContinuation<Void, any Error>?
    private var timeoutTask: Task<Void, Never>?

    func waitUntilOpen() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = lock.withLock { () -> Result<Void, RendezvousSignalingError>? in
                if let result { return result }
                waiter = continuation
                timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(30))
                    } catch {
                        return
                    }
                    self?.resolve(.failure(.connectionFailed))
                }
                return nil
            }
            if let immediate {
                continuation.resume(with: immediate.mapError { $0 as any Error })
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        resolve(.success(()))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError _: (any Error)?
    ) {
        // Completion before didOpen is a failed WebSocket handshake even when Foundation
        // does not attach an Error (for example, some rejected HTTP upgrades).
        resolve(.failure(.connectionFailed))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Join headers are capabilities; never forward them through a redirect.
        completionHandler(nil)
    }

    private func resolve(_ newResult: Result<Void, RendezvousSignalingError>) {
        let resolved = lock.withLock { () -> (
            CheckedContinuation<Void, any Error>?,
            Task<Void, Never>?
        ) in
            guard result == nil else { return (nil, nil) }
            result = newResult
            let resolvedWaiter = waiter
            let resolvedTimeout = timeoutTask
            waiter = nil
            timeoutTask = nil
            return (resolvedWaiter, resolvedTimeout)
        }
        resolved.1?.cancel()
        resolved.0?.resume(with: newResult.mapError { $0 as any Error })
    }
}

private extension RemotePeerRole {
    var opposite: RemotePeerRole {
        self == .host ? .viewer : .host
    }
}

private struct OutboundSignalWire: Encodable {
    let type: String
    let seq: UInt64
    let envelope: String
}

private struct WaitingWire: Decodable {
    let invitationExpiresAt: String
}

private struct ReadyWire: Decodable {
    let role: RemotePeerRole
    let invitationExpiresAt: String
    let iceServers: [ICEServerWire]
}

private struct ICEServerWire: Decodable {
    let urls: [String]
    let username: String?
    let credential: String?
    let credentialType: String?
}

private struct InboundSignalWire: Decodable {
    let from: RemotePeerRole
    let seq: UInt64
    let envelope: String
}

private struct PeerLeftWire: Decodable {
    let role: RemotePeerRole
}

private struct ServerErrorWire: Decodable {
    let error: String
}

private func wireArrayCount(_ value: Any?) -> Int {
    (value as? [Any])?.count ?? .max
}
