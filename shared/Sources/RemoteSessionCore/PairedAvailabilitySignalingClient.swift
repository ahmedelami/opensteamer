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
    internal typealias LivenessSleep = @Sendable (UInt64) async throws -> Void
    internal typealias ProbeNonceGenerator = @Sendable () throws -> Data

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
        static let firstProtocolStateTimeoutNanoseconds: UInt64 = 8_000_000_000
        static let livenessIntervalNanoseconds: UInt64 = 15_000_000_000
        static let livenessTimeoutNanoseconds: UInt64 = 5_000_000_000
        static let applicationProbeAckTimeoutNanoseconds: UInt64 = 5_000_000_000
        static let applicationProbeNonceBytes = 16
    }

    private let role: RemotePeerRole
    private let rendezvousURL: URL
    private let locator: RemoteAvailabilityLocator
    private let transport: any RendezvousSocketTransport
    private let firstProtocolStateTimeoutNanoseconds: UInt64
    private let livenessIntervalNanoseconds: UInt64
    private let livenessTimeoutNanoseconds: UInt64
    private let firstProtocolStateSleep: LivenessSleep
    private let livenessSleep: LivenessSleep
    private let applicationProbeAckTimeoutNanoseconds: UInt64
    private let applicationProbeAckSleep: LivenessSleep
    private let applicationProbeNonceGenerator: ProbeNonceGenerator

    private var state = State.idle
    private var continuation: EventStream.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var firstProtocolStateDeadlineTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var pendingApplicationProbe: PendingAvailabilityProbe?
    private var applicationProbeDeadlineTask: Task<Void, Never>?
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
        firstProtocolStateTimeoutNanoseconds = Limits.firstProtocolStateTimeoutNanoseconds
        livenessIntervalNanoseconds = Limits.livenessIntervalNanoseconds
        livenessTimeoutNanoseconds = Limits.livenessTimeoutNanoseconds
        firstProtocolStateSleep = Self.defaultLivenessSleep
        livenessSleep = Self.defaultLivenessSleep
        applicationProbeAckTimeoutNanoseconds = Limits.applicationProbeAckTimeoutNanoseconds
        applicationProbeAckSleep = Self.defaultLivenessSleep
        applicationProbeNonceGenerator = Self.defaultApplicationProbeNonce
    }

    internal init(
        endpoint: URL,
        locator: RemoteAvailabilityLocator,
        role: RemotePeerRole,
        transport: any RendezvousSocketTransport,
        firstProtocolStateTimeoutNanoseconds: UInt64 = Limits
            .firstProtocolStateTimeoutNanoseconds,
        livenessIntervalNanoseconds: UInt64 = Limits.livenessIntervalNanoseconds,
        livenessTimeoutNanoseconds: UInt64 = Limits.livenessTimeoutNanoseconds,
        firstProtocolStateSleep: @escaping LivenessSleep = PairedAvailabilitySignalingClient
            .defaultLivenessSleep,
        livenessSleep: @escaping LivenessSleep = PairedAvailabilitySignalingClient
            .defaultLivenessSleep,
        applicationProbeAckTimeoutNanoseconds: UInt64 = Limits
            .applicationProbeAckTimeoutNanoseconds,
        applicationProbeAckSleep: @escaping LivenessSleep = PairedAvailabilitySignalingClient
            .defaultLivenessSleep,
        applicationProbeNonceGenerator: @escaping ProbeNonceGenerator =
            PairedAvailabilitySignalingClient.defaultApplicationProbeNonce
    ) throws {
        guard locator.localRole == role else {
            throw RemoteSessionCoreError.invalidRendezvousCredential
        }
        guard firstProtocolStateTimeoutNanoseconds > 0,
              livenessTimeoutNanoseconds > 0,
              applicationProbeAckTimeoutNanoseconds > 0 else {
            throw RemoteSessionCoreError.invalidRendezvousCredential
        }
        self.role = role
        self.locator = locator
        rendezvousURL = try Self.makeRendezvousURL(endpoint: endpoint)
        self.transport = transport
        self.firstProtocolStateTimeoutNanoseconds = firstProtocolStateTimeoutNanoseconds
        self.livenessIntervalNanoseconds = livenessIntervalNanoseconds
        self.livenessTimeoutNanoseconds = livenessTimeoutNanoseconds
        self.firstProtocolStateSleep = firstProtocolStateSleep
        self.livenessSleep = livenessSleep
        self.applicationProbeAckTimeoutNanoseconds = applicationProbeAckTimeoutNanoseconds
        self.applicationProbeAckSleep = applicationProbeAckSleep
        self.applicationProbeNonceGenerator = applicationProbeNonceGenerator
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
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        // HTTP 101 alone does not prove that the Worker admitted this role. Require its first
        // valid protocol state before treating the socket as live or beginning periodic pings.
        firstProtocolStateDeadlineTask = Task { [weak self] in
            await self?.firstProtocolStateDeadlineLoop()
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
                guard let event = try parse(text: text) else {
                    continue
                }
                beginLivenessIfProtocolStateValidated(by: event)
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

    private func firstProtocolStateDeadlineLoop() async {
        do {
            try await firstProtocolStateSleep(firstProtocolStateTimeoutNanoseconds)
            try Task.checkCancellation()
            guard state == .connected,
                  firstProtocolStateDeadlineTask != nil else {
                return
            }
            await finish(throwing: RendezvousSignalingError.connectionClosed)
        } catch is CancellationError {
            return
        } catch {
            if state == .connected, firstProtocolStateDeadlineTask != nil {
                await finish(throwing: RendezvousSignalingError.connectionClosed)
            }
        }
    }

    private func beginLivenessIfProtocolStateValidated(
        by event: PairedAvailabilitySignalingEvent
    ) {
        switch event {
        case .waiting, .ready:
            break
        case .signal, .peerLeft, .serverError:
            return
        }
        guard let deadlineTask = firstProtocolStateDeadlineTask else { return }
        firstProtocolStateDeadlineTask = nil
        deadlineTask.cancel()
        guard livenessTask == nil else { return }
        livenessTask = Task { [weak self] in
            await self?.livenessLoop()
        }
    }

    private func livenessLoop() async {
        while state == .connected, !Task.isCancelled {
            do {
                try await livenessSleep(livenessIntervalNanoseconds)
                try Task.checkCancellation()
                guard state == .connected else { return }
                try await transport.sendPing(
                    timeoutNanoseconds: livenessTimeoutNanoseconds
                )
                if role == .host {
                    try await sendApplicationProbe()
                }
            } catch {
                // A transport callback can report `CancellationError` even though this owning
                // liveness task was never cancelled. Only task cancellation is a quiet shutdown;
                // a cancellation-shaped transport failure must fail the visible connection.
                if error is CancellationError, Task.isCancelled {
                    return
                }
                if state == .connected {
                    await finish(throwing: RendezvousSignalingError.connectionClosed)
                }
                return
            }
        }
    }

    private func sendApplicationProbe() async throws {
        guard role == .host,
              pendingApplicationProbe == nil,
              applicationProbeDeadlineTask == nil else {
            throw RendezvousSignalingError.connectionClosed
        }
        let nonce = try applicationProbeNonceGenerator()
        guard nonce.count == Limits.applicationProbeNonceBytes else {
            throw RemoteSessionCoreError.invalidSignalPayload
        }
        let encodedNonce = Self.base64URLEncoded(nonce)
        let wireData = try remoteCanonicalData(
            AvailabilityProbeWire(type: "availability-probe", nonce: encodedNonce)
        )
        guard wireData.count <= Limits.maximumWireMessageBytes,
              let text = String(data: wireData, encoding: .utf8) else {
            throw RemoteSessionCoreError.invalidSignalPayload
        }

        let resolver = AvailabilityProbeAckResolver()
        pendingApplicationProbe = PendingAvailabilityProbe(
            nonce: nonce,
            resolver: resolver
        )
        // Arm before `send`: URLSession normally completes the send promptly, but a wedged
        // transport must not suppress the application-level liveness deadline.
        applicationProbeDeadlineTask = Task { [weak self, resolver] in
            await self?.applicationProbeDeadlineLoop(resolver: resolver)
        }

        try await transport.send(text: text)
        try applicationProbeSendCompleted(resolver: resolver)
        try await resolver.wait()
    }

    private func applicationProbeDeadlineLoop(
        resolver: AvailabilityProbeAckResolver
    ) async {
        do {
            try await applicationProbeAckSleep(applicationProbeAckTimeoutNanoseconds)
            try Task.checkCancellation()
            guard state == .connected,
                  pendingApplicationProbe?.resolver === resolver else {
                return
            }
            await finish(throwing: RendezvousSignalingError.connectionClosed)
        } catch is CancellationError {
            return
        } catch {
            if state == .connected,
               pendingApplicationProbe?.resolver === resolver {
                await finish(throwing: RendezvousSignalingError.connectionClosed)
            }
        }
    }

    private func applicationProbeSendCompleted(
        resolver: AvailabilityProbeAckResolver
    ) throws {
        guard state == .connected,
              var pending = pendingApplicationProbe,
              pending.resolver === resolver else {
            throw RendezvousSignalingError.connectionClosed
        }
        pending.sendCompleted = true
        if pending.ackReceived {
            completeApplicationProbe(pending)
        } else {
            pendingApplicationProbe = pending
        }
    }

    private func receiveApplicationProbeAck(nonce: Data) throws {
        guard role == .host,
              var pending = pendingApplicationProbe,
              remoteConstantTimeEqual(pending.nonce, nonce) else {
            throw RendezvousSignalingError.invalidServerMessage
        }
        pending.ackReceived = true
        if pending.sendCompleted {
            completeApplicationProbe(pending)
        } else {
            pendingApplicationProbe = pending
        }
    }

    private func completeApplicationProbe(_ pending: PendingAvailabilityProbe) {
        guard pendingApplicationProbe?.resolver === pending.resolver else { return }
        pendingApplicationProbe = nil
        let deadlineTask = applicationProbeDeadlineTask
        applicationProbeDeadlineTask = nil
        deadlineTask?.cancel()
        pending.resolver.resolve(.success(()))
    }

    private func parse(text: String) throws -> PairedAvailabilitySignalingEvent? {
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

        case "availability-probe-ack":
            try Self.requireExactKeys(dictionary, ["type", "nonce"])
            let wire = try Self.decode(AvailabilityProbeAckWire.self, from: data)
            let nonce = try Self.decodeBase64URL(
                wire.nonce,
                maximumDecodedBytes: Limits.applicationProbeNonceBytes
            )
            guard nonce.count == Limits.applicationProbeNonceBytes else {
                throw RendezvousSignalingError.invalidServerMessage
            }
            try receiveApplicationProbeAck(nonce: nonce)
            return nil

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
        let activeFirstProtocolStateDeadlineTask = firstProtocolStateDeadlineTask
        firstProtocolStateDeadlineTask = nil
        let activeLivenessTask = livenessTask
        livenessTask = nil
        let activeApplicationProbeDeadlineTask = applicationProbeDeadlineTask
        applicationProbeDeadlineTask = nil
        let activeApplicationProbe = pendingApplicationProbe
        pendingApplicationProbe = nil
        activeTask?.cancel()
        activeFirstProtocolStateDeadlineTask?.cancel()
        activeLivenessTask?.cancel()
        activeApplicationProbeDeadlineTask?.cancel()
        activeApplicationProbe?.resolver.resolve(.failure(CancellationError()))
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

    private static func defaultLivenessSleep(_ nanoseconds: UInt64) async throws {
        try await Task<Never, Never>.sleep(nanoseconds: nanoseconds)
    }

    private static func defaultApplicationProbeNonce() throws -> Data {
        try remoteRandomBytes(count: Limits.applicationProbeNonceBytes)
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

private struct AvailabilityProbeWire: Encodable {
    let type: String
    let nonce: String
}

private struct AvailabilityProbeAckWire: Decodable {
    let nonce: String
}

private struct PendingAvailabilityProbe: Sendable {
    let nonce: Data
    let resolver: AvailabilityProbeAckResolver
    var sendCompleted = false
    var ackReceived = false
}

private final class AvailabilityProbeAckResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, any Error>?
    private var continuation: CheckedContinuation<Void, any Error>?

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate = lock.withLock { () -> Result<Void, any Error>? in
                    if let result { return result }
                    self.continuation = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }

    func resolve(_ newResult: Result<Void, any Error>) {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard result == nil else { return nil }
            result = newResult
            let waiter = continuation
            continuation = nil
            return waiter
        }
        waiter?.resume(with: newResult)
    }
}
