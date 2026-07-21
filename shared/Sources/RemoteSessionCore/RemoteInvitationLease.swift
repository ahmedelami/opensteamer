import Foundation

/// Observable lifecycle states for a one-time pairing invitation.
public enum RemoteInvitationStatus: Equatable, Sendable {
    case active
    case expired
    case consumed
}

/// Actor isolation makes consumption atomic even if multiple rendezvous requests arrive together.
public actor OneTimeRemoteInvitation {
    public static let defaultTimeToLive: TimeInterval = 10 * 60
    public static let maximumTimeToLive: TimeInterval = 24 * 60 * 60

    private let code: RemoteInvitationCode
    private let expirationDate: Date
    private var consumed = false

    public init(
        code: RemoteInvitationCode,
        createdAt: Date = Date(),
        timeToLive: TimeInterval = OneTimeRemoteInvitation.defaultTimeToLive
    ) throws {
        guard timeToLive.isFinite,
              timeToLive > 0,
              timeToLive <= Self.maximumTimeToLive else {
            throw RemoteSessionCoreError.invalidInvitationLifetime
        }
        self.code = code
        expirationDate = createdAt.addingTimeInterval(timeToLive)
    }

    /// Generates both the cryptographically random invitation and its bounded lease.
    public static func generate(
        createdAt: Date = Date(),
        timeToLive: TimeInterval = defaultTimeToLive
    ) throws -> OneTimeRemoteInvitation {
        try OneTimeRemoteInvitation(
            code: RemoteInvitationCode.generate(),
            createdAt: createdAt,
            timeToLive: timeToLive
        )
    }

    /// Explicitly exports the capability for presentation. Treat the return value as a secret.
    public func exportedCode() -> String {
        code.exportedCode
    }

    /// The absolute deadline after which consumption must fail.
    public func expiresAt() -> Date {
        expirationDate
    }

    /// Returns status at an injected time, allowing deterministic expiry checks in tests.
    public func status(at date: Date = Date()) -> RemoteInvitationStatus {
        if consumed { return .consumed }
        return date >= expirationDate ? .expired : .active
    }

    /// Atomically consumes the invitation. A successful result can occur only once.
    public func consume(at date: Date = Date()) throws -> RemoteInvitationCode {
        if consumed {
            throw RemoteSessionCoreError.invitationAlreadyConsumed
        }
        guard date < expirationDate else {
            throw RemoteSessionCoreError.invitationExpired
        }
        consumed = true
        return code
    }
}
