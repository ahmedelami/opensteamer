import Foundation

/// Pure state machine for invitation, availability, and media exchange ownership.
///
/// Exchange identifiers are scoped independently: availability may reconnect while
/// an already authorized media exchange finishes. Invalid ownership transitions fail
/// closed rather than silently replacing an active peer.
struct WorldwideHostLifecycle: Equatable, Sendable {
    /// Durable high-level state of the worldwide host process.
    enum RunState: Equatable, Sendable {
        case idle
        case inviting
        case pairedAvailable
        case stopped
    }

    private(set) var runState: RunState = .idle
    private(set) var activeExchangeID: String?
    private(set) var mediaExchangeID: String?

    /// Begins invitation or durable availability according to persisted pairing state.
    mutating func start(hasPairedViewer: Bool) throws {
        guard runState == .idle else { throw WorldwideHostLifecycleError.invalidTransition }
        runState = hasPairedViewer ? .pairedAvailable : .inviting
    }

    /// Crosses from one-time invitation into reusable paired availability.
    mutating func durablePairingRecordAvailable() throws {
        guard runState == .inviting else {
            throw WorldwideHostLifecycleError.invalidTransition
        }
        runState = .pairedAvailable
    }

    /// Claims one bounded, nonempty Worker exchange as the active availability peer.
    mutating func availabilityReady(exchangeID: String) throws {
        guard runState == .pairedAvailable,
              activeExchangeID == nil,
              !exchangeID.isEmpty,
              exchangeID.utf8.count <= 64 else {
            throw WorldwideHostLifecycleError.invalidTransition
        }
        activeExchangeID = exchangeID
    }

    /// Marks media active only for the exchange that currently owns availability.
    mutating func mediaStarted(exchangeID: String) throws {
        guard runState == .pairedAvailable,
              activeExchangeID == exchangeID,
              mediaExchangeID == nil else {
            throw WorldwideHostLifecycleError.invalidTransition
        }
        mediaExchangeID = exchangeID
    }

    /// Releases availability only when the departing exchange still owns it.
    mutating func availabilityPeerLeft(exchangeID: String) {
        guard activeExchangeID == exchangeID else { return }
        activeExchangeID = nil
    }

    /// Releases media only when the ending exchange still owns it.
    mutating func mediaEnded(exchangeID: String) {
        guard mediaExchangeID == exchangeID else { return }
        mediaExchangeID = nil
    }

    /// Enters the terminal state and clears all ephemeral exchange ownership.
    mutating func stop() {
        runState = .stopped
        activeExchangeID = nil
        mediaExchangeID = nil
    }
}

/// Bounded exponential backoff for the durable availability WebSocket.
struct WorldwideAvailabilityRetryPolicy: Equatable, Sendable {
    private(set) var nextDelaySeconds = 1
    private(set) var hasValidatedConnection = false

    /// A WebSocket open callback is insufficient because the Worker can accept the upgrade and
    /// immediately return a protocol error. Only a parsed waiting/ready event proves this socket
    /// owns the availability role and may reset backoff.
    mutating func observedValidAvailabilityState() -> Bool {
        let becameValidated = !hasValidatedConnection
        hasValidatedConnection = true
        nextDelaySeconds = 1
        return becameValidated
    }

    /// Returns the current retry delay, then doubles it up to thirty seconds.
    mutating func delayAfterFailure() -> Int {
        let delay = nextDelaySeconds
        nextDelaySeconds = min(nextDelaySeconds * 2, 30)
        hasValidatedConnection = false
        return delay
    }
}

/// Signals an attempted transition that violates worldwide-host ownership rules.
enum WorldwideHostLifecycleError: LocalizedError, Equatable {
    case invalidTransition

    var errorDescription: String? {
        "The worldwide host lifecycle transition is invalid."
    }
}
