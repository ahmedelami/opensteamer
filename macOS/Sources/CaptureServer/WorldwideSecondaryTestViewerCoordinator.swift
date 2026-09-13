import Foundation

/// Injectable boundary around the legacy consume-once worldwide screen service.
protocol WorldwideSecondaryTestViewerServing: AnyObject, Sendable {
    var completion: AsyncStream<Void> { get }

    func startSecondaryTestViewer() async throws -> String
    func stopSecondaryTestViewer() async
    func secondaryTestViewerHasUnconfirmedNativeCaptureStop() async -> Bool
}

extension WorldwideScreenService: WorldwideSecondaryTestViewerServing {
    func startSecondaryTestViewer() async throws -> String {
        try await start()
    }

    func stopSecondaryTestViewer() async {
        await stop()
    }

    func secondaryTestViewerHasUnconfirmedNativeCaptureStop() async -> Bool {
        hasUnconfirmedNativeCaptureStop()
    }
}

/// Pure ownership state for one optional secondary consume-once service.
struct WorldwideSecondaryTestViewerLifecycle: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case idle
        case starting
        case running
        case stopping
        case stopped
    }

    private(set) var state: State = .idle

    mutating func beginStart() throws {
        guard state == .idle else {
            throw WorldwideSecondaryTestViewerLifecycleError.invalidTransition
        }
        state = .starting
    }

    mutating func didStart() throws {
        guard state == .starting else {
            throw WorldwideSecondaryTestViewerLifecycleError.invalidTransition
        }
        state = .running
    }

    @discardableResult
    mutating func beginStop() -> Bool {
        switch state {
        case .idle, .starting, .running:
            state = .stopping
            return true
        case .stopping, .stopped:
            return false
        }
    }

    mutating func didStop() throws {
        guard state == .stopping else {
            throw WorldwideSecondaryTestViewerLifecycleError.invalidTransition
        }
        state = .stopped
    }
}

enum WorldwideSecondaryTestViewerLifecycleError: LocalizedError, Equatable {
    case invalidTransition

    var errorDescription: String? {
        "The secondary test viewer lifecycle transition is invalid."
    }
}

/// Owns a single legacy invitation service independently of paired-host availability.
///
/// The primary coordinator can therefore remain available when the secondary viewer consumes its
/// invitation or disconnects. Native stop uncertainty remains retained and retryable until the
/// enclosing process-level lifetime confirms all captures have stopped.
actor WorldwideSecondaryTestViewerCoordinator {
    nonisolated let completion: AsyncStream<Void>

    private let service: any WorldwideSecondaryTestViewerServing
    private let completionContinuation: AsyncStream<Void>.Continuation
    private var lifecycle = WorldwideSecondaryTestViewerLifecycle()
    private var serviceCompletionTask: Task<Void, Never>?
    private var stopCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopIsInProgress = false
    private var lastStopWasConfirmed = false
    private var completionWasFinished = false

    init(service: any WorldwideSecondaryTestViewerServing) {
        let pair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        completion = pair.stream
        completionContinuation = pair.continuation
        self.service = service
    }

    /// Starts the one-time rendezvous and returns its secret exactly once to the process presenter.
    func start() async throws -> String {
        try lifecycle.beginStart()
        do {
            let invitationCode = try await service.startSecondaryTestViewer()
            guard lifecycle.state == .starting else {
                await service.stopSecondaryTestViewer()
                throw CancellationError()
            }
            try lifecycle.didStart()
            observeServiceCompletion()
            return invitationCode
        } catch {
            if lifecycle.state == .starting {
                _ = lifecycle.beginStop()
                stopIsInProgress = true
                await service.stopSecondaryTestViewer()
                lastStopWasConfirmed = !(await service
                    .secondaryTestViewerHasUnconfirmedNativeCaptureStop())
                try? lifecycle.didStop()
                finishCompletion()
                finishStopping()
            }
            throw error
        }
    }

    /// Idempotently stops the secondary service and preserves it when native teardown is uncertain.
    @discardableResult
    func stop() async -> Bool {
        if lifecycle.state == .stopped {
            guard !lastStopWasConfirmed else { return true }
            await service.stopSecondaryTestViewer()
            lastStopWasConfirmed = !(await service
                .secondaryTestViewerHasUnconfirmedNativeCaptureStop())
            return lastStopWasConfirmed
        }
        if stopIsInProgress || lifecycle.state == .stopping {
            await waitForStopToFinish()
            return lastStopWasConfirmed
        }

        _ = lifecycle.beginStop()
        stopIsInProgress = true
        serviceCompletionTask?.cancel()
        serviceCompletionTask = nil
        await service.stopSecondaryTestViewer()
        lastStopWasConfirmed = !(await service
            .secondaryTestViewerHasUnconfirmedNativeCaptureStop())
        try? lifecycle.didStop()
        finishCompletion()
        finishStopping()
        return lastStopWasConfirmed
    }

    func currentState() -> WorldwideSecondaryTestViewerLifecycle.State {
        lifecycle.state
    }

    private func observeServiceCompletion() {
        let serviceCompletion = service.completion
        serviceCompletionTask = Task { [weak self] in
            for await _ in serviceCompletion { break }
            guard !Task.isCancelled else { return }
            await self?.serviceDidComplete()
        }
    }

    private func serviceDidComplete() async {
        guard lifecycle.state == .running else { return }
        _ = lifecycle.beginStop()
        stopIsInProgress = true
        serviceCompletionTask = nil
        await service.stopSecondaryTestViewer()
        lastStopWasConfirmed = !(await service
            .secondaryTestViewerHasUnconfirmedNativeCaptureStop())
        try? lifecycle.didStop()
        finishCompletion()
        finishStopping()
    }

    private func waitForStopToFinish() async {
        guard stopIsInProgress else { return }
        await withCheckedContinuation { continuation in
            stopCompletionWaiters.append(continuation)
        }
    }

    private func finishStopping() {
        stopIsInProgress = false
        let waiters = stopCompletionWaiters
        stopCompletionWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    private func finishCompletion() {
        guard !completionWasFinished else { return }
        completionWasFinished = true
        completionContinuation.yield(())
        completionContinuation.finish()
    }
}
