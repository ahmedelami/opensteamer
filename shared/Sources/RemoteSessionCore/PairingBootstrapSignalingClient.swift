import CryptoKit
import Foundation

public enum RemotePairingPayload: Codable, Equatable, Sendable {
    case hello(RemotePairingHello)
    case confirmation(RemotePairingConfirmation)
    case commit(RemotePairingCommit)

    private enum Kind: String, Codable {
        case hello
        case confirmation
        case commit
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case hello
        case confirmation
        case commit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .hello:
            self = .hello(try container.decode(RemotePairingHello.self, forKey: .hello))
        case .confirmation:
            self = .confirmation(
                try container.decode(RemotePairingConfirmation.self, forKey: .confirmation)
            )
        case .commit:
            self = .commit(try container.decode(RemotePairingCommit.self, forKey: .commit))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let hello):
            try container.encode(Kind.hello, forKey: .kind)
            try container.encode(hello, forKey: .hello)
        case .confirmation(let confirmation):
            try container.encode(Kind.confirmation, forKey: .kind)
            try container.encode(confirmation, forKey: .confirmation)
        case .commit(let commit):
            try container.encode(Kind.commit, forKey: .kind)
            try container.encode(commit, forKey: .commit)
        }
    }
}

public enum PairingBootstrapSignalingEvent: Equatable, Sendable {
    case waiting(invitationExpiresAt: Date)
    case ready(role: RemotePeerRole, invitationExpiresAt: Date)
    case signal(RemotePairingPayload)
    case peerLeft(RemotePeerRole)
    case serverError(RendezvousServerError)
}

private struct PairingBootstrapCipher: Sendable {
    let credential: RemoteRendezvousCredential
    let role: RemotePeerRole

    var sendingDirection: RemoteSignalDirection {
        role == .host ? .hostToViewer : .viewerToHost
    }

    var receivingDirection: RemoteSignalDirection {
        role == .host ? .viewerToHost : .hostToViewer
    }

    func seal(
        _ payload: RemotePairingPayload,
        sequence: UInt64
    ) throws -> SealedSignalingEnvelope {
        let plaintext = try remoteCanonicalData(payload)
        let empty = SealedSignalingEnvelope(
            channelID: credential.channelID,
            direction: sendingDirection,
            sequence: sequence,
            ciphertext: Data()
        )
        let key = role == .host ? credential.hostToViewer : credential.viewerToHost
        do {
            let box = try ChaChaPoly.seal(
                plaintext,
                using: SymmetricKey(data: key),
                authenticating: empty.additionalAuthenticatedData
            )
            return SealedSignalingEnvelope(
                channelID: credential.channelID,
                direction: sendingDirection,
                sequence: sequence,
                ciphertext: box.combined
            )
        } catch {
            throw RemoteSessionCoreError.authenticationFailed
        }
    }

    func open(_ envelope: SealedSignalingEnvelope) throws -> RemotePairingPayload {
        guard envelope.version == SealedSignalingEnvelope.currentVersion else {
            throw RemoteSessionCoreError.unsupportedEnvelopeVersion
        }
        guard envelope.channelID == credential.channelID else {
            throw RemoteSessionCoreError.wrongRendezvousChannel
        }
        guard envelope.direction == receivingDirection else {
            throw RemoteSessionCoreError.unexpectedSignalDirection
        }
        let key = role == .host ? credential.viewerToHost : credential.hostToViewer
        let plaintext: Data
        do {
            let box = try ChaChaPoly.SealedBox(combined: envelope.ciphertext)
            plaintext = try ChaChaPoly.open(
                box,
                using: SymmetricKey(data: key),
                authenticating: envelope.additionalAuthenticatedData
            )
        } catch {
            throw RemoteSessionCoreError.authenticationFailed
        }
        do {
            return try JSONDecoder().decode(RemotePairingPayload.self, from: plaintext)
        } catch {
            throw RemoteSessionCoreError.invalidSignalPayload
        }
    }
}

/// Invitation-encrypted transport for the pairing handshake only.
///
/// It deliberately cannot carry SDP/ICE. After commit, close it and use paired availability
/// plus a fresh reconnect-derived credential for the ordinary media signaling client.
public actor PairingBootstrapSignalingClient {
    public typealias EventStream = AsyncThrowingStream<PairingBootstrapSignalingEvent, Error>

    private enum State { case idle, connected, closed }
    private enum Limits {
        static let maximumWireMessageBytes = 90_000
        static let maximumEnvelopeBytes = 65_536
        static let maximumSequence: UInt64 = 2_147_483_647
        static let maximumEventBufferCount = 128
    }

    private let role: RemotePeerRole
    private let rendezvousURL: URL
    private let credential: RemoteRendezvousCredential
    private let transport: any RendezvousSocketTransport
    private let cipher: PairingBootstrapCipher

    private var state = State.idle
    private var continuation: EventStream.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var nextSequence: UInt64 = 0
    private var replayGuard = SignalingReplayGuard()

    public init(
        endpoint: URL,
        invitation: RemoteInvitationCode,
        role: RemotePeerRole
    ) throws {
        let credential = RemoteRendezvousCredential(invitation: invitation)
        self.role = role
        self.credential = credential
        cipher = PairingBootstrapCipher(credential: credential, role: role)
        rendezvousURL = try Self.makeRendezvousURL(endpoint: endpoint)
        transport = URLSessionRendezvousSocketTransport()
    }

    internal init(
        endpoint: URL,
        invitation: RemoteInvitationCode,
        role: RemotePeerRole,
        transport: any RendezvousSocketTransport
    ) throws {
        let credential = RemoteRendezvousCredential(invitation: invitation)
        self.role = role
        self.credential = credential
        cipher = PairingBootstrapCipher(credential: credential, role: role)
        rendezvousURL = try Self.makeRendezvousURL(endpoint: endpoint)
        self.transport = transport
    }

    public func connect() async throws -> EventStream {
        guard state == .idle else { throw RendezvousSignalingError.alreadyConnected }
        do {
            try await transport.connect(
                to: rendezvousURL,
                channelID: credential.channelID,
                role: role,
                admissionProof: credential.admissionProof,
                viewerAdmissionProof: nil,
                mode: .pairing
            )
        } catch {
            state = .closed
            await transport.close()
            throw RendezvousSignalingError.connectionFailed
        }

        // `transport.connect` is an actor-reentrant suspension point. A concurrent `close()` can
        // therefore win while the socket is still opening and move this client to `.closed`.
        // Never let a later successful connect completion resurrect that closed client.
        guard state == .idle else {
            await transport.close()
            throw RendezvousSignalingError.connectionClosed
        }

        let pair = EventStream.makeStream(
            bufferingPolicy: .bufferingOldest(Limits.maximumEventBufferCount)
        )
        continuation = pair.continuation
        state = .connected
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.close() }
        }
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
        return pair.stream
    }

    public func send(_ payload: RemotePairingPayload) async throws {
        guard state == .connected else { throw RendezvousSignalingError.notConnected }
        try Self.validate(payload: payload, senderRole: role)
        guard nextSequence <= Limits.maximumSequence else {
            throw RemoteSessionCoreError.sequenceExhausted
        }
        let envelope = try cipher.seal(payload, sequence: nextSequence)
        nextSequence += 1
        let envelopeData = try remoteCanonicalData(envelope)
        guard envelopeData.count <= Limits.maximumEnvelopeBytes else {
            throw RemoteSessionCoreError.invalidSignalPayload
        }
        let wire = PairingOutboundWire(
            type: "signal",
            seq: envelope.sequence,
            envelope: Self.base64URLEncoded(envelopeData)
        )
        let data = try remoteCanonicalData(wire)
        guard data.count <= Limits.maximumWireMessageBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw RemoteSessionCoreError.invalidSignalPayload
        }
        do {
            try await transport.send(text: text)
        } catch {
            await finish(throwing: RendezvousSignalingError.connectionClosed)
            throw RendezvousSignalingError.sendFailed
        }
    }

    public func close() async { await finish(throwing: nil) }

    private func receiveLoop() async {
        while state == .connected, !Task.isCancelled {
            let message: RendezvousSocketMessage
            do { message = try await transport.receive() }
            catch {
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
                let event = try parse(text: text)
                guard let continuation else { return }
                switch continuation.yield(event) {
                case .enqueued: break
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
            } catch {
                await finish(throwing: error)
                return
            }
        }
    }

    private func parse(text: String) throws -> PairingBootstrapSignalingEvent {
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= Limits.maximumWireMessageBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let type = dictionary["type"] as? String else {
            throw RendezvousSignalingError.invalidServerMessage
        }
        switch type {
        case "waiting":
            try Self.requireExactKeys(dictionary, ["type", "invitationExpiresAt"])
            let wire = try Self.decode(PairingWaitingWire.self, from: data)
            return .waiting(invitationExpiresAt: try Self.parseDate(wire.invitationExpiresAt))
        case "ready":
            try Self.requireExactKeys(
                dictionary,
                ["type", "role", "invitationExpiresAt", "iceServers"]
            )
            let wire = try Self.decode(PairingReadyWire.self, from: data)
            guard wire.role == role, wire.iceServers.count <= 16 else {
                throw RendezvousSignalingError.invalidServerMessage
            }
            return .ready(
                role: role,
                invitationExpiresAt: try Self.parseDate(wire.invitationExpiresAt)
            )
        case "signal":
            try Self.requireExactKeys(dictionary, ["type", "from", "seq", "envelope"])
            let wire = try Self.decode(PairingInboundWire.self, from: data)
            guard wire.from == role.opposite, wire.seq <= Limits.maximumSequence else {
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
            let payload = try cipher.open(envelope)
            try replayGuard.accept(sequence: envelope.sequence)
            try Self.validate(payload: payload, senderRole: role.opposite)
            return .signal(payload)
        case "peer-left":
            try Self.requireExactKeys(dictionary, ["type", "role"])
            let wire = try Self.decode(PairingPeerLeftWire.self, from: data)
            guard wire.role == role.opposite else {
                throw RendezvousSignalingError.invalidServerMessage
            }
            // The Worker may admit a replacement peer on this same one-time invitation.
            // Pairing transport sequences are scoped to one admitted peer, so both directions
            // must restart before the departure is observable by the handshake state machine.
            nextSequence = 0
            replayGuard = SignalingReplayGuard()
            return .peerLeft(wire.role)
        case "error":
            try Self.requireExactKeys(dictionary, ["type", "error"])
            let wire = try Self.decode(PairingErrorWire.self, from: data)
            return .serverError(Self.serverError(for: wire.error))
        default:
            throw RendezvousSignalingError.invalidServerMessage
        }
    }

    private func finish(throwing error: (any Error)?) async {
        guard state != .closed else { return }
        state = .closed
        let activeContinuation = continuation
        continuation = nil
        let task = receiveTask
        receiveTask = nil
        task?.cancel()
        await transport.close()
        if let error { activeContinuation?.finish(throwing: error) }
        else { activeContinuation?.finish() }
    }

    private static func validate(
        payload: RemotePairingPayload,
        senderRole: RemotePeerRole
    ) throws {
        let valid = switch payload {
        case .hello(let hello):
            hello.role == senderRole && hello.isStructurallyValid
        case .confirmation(let confirmation):
            confirmation.senderRole == senderRole && confirmation.isStructurallyValid
        case .commit(let commit):
            commit.senderRole == senderRole && commit.isStructurallyValid
        }
        guard valid else { throw RemoteSessionCoreError.invalidSignalPayload }
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
        if scheme == "ws" {
            guard Self.isLoopback(host: host) else {
                throw RendezvousSignalingError.invalidEndpoint
            }
        } else if scheme != "wss" {
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
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if value == "localhost" || value.hasSuffix(".localhost")
            || value == "::1" || value == "[::1]" { return true }
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        return pieces.count == 4 && pieces.first == "127" && pieces.allSatisfy { piece in
            guard !piece.isEmpty, piece.allSatisfy(\.isNumber), let byte = UInt8(piece) else {
                return false
            }
            return String(byte) == piece || piece == "0"
        }
    }

    private static func parseDate(_ value: String) throws -> Date {
        guard value.utf8.count <= 64,
              let date = try? Date(
                value,
                strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)
              ) else {
            throw RendezvousSignalingError.invalidServerMessage
        }
        return date
    }

    private static func requireExactKeys(
        _ dictionary: [String: Any],
        _ keys: Set<String>
    ) throws {
        guard Set(dictionary.keys) == keys else {
            throw RendezvousSignalingError.invalidServerMessage
        }
    }

    private static func validateEnvelopeSchema(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == [
                "version", "channelID", "direction", "sequence", "ciphertext"
              ] else {
            throw RendezvousSignalingError.invalidServerMessage
        }
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw RendezvousSignalingError.invalidServerMessage }
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
                  case 45, 48...57, 65...90, 95, 97...122: true
                  default: false
                  }
              }) else {
            throw RendezvousSignalingError.invalidServerMessage
        }
        var standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard.append(String(repeating: "=", count: (4 - standard.count % 4) % 4))
        guard let data = Data(base64Encoded: standard),
              data.count <= maximumDecodedBytes,
              base64URLEncoded(data) == value else {
            throw RendezvousSignalingError.invalidServerMessage
        }
        return data
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
}

private struct PairingOutboundWire: Encodable {
    let type: String
    let seq: UInt64
    let envelope: String
}
private struct PairingWaitingWire: Decodable { let invitationExpiresAt: String }
private struct PairingReadyWire: Decodable {
    let role: RemotePeerRole
    let invitationExpiresAt: String
    let iceServers: [PairingICEServerWire]
}
private struct PairingICEServerWire: Decodable { let urls: [String] }
private struct PairingInboundWire: Decodable {
    let from: RemotePeerRole
    let seq: UInt64
    let envelope: String
}
private struct PairingPeerLeftWire: Decodable { let role: RemotePeerRole }
private struct PairingErrorWire: Decodable { let error: String }
