import Darwin
import Dispatch
import Foundation

/// Converts process termination signals into a buffered event before mutable host state exists.
/// Main restores the default disposition only after every native/display dependency is down.
final class ProcessTerminationSignalMonitor: @unchecked Sendable {
    /// Each read creates an independently cancellable subscription to the buffered signal.
    var events: AsyncStream<Int32> {
        makeEvents()
    }

    private let lock = NSLock()
    private let signalNumbers: [Int32]
    private let onSignal: @Sendable (Int32) -> Void
    private var sources: [DispatchSourceSignal]
    private var continuations: [UUID: AsyncStream<Int32>.Continuation] = [:]
    private var pendingSignalNumber: Int32?
    private var isCancelled = false

    /// Installs Dispatch signal sources after temporarily ignoring default dispositions.
    init(
        signalNumbers: [Int32] = [SIGINT, SIGTERM],
        onSignal: @escaping @Sendable (Int32) -> Void = { _ in }
    ) {
        self.signalNumbers = signalNumbers
        self.onSignal = onSignal
        sources = []

        let queue = DispatchQueue(label: "org.example.opensteamer.termination-signals")
        sources.reserveCapacity(signalNumbers.count)
        for signalNumber in signalNumbers {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [weak self] in
                self?.receive(signalNumber)
            }
            sources.append(source)
            source.resume()
        }
    }

    /// Returns a buffered request without consuming it, including during synchronous startup.
    func pendingSignal() -> Int32? {
        lock.withLock { pendingSignalNumber }
    }

    /// Converts a buffered request into the same error used by the async service supervisors.
    func throwIfSignaled() throws {
        if let signalNumber = pendingSignal() {
            throw ProcessTerminationRequest(signalNumber: signalNumber)
        }
    }

    /// Idempotently tears down sources, restores defaults, and returns any buffered request.
    /// This may be called only after full cleanup has been confirmed.
    @discardableResult
    func cancelAndReturnPendingSignal() -> Int32? {
        let state = lock.withLock { () -> (
            Int32?,
            [DispatchSourceSignal],
            [AsyncStream<Int32>.Continuation]
        ) in
            guard !isCancelled else {
                return (pendingSignalNumber, [], [])
            }
            isCancelled = true
            let state = (pendingSignalNumber, sources, Array(continuations.values))
            sources = []
            continuations.removeAll(keepingCapacity: false)
            return state
        }
        state.1.forEach { $0.cancel() }
        state.2.forEach { $0.finish() }
        if !state.1.isEmpty {
            signalNumbers.forEach { Darwin.signal($0, SIG_DFL) }
        }
        return state.0
    }

    func cancel() {
        cancelAndReturnPendingSignal()
    }

    deinit {
        cancel()
    }

    private func makeEvents() -> AsyncStream<Int32> {
        let identifier = UUID()
        return AsyncStream<Int32>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(identifier: identifier)
            }
            let state = lock.withLock { () -> (Int32?, Bool) in
                guard !isCancelled else { return (pendingSignalNumber, true) }
                continuations[identifier] = continuation
                return (pendingSignalNumber, false)
            }
            if let pendingSignalNumber = state.0 {
                continuation.yield(pendingSignalNumber)
            }
            if state.1 {
                continuation.finish()
            }
        }
    }

    private func removeContinuation(identifier: UUID) {
        _ = lock.withLock {
            continuations.removeValue(forKey: identifier)
        }
    }

    /// Records before publishing so cancellation of one stream consumer cannot lose the signal.
    func receive(_ signalNumber: Int32) {
        let state = lock.withLock { () -> (
            Bool,
            [AsyncStream<Int32>.Continuation]
        ) in
            guard !isCancelled else { return (false, []) }
            pendingSignalNumber = signalNumber
            return (true, Array(continuations.values))
        }
        guard state.0 else { return }
        onSignal(signalNumber)
        state.1.forEach { $0.yield(signalNumber) }
    }
}

/// Pure ownership policy used by Main and covered without mutating process-global dispositions.
enum ProcessTerminationSignalPolicy {
    static func requiresMonitor(
        virtualDisplayEnabled: Bool,
        worldwideEnabled: Bool
    ) -> Bool {
        virtualDisplayEnabled || worldwideEnabled
    }

    static func mayRestoreDefaultHandling(fullCleanupIsConfirmed: Bool) -> Bool {
        fullCleanupIsConfirmed
    }

    static func requiresIndependentFallback(
        virtualDisplayEnabled: Bool,
        worldwideEnabled: Bool
    ) -> Bool {
        !virtualDisplayEnabled
            && requiresMonitor(
                virtualDisplayEnabled: virtualDisplayEnabled,
                worldwideEnabled: worldwideEnabled
            )
    }
}
