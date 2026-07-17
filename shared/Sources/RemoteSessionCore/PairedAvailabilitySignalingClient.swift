import CryptoKit
import Foundation

public enum RemoteAvailabilityPayload: Codable, Equatable, Sendable {
    case pairingCommit(RemotePairingCommit)
    case reconnectRequest(RemoteReconnectRequest)
    case reconnectResponse(RemoteReconnectResponse)

    private enum Kind: String, Codable {
        case pairingCommit
        case reconnectRequest
        case reconnectResponse
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case pairingCommit
        case reconnectRequest
        case reconnectResponse
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .pairingCommit:
            self = .pairingCommit(
                try container.decode(RemotePairingCommit.self, forKey: .pairingCommit)
            )
        case .reconnectRequest:
            self = .reconnectRequest(
                try container.decode(RemoteReconnectRequest.self, forKey: .reconnectRequest)
            )
        case .reconnectResponse:
            self = .reconnectResponse(
                try container.decode(RemoteReconnectResponse.self, forKey: .reconnectResponse)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pairingCommit(let commit):
            try container.encode(Kind.pairingCommit, forKey: .kind)
            try container.encode(commit, forKey: .pairingCommit)
        case .reconnectRequest(let request):
            try container.encode(Kind.reconnectRequest, forKey: .kind)
            try container.encode(request, forKey: .reconnectRequest)
        case .reconnectResponse(let response):
            try container.encode(Kind.reconnectResponse, forKey: .kind)
            try container.encode(response, forKey: .reconnectResponse)
        }
    }
}

public enum PairedAvailabilitySignalingEvent: Equatable, Sendable {
    case waiting
    case ready(role: RemotePeerRole, exchangeID: RemoteAvailabilityExchangeID)
    case signal(RemoteAvailabilityPayload)
    case peerLeft(role: RemotePeerRole, exchangeID: RemoteAvailabilityExchangeID)
    case serverError(RendezvousServerError)
}

public struct SealedAvailabilityEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion: UInt8 = 1

    public let version: UInt8
    public let channelID: RendezvousChannelID
    public let exchangeID: RemoteAvailabilityExchangeID
    public let direction: RemoteSignalDirection
    public let sequence: UInt64
    public let ciphertext: Data

    public init(
        version: UInt8 = SealedAvailabilityEnvelope.currentVersion,
        channelID: RendezvousChannelID,
        exchangeID: RemoteAvailabilityExchangeID,
        direction: RemoteSignalDirection,
        sequence: UInt64,
        ciphertext: Data
    ) {
        self.version = version
        self.channelID = channelID
        self.exchangeID = exchangeID
        self.direction = direction
        self.sequence = sequence
        self.ciphertext = ciphertext
    }

    internal var additionalAuthenticatedData: Data {
        var sequence = sequence.bigEndian
        return remoteDomainSeparated(
            "AudioStreamer.Availability.Envelope.AAD.v1",
            Data([version]),
            Data(channelID.wireValue.utf8),
            exchangeID.rawValue,
            Data([direction.wireByte]),
            withUnsafeBytes(of: &sequence) { Data($0) }
        )
    }
}

internal struct RemoteAvailabilityCipher: Sendable {
    let credential: RemoteRendezvousCredential
    let exchangeID: RemoteAvailabilityExchangeID
    let role: RemotePeerRole

    var sendingDirection: RemoteSignalDirection {
        role == .host ? .hostToViewer : .viewerToHost
    }

    var receivingDirection: RemoteSignalDirection {
        role == .host ? .viewerToHost : .hostToViewer
    }

    func seal(
        _ payload: RemoteAvailabilityPayload,
        sequence: UInt64
    ) throws -> SealedAvailabilityEnvelope {
        let plaintext: Data
        do {
            plaintext = try remoteCanonicalData(payload)
        } catch {
            throw RemoteSessionCoreError.invalidSignalPayload
        }
        let empty = SealedAvailabilityEnvelope(
            channelID: credential.channelID,
            exchangeID: exchangeID,
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
            return SealedAvailabilityEnvelope(
                channelID: credential.channelID,
                exchangeID: exchangeID,
                direction: sendingDirection,
                sequence: sequence,
                ciphertext: box.combined
            )
        } catch {
            throw RemoteSessionCoreError.authenticationFailed
        }
    }

    func open(_ envelope: SealedAvailabilityEnvelope) throws -> RemoteAvailabilityPayload {
        guard envelope.version == SealedAvailabilityEnvelope.currentVersion else {
            throw RemoteSessionCoreError.unsupportedEnvelopeVersion
        }
        guard envelope.channelID == credential.channelID else {
            throw RemoteSessionCoreError.wrongRendezvousChannel
        }
        guard envelope.exchangeID == exchangeID else {
            throw RemoteSessionCoreError.authenticationFailed
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
            return try JSONDecoder().decode(RemoteAvailabilityPayload.self, from: plaintext)
        } catch {
            throw RemoteSessionCoreError.invalidSignalPayload
        }
    }
}

/// Dedicated client for the persistent availability Durable Object.
///
/// It connects only to `/v2/availability`, requires the server to negotiate the exact WebSocket
/// subprotocol `audiostreamer.availability.v1`, sends `X-AudioStreamer-Mode: availability`, and
/// uses a role-separated admission capability. The host additionally registers the viewer
/// capability; the viewer never sends that header. It rejects every legacy invitation schema and
/// installs exchange-specific AEAD keys only after `availability-ready` supplies a fresh canonical
/// exchange identifier. It cannot carry SDP, ICE, or media signaling.
public actor PairedAvailabilitySignalingClient {
    public typealias EventStream = AsyncThrowingStream<PairedAvailabilitySignalingEvent, Error>

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
    }

    private let role: RemotePeerRole
    private let rendezvousURL: URL
    private let locator: RemoteAvailabilityLocator
    private let transport: any RendezvousSocketTransport

    private var state = State.idle
    private var continuation: EventStream.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var exchangeID: RemoteAvailabilityExchangeID?
    private var cipher: RemoteAvailabilityCipher?
    private var nextSequence: UInt64 = 0
    private var replayGuard = SignalingReplayGuard()

    public init(
        endpoint: URL,
        locator: RemoteAvailabilityLocator,
        role: RemotePeerRole
    ) throws {
        guard locator.localRole == role else {
            throw RemoteSessionCoreError.invalidRendezvousCredential
        }
        self.role = role
        self.locator = locator
        rendezvousURL = try Self.makeRendezvousURL(endpoint: endpoint)
        transport = URLSessionRendezvousSocketTransport()
    }

    internal init(
        endpoint: URL,
        locator: RemoteAvailabilityLocator,
        role: RemotePeerRole,
        transport: any RendezvousSocketTransport
    ) throws {
        guard locator.localRole == role else {
            throw RemoteSessionCoreError.invalidRendezvousCredential
        }
        self.role = role
        self.locator = locator
        rendezvousURL = try Self.makeRendezvousURL(endpoint: endpoint)
        self.transport = transport
    }

    public func connect() async throws -> EventStream {
        guard state == .idle else {
            throw RendezvousSignalingError.alreadyConnected
        }
        do {
            try await transport.connect(
                to: rendezvousURL,
                channelID: locator.channelID,
                role: role,
                admissionProof: locator.admissionProof,
                viewerAdmissionProof: locator.viewerRegistrationProof,
                mode: .availability
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
            Task { await self?.close() }
        }
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        return pair.stream
    }

    public func send(_ payload: RemoteAvailabilityPayload) async throws {
        guard state == .connected,
              let exchangeID,
              let cipher else {
            throw RendezvousSignalingError.notConnected
        }
        try Self.validate(payload: payload, senderRole: role)
        guard nextSequence <= Limits.maximumSequence else {
            await finish(throwing: RemoteSessionCoreError.sequenceExhausted)
            throw RemoteSessionCoreError.sequenceExhausted
        }
        let envelope = try cipher.seal(payload, sequence: nextSequence)
        nextSequence += 1
        let envelopeData = try remoteCanonicalData(envelope)
        guard envelopeData.count <= Limits.maximumEnvelopeBytes else {
            throw RemoteSessionCoreError.invalidSignalPayload
        }
        let wire = AvailabilityOutboundSignalWire(
            type: "availability-signal",
            exchangeID: exchangeID.wireValue,
            seq: envelope.sequence,
            envelope: Self.base64URLEncoded(envelopeData)
        )
        let wireData = try remoteCanonicalData(wire)
        guard wireData.count <= Limits.maximumWireMessageBytes,
              let text = String(data: wireData, encoding: .utf8) else {
            throw RemoteSessionCoreError.invalidSignalPayload
        }
        do {
            try await transport.send(text: text)
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
                let event = try parse(text: text)
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
            } catch {
                await finish(throwing: error)
                return
            }
        }
    }

    private func parse(text: String) throws -> PairedAvailabilitySignalingEvent {
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= Limits.maximumWireMessageBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let type = dictionary["type"] as? String else {
            throw RendezvousSignalingError.invalidServerMessage
        }

        switch type {
        case "availability-waiting":
            try Self.requireExactKeys(dictionary, ["type"])
            return .waiting

        case "availability-ready":
            try Self.requireExactKeys(dictionary, ["type", "role", "exchangeID"])
            let wire = try Self.decode(AvailabilityReadyWire.self, from: data)
            guard wire.role == role else {
                throw RendezvousSignalingError.invalidServerMessage
            }
            let newExchange: RemoteAvailabilityExchangeID
            do {
                newExchange = try RemoteAvailabilityExchangeID(wireValue: wire.exchangeID)
            } catch {
                throw RendezvousSignalingError.invalidServerMessage
            }
            let credential = try locator.credential(exchangeID: newExchange)
            exchangeID = newExchange
            cipher = RemoteAvailabilityCipher(
                credential: credential,
                exchangeID: newExchange,
                role: role
            )
            nextSequence = 0
            replayGuard = SignalingReplayGuard()
            return .ready(role: role, exchangeID: newExchange)

        case "availability-signal":
            try Self.requireExactKeys(
                dictionary,
                ["type", "from", "exchangeID", "seq", "envelope"]
            )
            let wire = try Self.decode(AvailabilityInboundSignalWire.self, from: data)
            guard wire.from == role.opposite,
                  wire.seq <= Limits.maximumSequence,
                  let currentExchange = exchangeID,
                  wire.exchangeID == currentExchange.wireValue,
                  let cipher else {
                throw RendezvousSignalingError.invalidServerMessage
            }
            let envelopeData = try Self.decodeBase64URL(
                wire.envelope,
                maximumDecodedBytes: Limits.maximumEnvelopeBytes
            )
            try Self.validateEnvelopeSchema(envelopeData)
            let envelope = try Self.decode(SealedAvailabilityEnvelope.self, from: envelopeData)
            guard envelope.sequence == wire.seq,
                  envelope.exchangeID == currentExchange else {
                throw RendezvousSignalingError.invalidServerMessage
            }
            let payload = try cipher.open(envelope)
            try replayGuard.accept(sequence: envelope.sequence)
            try Self.validate(payload: payload, senderRole: role.opposite)
            return .signal(payload)

        case "availability-peer-left":
            try Self.requireExactKeys(dictionary, ["type", "role", "exchangeID"])
            let wire = try Self.decode(AvailabilityPeerLeftWire.self, from: data)
            guard wire.role == role.opposite,
                  let currentExchange = exchangeID,
                  wire.exchangeID == currentExchange.wireValue else {
                throw RendezvousSignalingError.invalidServerMessage
            }
            exchangeID = nil
            cipher = nil
            nextSequence = 0
            replayGuard = SignalingReplayGuard()
            return .peerLeft(role: wire.role, exchangeID: currentExchange)

        case "error":
            try Self.requireExactKeys(dictionary, ["type", "error"])
            let wire = try Self.decode(AvailabilityErrorWire.self, from: data)
            guard !wire.error.isEmpty,
                  wire.error.utf8.count <= 64,
                  wire.error.utf8.allSatisfy(Self.isSafeErrorByte) else {
                throw RendezvousSignalingError.invalidServerMessage
            }
            return .serverError(Self.serverError(for: wire.error))

        default:
            // In particular, legacy `waiting`, `ready`, and `signal` fail closed here.
            throw RendezvousSignalingError.invalidServerMessage
        }
    }

    private func finish(throwing error: (any Error)?) async {
        guard state != .closed else { return }
        state = .closed
        let activeContinuation = continuation
        continuation = nil
        let activeTask = receiveTask
        receiveTask = nil
        activeTask?.cancel()
        await transport.close()
        if let error {
            activeContinuation?.finish(throwing: error)
        } else {
            activeContinuation?.finish()
        }
    }

    private static func validate(
        payload: RemoteAvailabilityPayload,
        senderRole: RemotePeerRole
    ) throws {
        let valid = switch payload {
        case .pairingCommit(let commit):
            commit.senderRole == senderRole && commit.isStructurallyValid
        case .reconnectRequest(let request):
            senderRole == .viewer && request.isStructurallyValid
        case .reconnectResponse(let response):
            senderRole == .host && response.isStructurallyValid
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
        components.path = "/v2/availability"
        guard let result = components.url else {
            throw RendezvousSignalingError.invalidEndpoint
        }
        return result
    }

    private static func isLoopback(host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if normalized == "localhost" || normalized.hasSuffix(".localhost")
            || normalized == "::1" || normalized == "[::1]" {
            return true
        }
        let pieces = normalized.split(separator: ".", omittingEmptySubsequences: false)
        return pieces.count == 4 && pieces.first == "127" && pieces.allSatisfy { piece in
            guard !piece.isEmpty, piece.allSatisfy(\.isNumber), let value = UInt8(piece) else {
                return false
            }
            return String(value) == piece || piece == "0"
        }
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
              let dictionary = object as? [String: Any] else {
            throw RendezvousSignalingError.invalidServerMessage
        }
        try requireExactKeys(
            dictionary,
            ["version", "channelID", "exchangeID", "direction", "sequence", "ciphertext"]
        )
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw RendezvousSignalingError.invalidServerMessage
        }
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
        case "availability_unavailable", "peer_unavailable": .peerUnavailable
        case "rate_limited": .rateLimited
        case "role_already_claimed": .roleConflict
        default: .requestRejected
        }
    }

    private static func isSafeErrorByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 95, 97...122: true
        default: false
        }
    }
}

private struct AvailabilityReadyWire: Decodable {
    let role: RemotePeerRole
    let exchangeID: String
}

private struct AvailabilityOutboundSignalWire: Encodable {
    let type: String
    let exchangeID: String
    let seq: UInt64
    let envelope: String
}

private struct AvailabilityInboundSignalWire: Decodable {
    let from: RemotePeerRole
    let exchangeID: String
    let seq: UInt64
    let envelope: String
}

private struct AvailabilityPeerLeftWire: Decodable {
    let role: RemotePeerRole
    let exchangeID: String
}

private struct AvailabilityErrorWire: Decodable {
    let error: String
}
