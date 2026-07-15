import Foundation

/// Public failures are intentionally coarse and never contain invitation or key material.
public enum RemoteSessionCoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidInvitationCode
    case unsupportedInvitationVersion
    case secureRandomGenerationFailed
    case invalidInvitationLifetime
    case invitationExpired
    case invitationAlreadyConsumed
    case invalidRendezvousChannel
    case unsupportedEnvelopeVersion
    case wrongRendezvousChannel
    case unexpectedSignalDirection
    case authenticationFailed
    case invalidSignalPayload
    case replayedSequence
    case sequenceOutsideReplayWindow
    case sequenceExhausted

    public var errorDescription: String? {
        switch self {
        case .invalidInvitationCode:
            "The invitation code is invalid."
        case .unsupportedInvitationVersion:
            "This invitation code version is not supported."
        case .secureRandomGenerationFailed:
            "A secure invitation code could not be generated."
        case .invalidInvitationLifetime:
            "The invitation lifetime is invalid."
        case .invitationExpired:
            "The invitation has expired."
        case .invitationAlreadyConsumed:
            "The invitation has already been used."
        case .invalidRendezvousChannel:
            "The rendezvous channel is invalid."
        case .unsupportedEnvelopeVersion:
            "This signaling envelope version is not supported."
        case .wrongRendezvousChannel:
            "The signaling envelope belongs to a different session."
        case .unexpectedSignalDirection:
            "The signaling envelope has an unexpected direction."
        case .authenticationFailed:
            "The signaling envelope could not be authenticated."
        case .invalidSignalPayload:
            "The signaling payload is invalid."
        case .replayedSequence:
            "The signaling envelope was already received."
        case .sequenceOutsideReplayWindow:
            "The signaling envelope is too old."
        case .sequenceExhausted:
            "The signaling sequence is exhausted."
        }
    }
}
