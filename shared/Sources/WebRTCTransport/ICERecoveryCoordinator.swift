import Foundation

/// Runs one bounded ICE-recovery workflow for one peer-connection generation.
///
/// This coordinator deliberately does not reconnect signaling. A restart can succeed only while
/// the authenticated rendezvous socket that carries its offer, answer, and candidates is alive.
public actor ICERecoveryCoordinator {
    public struct Policy: Equatable, Sendable {
        public let disconnectedGrace: Duration
        public let restartTimeout: Duration
        public let retryDelay: Duration
        public let maximumAttempts: Int

        public init(
            disconnectedGrace: Duration = .seconds(2),
            restartTimeout: Duration = .seconds(8),
            retryDelay: Duration = .seconds(2),
            maximumAttempts: Int = 2
        ) {
            precondition(disconnectedGrace >= .zero)
            precondition(restartTimeout >= .zero)
            precondition(retryDelay >= .zero)
            precondition(maximumAttempts > 0)

            self.disconnectedGrace = disconnectedGrace
            self.restartTimeout = restartTimeout
            self.retryDelay = retryDelay
            self.maximumAttempts = maximumAttempts
        }
    }

    public typealias RestartAction = @Sendable () async throws -> Void
    public typealias ExhaustedAction = @Sendable () async -> Void
    internal typealias Sleeper = @Sendable (Duration) async throws -> Void

    private enum Phase: Sendable {
        case idle
        case grace
        case attempting
        case awaitingConnection
        case retryDelay
        case exhausted
        case cancelled
    }

    private let policy: Policy
    private let restart: RestartAction
    private let exhausted: ExhaustedAction
    private let sleeper: Sleeper

    private var recoveryTask: Task<Void, Never>?
    private var epoch: UInt64 = 0
    private var attempts = 0
    private var phase: Phase = .idle
    private var exhaustionWasDelivered = false

    public init(
        policy: Policy = .init(),
        restart: @escaping RestartAction,
        exhausted: @escaping ExhaustedAction
    ) {
        self.policy = policy
        self.restart = restart
        self.exhausted = exhausted
        sleeper = { duration in
            try await Task.sleep(for: duration)
        }
    }

    internal init(
        policy: Policy,
        restart: @escaping RestartAction,
        exhausted: @escaping ExhaustedAction,
        sleeper: @escaping Sleeper
    ) {
        self.policy = policy
        self.restart = restart
        self.exhausted = exhausted
        self.sleeper = sleeper
    }

    public func iceStateChanged(_ state: WebRTCICEState) {
        guard phase != .cancelled else { return }

        switch state {
        case .connected, .completed:
            resetAfterConnection()

        case .disconnected:
            guard phase == .idle else { return }
            startWorkflow(after: policy.disconnectedGrace)

        case .failed:
            startImmediatelyIfPossible()

        case .closed:
            cancel()

        case .new, .checking, .unknown:
            break
        }
    }

    /// Starts recovery immediately, or accelerates a pending disconnected grace period.
    /// Duplicate requests during an attempt, timeout, or retry delay are coalesced.
    public func restartRequested() {
        guard phase != .cancelled else { return }
        startImmediatelyIfPossible()
    }

    /// Permanently cancels this coordinator. A replacement peer must receive a new instance.
    public func cancel() {
        invalidateWorkflow()
        attempts = 0
        phase = .cancelled
    }

    private func startImmediatelyIfPossible() {
        switch phase {
        case .idle, .grace:
            startWorkflow(after: .zero)
        case .attempting, .awaitingConnection, .retryDelay, .exhausted, .cancelled:
            break
        }
    }

    private func startWorkflow(after initialDelay: Duration) {
        invalidateWorkflow()
        attempts = 0
        exhaustionWasDelivered = false
        phase = initialDelay > .zero ? .grace : .attempting

        let workflowEpoch = epoch
        recoveryTask = Task { [weak self] in
            await self?.runWorkflow(epoch: workflowEpoch, initialDelay: initialDelay)
        }
    }

    private func runWorkflow(epoch workflowEpoch: UInt64, initialDelay: Duration) async {
        defer {
            finishWorkflow(epoch: workflowEpoch)
        }

        if initialDelay > .zero {
            guard await wait(for: initialDelay, epoch: workflowEpoch) else { return }
        }

        for attempt in 1...policy.maximumAttempts {
            guard isCurrent(workflowEpoch) else { return }
            attempts = attempt
            phase = .attempting

            let restartWasSent: Bool
            do {
                try await restart()
                restartWasSent = true
            } catch {
                // A failed action still consumes an attempt, but there is no offer/request whose
                // answer should receive the normal connection timeout.
                restartWasSent = false
            }

            guard isCurrent(workflowEpoch) else { return }

            if restartWasSent {
                phase = .awaitingConnection
                guard await wait(for: policy.restartTimeout, epoch: workflowEpoch) else { return }
            }

            guard isCurrent(workflowEpoch) else { return }
            if attempt == policy.maximumAttempts {
                await exhaust(epoch: workflowEpoch)
                return
            }

            phase = .retryDelay
            guard await wait(for: policy.retryDelay, epoch: workflowEpoch) else { return }
        }
    }

    private func wait(for duration: Duration, epoch workflowEpoch: UInt64) async -> Bool {
        guard isCurrent(workflowEpoch) else { return false }
        if duration > .zero {
            do {
                try await sleeper(duration)
            } catch {
                return false
            }
        }
        return isCurrent(workflowEpoch)
    }

    private func exhaust(epoch workflowEpoch: UInt64) async {
        guard isCurrent(workflowEpoch), !exhaustionWasDelivered else { return }
        exhaustionWasDelivered = true
        phase = .exhausted
        await exhausted()
    }

    private func resetAfterConnection() {
        invalidateWorkflow()
        attempts = 0
        exhaustionWasDelivered = false
        phase = .idle
    }

    private func invalidateWorkflow() {
        epoch &+= 1
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private func finishWorkflow(epoch workflowEpoch: UInt64) {
        guard workflowEpoch == epoch else { return }
        recoveryTask = nil
        if phase != .exhausted, phase != .cancelled {
            attempts = 0
            phase = .idle
        }
    }

    private func isCurrent(_ workflowEpoch: UInt64) -> Bool {
        workflowEpoch == epoch && !Task.isCancelled && phase != .cancelled
    }
}
