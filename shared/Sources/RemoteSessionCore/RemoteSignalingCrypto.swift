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

    fileprivate var wireByte: UInt8 {
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

public struct RemoteSignalingCipher: Sendable {
    public let channelID: RendezvousChannelID
    public let role: RemotePeerRole

    internal let admissionProof: RendezvousAdmissionProof

    private let sendingKey: Data
    private let receivingKey: Data

    public init(invitation: RemoteInvitationCode, role: RemotePeerRole) {
        let keys = RemoteSessionKeys(invitation: invitation)
        channelID = keys.channelID
        admissionProof = keys.admissionProof
        self.role = role

        switch role {
        case .host:
            sendingKey = keys.hostToViewer
            receivingKey = keys.viewerToHost
        case .viewer:
            sendingKey = keys.viewerToHost
            receivingKey = keys.hostToViewer
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

private extension SealedSignalingEnvelope {
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
