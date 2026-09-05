import Foundation

/// Three recovery attempts per unchanged route. Manual restart, a route change,
/// or sustained fresh samples begins a new episode.
public struct CaptureRetryPolicy {
    private var attempts = 0
    private var nextAttemptAt: TimeInterval?
    private let delays: [TimeInterval] = [1, 3, 10]

    public init() {}
    public mutating func reset() { attempts = 0; nextAttemptAt = nil }

    public mutating func shouldRetry(now: TimeInterval) -> Bool {
        guard now.isFinite, attempts < delays.count else { return false }
        guard let deadline = nextAttemptAt else {
            nextAttemptAt = now + delays[attempts]
            return false
        }
        guard now >= deadline else { return false }
        attempts += 1
        nextAttemptAt = nil
        return true
    }
}
