@preconcurrency import CallKit
import Foundation

/// Privacy-minimal CallKit evidence for the worldwide audio policy. Only aggregate lifecycle
/// counts and opaque monotonic revisions cross this boundary; identifiers, handles, contacts, and
/// transaction metadata are never published.
struct WorldwideCallActivitySnapshot: Equatable, Sendable {
    let nonEndedCallCount: Int
    let connectedNonEndedCallCount: Int
    /// Monotonic privacy-safe invalidation sequence. It changes even when one call replaces
    /// another without changing aggregate counts, forcing a fresh Mac-hosted evidence heartbeat.
    let revision: UInt64
    /// Advances only when the exact non-ended CXCall UUID set changes. The UUIDs never leave the
    /// private observer; this opaque revision lets the lifecycle keep one random epoch stable while
    /// the same call progresses from ringing to connected.
    let membershipRevision: UInt64

    init(
        nonEndedCallCount: Int,
        connectedNonEndedCallCount: Int,
        revision: UInt64 = 0,
        membershipRevision: UInt64 = 0
    ) {
        let normalizedNonEndedCount = max(0, nonEndedCallCount)
        self.nonEndedCallCount = normalizedNonEndedCount
        self.connectedNonEndedCallCount = min(
            normalizedNonEndedCount,
            max(0, connectedNonEndedCallCount)
        )
        self.revision = revision
        self.membershipRevision = membershipRevision
    }

    static let inactive = WorldwideCallActivitySnapshot(
        nonEndedCallCount: 0,
        connectedNonEndedCallCount: 0,
        revision: 0,
        membershipRevision: 0
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

        var nonEndedCallIDs: Set<UUID> = []
        var connectedNonEndedCallCount = 0
        for call in observer.calls where !call.hasEnded {
            nonEndedCallIDs.insert(call.uuid)
            if call.hasConnected {
                connectedNonEndedCallCount += 1
            }
        }
        if nonEndedCallIDs != observedNonEndedCallIDs {
            observedNonEndedCallIDs = nonEndedCallIDs
            nextMembershipRevision &+= 1
            if nextMembershipRevision == 0 {
                nextMembershipRevision = 1
            }
        }
        return WorldwideCallActivitySnapshot(
            nonEndedCallCount: nonEndedCallIDs.count,
            connectedNonEndedCallCount: connectedNonEndedCallCount,
            revision: snapshot.revision,
            membershipRevision: nextMembershipRevision
        )
    }
    var onSnapshotChanged: ((WorldwideCallActivitySnapshot) -> Void)?
    private var isObserving = false
    /// Exact CallKit UUIDs remain process-local and are used only for set equality. They are never
    /// copied into a snapshot, log, diagnostic, transport message, or persisted artifact.
    private var observedNonEndedCallIDs: Set<UUID> = []
    private var nextMembershipRevision: UInt64 = 0
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
        observedNonEndedCallIDs.removeAll(keepingCapacity: false)
        nextMembershipRevision = 0
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
            refreshCurrentAggregate(advanceRevision: true)
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

    private func refreshCurrentAggregate(
        notify: Bool = true,
        advanceRevision: Bool = false
    ) {
        guard isObserving else { return }
        let aggregate = liveSnapshot
        publish(
            WorldwideCallActivitySnapshot(
                nonEndedCallCount: aggregate.nonEndedCallCount,
                connectedNonEndedCallCount:
                    aggregate.connectedNonEndedCallCount,
                revision: advanceRevision
                    ? snapshot.revision &+ 1
                    : snapshot.revision,
                membershipRevision:
                    aggregate.membershipRevision
            ),
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
