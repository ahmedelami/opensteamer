import Foundation
import Testing
@testable import WebRTCTransport

struct ICERecoveryCoordinatorTests {
    private let policy = ICERecoveryCoordinator.Policy(
        disconnectedGrace: .seconds(10),
        restartTimeout: .seconds(20),
        retryDelay: .seconds(30),
        maximumAttempts: 2
    )

    @Test func connectedDuringGraceCancelsRecovery() async {
        let sleeper = ControlledSleeper()
        let restartCalls = AsyncCounter()
        let exhaustedCalls = AsyncCounter()
        let coordinator = ICERecoveryCoordinator(
            policy: policy,
            restart: { await restartCalls.increment() },
            exhausted: { await exhaustedCalls.increment() },
            sleeper: { try await sleeper.sleep(for: $0) }
        )

        await coordinator.iceStateChanged(.disconnected)
        await coordinator.iceStateChanged(.disconnected)
        #expect(await eventually { sleeper.pendingDurations() == [.seconds(10)] })

        await coordinator.iceStateChanged(.connected)
        #expect(await eventually { sleeper.pendingDurations().isEmpty })
        #expect(await restartCalls.value == 0)
        #expect(await exhaustedCalls.value == 0)
    }

    @Test func immediateRequestAcceleratesGraceAndCoalescesDuplicates() async {
        let sleeper = ControlledSleeper()
        let restartCalls = AsyncCounter()
        let coordinator = ICERecoveryCoordinator(
            policy: policy,
            restart: { await restartCalls.increment() },
            exhausted: {},
            sleeper: { try await sleeper.sleep(for: $0) }
        )

        await coordinator.iceStateChanged(.disconnected)
        #expect(await eventually { sleeper.pendingDurations() == [.seconds(10)] })

        await coordinator.restartRequested()
        #expect(await eventually {
            await restartCalls.value == 1
                && sleeper.pendingDurations() == [.seconds(20)]
        })

        await coordinator.restartRequested()
        await coordinator.iceStateChanged(.failed)
        #expect(await restartCalls.value == 1)
        #expect(sleeper.pendingDurations() == [.seconds(20)])
        await coordinator.iceStateChanged(.completed)
    }

    @Test func timeoutsRetryThenExhaustExactlyOnce() async {
        let sleeper = ControlledSleeper()
        let restartCalls = AsyncCounter()
        let exhaustedCalls = AsyncCounter()
        let coordinator = ICERecoveryCoordinator(
            policy: policy,
            restart: { await restartCalls.increment() },
            exhausted: { await exhaustedCalls.increment() },
            sleeper: { try await sleeper.sleep(for: $0) }
        )

        await coordinator.restartRequested()
        #expect(await eventually {
            await restartCalls.value == 1
                && sleeper.pendingDurations() == [.seconds(20)]
        })
        #expect(sleeper.resumeNext(matching: .seconds(20)))
        #expect(await eventually { sleeper.pendingDurations() == [.seconds(30)] })
        #expect(sleeper.resumeNext(matching: .seconds(30)))
        #expect(await eventually {
            await restartCalls.value == 2
                && sleeper.pendingDurations() == [.seconds(20)]
        })
        #expect(sleeper.resumeNext(matching: .seconds(20)))
        #expect(await eventually { await exhaustedCalls.value == 1 })

        await coordinator.restartRequested()
        await coordinator.iceStateChanged(.failed)
        #expect(await restartCalls.value == 2)
        #expect(await exhaustedCalls.value == 1)
    }

    @Test func connectedDuringSuspendedRestartInvalidatesItsCompletion() async {
        let sleeper = ControlledSleeper()
        let suspendedRestart = SuspendedAction()
        let exhaustedCalls = AsyncCounter()
        let coordinator = ICERecoveryCoordinator(
            policy: policy,
            restart: { try await suspendedRestart.run() },
            exhausted: { await exhaustedCalls.increment() },
            sleeper: { try await sleeper.sleep(for: $0) }
        )

        await coordinator.restartRequested()
        #expect(await eventually { await suspendedRestart.callCount == 1 })
        await coordinator.iceStateChanged(.connected)
        await suspendedRestart.release()
        #expect(await eventually { sleeper.pendingDurations().isEmpty })
        #expect(await exhaustedCalls.value == 0)
    }

    @Test func thrownRestartConsumesAttemptAndUsesRetryDelay() async {
        let sleeper = ControlledSleeper()
        let scriptedRestart = ScriptedAction(failures: 1)
        let exhaustedCalls = AsyncCounter()
        let coordinator = ICERecoveryCoordinator(
            policy: policy,
            restart: { try await scriptedRestart.run() },
            exhausted: { await exhaustedCalls.increment() },
            sleeper: { try await sleeper.sleep(for: $0) }
        )

        await coordinator.restartRequested()
        #expect(await eventually {
            await scriptedRestart.callCount == 1
                && sleeper.pendingDurations() == [.seconds(30)]
        })
        #expect(sleeper.resumeNext(matching: .seconds(30)))
        #expect(await eventually {
            await scriptedRestart.callCount == 2
                && sleeper.pendingDurations() == [.seconds(20)]
        })
        await coordinator.iceStateChanged(.connected)
        #expect(await exhaustedCalls.value == 0)
        #expect(await eventually { sleeper.pendingDurations().isEmpty })
    }

    @Test func cancelIsTerminalAndSuppressesLaterSignals() async {
        let sleeper = ControlledSleeper()
        let restartCalls = AsyncCounter()
        let exhaustedCalls = AsyncCounter()
        let coordinator = ICERecoveryCoordinator(
            policy: policy,
            restart: { await restartCalls.increment() },
            exhausted: { await exhaustedCalls.increment() },
            sleeper: { try await sleeper.sleep(for: $0) }
        )

        await coordinator.restartRequested()
        #expect(await eventually {
            await restartCalls.value == 1
                && sleeper.pendingDurations() == [.seconds(20)]
        })
        await coordinator.cancel()
        await coordinator.iceStateChanged(.failed)
        await coordinator.iceStateChanged(.disconnected)
        await coordinator.restartRequested()
        #expect(await restartCalls.value == 1)
        #expect(await exhaustedCalls.value == 0)
        #expect(await eventually { sleeper.pendingDurations().isEmpty })
    }
}

private enum TestRecoveryError: Error, Sendable {
    case failed
}

private actor AsyncCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor ScriptedAction {
    private var failuresRemaining: Int
    private(set) var callCount = 0

    init(failures: Int) {
        failuresRemaining = failures
    }

    func run() throws {
        callCount += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw TestRecoveryError.failed
        }
    }
}

private actor SuspendedAction {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func run() async throws {
        callCount += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class ControlledSleeper: @unchecked Sendable {
    private struct Waiter {
        let id: UInt64
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var nextID: UInt64 = 1
    private var registering: Set<UInt64> = []
    private var cancelledBeforeRegistration: Set<UInt64> = []
    private var waiters: [Waiter] = []

    func sleep(for duration: Duration) async throws {
        let id = withLock {
            let id = nextID
            nextID &+= 1
            registering.insert(id)
            return id
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let shouldCancel = withLock {
                    registering.remove(id)
                    if cancelledBeforeRegistration.remove(id) != nil || Task.isCancelled {
                        return true
                    }
                    waiters.append(.init(id: id, duration: duration, continuation: continuation))
                    return false
                }
                if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancel(id: id)
        }
    }

    func pendingDurations() -> [Duration] {
        withLock { waiters.map(\.duration) }
    }

    @discardableResult
    func resumeNext(matching duration: Duration) -> Bool {
        let continuation: CheckedContinuation<Void, any Error>? = withLock {
            guard let index = waiters.firstIndex(where: { $0.duration == duration }) else {
                return nil
            }
            return waiters.remove(at: index).continuation
        }
        continuation?.resume()
        return continuation != nil
    }

    private func cancel(id: UInt64) {
        let continuation: CheckedContinuation<Void, any Error>? = withLock {
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                return waiters.remove(at: index).continuation
            }
            if registering.contains(id) {
                cancelledBeforeRegistration.insert(id)
            }
            return nil
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private func eventually(
    iterations: Int = 10_000,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<iterations {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
