import Foundation
import RemoteSessionCore

/// The screen state the host has actually reached, not merely the state the viewer requested.
public enum WebRTCScreenState: String, Codable, CaseIterable, Sendable {
    case active
    case inactive
}

/// A monotonically identified command delivered over the ordered WebRTC control channel.
public struct WebRTCControlRequest: Codable, Equatable, Sendable {
    public let id: UInt64
    public let command: RemoteControlCommand

    public init(id: UInt64, command: RemoteControlCommand) {
        self.id = id
        self.command = command
    }
}

/// Confirmation that the host has completed a request and reached `state`.
public struct WebRTCControlAcknowledgement: Codable, Equatable, Sendable {
    public let id: UInt64
    public let state: WebRTCScreenState
    /// Present only when a successful Show/Active transition also authorizes this exact
    /// screen generation for remote input. Older v2 peers safely ignore this optional field.
    public let inputCapability: WebRTCInputCapability?

    public init(
        id: UInt64,
        state: WebRTCScreenState,
        inputCapability: WebRTCInputCapability? = nil
    ) {
        self.id = id
        self.state = state
        self.inputCapability = inputCapability
    }
}

/// Privacy-minimal viewer challenge that causally binds a later Mac process sample to one
/// prospective next-call epoch and then one exact CallKit epoch. It contains no process,
/// participant, handle, or contact identity.
public struct WebRTCMacHostedCallChallenge: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 3

    public let protocolVersion: Int
    public let sequence: UInt64
    public let nonce: UUID
    /// Stable privacy-random identity for one prospectively armed next-call epoch and, once the
    /// iPhone observes its first inactive-to-active CallKit membership edge, that exact call.
    /// Challenge nonces may rotate before admission; this epoch nonce must not cross a
    /// contamination, peer, transport, interruption, or replacement-call boundary.
    public let callEpochNonce: UUID

    public init(
        sequence: UInt64,
        callEpochNonce: UUID,
        nonce: UUID = UUID(),
        protocolVersion: Int = Self.currentProtocolVersion
    ) {
        self.protocolVersion = protocolVersion
        self.sequence = sequence
        self.nonce = nonce
        self.callEpochNonce = callEpochNonce
    }

    public var isValid: Bool {
        protocolVersion == Self.currentProtocolVersion
            && sequence > 0
            && nonce != Self.zeroUUID
            && callEpochNonce != Self.zeroUUID
            && nonce != callEpochNonce
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

/// Privacy-minimal, transport-bound proof that the Mac freshly sampled one exact FaceTime duplex
/// process after receiving the echoed viewer challenge. Evidence sequence numbers are monotonic
/// for one peer lifetime.
public struct WebRTCMacHostedCallEvidence: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 3

    public enum State: String, Codable, Sendable {
        case active
        /// The host installed this exact prospective challenge from a known-empty native
        /// baseline. It is never microphone authorization by itself.
        case preflightArmed
        /// The exact binder is neither prospectively armed nor causally active. This includes a
        /// poisoned/revoked transition and can never acknowledge a preflight.
        case inactive
    }

    public let protocolVersion: Int
    public let sequence: UInt64
    public let challengeSequence: UInt64
    public let challengeNonce: UUID
    /// Echo of the challenged CallKit-call identity; it must match independently of the rotating
    /// challenge nonce and monotonic sequence.
    public let callEpochNonce: UUID
    public let state: State

    public init(
        sequence: UInt64,
        challengeSequence: UInt64,
        challengeNonce: UUID,
        callEpochNonce: UUID,
        state: State,
        protocolVersion: Int = Self.currentProtocolVersion
    ) {
        self.protocolVersion = protocolVersion
        self.sequence = sequence
        self.challengeSequence = challengeSequence
        self.challengeNonce = challengeNonce
        self.callEpochNonce = callEpochNonce
        self.state = state
    }

    public var isValid: Bool {
        protocolVersion == Self.currentProtocolVersion
            && sequence > 0
            && challengeSequence > 0
            && challengeNonce != Self.zeroUUID
            && callEpochNonce != Self.zeroUUID
            && challengeNonce != callEpochNonce
    }

    /// Exact three-dimensional challenge identity. None of these identities may be inferred from
    /// another: the sequence orders challenges, the nonce prevents replay, and the CallKit epoch
    /// prevents a replacement call with the same aggregate counts from inheriting evidence.
    func matches(_ challenge: WebRTCMacHostedCallChallenge) -> Bool {
        isValid
            && challenge.isValid
            && challengeSequence == challenge.sequence
            && challengeNonce == challenge.nonce
            && callEpochNonce == challenge.callEpochNonce
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}
