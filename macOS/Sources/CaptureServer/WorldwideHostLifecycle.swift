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

enum WorldwideHostLifecycleError: LocalizedError, Equatable {
    case invalidTransition

    var errorDescription: String? {
        "The worldwide host lifecycle transition is invalid."
    }
}
