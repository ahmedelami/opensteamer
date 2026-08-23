import CoreAudio
import Foundation

protocol BlackHoleDeviceAvailabilityListenerCleanupRetaining:
    AnyObject,
    Sendable
{
    func retain(
        id: UUID,
        attempt: @escaping @Sendable () -> Bool
    )
    func redrive(id: UUID)
    func contains(id: UUID) -> Bool

    @discardableResult
    func redriveRetained(
        maximumAttemptCount: Int
    ) -> Int

    var retainedJobCount: Int { get }
}

protocol BlackHoleDeferredCleanupRetryScheduling:
    AnyObject,
    Sendable
{
    func schedule(
        after delay: TimeInterval,
        work: @escaping @Sendable () -> Void
    )
}

final class SystemBlackHoleDeferredCleanupRetryScheduler:
    BlackHoleDeferredCleanupRetryScheduling,
    @unchecked Sendable
{
    static let shared =
        SystemBlackHoleDeferredCleanupRetryScheduler()

    private let queue = DispatchQueue(
        label: "opensteamer.BlackHoleDeferredCleanupRetry",
        qos: .utility
    )

    func schedule(
        after delay: TimeInterval,
        work: @escaping @Sendable () -> Void
    ) {
        let nanoseconds = Int(
            max(0.001, delay) * 1_000_000_000
        )
        queue.asyncAfter(
            deadline: .now()
                + .nanoseconds(nanoseconds),
            execute: work
        )
    }
}

private final class BlackHoleSerializedDeferredCleanupRetainer:
    @unchecked Sendable
{
    private struct Job {
        let id: UUID
        let attempt: @Sendable () -> Bool
        var isInFlight: Bool
        var failureCount: Int
    }

    private let lock = NSLock()
    private let retryScheduler:
        any BlackHoleDeferredCleanupRetryScheduling
    private var jobs: [UUID: Job] = [:]
    private var order: [UUID] = []
    private var autonomousRetryIsScheduled = false

    init(
        retryScheduler:
            any BlackHoleDeferredCleanupRetryScheduling
    ) {
        self.retryScheduler = retryScheduler
    }

    func retain(
        id: UUID,
        attempt: @escaping @Sendable () -> Bool
    ) {
        let inserted = withLock {
            guard jobs[id] == nil else {
                return false
            }
            jobs[id] = Job(
                id: id,
                attempt: attempt,
                isInFlight: false,
                failureCount: 0
            )
            order.append(id)
            return true
        }
        if inserted {
            scheduleAutonomousRetryIfNeeded()
        }
    }

    func redrive(id: UUID) {
        guard let job = claim(id: id) else {
            return
        }
        finish(
            job: job,
            completed: job.attempt()
        )
    }

    @discardableResult
    func redriveRetained(
        maximumAttemptCount: Int
    ) -> Int {
        for _ in 0..<max(0, maximumAttemptCount) {
            guard let job = claimNext() else {
                break
            }
            finish(
                job: job,
                completed: job.attempt()
            )
        }
        return retainedJobCount
    }

    var retainedJobCount: Int {
        withLock { jobs.count }
    }

    func contains(id: UUID) -> Bool {
        withLock {
            jobs[id] != nil
        }
    }

    var inFlightJobCount: Int {
        withLock {
            jobs.values.filter(\.isInFlight).count
        }
    }

    private func claim(id: UUID) -> Job? {
        withLock {
            guard var job = jobs[id],
                  !job.isInFlight else {
                return nil
            }
            job.isInFlight = true
            jobs[id] = job
            order.removeAll { $0 == id }
            return job
        }
    }

    private func claimNext() -> Job? {
        withLock {
            let candidateCount = order.count
            for _ in 0..<candidateCount {
                let id = order.removeFirst()
                guard var job = jobs[id] else {
                    continue
                }
                guard !job.isInFlight else {
                    order.append(id)
                    continue
                }
                job.isInFlight = true
                jobs[id] = job
                return job
            }
            return nil
        }
    }

    private func finish(
        job: Job,
        completed: Bool
    ) {
        let needsRetry = withLock {
            guard var current = jobs[job.id],
                  current.isInFlight else {
                return false
            }
            if completed {
                jobs.removeValue(forKey: job.id)
                order.removeAll { $0 == job.id }
                return false
            }

            current.isInFlight = false
            current.failureCount = min(
                current.failureCount + 1,
                16
            )
            jobs[job.id] = current
            if !order.contains(job.id) {
                order.append(job.id)
            }
            return true
        }
        if needsRetry {
            scheduleAutonomousRetryIfNeeded()
        }
    }

    private func scheduleAutonomousRetryIfNeeded() {
        let delay: TimeInterval? = withLock {
            guard !jobs.isEmpty,
                  !autonomousRetryIsScheduled else {
                return nil
            }
            autonomousRetryIsScheduled = true
            let minimumFailureCount =
                jobs.values.map(\.failureCount).min() ?? 0
            let exponent = min(
                max(0, minimumFailureCount),
                4
            )
            return min(
                1.6,
                0.1 * Double(1 << exponent)
            )
        }
        guard let delay else {
            return
        }
        retryScheduler.schedule(
            after: delay
        ) { [weak self] in
            self?.autonomousRetryFired()
        }
    }

    private func autonomousRetryFired() {
        withLock {
            autonomousRetryIsScheduled = false
        }
        _ = redriveRetained(
            maximumAttemptCount: 1
        )
        scheduleAutonomousRetryIfNeeded()
    }

    private func withLock<T>(
        _ body: () -> T
    ) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class BlackHoleDeviceAvailabilityListenerCleanupRetainer:
    BlackHoleDeviceAvailabilityListenerCleanupRetaining,
    @unchecked Sendable
{
    static let shared =
        BlackHoleDeviceAvailabilityListenerCleanupRetainer()

    private let core:
        BlackHoleSerializedDeferredCleanupRetainer

    init(
        retryScheduler:
            any BlackHoleDeferredCleanupRetryScheduling =
                SystemBlackHoleDeferredCleanupRetryScheduler
                    .shared
    ) {
        core =
            BlackHoleSerializedDeferredCleanupRetainer(
                retryScheduler: retryScheduler
            )
    }

    func retain(
        id: UUID,
        attempt: @escaping @Sendable () -> Bool
    ) {
        core.retain(
            id: id,
            attempt: attempt
        )
    }

    func redrive(id: UUID) {
        core.redrive(id: id)
    }

    func contains(id: UUID) -> Bool {
        core.contains(id: id)
    }

    @discardableResult
    func redriveRetained(
        maximumAttemptCount: Int
    ) -> Int {
        core.redriveRetained(
            maximumAttemptCount:
                maximumAttemptCount
        )
    }

    var retainedJobCount: Int {
        core.retainedJobCount
    }

    #if DEBUG
    var debugInFlightJobCountForTesting: Int {
        core.inFlightJobCount
    }
    #endif
}

final class CoreAudioPropertyListenerRegistration:
    @unchecked Sendable
{
    let block: AudioObjectPropertyListenerBlock

    init(
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) {
        self.block = block
    }
}

protocol BlackHoleDefaultInputLeaseDeferredCleanupRetaining:
    AnyObject,
    Sendable
{
    func retain(
        id: UUID,
        attempt: @escaping @Sendable () -> Bool
    )
    func redrive(id: UUID)

    @discardableResult
    func redriveRetained(
        maximumAttemptCount: Int
    ) -> Int

    var retainedJobCount: Int { get }
}

final class BlackHoleDefaultInputLeaseDeferredCleanupRetainer:
    BlackHoleDefaultInputLeaseDeferredCleanupRetaining,
    @unchecked Sendable
{
    static let shared =
        BlackHoleDefaultInputLeaseDeferredCleanupRetainer()

    private let core:
        BlackHoleSerializedDeferredCleanupRetainer

    init(
        retryScheduler:
            any BlackHoleDeferredCleanupRetryScheduling =
                SystemBlackHoleDeferredCleanupRetryScheduler
                    .shared
    ) {
        core =
            BlackHoleSerializedDeferredCleanupRetainer(
                retryScheduler: retryScheduler
            )
    }

    func retain(
        id: UUID,
        attempt: @escaping @Sendable () -> Bool
    ) {
        core.retain(
            id: id,
            attempt: attempt
        )
    }

    func redrive(id: UUID) {
        core.redrive(id: id)
    }

    @discardableResult
    func redriveRetained(
        maximumAttemptCount: Int
    ) -> Int {
        core.redriveRetained(
            maximumAttemptCount:
                maximumAttemptCount
        )
    }

    var retainedJobCount: Int {
        core.retainedJobCount
    }
}
