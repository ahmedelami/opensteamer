import Foundation

/// A host-owned, synchronously revocable capability for the single transition that exposes
/// screen media. The peer holds its lock across the final native-health check and Active ACK,
/// giving recovery/capture-stop code a deterministic ordering against that transition.
public final class WebRTCControlAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var isRevoked = false

    public init() {}

    public func revoke() {
        lock.lock()
        isRevoked = true
        lock.unlock()
    }

    public var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isRevoked
    }

    public func withValidAuthorization<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !isRevoked else {
            throw WebRTCTransportError.controlAuthorizationRevoked
        }
        return try operation()
    }
}

/// A host-owned, synchronously revocable capability for exposing captured system audio to the
/// WebRTC sender. It is intentionally independent of screen visibility: hiding the remote screen
/// must not mute audio, while any transport-uncertainty boundary revokes this gate immediately.
public final class WebRTCAudioAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var isRevoked = false

    public init() {}

    public func revoke() {
        lock.lock()
        isRevoked = true
        lock.unlock()
    }

    public var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isRevoked
    }

    public func withValidAuthorization<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !isRevoked else {
            throw WebRTCTransportError.audioAuthorizationRevoked
        }
        return try operation()
    }
}

/// A synchronously revocable capability for one continuously monitored FaceTime/CallKit epoch
/// proof. The host may preserve the exact instance across challenge-nonce rotations, but revokes
/// it before poisoning, replacing, or retiring the underlying proof. `WebRTCPeer` holds this lock
/// across its final identity/transport checks and the synchronous data-channel send, so revocation
/// has a deterministic order against an already-queued native observation.
public final class WebRTCMacHostedCallEvidenceAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var isRevoked = false
    /// Stable identity of the exact CallKit epoch whose native causal binding created this token.
    /// It is deliberately independent from rotating per-transport challenge nonces.
    public let callEpochNonce: UUID

    public init(callEpochNonce: UUID) {
        self.callEpochNonce = callEpochNonce
    }

    public func revoke() {
        lock.lock()
        isRevoked = true
        lock.unlock()
    }

    public var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isRevoked && callEpochNonce != Self.zeroUUID
    }

    public func withValidAuthorization<T>(
        _ operation: () throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !isRevoked,
              callEpochNonce != Self.zeroUUID else {
            throw WebRTCTransportError
                .macHostedCallEvidenceAuthorizationRevoked
        }
        return try operation()
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

/// A process-local, synchronously revocable gate for one remote-input generation.
///
/// This is deliberately not part of the Codable wire capability. The host service and
/// `WebRTCPeer` share the same instance so transport/capture uncertainty can linearize against
/// an already-queued request at the final OS-injection boundary. The viewer receives a separate
/// local instance so dismiss/background/Hide can likewise linearize against a queued send.
public final class WebRTCInputAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var isRevoked = false

    public init() {}

    public func revoke() {
        lock.lock()
        isRevoked = true
        lock.unlock()
    }

    public var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isRevoked
    }

    public func withValidAuthorization<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !isRevoked else {
            throw WebRTCTransportError.inputUnavailable
        }
        return try operation()
    }
}

/// A viewer-local, synchronously revocable gate for input already admitted to one session.
///
/// The session authorization remains valid across rendered-size and track transitions so fresh
/// pointer input can resume without another Show. Scroll packets therefore carry this narrower
/// gate through the local queue and actor hop. Revoking it linearizes configuration invalidation
/// against the peer's final data-channel send without revoking unrelated tap or keyboard input.
public final class WebRTCInputSendAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var isRevoked = false

    public init() {}

    public func revoke() {
        lock.lock()
        isRevoked = true
        lock.unlock()
    }

    public var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isRevoked
    }

    public func withValidAuthorization<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !isRevoked else {
            throw WebRTCTransportError.inputUnavailable
        }
        return try operation()
    }
}

/// Establishes one lock order for the session and narrower local-send authorization gates.
/// Revocation never holds both locks, so this order cannot form an ABBA cycle.
enum WebRTCInputSendAuthorizationOrder {
    static func withValidAuthorizations<Result>(
        inputAuthorization: WebRTCInputAuthorization,
        sendAuthorization: WebRTCInputSendAuthorization?,
        operation: () throws -> Result
    ) throws -> Result {
        try inputAuthorization.withValidAuthorization {
            guard let sendAuthorization else {
                return try operation()
            }
            return try sendAuthorization.withValidAuthorization(operation)
        }
    }
}
