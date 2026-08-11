import CoreAudio
import Foundation

/// The two output defaults that must remain non-BlackHole during worldwide duplex audio.
enum BlackHoleDefaultOutputKind: CaseIterable, Hashable, Sendable {
    case output
    case systemOutput

    var selector: AudioObjectPropertySelector {
        switch self {
        case .output:
            kAudioHardwarePropertyDefaultOutputDevice
        case .systemOutput:
            kAudioHardwarePropertyDefaultSystemOutputDevice
        }
    }
}

enum BlackHoleDefaultOutputMutationResult: Equatable, Sendable {
    case written(OSStatus)
    case currentOutputMismatch
    case readFailed
}

protocol WorldwideSafeOutputInvariantOperations: AnyObject, Sendable {
    func addDefaultOutputListener(
        kind: BlackHoleDefaultOutputKind,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListenerRegistration
    ) -> OSStatus

    func removeDefaultOutputListener(
        kind: BlackHoleDefaultOutputKind,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListenerRegistration
    ) -> OSStatus

    func currentDefaultOutputUID(
        _ kind: BlackHoleDefaultOutputKind
    ) throws -> String

    /// Resolves and validates one alive device with at least one output channel.
    func resolveUsableOutputDeviceID(uid: String) throws -> AudioDeviceID

    /// Keeps the last read immediately adjacent to the selector-specific write.
    func compareAndSetDefaultOutputDevice(
        _ deviceID: AudioDeviceID,
        kind: BlackHoleDefaultOutputKind,
        expectedCurrentUID: String
    ) -> BlackHoleDefaultOutputMutationResult
}

/// Summary of one worldwide safe-output invariant check.
public struct WorldwideSafeOutputInvariantResult:
    Equatable,
    Sendable
{
    public let changedDefaultOutput: Bool
    public let changedDefaultSystemOutput: Bool

    public var changedAnything: Bool {
        changedDefaultOutput || changedDefaultSystemOutput
    }
}

/// Stable two-selector observation used by the healthy-session invariant monitor.
public struct WorldwideSafeOutputInvariantVerification:
    Equatable,
    Sendable
{
    public let isSatisfied: Bool
    public let changedSincePreviousObservation: Bool
}

/// Identifies one exact, session-lifetime pair of Core Audio output listeners.
public struct WorldwideSafeOutputInvariantMonitoringEpoch:
    Equatable,
    Hashable,
    Sendable
{
    public let id: UUID

    fileprivate init(id: UUID = UUID()) {
        self.id = id
    }
}

/// Proof consumed when a caller opens a fail-closed microphone writer gate.
///
/// The listener sequence belongs only to `monitoringEpoch`; it must never be
/// compared across monitoring lifetimes.
public struct WorldwideSafeOutputInvariantAuthorization:
    Equatable,
    Sendable
{
    public let monitoringEpoch:
        WorldwideSafeOutputInvariantMonitoringEpoch
    public let listenerSequence: UInt64
}

/// Enforces the worldwide duplex invariant that BlackHole may be the input, never an output.
///
/// When exactly one selector is BlackHole, the other current usable output supplies the preferred
/// replacement. When both are BlackHole, the built-in speaker is the deterministic fallback. The
/// default-input selector is deliberately absent from this type. Core Audio has no atomic
/// compare-and-set; an exact listener sequence plus readback rejects every observable overlap.
public final class WorldwideSafeOutputInvariant: @unchecked Sendable {
    public static let canonicalBlackHoleUID =
        WorldwideBlackHoleMicrophoneEndpointContract
            .visibleDefaultInputDeviceUID
    public static let hiddenMirrorBlackHoleUID =
        WorldwideBlackHoleMicrophoneEndpointContract
            .hiddenMirrorSinkDeviceUID
    public static let builtInSpeakerUID = "BuiltInSpeakerDevice"

    public static func isForbiddenOutputUID(_ uid: String) -> Bool {
        uid == canonicalBlackHoleUID
            || uid == hiddenMirrorBlackHoleUID
    }

    private struct Snapshot: Equatable {
        let outputUID: String
        let systemOutputUID: String

        func uid(for kind: BlackHoleDefaultOutputKind) -> String {
            switch kind {
            case .output:
                outputUID
            case .systemOutput:
                systemOutputUID
            }
        }

        var isSafe: Bool {
            !WorldwideSafeOutputInvariant
                .isForbiddenOutputUID(outputUID)
                && !WorldwideSafeOutputInvariant
                    .isForbiddenOutputUID(systemOutputUID)
        }

        var preferredSafeUID: String? {
            if !WorldwideSafeOutputInvariant
                .isForbiddenOutputUID(outputUID) {
                return outputUID
            }
            if !WorldwideSafeOutputInvariant
                .isForbiddenOutputUID(systemOutputUID) {
                return systemOutputUID
            }
            return nil
        }
    }

    private final class ChangeSignal: @unchecked Sendable {
        private let condition = NSCondition()
        private var count: UInt64 = 0
        private var onUncertain:
            (@Sendable (_ eventSequence: UInt64) -> Void)?

        init(
            onUncertain:
                (@Sendable (_ eventSequence: UInt64) -> Void)? = nil
        ) {
            self.onUncertain = onUncertain
        }

        func record() {
            condition.lock()
            let eventSequence = Self.nextNonzero(count)
            // This callback is deliberately invoked before the sequence is
            // published. A constant-time, thread-safe writer-gate close can
            // therefore win against every later authorization commit.
            onUncertain?(eventSequence)
            count = eventSequence
            condition.broadcast()
            condition.unlock()
        }

        /// Runs the authorization commit under the same lock used by listener
        /// callbacks. A selector callback either closes the gate and publishes
        /// a newer sequence first, or runs only after this commit has opened it.
        func commitIfUnchanged(
            after expected: UInt64,
            _ commit: () throws -> Void
        ) rethrows -> Bool {
            condition.lock()
            defer { condition.unlock() }
            guard count == expected,
                  onUncertain != nil else {
                return false
            }
            try commit()
            return true
        }

        func deactivateUncertaintyCallback() {
            condition.lock()
            onUncertain = nil
            condition.unlock()
        }

        func snapshot() -> UInt64 {
            condition.lock()
            defer { condition.unlock() }
            return count
        }

        func waitForAdvance(
            after previous: UInt64,
            timeout: TimeInterval
        ) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock()
            defer { condition.unlock() }
            while count <= previous {
                guard condition.wait(until: deadline) else {
                    return count > previous
                }
            }
            return true
        }

        private static func nextNonzero(
            _ value: UInt64
        ) -> UInt64 {
            let next = value &+ 1
            return next == 0 ? 1 : next
        }
    }

    private struct Registration {
        let queue: DispatchQueue
        let signal: ChangeSignal
        let removalJob: ListenerRemovalJob
    }

    private struct ActiveSessionMonitoring {
        let epoch:
            WorldwideSafeOutputInvariantMonitoringEpoch
        let registration: Registration
    }

    /// Owns the exact queue/listener identities until every successful Core
    /// Audio removal. Successful members are discarded individually; failed
    /// members remain available to the bounded deferred cleanup redrive.
    private final class ListenerRemovalJob: @unchecked Sendable {
        let id = UUID()

        private let operations:
            any WorldwideSafeOutputInvariantOperations
        private let queue: DispatchQueue
        private let lock = NSLock()
        private var listeners: [
            BlackHoleDefaultOutputKind:
                CoreAudioPropertyListenerRegistration
        ]

        init(
            operations:
                any WorldwideSafeOutputInvariantOperations,
            queue: DispatchQueue,
            listeners: [
                BlackHoleDefaultOutputKind:
                    CoreAudioPropertyListenerRegistration
            ]
        ) {
            self.operations = operations
            self.queue = queue
            self.listeners = listeners
        }

        func remove(
            maximumAttemptCount: Int
        ) -> OSStatus {
            var firstFailure = noErr
            for _ in 0..<max(1, maximumAttemptCount) {
                let status = removeOnce()
                if status == noErr {
                    return noErr
                }
                if firstFailure == noErr {
                    firstFailure = status
                }
            }
            return firstFailure
        }

        func removeOnce() -> OSStatus {
            lock.lock()
            defer { lock.unlock() }

            queue.sync {}
            var firstFailure = noErr
            for kind in BlackHoleDefaultOutputKind.allCases {
                guard let listener = listeners[kind] else {
                    continue
                }
                let status = operations.removeDefaultOutputListener(
                    kind: kind,
                    queue: queue,
                    listener: listener
                )
                if status == noErr {
                    listeners[kind] = nil
                } else if firstFailure == noErr {
                    firstFailure = status
                }
            }
            queue.sync {}
            return listeners.isEmpty ? noErr : firstFailure
        }
    }

    private enum WriteProof {
        case proved
        case retryable
        case attemptedButUnproved
        case observableContention
    }

    private let operations:
        any WorldwideSafeOutputInvariantOperations
    private let operationQueue: DispatchQueue
    private let listenerQueue: DispatchQueue
    private let listenerCleanupRetainer:
        any BlackHoleDeviceAvailabilityListenerCleanupRetaining
    private let proofTimeout: TimeInterval
    private let operationQueueKey = DispatchSpecificKey<UUID>()
    private let operationQueueToken = UUID()
    private let maximumAttemptCount: Int
    private let maximumListenerRemovalAttemptCount: Int
    private var lastObservedSnapshot: Snapshot?
    private var activeSessionMonitoring:
        ActiveSessionMonitoring?

    public convenience init() {
        self.init(
            operations: SystemWorldwideSafeOutputInvariantOperations(),
            operationQueue: DispatchQueue(
                label: "opensteamer.WorldwideSafeOutputInvariant.operations"
            ),
            listenerQueue: DispatchQueue(
                label: "opensteamer.WorldwideSafeOutputInvariant.listener"
            ),
            proofTimeout: 0.5,
            maximumAttemptCount: 3,
            maximumListenerRemovalAttemptCount: 3
        )
    }

    init(
        operations:
            any WorldwideSafeOutputInvariantOperations,
        operationQueue: DispatchQueue,
        listenerQueue: DispatchQueue = DispatchQueue(
            label: "opensteamer.WorldwideSafeOutputInvariant.listener.test"
        ),
        proofTimeout: TimeInterval = 0.05,
        maximumAttemptCount: Int = 3,
        maximumListenerRemovalAttemptCount: Int = 3,
        listenerCleanupRetainer:
            any BlackHoleDeviceAvailabilityListenerCleanupRetaining =
                BlackHoleDeviceAvailabilityListenerCleanupRetainer.shared
    ) {
        self.operations = operations
        self.operationQueue = operationQueue
        self.listenerQueue = listenerQueue
        self.listenerCleanupRetainer =
            listenerCleanupRetainer
        self.proofTimeout = max(0.001, proofTimeout)
        self.maximumAttemptCount = max(1, maximumAttemptCount)
        self.maximumListenerRemovalAttemptCount = max(
            1,
            maximumListenerRemovalAttemptCount
        )
        operationQueue.setSpecific(
            key: operationQueueKey,
            value: operationQueueToken
        )
    }

    /// Installs one exact listener for each protected output selector and keeps
    /// those listeners alive until `endSessionMonitoring(epoch:)` succeeds or
    /// retains their exact identities for deferred cleanup.
    ///
    /// `onUncertain` executes synchronously on the Core Audio listener queue,
    /// under the listener-sequence lock, and before the new sequence is made
    /// observable. It must be constant-time, thread-safe, and non-reentrant.
    /// Its first action should close the microphone writer authorization gate;
    /// actor reconciliation may be queued only after that synchronous close.
    /// The exact epoch and event sequence let that later actor work reject a
    /// stale callback already superseded by a newer admission authorization.
    public func beginSessionMonitoring(
        onUncertain: @escaping @Sendable (
            WorldwideSafeOutputInvariantMonitoringEpoch,
            _ eventSequence: UInt64
        ) -> Void
    ) throws -> WorldwideSafeOutputInvariantMonitoringEpoch {
        try onOperationQueue {
            guard activeSessionMonitoring == nil else {
                throw WorldwideSafeOutputInvariantError
                    .sessionMonitoringAlreadyActive
            }

            let epoch =
                WorldwideSafeOutputInvariantMonitoringEpoch()
            let registration = try installRegistration(
                onUncertain: { eventSequence in
                    onUncertain(epoch, eventSequence)
                }
            )
            activeSessionMonitoring = ActiveSessionMonitoring(
                epoch: epoch,
                registration: registration
            )
            return epoch
        }
    }

    /// Removes the exact session-lifetime listeners. The caller must close the
    /// writer gate and release default-input ownership before invoking this.
    /// A failed bounded removal is retained with the same listener identities
    /// for autonomous cleanup and is reported as an error.
    public func endSessionMonitoring(
        epoch: WorldwideSafeOutputInvariantMonitoringEpoch
    ) throws {
        try onOperationQueue {
            guard let activeSessionMonitoring else {
                throw WorldwideSafeOutputInvariantError
                    .sessionMonitoringInactive
            }
            guard activeSessionMonitoring.epoch == epoch else {
                throw WorldwideSafeOutputInvariantError
                    .sessionMonitoringEpochMismatch
            }

            self.activeSessionMonitoring = nil
            activeSessionMonitoring.registration.signal
                .deactivateUncertaintyCallback()
            let removalStatus = removeRegistration(
                activeSessionMonitoring.registration
            )
            guard removalStatus == noErr else {
                retainFailedRemoval(
                    activeSessionMonitoring.registration
                )
                throw WorldwideSafeOutputInvariantError
                    .listenerRemovalFailed(
                        status: removalStatus
                    )
            }
        }
    }

    /// Returns only after both output selectors are known not to reference BlackHole.
    public func enforce()
        throws -> WorldwideSafeOutputInvariantResult {
        try onOperationQueue {
            if let activeSessionMonitoring {
                let snapshot = try fencedSnapshot(
                    registration:
                        activeSessionMonitoring.registration
                )
                guard snapshot.isSafe else {
                    throw WorldwideSafeOutputInvariantError
                        .sessionRepairRequiresAdmissionFence
                }
                lastObservedSnapshot = snapshot
                return WorldwideSafeOutputInvariantResult(
                    changedDefaultOutput: false,
                    changedDefaultSystemOutput: false
                )
            }
            return try withRegistration { registration in
                try enforceLocked(registration: registration)
            }
        }
    }

    /// Keeps both output-selector listeners installed across one synchronous
    /// default-input admission attempt.
    ///
    /// Core Audio does not provide a transaction spanning the output and input
    /// selectors. This is the narrowest observable fence: establish a stable,
    /// safe output snapshot, perform the input-only admission while the exact
    /// listeners remain registered, validate their sequence through exact
    /// removal, and require one final stable safe snapshot after removal.
    ///
    /// `beforeFirstMutation` runs at most once, immediately before the first
    /// output mutation and while both exact listeners are installed. A caller
    /// can use it to revoke input ownership before this invariant repairs an
    /// unsafe output route. `rollback` runs for any failed post-admission proof,
    /// including a teardown-time route change or listener-removal failure.
    public func enforceDuringAdmission<T>(
        beforeFirstMutation: () throws -> Void = {},
        admission: () -> T,
        rollback: (T) -> Void
    ) throws -> (
        invariant: WorldwideSafeOutputInvariantResult,
        admission: T
    ) {
        try onOperationQueue {
            if let activeSessionMonitoring {
                let transaction = try
                    enforceDuringActiveAdmissionLocked(
                        active: activeSessionMonitoring,
                        beforeFirstMutation:
                            beforeFirstMutation,
                        admission: admission,
                        rollback: rollback,
                        commit: { _, _ in }
                    )
                return (
                    invariant: transaction.invariant,
                    admission: transaction.admission
                )
            }

            let registration = try installRegistration()
            let preparation = Result { () throws -> (
                WorldwideSafeOutputInvariantResult,
                Snapshot
            ) in
                let invariant = try enforceLocked(
                    registration: registration,
                    beforeFirstMutation: beforeFirstMutation
                )
                let snapshot = try fencedSnapshot(
                    registration: registration
                )
                guard snapshot.isSafe else {
                    throw WorldwideSafeOutputInvariantError
                        .didNotConverge
                }
                self.lastObservedSnapshot = snapshot
                return (invariant, snapshot)
            }
            guard case .success(
                let (invariant, admittedSnapshot)
            ) = preparation else {
                guard case .failure(let error) = preparation else {
                    preconditionFailure("unreachable Result state")
                }
                try finishFailedRegistration(
                    registration,
                    preserving: error
                )
            }

            let admittedSequence = registration.signal.snapshot()
            let admittedValue = admission()
            var removalWasAttempted = false

            do {
                drainListenerQueue(registration)
                guard registration.signal.snapshot()
                        == admittedSequence else {
                    throw WorldwideSafeOutputInvariantError
                        .observableContention
                }
                let completedSnapshot = try fencedSnapshot(
                    registration: registration
                )
                guard registration.signal.snapshot()
                        == admittedSequence,
                      completedSnapshot == admittedSnapshot,
                      completedSnapshot.isSafe else {
                    throw WorldwideSafeOutputInvariantError
                        .observableContention
                }

                let removalSequence =
                    registration.signal.snapshot()
                removalWasAttempted = true
                let removalStatus = removeRegistration(
                    registration
                )
                if removalStatus != noErr {
                    retainFailedRemoval(registration)
                    throw WorldwideSafeOutputInvariantError
                        .listenerRemovalFailed(
                            status: removalStatus
                        )
                }
                guard registration.signal.snapshot()
                        == removalSequence else {
                    throw WorldwideSafeOutputInvariantError
                        .observableContention
                }

                let postRemovalSnapshot =
                    try stableSnapshotWithoutListeners()
                guard postRemovalSnapshot.isSafe,
                      postRemovalSnapshot
                        == completedSnapshot else {
                    throw WorldwideSafeOutputInvariantError
                        .observableContention
                }
                lastObservedSnapshot = postRemovalSnapshot
                return (
                    invariant: invariant,
                    admission: admittedValue
                )
            } catch {
                rollback(admittedValue)
                guard !removalWasAttempted else {
                    throw error
                }
                try finishFailedRegistration(
                    registration,
                    preserving: error
                )
            }
        }
    }

    /// Performs input admission and its writer-gate authorization under the
    /// exact session-lifetime listener pair.
    ///
    /// `commit` is invoked only after the admitted output snapshot has been
    /// proven stable and safe. It runs under the same lock as the listener
    /// callback: an overlapping callback either closes the gate first and
    /// prevents this commit, or closes it immediately after this commit.
    /// `beforeFirstMutation` must synchronously close the writer gate, revoke
    /// forwarding, and release default-input ownership; it runs once before
    /// any invariant-owned output repair and does not fabricate a listener
    /// event or queue reconciliation work. Throw when release cannot be
    /// proven; the invariant then performs no compare-and-set mutation.
    public func enforceDuringAdmission<T>(
        monitoringEpoch:
            WorldwideSafeOutputInvariantMonitoringEpoch,
        beforeFirstMutation: () throws -> Void = {},
        admission: () -> T,
        rollback: (T) -> Void,
        commit: (
            T,
            WorldwideSafeOutputInvariantAuthorization
        ) throws -> Void
    ) throws -> (
        invariant: WorldwideSafeOutputInvariantResult,
        admission: T,
        authorization:
            WorldwideSafeOutputInvariantAuthorization
    ) {
        try onOperationQueue {
            guard let activeSessionMonitoring else {
                throw WorldwideSafeOutputInvariantError
                    .sessionMonitoringInactive
            }
            guard activeSessionMonitoring.epoch
                    == monitoringEpoch else {
                throw WorldwideSafeOutputInvariantError
                    .sessionMonitoringEpochMismatch
            }
            return try enforceDuringActiveAdmissionLocked(
                active: activeSessionMonitoring,
                beforeFirstMutation: beforeFirstMutation,
                admission: admission,
                rollback: rollback,
                commit: commit
            )
        }
    }

    /// Observes both selectors without mutation and reports a stable route change.
    public func verify()
        throws -> WorldwideSafeOutputInvariantVerification {
        try onOperationQueue {
            if let activeSessionMonitoring {
                return try verifyLocked(
                    registration:
                        activeSessionMonitoring.registration
                )
            }
            return try withRegistration { registration in
                try verifyLocked(registration: registration)
            }
        }
    }

    /// Verifies through the exact session registration and rejects a stale
    /// epoch instead of silently creating a new listener pair.
    public func verify(
        monitoringEpoch:
            WorldwideSafeOutputInvariantMonitoringEpoch
    ) throws -> WorldwideSafeOutputInvariantVerification {
        try onOperationQueue {
            guard let activeSessionMonitoring else {
                throw WorldwideSafeOutputInvariantError
                    .sessionMonitoringInactive
            }
            guard activeSessionMonitoring.epoch
                    == monitoringEpoch else {
                throw WorldwideSafeOutputInvariantError
                    .sessionMonitoringEpochMismatch
            }
            return try verifyLocked(
                registration:
                    activeSessionMonitoring.registration
            )
        }
    }

    private func enforceDuringActiveAdmissionLocked<T>(
        active: ActiveSessionMonitoring,
        beforeFirstMutation: () throws -> Void,
        admission: () -> T,
        rollback: (T) -> Void,
        commit: (
            T,
            WorldwideSafeOutputInvariantAuthorization
        ) throws -> Void
    ) throws -> (
        invariant: WorldwideSafeOutputInvariantResult,
        admission: T,
        authorization:
            WorldwideSafeOutputInvariantAuthorization
    ) {
        let registration = active.registration
        let invariant = try enforceLocked(
            registration: registration,
            beforeFirstMutation: beforeFirstMutation
        )
        let admittedSnapshot = try fencedSnapshot(
            registration: registration
        )
        guard admittedSnapshot.isSafe else {
            throw WorldwideSafeOutputInvariantError
                .didNotConverge
        }
        lastObservedSnapshot = admittedSnapshot

        let admittedSequence = registration.signal.snapshot()
        let admittedValue = admission()
        do {
            drainListenerQueue(registration)
            guard registration.signal.snapshot()
                    == admittedSequence else {
                throw WorldwideSafeOutputInvariantError
                    .observableContention
            }
            let completedSnapshot = try fencedSnapshot(
                registration: registration
            )
            guard registration.signal.snapshot()
                    == admittedSequence,
                  completedSnapshot == admittedSnapshot,
                  completedSnapshot.isSafe else {
                throw WorldwideSafeOutputInvariantError
                    .observableContention
            }

            let authorization =
                WorldwideSafeOutputInvariantAuthorization(
                    monitoringEpoch: active.epoch,
                    listenerSequence: admittedSequence
                )
            let committed = try registration.signal
                .commitIfUnchanged(
                    after: admittedSequence
                ) {
                    try commit(
                        admittedValue,
                        authorization
                    )
                }
            guard committed else {
                throw WorldwideSafeOutputInvariantError
                    .observableContention
            }

            // The listener remains installed. This readback rejects any
            // notification queued immediately after the commit; its callback
            // has already synchronously revoked the new authorization.
            drainListenerQueue(registration)
            guard registration.signal.snapshot()
                    == admittedSequence else {
                throw WorldwideSafeOutputInvariantError
                    .observableContention
            }
            let committedSnapshot = try fencedSnapshot(
                registration: registration
            )
            guard registration.signal.snapshot()
                    == admittedSequence,
                  committedSnapshot == completedSnapshot,
                  committedSnapshot.isSafe else {
                throw WorldwideSafeOutputInvariantError
                    .observableContention
            }

            lastObservedSnapshot = committedSnapshot
            return (
                invariant: invariant,
                admission: admittedValue,
                authorization: authorization
            )
        } catch {
            rollback(admittedValue)
            throw error
        }
    }

    private func verifyLocked(
        registration: Registration
    ) throws -> WorldwideSafeOutputInvariantVerification {
        let current = try fencedSnapshot(
            registration: registration
        )
        let changed = lastObservedSnapshot.map {
            $0 != current
        } ?? true
        lastObservedSnapshot = current
        return WorldwideSafeOutputInvariantVerification(
            isSatisfied: current.isSafe,
            changedSincePreviousObservation: changed
        )
    }

    private func enforceLocked(
        registration: Registration,
        beforeFirstMutation: () throws -> Void = {}
    ) throws -> WorldwideSafeOutputInvariantResult {
        var changedDefaultOutput = false
        var changedDefaultSystemOutput = false
        var preparedForMutation = false

        let prepareForMutation = { () throws -> Void in
            guard !preparedForMutation else { return }
            preparedForMutation = true
            try beforeFirstMutation()
        }

        for _ in 0..<maximumAttemptCount {
            let before = try fencedSnapshot(
                registration: registration
            )
            if before.isSafe {
                lastObservedSnapshot = before
                return WorldwideSafeOutputInvariantResult(
                    changedDefaultOutput: changedDefaultOutput,
                    changedDefaultSystemOutput:
                        changedDefaultSystemOutput
                )
            }

            let (safeUID, safeDeviceID) = try safeOutputTarget(
                for: before
            )

            var shouldRetry = false
            for kind in BlackHoleDefaultOutputKind.allCases
                where Self.isForbiddenOutputUID(
                    before.uid(for: kind)
                ) {
                let unsafeUID = before.uid(for: kind)
                switch try writeAndProve(
                    deviceID: safeDeviceID,
                    kind: kind,
                    expectedCurrentUID: unsafeUID,
                    replacementUID: safeUID,
                    registration: registration,
                    prepareForMutation: prepareForMutation
                ) {
                case .proved:
                    switch kind {
                    case .output:
                        changedDefaultOutput = true
                    case .systemOutput:
                        changedDefaultSystemOutput = true
                    }
                case .retryable:
                    shouldRetry = true
                case .attemptedButUnproved:
                    throw WorldwideSafeOutputInvariantError
                        .mutationUnproved
                case .observableContention:
                    throw WorldwideSafeOutputInvariantError
                        .observableContention
                }
            }

            let after = try fencedSnapshot(
                registration: registration
            )
            if after.isSafe {
                lastObservedSnapshot = after
                return WorldwideSafeOutputInvariantResult(
                    changedDefaultOutput: changedDefaultOutput,
                    changedDefaultSystemOutput:
                        changedDefaultSystemOutput
                )
            }
            if !shouldRetry {
                break
            }
        }

        throw WorldwideSafeOutputInvariantError
            .didNotConverge
    }

    private func snapshot() throws -> Snapshot {
        Snapshot(
            outputUID: try operations.currentDefaultOutputUID(.output),
            systemOutputUID:
                try operations.currentDefaultOutputUID(.systemOutput)
        )
    }

    /// Fences every two-selector observation with one exact listener sequence.
    private func fencedSnapshot(
        registration: Registration
    ) throws -> Snapshot {
        drainListenerQueue(registration)
        let sequence = registration.signal.snapshot()
        let first = try snapshot()
        drainListenerQueue(registration)
        guard registration.signal.snapshot() == sequence else {
            throw WorldwideSafeOutputInvariantError
                .observableContention
        }
        let second = try snapshot()
        drainListenerQueue(registration)
        guard registration.signal.snapshot() == sequence,
              second == first else {
            throw WorldwideSafeOutputInvariantError
                .observableContention
        }
        return second
    }

    private func safeOutputTarget(
        for snapshot: Snapshot
    ) throws -> (uid: String, deviceID: AudioDeviceID) {
        if let preferredUID = snapshot.preferredSafeUID,
           preferredUID != Self.builtInSpeakerUID,
           let preferredDeviceID = try? operations
            .resolveUsableOutputDeviceID(uid: preferredUID) {
            return (preferredUID, preferredDeviceID)
        }

        let deviceID = try operations.resolveUsableOutputDeviceID(
            uid: Self.builtInSpeakerUID
        )
        return (Self.builtInSpeakerUID, deviceID)
    }

    private func installRegistration(
        onUncertain:
            (@Sendable (_ eventSequence: UInt64) -> Void)? = nil
    ) throws -> Registration {
        let signal = ChangeSignal(
            onUncertain: onUncertain
        )
        var installed: [
            BlackHoleDefaultOutputKind:
                CoreAudioPropertyListenerRegistration
        ] = [:]

        for kind in BlackHoleDefaultOutputKind.allCases {
            let listener = CoreAudioPropertyListenerRegistration {
                [signal] _, _ in
                signal.record()
            }
            let status = operations.addDefaultOutputListener(
                kind: kind,
                queue: listenerQueue,
                listener: listener
            )
            guard status == noErr else {
                signal.deactivateUncertaintyCallback()
                if !installed.isEmpty {
                    let partialRegistration = makeRegistration(
                        signal: signal,
                        listeners: installed
                    )
                    if removeRegistration(partialRegistration)
                        != noErr {
                        retainFailedRemoval(
                            partialRegistration
                        )
                    }
                }
                throw WorldwideSafeOutputInvariantError
                    .listenerRegistrationFailed(
                        kind: kind,
                        status: status
                    )
            }
            installed[kind] = listener
        }

        return makeRegistration(
            signal: signal,
            listeners: installed
        )
    }

    private func makeRegistration(
        signal: ChangeSignal,
        listeners: [
            BlackHoleDefaultOutputKind:
                CoreAudioPropertyListenerRegistration
        ]
    ) -> Registration {
        Registration(
            queue: listenerQueue,
            signal: signal,
            removalJob: ListenerRemovalJob(
                operations: operations,
                queue: listenerQueue,
                listeners: listeners
            )
        )
    }

    private func withRegistration<T>(
        _ body: (Registration) throws -> T
    ) throws -> T {
        let registration = try installRegistration()
        let result = Result {
            try body(registration)
        }
        let removalStatus = removeRegistration(registration)
        guard removalStatus == noErr else {
            retainFailedRemoval(registration)
            throw WorldwideSafeOutputInvariantError
                .listenerRemovalFailed(status: removalStatus)
        }
        return try result.get()
    }

    private func removeRegistration(
        _ registration: Registration
    ) -> OSStatus {
        drainListenerQueue(registration)
        let status = registration.removalJob.remove(
            maximumAttemptCount:
                maximumListenerRemovalAttemptCount
        )
        drainListenerQueue(registration)
        return status
    }

    private func retainFailedRemoval(
        _ registration: Registration
    ) {
        let removalJob = registration.removalJob
        listenerCleanupRetainer.retain(
            id: removalJob.id
        ) {
            removalJob.removeOnce() == noErr
        }
    }

    private func finishFailedRegistration(
        _ registration: Registration,
        preserving error: Error
    ) throws -> Never {
        let removalStatus = removeRegistration(registration)
        guard removalStatus == noErr else {
            retainFailedRemoval(registration)
            throw WorldwideSafeOutputInvariantError
                .listenerRemovalFailed(status: removalStatus)
        }
        throw error
    }

    /// A final double-read after exact listener removal. There is no Core Audio
    /// transaction that can cover this boundary, so success requires two equal,
    /// independently read safe selector snapshots.
    private func stableSnapshotWithoutListeners()
        throws -> Snapshot {
        let first = try snapshot()
        let second = try snapshot()
        guard first == second,
              second.isSafe else {
            throw WorldwideSafeOutputInvariantError
                .observableContention
        }
        return second
    }

    private func writeAndProve(
        deviceID: AudioDeviceID,
        kind: BlackHoleDefaultOutputKind,
        expectedCurrentUID: String,
        replacementUID: String,
        registration: Registration,
        prepareForMutation: () throws -> Void
    ) throws -> WriteProof {
        drainListenerQueue(registration)
        let before = registration.signal.snapshot()
        guard outputFenceMatches(
            kind: kind,
            expectedUID: expectedCurrentUID,
            sequence: before,
            registration: registration
        ) else {
            return .retryable
        }

        try prepareForMutation()
        drainListenerQueue(registration)
        guard registration.signal.snapshot() == before else {
            return .observableContention
        }
        guard outputFenceMatches(
            kind: kind,
            expectedUID: expectedCurrentUID,
            sequence: before,
            registration: registration
        ) else {
            return .retryable
        }

        let mutation = operations.compareAndSetDefaultOutputDevice(
            deviceID,
            kind: kind,
            expectedCurrentUID: expectedCurrentUID
        )
        switch mutation {
        case .currentOutputMismatch, .readFailed:
            return .retryable
        case .written(let status):
            guard status == noErr else {
                return .retryable
            }
        }

        // Core Audio has no atomic compare-and-set. The immediate comparison,
        // exact listener sequence, and stable readback detect observable overlap
        // across the residual read/write window; they do not claim atomicity.
        let expectedProof = Self.nextSignalSequence(after: before)
        guard registration.signal.waitForAdvance(
            after: before,
            timeout: proofTimeout
        ) else {
            return .attemptedButUnproved
        }

        let deadline = Date().addingTimeInterval(proofTimeout)
        repeat {
            drainListenerQueue(registration)
            let observed = registration.signal.snapshot()
            guard observed == expectedProof else {
                return .observableContention
            }
            if outputFenceMatches(
                kind: kind,
                expectedUID: replacementUID,
                sequence: observed,
                registration: registration
            ) {
                return .proved
            }
            Thread.sleep(forTimeInterval: 0.005)
        } while Date() < deadline

        drainListenerQueue(registration)
        return registration.signal.snapshot() == expectedProof
            ? .attemptedButUnproved
            : .observableContention
    }

    private func outputFenceMatches(
        kind: BlackHoleDefaultOutputKind,
        expectedUID: String,
        sequence: UInt64,
        registration: Registration
    ) -> Bool {
        drainListenerQueue(registration)
        guard registration.signal.snapshot() == sequence,
              (try? operations.currentDefaultOutputUID(kind))
                == expectedUID else {
            return false
        }
        drainListenerQueue(registration)
        guard registration.signal.snapshot() == sequence,
              (try? operations.currentDefaultOutputUID(kind))
                == expectedUID else {
            return false
        }
        drainListenerQueue(registration)
        return registration.signal.snapshot() == sequence
    }

    private func drainListenerQueue(_ registration: Registration) {
        registration.queue.sync {}
    }

    private static func nextSignalSequence(after value: UInt64) -> UInt64 {
        let next = value &+ 1
        return next == 0 ? 1 : next
    }

    private func onOperationQueue<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        if DispatchQueue.getSpecific(key: operationQueueKey)
            == operationQueueToken {
            return try body()
        }
        return try operationQueue.sync(execute: body)
    }
}

enum WorldwideSafeOutputInvariantError:
    LocalizedError,
    Equatable,
    Sendable
{
    case safeOutputUnavailable
    case listenerRegistrationFailed(
        kind: BlackHoleDefaultOutputKind,
        status: OSStatus
    )
    case listenerRemovalFailed(status: OSStatus)
    case mutationUnproved
    case observableContention
    case didNotConverge
    case sessionMonitoringAlreadyActive
    case sessionMonitoringInactive
    case sessionMonitoringEpochMismatch
    case sessionRepairRequiresAdmissionFence

    var errorDescription: String? {
        switch self {
        case .safeOutputUnavailable:
            "No usable non-BlackHole output device is available."
        case .listenerRegistrationFailed(let kind, let status):
            "Registering the \(kind.label) safety listener failed with "
                + "Core Audio status \(status)."
        case .listenerRemovalFailed(let status):
            "Removing a safe-output listener failed with Core Audio "
                + "status \(status)."
        case .mutationUnproved:
            "A safe-output mutation could not be proven by its exact "
                + "notification and readback."
        case .observableContention:
            "An overlapping output-route change was observed; microphone "
                + "admission is deferred."
        case .didNotConverge:
            "The worldwide safe-output invariant did not converge."
        case .sessionMonitoringAlreadyActive:
            "A worldwide safe-output monitoring session is already active."
        case .sessionMonitoringInactive:
            "No worldwide safe-output monitoring session is active."
        case .sessionMonitoringEpochMismatch:
            "The worldwide safe-output monitoring epoch is stale."
        case .sessionRepairRequiresAdmissionFence:
            "An active worldwide microphone session may repair outputs only "
                + "inside the admission fence."
        }
    }
}

private extension BlackHoleDefaultOutputKind {
    var label: String {
        switch self {
        case .output:
            "default output"
        case .systemOutput:
            "default system output"
        }
    }
}

private final class SystemWorldwideSafeOutputInvariantOperations:
    WorldwideSafeOutputInvariantOperations,
    @unchecked Sendable
{
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    func addDefaultOutputListener(
        kind: BlackHoleDefaultOutputKind,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListenerRegistration
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kind.selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectAddPropertyListenerBlock(
            systemObject,
            &address,
            queue,
            listener.block
        )
    }

    func removeDefaultOutputListener(
        kind: BlackHoleDefaultOutputKind,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListenerRegistration
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kind.selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectRemovePropertyListenerBlock(
            systemObject,
            &address,
            queue,
            listener.block
        )
    }

    func currentDefaultOutputUID(
        _ kind: BlackHoleDefaultOutputKind
    ) throws -> String {
        let deviceID = try currentDefaultDeviceID(kind)
        guard let uid = deviceUID(deviceID), !uid.isEmpty else {
            throw CaptureError.audioDeviceConfiguration(
                "read \(kind.label) stable UID",
                kAudio_ParamError
            )
        }
        return uid
    }

    func resolveUsableOutputDeviceID(uid: String) throws -> AudioDeviceID {
        guard !WorldwideSafeOutputInvariant
                .isForbiddenOutputUID(uid)
        else {
            throw WorldwideSafeOutputInvariantError
                .safeOutputUnavailable
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier: CFString = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(
                systemObject,
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr,
              deviceID != kAudioObjectUnknown,
              deviceUID(deviceID) == uid,
              try isAlive(deviceID),
              try outputChannelCount(deviceID) > 0 else {
            throw WorldwideSafeOutputInvariantError
                .safeOutputUnavailable
        }
        return deviceID
    }

    func compareAndSetDefaultOutputDevice(
        _ deviceID: AudioDeviceID,
        kind: BlackHoleDefaultOutputKind,
        expectedCurrentUID: String
    ) -> BlackHoleDefaultOutputMutationResult {
        do {
            guard try currentDefaultOutputUID(kind)
                    == expectedCurrentUID else {
                return .currentOutputMismatch
            }
        } catch {
            return .readFailed
        }

        // This is the narrowest comparison/write window Core Audio exposes.
        // The caller's listener sequence and readback fence observable overlap.
        var mutableDeviceID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kind.selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return .written(
            AudioObjectSetPropertyData(
                systemObject,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<AudioDeviceID>.size),
                &mutableDeviceID
            )
        )
    }

    private func currentDefaultDeviceID(
        _ kind: BlackHoleDefaultOutputKind
    ) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kind.selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr,
              deviceID != kAudioObjectUnknown else {
            throw CaptureError.audioDeviceConfiguration(
                "read \(kind.label)",
                status
            )
        }
        return deviceID
    }

    private func isAlive(_ deviceID: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        guard status == noErr else {
            throw CaptureError.audioDeviceConfiguration(
                "read output-device liveness",
                status
            )
        }
        return value != 0
    }

    private func outputChannelCount(
        _ deviceID: AudioDeviceID
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        )
        guard status == noErr, size > 0 else {
            throw CaptureError.audioDeviceConfiguration(
                "read output stream-configuration size",
                status
            )
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            storage
        )
        guard status == noErr else {
            throw CaptureError.audioDeviceConfiguration(
                "read output stream configuration",
                status
            )
        }

        let buffers = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.reduce(0) { partial, buffer in
            partial &+ buffer.mNumberChannels
        }
    }

    private func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                $0
            )
        }
        guard status == noErr else { return nil }
        return value as String
    }
}
