@preconcurrency import CallKit
import Foundation

/// Privacy-minimal CallKit evidence for the worldwide audio policy. Only aggregate lifecycle
/// counts cross this boundary; identifiers, handles, contacts, and transaction metadata are never
/// retained or published.
struct WorldwideCallActivitySnapshot: Equatable, Sendable {
    let nonEndedCallCount: Int
    let connectedNonEndedCallCount: Int

    init(
        nonEndedCallCount: Int,
        connectedNonEndedCallCount: Int
    ) {
        let normalizedNonEndedCount = max(0, nonEndedCallCount)
        self.nonEndedCallCount = normalizedNonEndedCount
        self.connectedNonEndedCallCount = min(
            normalizedNonEndedCount,
            max(0, connectedNonEndedCallCount)
        )
    }

    static let inactive = WorldwideCallActivitySnapshot(
        nonEndedCallCount: 0,
        connectedNonEndedCallCount: 0
    )

    var hasNonEndedCall: Bool {
        nonEndedCallCount > 0
    }

    var hasConnectedNonEndedCall: Bool {
        connectedNonEndedCallCount > 0
    }
}

@MainActor
protocol WorldwideCallActivityObserving: AnyObject {
    var snapshot: WorldwideCallActivitySnapshot { get }
    /// A synchronous, uncached aggregate used immediately before either audio gate can open.
    var liveSnapshot: WorldwideCallActivitySnapshot { get }
    var onSnapshotChanged: ((WorldwideCallActivitySnapshot) -> Void)? { get set }

    func startObserving()
    func stopObserving()
}

/// Main-actor adapter around `CXCallObserver` that exposes only aggregate call lifecycle state.
/// Delegate callbacks are treated as invalidation signals; each one rereads the observer so queued
/// CallKit delivery cannot publish stale call details or reopen audio from an obsolete snapshot.
@MainActor
final class WorldwideCallActivityObserver: NSObject,
    WorldwideCallActivityObserving,
    CXCallObserverDelegate,
    @unchecked Sendable
{
    private let observer: CXCallObserver
    private(set) var snapshot = WorldwideCallActivitySnapshot.inactive
    var liveSnapshot: WorldwideCallActivitySnapshot {
        #if DEBUG
        if let debugLiveSnapshot {
            return debugLiveSnapshot
        }
        #endif

        var nonEndedCallCount = 0
        var connectedNonEndedCallCount = 0
        for call in observer.calls where !call.hasEnded {
            nonEndedCallCount += 1
            if call.hasConnected {
                connectedNonEndedCallCount += 1
            }
        }
        return WorldwideCallActivitySnapshot(
            nonEndedCallCount: nonEndedCallCount,
            connectedNonEndedCallCount: connectedNonEndedCallCount
        )
    }
    var onSnapshotChanged: ((WorldwideCallActivitySnapshot) -> Void)?
    private var isObserving = false
    #if DEBUG
    private var debugLiveSnapshot: WorldwideCallActivitySnapshot?
    #endif

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
        snapshot = .inactive
    }

    nonisolated func callObserver(
        _ callObserver: CXCallObserver,
        callChanged call: CXCall
    ) {
        // The delegate is registered on the main queue. Enter the MainActor
        // synchronously so microphone revocation completes before this callback
        // returns, while still discarding all call-specific data.
        _ = callObserver
        _ = call
        refreshSynchronouslyOnRegisteredMainQueue()
    }

    nonisolated private func refreshSynchronouslyOnRegisteredMainQueue() {
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            refreshCurrentAggregate()
        }
    }

    #if DEBUG
    func debugSetLiveSnapshotForTests(
        _ snapshot: WorldwideCallActivitySnapshot?
    ) {
        debugLiveSnapshot = snapshot
    }

    nonisolated func debugDeliverDelegateInvalidationSynchronouslyForTests() {
        refreshSynchronouslyOnRegisteredMainQueue()
    }
    #endif

    private func refreshCurrentAggregate(notify: Bool = true) {
        guard isObserving else { return }
        publish(
            liveSnapshot,
            notify: notify
        )
    }

    private func publish(
        _ snapshot: WorldwideCallActivitySnapshot,
        notify: Bool
    ) {
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        if notify {
            onSnapshotChanged?(snapshot)
        }
    }
}
