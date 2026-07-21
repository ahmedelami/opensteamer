@preconcurrency import CallKit
import Foundation

/// Privacy-minimal CallKit evidence for the worldwide audio policy. Only the aggregate number of
/// calls whose `hasEnded` flag is false crosses this boundary; identifiers, handles, contacts, and
/// transaction metadata are never retained or published.
@MainActor
protocol WorldwideCallActivityObserving: AnyObject {
    var nonEndedCallCount: Int { get }
    /// A synchronous, uncached aggregate used immediately before either audio gate can open.
    var liveNonEndedCallCount: Int { get }
    var onNonEndedCallCountChanged: ((Int) -> Void)? { get set }

    func startObserving()
    func stopObserving()
}

/// Main-actor adapter around `CXCallObserver` that exposes only an aggregate active-call count.
/// Delegate callbacks are treated as invalidation signals; each one rereads the observer so queued
/// CallKit delivery cannot publish stale call details or reopen audio from an obsolete snapshot.
@MainActor
final class WorldwideCallActivityObserver: NSObject,
    WorldwideCallActivityObserving,
    CXCallObserverDelegate,
    @unchecked Sendable
{
    private let observer: CXCallObserver
    private(set) var nonEndedCallCount = 0
    var liveNonEndedCallCount: Int {
        observer.calls.lazy.filter { !$0.hasEnded }.count
    }
    var onNonEndedCallCountChanged: ((Int) -> Void)?
    private var isObserving = false

    override init() {
        observer = CXCallObserver()
        super.init()
    }

    func startObserving() {
        guard !isObserving else {
            refreshCurrentAggregate()
            return
        }
        isObserving = true
        // Register first, then sample. A call transition between these operations is harmless:
        // both the synchronous sample and any queued delegate callback reread the current
        // aggregate instead of publishing a captured, potentially stale count.
        observer.setDelegate(self, queue: .main)
        refreshCurrentAggregate(notify: false)
    }

    func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        observer.setDelegate(nil, queue: nil)
        nonEndedCallCount = 0
    }

    nonisolated func callObserver(
        _ callObserver: CXCallObserver,
        callChanged call: CXCall
    ) {
        // Do not capture either CallKit object across the concurrency boundary. Late callbacks
        // after stop/restart are safe because the MainActor rereads the retained observer's
        // current aggregate and verifies that observation is still active.
        _ = callObserver
        _ = call
        Task { @MainActor [weak self] in
            self?.refreshCurrentAggregate()
        }
    }

    private func refreshCurrentAggregate(notify: Bool = true) {
        guard isObserving else { return }
        publish(
            liveNonEndedCallCount,
            notify: notify
        )
    }

    private func publish(_ count: Int, notify: Bool) {
        let normalized = max(0, count)
        guard normalized != nonEndedCallCount else { return }
        nonEndedCallCount = normalized
        if notify {
            onNonEndedCallCountChanged?(normalized)
        }
    }
}
