import CryptoKit
import Foundation

public struct RendezvousChannelID: Codable, Equatable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let wireValue: String

    public init(wireValue: String) throws {
        let decoded: Data
        do {
            decoded = try CrockfordBase32.decode(wireValue, expectedByteCount: 32)
        } catch {
            throw RemoteSessionCoreError.invalidRendezvousChannel
        }
        guard CrockfordBase32.encode(decoded) == wireValue else {
            throw RemoteSessionCoreError.invalidRendezvousChannel
        }
        self.wireValue = wireValue
    }

    public var description: String { "<redacted rendezvous channel>" }
    public var debugDescription: String { description }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(wireValue: container.decode(String.self))
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid rendezvous channel"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }

    internal init(derivedBytes: Data) {
        wireValue = CrockfordBase32.encode(derivedBytes)
    }
}

internal struct RendezvousAdmissionProof: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    let wireValue: String

    init(derivedBytes: Data) {
        precondition(derivedBytes.count == 32)
        wireValue = derivedBytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    var description: String { "<redacted rendezvous admission proof>" }
    var debugDescription: String { description }
}

public enum RemoteSignalDirection: String, Codable, CaseIterable, Sendable {
    case hostToViewer
    case viewerToHost

    internal var wireByte: UInt8 {
        switch self {
        case .hostToViewer: 1
        case .viewerToHost: 2
        }
    }
}

public struct SealedSignalingEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion: UInt8 = 1

    public let version: UInt8
    public let channelID: RendezvousChannelID
    public let direction: RemoteSignalDirection
    public let sequence: UInt64
    /// ChaChaPoly's combined nonce, ciphertext, and authentication tag.
    public let ciphertext: Data

    public init(
        version: UInt8 = SealedSignalingEnvelope.currentVersion,
        channelID: RendezvousChannelID,
        direction: RemoteSignalDirection,
        sequence: UInt64,
        ciphertext: Data
    ) {
        self.version = version
        self.channelID = channelID
        self.direction = direction
        self.sequence = sequence
        self.ciphertext = ciphertext
    }
}

/// Complete secret material for one encrypted rendezvous channel.
///
/// The value is intentionally not Codable: durable pair records derive availability
/// credentials on demand, while reconnect credentials are fresh and session-scoped.
/// Textual descriptions never reveal routing or key material.
public struct RemoteRendezvousCredential: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let channelID: RendezvousChannelID

    internal let admissionProof: RendezvousAdmissionProof
    internal let hostToViewer: Data
    internal let viewerToHost: Data

    public var description: String { "<redacted remote rendezvous credential>" }
    public var debugDescription: String { description }

    internal init(invitation: RemoteInvitationCode) {
        let keys = RemoteSessionKeys(invitation: invitation)
        channelID = keys.channelID
        admissionProof = keys.admissionProof
        hostToViewer = keys.hostToViewer
        viewerToHost = keys.viewerToHost
    }

    internal init(keyMaterial: Data, salt: Data, context: String) throws {
        guard keyMaterial.count >= 32,
              salt.count >= 16,
              !context.isEmpty,
              context.utf8.count <= 128 else {
            throw RemoteSessionCoreError.invalidRendezvousCredential
        }

        let derivationSalt = remoteDomainSeparated(
            "AudioStreamer.DurableRendezvous.Salt.v1",
            salt,
            Data(context.utf8)
        )
        func derive(_ label: String) -> Data {
            remoteHKDF(
                input: keyMaterial,
                salt: derivationSalt,
                label: "AudioStreamer.DurableRendezvous.\(context).\(label).v1"
            )
        }

        channelID = RendezvousChannelID(derivedBytes: derive("channel"))
        admissionProof = RendezvousAdmissionProof(derivedBytes: derive("admission"))
        hostToViewer = derive("host-to-viewer")
        viewerToHost = derive("viewer-to-host")
    }

    internal init(
        channelID: RendezvousChannelID,
        admissionProof: RendezvousAdmissionProof,
        hostToViewer: Data,
        viewerToHost: Data
    ) throws {
        guard hostToViewer.count == 32,
              viewerToHost.count == 32,
              !remoteConstantTimeEqual(hostToViewer, viewerToHost) else {
            throw RemoteSessionCoreError.invalidRendezvousCredential
        }
        self.channelID = channelID
        self.admissionProof = admissionProof
        self.hostToViewer = hostToViewer
        self.viewerToHost = viewerToHost
    }
}

/// Stable pair-scoped routing material for the availability Durable Object. Host and viewer
/// locators share one v2 channel but carry distinct, role-bound admission capabilities. The
/// locator intentionally contains no reusable signaling AEAD keys; those are derived only after
/// the server supplies a fresh 128-bit exchange identifier.
public struct RemoteAvailabilityLocator: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let channelID: RendezvousChannelID

    internal let localRole: RemotePeerRole
    internal let admissionProof: RendezvousAdmissionProof
    /// Supplied only by the host while registering the availability channel. A viewer locator
    /// does not retain or transmit this registration capability.
    internal let viewerRegistrationProof: RendezvousAdmissionProof?
    private let exchangeKeySeed: Data
    private let pairID: UUID

    internal init(
        pairRootKey: Data,
        pairID: UUID,
        pairingTranscriptHash: Data,
        localRole: RemotePeerRole
    ) throws {
        guard pairRootKey.count == 32,
              !remoteUUIDIsZero(pairID),
              pairingTranscriptHash.count == 32 else {
            throw RemoteSessionCoreError.invalidRendezvousCredential
        }
        let routingMaterial = remoteHKDF(
            input: pairRootKey,
            salt: remoteDomainSeparated(
                "AudioStreamer.Availability.Route.Salt.v1",
                remoteUUIDData(pairID),
                pairingTranscriptHash
            ),
            label: "AudioStreamer.Availability.Route.v1"
        )
        channelID = RendezvousChannelID(
            derivedBytes: remoteHKDF(
                input: routingMaterial,
                salt: pairingTranscriptHash,
                label: "AudioStreamer.Availability.Channel.v2"
            )
        )
        let hostAdmissionProof = RendezvousAdmissionProof(
            derivedBytes: remoteHKDF(
                input: routingMaterial,
                salt: pairingTranscriptHash,
                label: "AudioStreamer.Availability.Admission.Host.v2"
            )
        )
        let viewerAdmissionProof = RendezvousAdmissionProof(
            derivedBytes: remoteHKDF(
                input: routingMaterial,
                salt: pairingTranscriptHash,
                label: "AudioStreamer.Availability.Admission.Viewer.v2"
            )
        )
        self.localRole = localRole
        switch localRole {
        case .host:
            admissionProof = hostAdmissionProof
            viewerRegistrationProof = viewerAdmissionProof
        case .viewer:
            admissionProof = viewerAdmissionProof
            viewerRegistrationProof = nil
        }
        exchangeKeySeed = remoteHKDF(
            input: pairRootKey,
            salt: remoteDomainSeparated(
                "AudioStreamer.Availability.ExchangeSeed.Salt.v1",
                remoteUUIDData(pairID),
                pairingTranscriptHash
            ),
            label: "AudioStreamer.Availability.ExchangeSeed.v1"
        )
        self.pairID = pairID
    }

    public var description: String { "<redacted remote availability locator>" }
    public var debugDescription: String { description }

    /// Derives direction- and purpose-separated AEAD keys for exactly one server exchange.
    public func credential(
        exchangeID: RemoteAvailabilityExchangeID
    ) throws -> RemoteRendezvousCredential {
        let salt = remoteDomainSeparated(
            "AudioStreamer.Availability.Exchange.Salt.v1",
            remoteUUIDData(pairID),
            exchangeID.rawValue
        )
        return try RemoteRendezvousCredential(
            channelID: channelID,
            admissionProof: admissionProof,
            hostToViewer: remoteHKDF(
                input: exchangeKeySeed,
                salt: salt,
                label: "AudioStreamer.Availability.Exchange.Signaling.HostToViewer.v1"
            ),
            viewerToHost: remoteHKDF(
                input: exchangeKeySeed,
                salt: salt,
                label: "AudioStreamer.Availability.Exchange.Signaling.ViewerToHost.v1"
            )
        )
    }
}

/// Canonical 128-bit server-issued identifier for one availability exchange.
public struct RemoteAvailabilityExchangeID: Codable, Equatable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let wireValue: String

    internal let rawValue: Data

    public init(wireValue: String) throws {
        guard wireValue.utf8.count == 22,
              wireValue.utf8.allSatisfy({ byte in
                  switch byte {
                  case 45, 48...57, 65...90, 95, 97...122: true
                  default: false
                  }
              }) else {
            throw RemoteSessionCoreError.invalidRendezvousCredential
        }
        var standard = wireValue.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard.append("==")
        guard let decoded = Data(base64Encoded: standard),
              decoded.count == 16,
              Self.encode(decoded) == wireValue else {
            throw RemoteSessionCoreError.invalidRendezvousCredential
        }
        self.wireValue = wireValue
        rawValue = decoded
    }

    internal init(rawValue: Data) throws {
        guard rawValue.count == 16 else {
            throw RemoteSessionCoreError.invalidRendezvousCredential
        }
        self.rawValue = rawValue
        wireValue = Self.encode(rawValue)
    }

    public var description: String { "<redacted remote availability exchange>" }
    public var debugDescription: String { description }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(wireValue: container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }

    private static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct RemoteSignalingCipher: Sendable {
    public let channelID: RendezvousChannelID
    public let role: RemotePeerRole

    internal let admissionProof: RendezvousAdmissionProof

    private let sendingKey: Data
    private let receivingKey: Data

    public init(invitation: RemoteInvitationCode, role: RemotePeerRole) {
        self.init(credential: RemoteRendezvousCredential(invitation: invitation), role: role)
    }

    public init(credential: RemoteRendezvousCredential, role: RemotePeerRole) {
        channelID = credential.channelID
        admissionProof = credential.admissionProof
        self.role = role

        switch role {
        case .host:
            sendingKey = credential.hostToViewer
            receivingKey = credential.viewerToHost
        case .viewer:
            sendingKey = credential.viewerToHost
            receivingKey = credential.hostToViewer
        }
    }

    public var sendingDirection: RemoteSignalDirection {
        role == .host ? .hostToViewer : .viewerToHost
    }

    public var receivingDirection: RemoteSignalDirection {
        role == .host ? .viewerToHost : .hostToViewer
    }

    public func seal(_ payload: RemoteSignalPayload, sequence: UInt64) throws -> SealedSignalingEnvelope {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext: Data
        do {
            plaintext = try encoder.encode(payload)
        } catch {
            throw RemoteSessionCoreError.invalidSignalPayload
        }

        let envelope = SealedSignalingEnvelope(
            channelID: channelID,
            direction: sendingDirection,
            sequence: sequence,
            ciphertext: Data()
        )
        do {
            let box = try ChaChaPoly.seal(
                plaintext,
                using: SymmetricKey(data: sendingKey),
                authenticating: envelope.additionalAuthenticatedData
            )
            return SealedSignalingEnvelope(
                channelID: channelID,
                direction: sendingDirection,
                sequence: sequence,
                ciphertext: box.combined
            )
        } catch {
            throw RemoteSessionCoreError.authenticationFailed
        }
    }

    public func open(_ envelope: SealedSignalingEnvelope) throws -> RemoteSignalPayload {
        guard envelope.version == SealedSignalingEnvelope.currentVersion else {
            throw RemoteSessionCoreError.unsupportedEnvelopeVersion
        }
        guard envelope.channelID == channelID else {
            throw RemoteSessionCoreError.wrongRendezvousChannel
        }
        guard envelope.direction == receivingDirection else {
            throw RemoteSessionCoreError.unexpectedSignalDirection
        }

        let plaintext: Data
        do {
            let box = try ChaChaPoly.SealedBox(combined: envelope.ciphertext)
            plaintext = try ChaChaPoly.open(
                box,
                using: SymmetricKey(data: receivingKey),
                authenticating: envelope.additionalAuthenticatedData
            )
        } catch {
            throw RemoteSessionCoreError.authenticationFailed
        }

        do {
            return try JSONDecoder().decode(RemoteSignalPayload.self, from: plaintext)
        } catch {
            throw RemoteSessionCoreError.invalidSignalPayload
        }
    }
}

public struct SignalingReplayGuard: Sendable {
    public static let windowSize: UInt64 = 64

    private var highestSequence: UInt64?
    private var receivedBitmap: UInt64 = 0

    public init() {}

    /// Accepts limited reordering while rejecting duplicates and packets older than the window.
    public mutating func accept(sequence: UInt64) throws {
        guard let highestSequence else {
            self.highestSequence = sequence
            receivedBitmap = 1
            return
        }

        if sequence > highestSequence {
            let advance = sequence - highestSequence
            receivedBitmap = advance >= Self.windowSize
                ? 1
                : (receivedBitmap << advance) | 1
            self.highestSequence = sequence
            return
        }

        let age = highestSequence - sequence
        guard age < Self.windowSize else {
            throw RemoteSessionCoreError.sequenceOutsideReplayWindow
        }
        let mask = UInt64(1) << age
        guard receivedBitmap & mask == 0 else {
            throw RemoteSessionCoreError.replayedSequence
        }
        receivedBitmap |= mask
    }
}

/// Owns sequence allocation so concurrent sends cannot reuse a nonce/key/sequence tuple.
public actor RemoteSignalingSender {
    private let cipher: RemoteSignalingCipher
    private var nextSequence: UInt64

    public init(cipher: RemoteSignalingCipher, initialSequence: UInt64 = 0) {
        self.cipher = cipher
        nextSequence = initialSequence
    }

    public func seal(_ payload: RemoteSignalPayload) throws -> SealedSignalingEnvelope {
        guard nextSequence < UInt64.max else {
            throw RemoteSessionCoreError.sequenceExhausted
        }
        let envelope = try cipher.seal(payload, sequence: nextSequence)
        nextSequence += 1
        return envelope
    }
}

/// Authenticates before marking a sequence received, preventing forged packets from consuming it.
public actor RemoteSignalingReceiver {
    private let cipher: RemoteSignalingCipher
    private var replayGuard = SignalingReplayGuard()

    public init(cipher: RemoteSignalingCipher) {
        self.cipher = cipher
    }

    public func open(_ envelope: SealedSignalingEnvelope) throws -> RemoteSignalPayload {
        let payload = try cipher.open(envelope)
        try replayGuard.accept(sequence: envelope.sequence)
        return payload
    }
}

private struct RemoteSessionKeys {
    let channelID: RendezvousChannelID
    let admissionProof: RendezvousAdmissionProof
    let hostToViewer: Data
    let viewerToHost: Data

    init(invitation: RemoteInvitationCode) {
        let inputKey = SymmetricKey(data: invitation.secretMaterial)
        let salt = Data("AudioStreamer.RemoteSession.HKDF-SHA256.v1\0".utf8)

        let channel = Self.derive(
            inputKey: inputKey,
            salt: salt,
            label: "rendezvous-channel"
        )
        channelID = RendezvousChannelID(derivedBytes: channel)
        admissionProof = RendezvousAdmissionProof(
            derivedBytes: Self.derive(
                inputKey: inputKey,
                salt: salt,
                label: "rendezvous-admission-proof"
            )
        )
        hostToViewer = Self.derive(
            inputKey: inputKey,
            salt: salt,
            label: "signaling-host-to-viewer"
        )
        viewerToHost = Self.derive(
            inputKey: inputKey,
            salt: salt,
            label: "signaling-viewer-to-host"
        )
    }

    private static func derive(inputKey: SymmetricKey, salt: Data, label: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: Data(label.utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }
}

internal extension SealedSignalingEnvelope {
    var additionalAuthenticatedData: Data {
        var data = Data("AudioStreamer.Signaling.Envelope.AAD.v1\0".utf8)
        data.append(version)
        data.append(contentsOf: channelID.wireValue.utf8)
        data.append(0)
        data.append(direction.wireByte)
        var bigEndianSequence = sequence.bigEndian
        withUnsafeBytes(of: &bigEndianSequence) { data.append(contentsOf: $0) }
        return data
    }
}
