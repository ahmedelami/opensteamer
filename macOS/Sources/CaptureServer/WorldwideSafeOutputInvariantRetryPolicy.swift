/// Caps invariant mutations while preserving continuous read-only verification.
struct WorldwideSafeOutputInvariantRetryPolicy: Equatable, Sendable {
    let maximumFailedAttemptCount: Int
    let maximumBackoffTickCount: Int
    let cappedCooldownTickCount: Int
    private(set) var failedAttemptCount = 0
    private(set) var backoffTickCount = 0
    private(set) var cooldownTickCount = 0

    init(
        maximumFailedAttemptCount: Int = 6,
        maximumBackoffTickCount: Int = 16,
        cappedCooldownTickCount: Int = 60
    ) {
        self.maximumFailedAttemptCount = max(
            1,
            maximumFailedAttemptCount
        )
        self.maximumBackoffTickCount = max(
            1,
            maximumBackoffTickCount
        )
        self.cappedCooldownTickCount = max(
            1,
            cappedCooldownTickCount
        )
    }

    mutating func shouldAttemptOnCurrentTick() -> Bool {
        if failedAttemptCount >= maximumFailedAttemptCount {
            guard cooldownTickCount == 0 else {
                cooldownTickCount -= 1
                return false
            }
            failedAttemptCount = 0
            backoffTickCount = 0
        }
        guard backoffTickCount == 0 else {
            backoffTickCount -= 1
            return false
        }
        return true
    }

    mutating func recordFailure() {
        guard failedAttemptCount < maximumFailedAttemptCount else {
            return
        }
        failedAttemptCount += 1
        guard failedAttemptCount < maximumFailedAttemptCount else {
            backoffTickCount = 0
            cooldownTickCount = cappedCooldownTickCount
            return
        }
        let shift = min(failedAttemptCount - 1, 30)
        backoffTickCount = min(
            1 << shift,
            maximumBackoffTickCount
        )
    }

    mutating func reset() {
        failedAttemptCount = 0
        backoffTickCount = 0
        cooldownTickCount = 0
    }
}
