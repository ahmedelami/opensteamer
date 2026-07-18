import Foundation

struct WorldwideHostLifecycle: Equatable, Sendable {
    enum RunState: Equatable, Sendable {
        case idle
        case inviting
        case pairedAvailable
        case stopped
    }

    private(set) var runState: RunState = .idle
    private(set) var activeExchangeID: String?
    private(set) var mediaExchangeID: String?

    mutating func start(hasPairedViewer: Bool) throws {
        guard runState == .idle else { throw WorldwideHostLifecycleError.invalidTransition }
        runState = hasPairedViewer ? .pairedAvailable : .inviting
    }

    mutating func durablePairingRecordAvailable() throws {
        guard runState == .inviting else {
            throw WorldwideHostLifecycleError.invalidTransition
        }
        runState = .pairedAvailable
    }

    mutating func availabilityReady(exchangeID: String) throws {
        guard runState == .pairedAvailable,
              activeExchangeID == nil,
              !exchangeID.isEmpty,
              exchangeID.utf8.count <= 64 else {
            throw WorldwideHostLifecycleError.invalidTransition
        }
        activeExchangeID = exchangeID
    }

    mutating func mediaStarted(exchangeID: String) throws {
        guard runState == .pairedAvailable,
              activeExchangeID == exchangeID,
              mediaExchangeID == nil else {
            throw WorldwideHostLifecycleError.invalidTransition
        }
        mediaExchangeID = exchangeID
    }

    mutating func availabilityPeerLeft(exchangeID: String) {
        guard activeExchangeID == exchangeID else { return }
        activeExchangeID = nil
    }

    mutating func mediaEnded(exchangeID: String) {
        guard mediaExchangeID == exchangeID else { return }
        mediaExchangeID = nil
    }

    mutating func stop() {
        runState = .stopped
        activeExchangeID = nil
        mediaExchangeID = nil
    }
}

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

    mutating func delayAfterFailure() -> Int {
        let delay = nextDelaySeconds
        nextDelaySeconds = min(nextDelaySeconds * 2, 30)
        hasValidatedConnection = false
        return delay
    }
}

enum WorldwideHostLifecycleError: LocalizedError, Equatable {
    case invalidTransition

    var errorDescription: String? {
        "The worldwide host lifecycle transition is invalid."
    }
}
