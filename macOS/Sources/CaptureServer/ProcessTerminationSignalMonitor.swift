import Darwin
import Dispatch
import Foundation

/// Converts process termination signals into an async event while the worldwide host is active.
/// The signal disposition is restored only after the coordinator has shut down its WebSockets.
final class ProcessTerminationSignalMonitor: @unchecked Sendable {
    /// Buffered stream of the most recent monitored Unix signal.
    let events: AsyncStream<Int32>

    private let lock = NSLock()
    private let signalNumbers: [Int32]
    private var sources: [DispatchSourceSignal]
    private var continuation: AsyncStream<Int32>.Continuation?
    private var isCancelled = false

    /// Installs Dispatch signal sources after temporarily ignoring default dispositions.
    init(signalNumbers: [Int32] = [SIGINT, SIGTERM]) {
        let pair = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream
        continuation = pair.continuation
        self.signalNumbers = signalNumbers

        let queue = DispatchQueue(label: "org.example.audiostreamer.termination-signals")
        var configuredSources: [DispatchSourceSignal] = []
        configuredSources.reserveCapacity(signalNumbers.count)
        for signalNumber in signalNumbers {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [continuation = pair.continuation] in
                continuation.yield(signalNumber)
            }
            configuredSources.append(source)
            source.resume()
        }
        sources = configuredSources
    }

    /// Idempotently tears down sources, finishes events, and restores default dispositions.
    func cancel() {
        let resources = lock.withLock { () -> (
            [DispatchSourceSignal],
            AsyncStream<Int32>.Continuation?
        )? in
            guard !isCancelled else { return nil }
            isCancelled = true
            let resources = (sources, continuation)
            sources = []
            continuation = nil
            return resources
        }
        guard let resources else { return }
        resources.0.forEach { $0.cancel() }
        resources.1?.finish()
        signalNumbers.forEach { Darwin.signal($0, SIG_DFL) }
    }

    /// Restore normal Unix termination semantics only after async worldwide cleanup completes.
    /// This is used by the explicit worldwide + trusted-LAN coexistence mode, whose LAN capture
    /// loop is otherwise intentionally left unchanged.
    func resumeDefaultHandlingAndReraise(_ signalNumber: Int32) -> Never {
        cancel()
        Darwin.raise(signalNumber)
        // `raise` terminates under the restored default disposition. Keep a deterministic fallback
        // for an unusual environment that has the signal blocked at the process level.
        Darwin._exit(128 + signalNumber)
    }

    deinit {
        cancel()
    }
}
