import CoreAudio
import Foundation

/// One read-only observation of whether the canonical BlackHole 2ch endpoint exists.
public struct BlackHoleDeviceAvailabilitySnapshot: Equatable, Sendable {
    public let monitorEpoch: UUID
    public let deviceGeneration: UInt64
    public let isAvailable: Bool
    public let deviceUID: String?

    public init(
        monitorEpoch: UUID,
        deviceGeneration: UInt64,
        isAvailable: Bool,
        deviceUID: String?
    ) {
        self.monitorEpoch = monitorEpoch
        self.deviceGeneration = deviceGeneration
        self.isAvailable = isAvailable
        self.deviceUID = deviceUID
    }
}

/// Result of logically stopping one monitor epoch and removing its exact listener.
///
/// `.stopped` means physical listener removal completed. `.retryableFailure`
/// means the epoch is fenced and replacement-safe, but exact physical cleanup
/// debt remains retained and autonomously redrivable.
public enum BlackHoleDeviceAvailabilityMonitorStopResult:
    Equatable,
    Sendable
{
    case stopped
    case retryableFailure
}

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

/// Observes Core Audio's device inventory without changing any default route.
///
/// The listener is registered before the initial inventory read. Every successful
/// start receives a fresh epoch, and every distinct identity state in that epoch
/// receives a strictly increasing generation. Factual absence publishes unavailable;
/// transient inventory failures preserve the last factual state and keep one token-fenced retry outstanding until a factual read, stop, or newer event.
public final class BlackHoleDeviceAvailabilityMonitor: @unchecked Sendable {
    public typealias Observer =
        @Sendable (BlackHoleDeviceAvailabilitySnapshot) -> Void

    typealias InventoryRetryScheduler =
        @Sendable (@escaping @Sendable () -> Void) -> Void

    private struct InventoryRetry {
        let epoch: UUID
        let token: UUID
    }

    private struct Registration: @unchecked Sendable {
        let id: UUID
        var address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let listener: CoreAudioPropertyListenerRegistration
        let epoch: UUID
    }

    private let operations:
        any BlackHoleDeviceAvailabilityMonitoringOperations
    private let callbackQueue: DispatchQueue
    private let makeEpoch: @Sendable () -> UUID
    private let scheduleInventoryRetry: InventoryRetryScheduler
    private let listenerCleanupRetainer:
        any BlackHoleDeviceAvailabilityListenerCleanupRetaining
    private let queueKey = DispatchSpecificKey<UUID>()
    private let queueToken = UUID()

    private var registration: Registration?
    private var observer: Observer?
    private var currentEpoch: UUID?
    private var nextDeviceGeneration: UInt64 = 0
    private var lastPublishedGeneration: UInt64 = 0
    private var latestSnapshot: BlackHoleDeviceAvailabilitySnapshot?
    private var inventoryRetry: InventoryRetry?
    private var deferredCleanupIDs: Set<UUID> = []
    private let maximumListenerRemovalAttemptCount = 3

    public convenience init() {
        let callbackQueue = DispatchQueue(
            label: "opensteamer.BlackHoleDeviceAvailabilityMonitor"
        )
        self.init(
            operations: SystemBlackHoleDeviceAvailabilityOperations(),
            callbackQueue: callbackQueue,
            makeEpoch: { UUID() },
            scheduleInventoryRetry: { work in
                callbackQueue.asyncAfter(
                    deadline: .now() + .milliseconds(100),
                    execute: work
                )
            }
        )
    }

    convenience init(
        operations:
            any BlackHoleDeviceAvailabilityMonitoringOperations,
        callbackQueue: DispatchQueue,
        makeEpoch: @escaping @Sendable () -> UUID,
        listenerCleanupRetainer:
            any BlackHoleDeviceAvailabilityListenerCleanupRetaining =
                BlackHoleDeviceAvailabilityListenerCleanupRetainer.shared
    ) {
        self.init(
            operations: operations,
            callbackQueue: callbackQueue,
            makeEpoch: makeEpoch,
            scheduleInventoryRetry: { work in
                callbackQueue.asyncAfter(
                    deadline: .now() + .milliseconds(100),
                    execute: work
                )
            },
            listenerCleanupRetainer:
                listenerCleanupRetainer
        )
    }

    init(
        operations:
            any BlackHoleDeviceAvailabilityMonitoringOperations,
        callbackQueue: DispatchQueue,
        makeEpoch: @escaping @Sendable () -> UUID,
        scheduleInventoryRetry:
            @escaping InventoryRetryScheduler,
        listenerCleanupRetainer:
            any BlackHoleDeviceAvailabilityListenerCleanupRetaining =
                BlackHoleDeviceAvailabilityListenerCleanupRetainer.shared
    ) {
        self.operations = operations
        self.callbackQueue = callbackQueue
        self.makeEpoch = makeEpoch
        self.scheduleInventoryRetry =
            scheduleInventoryRetry
        self.listenerCleanupRetainer =
            listenerCleanupRetainer
        callbackQueue.setSpecific(
            key: queueKey,
            value: queueToken
        )
    }

    deinit {
        if isOnCallbackQueue {
            retainCurrentRegistrationForDeferredCleanup()
        } else {
            _ = stop()
        }
    }

    /// Registers the listener first, then publishes the initial inventory.
    @discardableResult
    public func start(observer: @escaping Observer) throws -> UUID {
        try onCallbackQueue {
            _ = listenerCleanupRetainer.redriveRetained(
                maximumAttemptCount: 1
            )
            pruneDeferredCleanupIDs()

            guard registration == nil else {
                throw CaptureError.audioRouteUnhealthy(
                    "BlackHole device availability monitoring is already active"
                )
            }

            let epoch = makeEpoch()
            currentEpoch = epoch
            nextDeviceGeneration = 0
            lastPublishedGeneration = 0
            latestSnapshot = nil
            inventoryRetry = nil
            self.observer = observer

            var address = Self.devicesAddress
            let listener = CoreAudioPropertyListenerRegistration {
                [weak self] _, _ in
                self?.devicesDidChange(epoch: epoch)
            }
            let status = operations.addDevicesListener(
                address: &address,
                queue: callbackQueue,
                listener: listener
            )
            guard status == noErr else {
                currentEpoch = nil
                self.observer = nil
                throw CaptureError.audioDeviceConfiguration(
                    "register BlackHole device-list monitor",
                    status
                )
            }

            registration = Registration(
                id: UUID(),
                address: address,
                queue: callbackQueue,
                listener: listener,
                epoch: epoch
            )

            refreshInventory(
                epoch: epoch,
                invalidatesPendingRetry: true
            )
            return epoch
        }
    }

    /// Fences the current epoch before removing the exact listener registration.
    ///
    /// Removal failures retain the original address, queue, and listener
    /// object in an inert cleanup owner; they never block a replacement
    /// monitoring session.
    @discardableResult
    public func stop()
        -> BlackHoleDeviceAvailabilityMonitorStopResult {
        onCallbackQueue {
            currentEpoch = nil
            observer = nil
            nextDeviceGeneration = 0
            lastPublishedGeneration = 0
            latestSnapshot = nil
            inventoryRetry = nil

            guard let registration else {
                _ = listenerCleanupRetainer
                    .redriveRetained(
                        maximumAttemptCount: 1
                    )
                pruneDeferredCleanupIDs()
                return deferredCleanupIDs.isEmpty
                    ? .stopped
                    : .retryableFailure
            }
            self.registration = nil
            guard removeRegistration(registration) else {
                retainRegistrationCleanup(registration)
                Self.reportDegradedCleanup(
                    "BlackHole device monitor logically stopped, but exact listener removal remains deferred."
                )
                return .retryableFailure
            }
            pruneDeferredCleanupIDs()
            return deferredCleanupIDs.isEmpty
                ? .stopped
                : .retryableFailure
        }
    }

    private func removeRegistration(
        _ registration: Registration
    ) -> Bool {
        Self.removeRegistration(
            registration,
            operations: operations,
            maximumAttemptCount:
                maximumListenerRemovalAttemptCount
        )
    }

    private static func removeRegistration(
        _ registration: Registration,
        operations:
            any BlackHoleDeviceAvailabilityMonitoringOperations,
        maximumAttemptCount: Int
    ) -> Bool {
        for _ in 0..<max(0, maximumAttemptCount) {
            if removeRegistrationOnce(
                registration,
                operations: operations
            ) {
                return true
            }
        }
        return false
    }

    private static func removeRegistrationOnce(
        _ registration: Registration,
        operations:
            any BlackHoleDeviceAvailabilityMonitoringOperations
    ) -> Bool {
        var address = registration.address
        return operations.removeDevicesListener(
            address: &address,
            queue: registration.queue,
            listener: registration.listener
        ) == noErr
    }

    private func retainCurrentRegistrationForDeferredCleanup() {
        currentEpoch = nil
        observer = nil
        nextDeviceGeneration = 0
        lastPublishedGeneration = 0
        latestSnapshot = nil
        inventoryRetry = nil
        guard let registration else { return }
        self.registration = nil
        retainRegistrationCleanup(registration)
        Self.reportDegradedCleanup(
            "BlackHole device monitor deinitialized on its callback queue; exact listener cleanup was deferred."
        )
    }

    private func retainRegistrationCleanup(
        _ registration: Registration
    ) {
        let operations = operations
        deferredCleanupIDs.insert(registration.id)
        listenerCleanupRetainer.retain(
            id: registration.id
        ) {
            Self.removeRegistrationOnce(
                registration,
                operations: operations
            )
        }
    }

    private static func reportDegradedCleanup(
        _ message: String
    ) {
        guard let data = (message + "\n").data(
            using: .utf8
        ) else {
            return
        }
        FileHandle.standardError.write(data)
    }

    /// Returns the newest snapshot published by the current monitor epoch.
    public func currentSnapshot() -> BlackHoleDeviceAvailabilitySnapshot? {
        onCallbackQueue {
            latestSnapshot
        }
    }

    /// Number of this monitor's exact listener registrations still owned by deferred cleanup.
    public var deferredListenerCleanupCount: Int {
        onCallbackQueue {
            pruneDeferredCleanupIDs()
            return deferredCleanupIDs.count
        }
    }

    private func pruneDeferredCleanupIDs() {
        deferredCleanupIDs = Set(
            deferredCleanupIDs.filter {
                listenerCleanupRetainer.contains(id: $0)
            }
        )
    }

    private func devicesDidChange(epoch: UUID) {
        if isOnCallbackQueue {
            refreshInventory(
                epoch: epoch,
                invalidatesPendingRetry: true
            )
        } else {
            callbackQueue.async { [weak self] in
                self?.refreshInventory(
                    epoch: epoch,
                    invalidatesPendingRetry: true
                )
            }
        }
    }

    private func refreshInventory(
        epoch: UUID,
        invalidatesPendingRetry: Bool
    ) {
        guard currentEpoch == epoch,
              registration?.epoch == epoch else {
            return
        }

        if invalidatesPendingRetry {
            inventoryRetry = nil
        }

        let uid: String?
        do {
            uid = try operations.resolveBlackHole2ChannelDeviceUID()
        } catch {
            guard Self.isFactualDeviceAbsence(error) else {
                scheduleInventoryRetryIfNeeded(
                    epoch: epoch
                )
                return
            }
            uid = nil
        }

        inventoryRetry = nil

        let isAvailable = uid != nil
        if let latestSnapshot,
           latestSnapshot.isAvailable == isAvailable,
           latestSnapshot.deviceUID == uid {
            return
        }

        nextDeviceGeneration &+= 1
        if nextDeviceGeneration == 0 {
            nextDeviceGeneration = 1
        }

        publishIfCurrent(
            BlackHoleDeviceAvailabilitySnapshot(
                monitorEpoch: epoch,
                deviceGeneration: nextDeviceGeneration,
                isAvailable: isAvailable,
                deviceUID: uid
            )
        )
    }

    private func scheduleInventoryRetryIfNeeded(
        epoch: UUID
    ) {
        guard currentEpoch == epoch,
              registration?.epoch == epoch,
              inventoryRetry == nil else {
            return
        }

        let retry = InventoryRetry(
            epoch: epoch,
            token: UUID()
        )
        inventoryRetry = retry
        scheduleInventoryRetry { [weak self] in
            guard let self else { return }
            self.callbackQueue.async { [weak self] in
                self?.performInventoryRetry(retry)
            }
        }
    }

    private func performInventoryRetry(
        _ retry: InventoryRetry
    ) {
        guard inventoryRetry?.epoch == retry.epoch,
              inventoryRetry?.token == retry.token,
              currentEpoch == retry.epoch,
              registration?.epoch == retry.epoch else {
            return
        }

        inventoryRetry = nil
        refreshInventory(
            epoch: retry.epoch,
            invalidatesPendingRetry: false
        )
    }

    private static func isFactualDeviceAbsence(
        _ error: any Error
    ) -> Bool {
        guard let captureError = error as? CaptureError else {
            return false
        }
        if case .audioDeviceNotFound = captureError {
            return true
        }
        return false
    }

    private func publishIfCurrent(
        _ snapshot: BlackHoleDeviceAvailabilitySnapshot
    ) {
        guard snapshot.monitorEpoch == currentEpoch,
              snapshot.deviceGeneration > lastPublishedGeneration else {
            return
        }

        latestSnapshot = snapshot
        lastPublishedGeneration = snapshot.deviceGeneration
        let observer = observer
        observer?(snapshot)
    }

    #if DEBUG
    /// Injects a publication candidate through the production epoch/generation fence.
    func publishForTesting(
        _ snapshot: BlackHoleDeviceAvailabilitySnapshot
    ) {
        onCallbackQueue {
            publishIfCurrent(snapshot)
        }
    }
    #endif

    private var isOnCallbackQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) == queueToken
    }

    private func onCallbackQueue<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        if isOnCallbackQueue {
            return try body()
        }
        return try callbackQueue.sync(execute: body)
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
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

protocol BlackHoleDeviceAvailabilityMonitoringOperations:
    AnyObject,
    Sendable
{
    func addDevicesListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListenerRegistration
    ) -> OSStatus

    func removeDevicesListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListenerRegistration
    ) -> OSStatus

    func resolveBlackHole2ChannelDeviceUID() throws -> String
}

private final class SystemBlackHoleDeviceAvailabilityOperations:
    BlackHoleDeviceAvailabilityMonitoringOperations,
    @unchecked Sendable
{
    func addDevicesListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListenerRegistration
    ) -> OSStatus {
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener.block
        )
    }

    func removeDevicesListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListenerRegistration
    ) -> OSStatus {
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener.block
        )
    }

    func resolveBlackHole2ChannelDeviceUID() throws -> String {
        try BlackHoleRouteVerifier.blackHole2ChannelDeviceUID()
    }
}

protocol BlackHoleDefaultInputLeaseOperations:
    AnyObject,
    Sendable
{
    func addDefaultInputListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListenerRegistration
    ) -> OSStatus

    func removeDefaultInputListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListenerRegistration
    ) -> OSStatus

    func currentDefaultInputUID() throws -> String
    func resolveDeviceID(uid: String) throws -> AudioDeviceID
    func compareAndSetDefaultInputDevice(
        _ deviceID: AudioDeviceID,
        expectedCurrentUID: String
    ) -> BlackHoleDefaultInputMutationResult
}

enum BlackHoleDefaultInputMutationResult:
    Equatable,
    Sendable
{
    case written(OSStatus)
    case currentInputMismatch
    case readFailed
}

/// Owns one generation-bound, input-only Core Audio default selection.
///
/// The exact default-input listener is installed before every owned write. A write
/// succeeds only after exactly one post-fence listener notification and stable-UID
/// readback. Release keeps its captured restoration baseline across bounded,
/// retryable failures and restores only while the current input remains the lease's
/// BlackHole target.
public enum BlackHoleDefaultInputLeaseAcquisitionResult:
    Equatable,
    Sendable
{
    case acquired
    /// No default-input write or ownership occurred, so the same generation
    /// may make another bounded attempt.
    case retryableFailure
    /// Ownership is uncertain or this generation observed a newer external
    /// selection. Retrying could overwrite the user or another application.
    case terminalFailure
}

public enum BlackHoleDefaultInputLeaseReleaseResult:
    Equatable,
    Sendable
{
    case released
    case retryableFailure
    case externallySuperseded
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

public final class BlackHoleDefaultInputLease:
    @unchecked Sendable
{
    static func redriveDeferredCleanup(
        using retainer:
            any BlackHoleDefaultInputLeaseDeferredCleanupRetaining,
        maximumAttemptCount: Int
    ) -> Bool {
        retainer.redriveRetained(
            maximumAttemptCount:
                maximumAttemptCount
        ) == 0
    }

    public static func redriveRetainedDeferredCleanup(
        maximumAttemptCount: Int
    ) -> Bool {
        redriveDeferredCleanup(
            using:
                BlackHoleDefaultInputLeaseDeferredCleanupRetainer
                    .shared,
            maximumAttemptCount:
                maximumAttemptCount
        )
    }
    public static let canonicalDeviceUID = "BlackHole2ch_UID"

    private final class ChangeSignal:
        @unchecked Sendable
    {
        private let condition = NSCondition()
        private var count: UInt64 = 0

        @discardableResult
        func record() -> UInt64 {
            condition.lock()
            count &+= 1
            if count == 0 {
                count = 1
            }
            let recorded = count
            condition.broadcast()
            condition.unlock()
            return recorded
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
    }

    private struct Registration {
        let id: UUID
        var address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let listener: CoreAudioPropertyListenerRegistration
        let signal: ChangeSignal
    }

    private struct ActiveLease {
        let generation: UInt64
        let targetUID: String
        let registration: Registration
        var restoreUID: String?
        var ownsSelection: Bool
        var acceptedSignalSequence: UInt64
        var targetWasRemoved: Bool
    }

    private struct RetryBaseline {
        let targetUID: String
        let defaultInputUID: String
    }

    private enum CurrentInputFenceResult: Equatable {
        case matched
        case changed
        case unreadable
    }

    private enum WriteAndProveResult {
        case proved(signalSequence: UInt64)
        case prewriteFenceFailed
        case prewriteInputChanged
        case prewriteReadFailed
        case contentionDetected(signalSequence: UInt64)
        case failedWithoutMutation
        case attemptedButUnproved(signalSequence: UInt64)
    }

    private enum PendingDeregistrationCompletion:
        Equatable
    {
        case retryableAcquisition
        case released
        case externallySuperseded
        case terminalized
    }

    private struct PendingDeregistration {
        let generation: UInt64
        let registration: Registration
        let completion: PendingDeregistrationCompletion
    }

    private enum PendingDeregistrationRetryResult {
        case none
        case retryableFailure
        case completed(PendingDeregistration)
    }

    private final class DeferredCleanupOwner:
        @unchecked Sendable
    {
        let id = UUID()

        private let operations:
            any BlackHoleDefaultInputLeaseOperations
        private let operationQueue: DispatchQueue
        private let proofTimeout: TimeInterval
        private let maximumRestoreAttemptCount = 3
        private let maximumReadAttemptCount = 3
        private let maximumListenerRemovalAttemptCount = 3
        private let operationQueueKey =
            DispatchSpecificKey<UUID>()
        private let operationQueueToken = UUID()
        private let lock = NSLock()
        private var activeLeaseStorage: ActiveLease?
        private var pendingDeregistrationStorage:
            PendingDeregistration?

        init(
            operations:
                any BlackHoleDefaultInputLeaseOperations,
            operationQueue: DispatchQueue,
            proofTimeout: TimeInterval
        ) {
            self.operations = operations
            self.operationQueue = operationQueue
            self.proofTimeout = proofTimeout
            operationQueue.setSpecific(
                key: operationQueueKey,
                value: operationQueueToken
            )
        }

        var activeLease: ActiveLease? {
            get {
                withLock {
                    activeLeaseStorage
                }
            }
            set {
                withLock {
                    activeLeaseStorage = newValue
                }
            }
        }

        var pendingDeregistration:
            PendingDeregistration? {
            get {
                withLock {
                    pendingDeregistrationStorage
                }
            }
            set {
                withLock {
                    pendingDeregistrationStorage =
                        newValue
                }
            }
        }

        var hasCleanupOwnership: Bool {
            withLock {
                activeLeaseStorage != nil
                    || pendingDeregistrationStorage
                        != nil
            }
        }

        func runCleanupEpisode() -> Bool {
            if DispatchQueue.getSpecific(
                key: operationQueueKey
            ) == operationQueueToken {
                return cleanupEpisodeOnOperationQueue()
            }
            return operationQueue.sync {
                cleanupEpisodeOnOperationQueue()
            }
        }

        private func cleanupEpisodeOnOperationQueue()
            -> Bool {
            withLock {
                if let pending =
                        pendingDeregistrationStorage {
                    guard removeRegistration(
                        pending.registration
                    ) else {
                        return false
                    }
                    pendingDeregistrationStorage = nil
                }

                guard var active =
                        activeLeaseStorage else {
                    return true
                }

                let routeCompleted: Bool
                if active.targetWasRemoved
                    || !active.ownsSelection
                    || active.restoreUID == nil {
                    routeCompleted = true
                } else {
                    routeCompleted =
                        restoreRouteIfStillOwned(
                            &active
                        )
                }

                guard routeCompleted else {
                    activeLeaseStorage = active
                    return false
                }

                activeLeaseStorage = nil
                guard removeRegistration(
                    active.registration
                ) else {
                    pendingDeregistrationStorage =
                        PendingDeregistration(
                            generation:
                                active.generation,
                            registration:
                                active.registration,
                            completion: .released
                        )
                    return false
                }
                return true
            }
        }

        private func restoreRouteIfStillOwned(
            _ active: inout ActiveLease
        ) -> Bool {
            guard let restoreUID =
                    active.restoreUID else {
                return true
            }

            for attempt in 0..<maximumRestoreAttemptCount {
                guard let currentUID =
                        currentDefaultInputUIDWithRetries()
                else {
                    if attempt + 1
                        < maximumRestoreAttemptCount {
                        continue
                    }
                    return false
                }

                if currentUID == restoreUID {
                    return true
                }
                guard currentUID
                        == active.targetUID else {
                    return true
                }

                let restoreDeviceID:
                    AudioDeviceID
                do {
                    restoreDeviceID =
                        try operations.resolveDeviceID(
                            uid: restoreUID
                        )
                } catch {
                    if attempt + 1
                        < maximumRestoreAttemptCount {
                        continue
                    }
                    return false
                }

                let previousSignal =
                    active.registration.signal.snapshot()
                let mutation = operations
                    .compareAndSetDefaultInputDevice(
                        restoreDeviceID,
                        expectedCurrentUID:
                            active.targetUID
                    )
                switch mutation {
                case .currentInputMismatch:
                    return true

                case .readFailed:
                    continue

                case .written(let status):
                    if status == noErr {
                        _ = active.registration.signal
                            .waitForAdvance(
                                after: previousSignal,
                                timeout: proofTimeout
                            )
                        drainListenerQueue(
                            active.registration
                        )
                    }

                    guard let observedUID =
                            currentDefaultInputUIDWithRetries()
                    else {
                        continue
                    }
                    if observedUID == restoreUID {
                        return true
                    }
                    if observedUID
                            != active.targetUID {
                        return true
                    }
                    active.acceptedSignalSequence =
                        active.registration.signal
                            .snapshot()
                }
            }

            return false
        }

        private func removeRegistration(
            _ registration: Registration
        ) -> Bool {
            drainListenerQueue(registration)
            for attempt in 0..<maximumListenerRemovalAttemptCount {
                var address = registration.address
                let status =
                    operations
                        .removeDefaultInputListener(
                            address: &address,
                            queue: registration.queue,
                            listener:
                                registration.listener
                        )
                if status == noErr {
                    drainListenerQueue(registration)
                    return true
                }
                if attempt + 1
                    < maximumListenerRemovalAttemptCount {
                    Thread.sleep(
                        forTimeInterval: 0.005
                    )
                }
            }
            drainListenerQueue(registration)
            return false
        }

        private func drainListenerQueue(
            _ registration: Registration
        ) {
            registration.queue.sync {}
        }

        private func currentDefaultInputUIDWithRetries()
            -> String? {
            for attempt in 0..<maximumReadAttemptCount {
                do {
                    return try operations
                        .currentDefaultInputUID()
                } catch {
                    if attempt + 1
                        < maximumReadAttemptCount {
                        Thread.sleep(
                            forTimeInterval: 0.005
                        )
                    }
                }
            }
            return nil
        }

        private func withLock<T>(
            _ body: () -> T
        ) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    private let operations:
        any BlackHoleDefaultInputLeaseOperations
    private let operationQueue: DispatchQueue
    private let listenerQueue: DispatchQueue
    private let proofTimeout: TimeInterval
    private let maximumRestoreAttemptCount = 3
    private let maximumReadAttemptCount = 3
    private let maximumListenerRemovalAttemptCount = 3
    private let operationQueueKey =
        DispatchSpecificKey<UUID>()
    private let operationQueueToken = UUID()
    private let deferredCleanupRetainer:
        any BlackHoleDefaultInputLeaseDeferredCleanupRetaining
    private let deferredCleanupOwner:
        DeferredCleanupOwner

    private var activeLease: ActiveLease? {
        get {
            deferredCleanupOwner.activeLease
        }
        set {
            deferredCleanupOwner.activeLease =
                newValue
        }
    }

    private var pendingDeregistration:
        PendingDeregistration? {
        get {
            deferredCleanupOwner
                .pendingDeregistration
        }
        set {
            deferredCleanupOwner
                .pendingDeregistration = newValue
        }
    }

    private var highestGenerationSeen: UInt64 = 0
    private var highestRetiredGeneration: UInt64 = 0
    private var terminalGeneration: UInt64?
    private var retryBaseline:
        (generation: UInt64, value: RetryBaseline)?

    public convenience init() {
        self.init(
            operations:
                SystemBlackHoleDefaultInputLeaseOperations(),
            operationQueue: DispatchQueue(
                label: "opensteamer.BlackHoleDefaultInputLease.operations"
            ),
            listenerQueue: DispatchQueue(
                label: "opensteamer.BlackHoleDefaultInputLease.listener"
            ),
            proofTimeout: 0.5
        )
    }

    init(
        operations:
            any BlackHoleDefaultInputLeaseOperations,
        operationQueue: DispatchQueue,
        listenerQueue: DispatchQueue,
        proofTimeout: TimeInterval,
        deferredCleanupRetainer:
            any BlackHoleDefaultInputLeaseDeferredCleanupRetaining =
                BlackHoleDefaultInputLeaseDeferredCleanupRetainer
                    .shared
    ) {
        let boundedProofTimeout =
            max(0.001, proofTimeout)
        self.operations = operations
        self.operationQueue = operationQueue
        self.listenerQueue = listenerQueue
        self.proofTimeout = boundedProofTimeout
        self.deferredCleanupRetainer =
            deferredCleanupRetainer
        deferredCleanupOwner =
            DeferredCleanupOwner(
                operations: operations,
                operationQueue: operationQueue,
                proofTimeout: boundedProofTimeout
            )
        operationQueue.setSpecific(
            key: operationQueueKey,
            value: operationQueueToken
        )
        _ = deferredCleanupRetainer
            .redriveRetained(
                maximumAttemptCount: 1
            )
    }

    deinit {
        let owner = deferredCleanupOwner
        guard owner.hasCleanupOwnership else {
            return
        }

        let retainer = deferredCleanupRetainer
        let operationQueue = operationQueue
        let cleanupID = owner.id
        retainer.retain(id: cleanupID) {
            owner.runCleanupEpisode()
        }

        // Never synchronously enter operationQueue from deinit. In particular,
        // releasing the last lease reference inside listenerQueue must allow
        // that callback to return before restoration or exact deregistration
        // can wait for listenerQueue.
        operationQueue.async {
            retainer.redrive(id: cleanupID)
        }
    }

    /// Selects the supplied stable UID for one current connection generation.
    @discardableResult
    public func acquire(
        generation: UInt64,
        targetUID: String =
            BlackHoleDefaultInputLease.canonicalDeviceUID
    ) -> Bool {
        acquisitionResult(
            generation: generation,
            targetUID: targetUID
        ) == .acquired
    }

    /// Returns whether a failed acquisition is provably safe to retry.
    ///
    /// Only failures before an owned mutation, or a rejected mutation proved to
    /// have left the baseline unchanged, are retryable. A newer external choice
    /// terminalizes only that current generation.
    public func acquisitionResult(
        generation: UInt64,
        targetUID: String =
            BlackHoleDefaultInputLease.canonicalDeviceUID
    ) -> BlackHoleDefaultInputLeaseAcquisitionResult {
        onOperationQueue {
            acquireLocked(
                generation: generation,
                targetUID: targetUID
            )
        }
    }

    /// Releases only the exact generation supplied by its owner.
    @discardableResult
    public func release(
        generation: UInt64
    ) -> BlackHoleDefaultInputLeaseReleaseResult {
        onOperationQueue {
            releaseLocked(expectedGeneration: generation)
        }
    }

    /// Releases any remaining generation during graceful owner teardown.
    @discardableResult
    public func shutdown()
        -> BlackHoleDefaultInputLeaseReleaseResult {
        onOperationQueue {
            let result = releaseLocked(expectedGeneration: nil)
            if result != .retryableFailure {
                retryBaseline = nil
                terminalGeneration = nil
                pendingDeregistration = nil
                highestGenerationSeen = 0
                highestRetiredGeneration = 0
            }
            return result
        }
    }

    #if DEBUG
    func drainForTesting() {
        onOperationQueue {}
    }

    var debugBookkeepingEntryCountForTesting: Int {
        onOperationQueue {
            (terminalGeneration == nil ? 0 : 1)
                + (retryBaseline == nil ? 0 : 1)
                + (pendingDeregistration == nil ? 0 : 1)
        }
    }

    var debugHighestGenerationForTesting: UInt64 {
        onOperationQueue {
            highestGenerationSeen
        }
    }
    #endif

    private func acquireLocked(
        generation: UInt64,
        targetUID: String
    ) -> BlackHoleDefaultInputLeaseAcquisitionResult {
        guard generation > 0, !targetUID.isEmpty else {
            return .terminalFailure
        }

        if let pendingDeregistration {
            let sameGenerationCannotRetry =
                pendingDeregistration.generation == generation
                    && pendingDeregistration.completion
                        != .retryableAcquisition
            switch retryPendingDeregistration(
                expectedGeneration: nil
            ) {
            case .none:
                break

            case .retryableFailure:
                return sameGenerationCannotRetry
                    ? .terminalFailure
                    : .retryableFailure

            case .completed(let completed):
                if completed.completion
                        == .retryableAcquisition,
                   completed.registration.signal.snapshot()
                        != 0 {
                    clearRetryBaseline(
                        for: completed.generation
                    )
                    markTerminal(completed.generation)
                    if completed.generation == generation {
                        return .terminalFailure
                    }
                }
            }
        }

        guard generation > highestRetiredGeneration else {
            return .terminalFailure
        }
        guard generation >= highestGenerationSeen else {
            return .terminalFailure
        }

        if generation > highestGenerationSeen {
            _ = releaseLocked(expectedGeneration: nil)
            guard activeLease == nil,
                  pendingDeregistration == nil else {
                return .retryableFailure
            }
            highestGenerationSeen = generation
            terminalGeneration = nil
            retryBaseline = nil
        }

        guard terminalGeneration != generation else {
            return .terminalFailure
        }

        if var activeLease,
           activeLease.generation == generation,
           activeLease.targetUID == targetUID {
            if activeLease.targetWasRemoved {
                self.activeLease = nil
                clearRetryBaseline(for: generation)
                _ = beginDeregistration(
                    generation: generation,
                    registration:
                        activeLease.registration,
                    completion: .released
                )
                return .terminalFailure
            } else {
                switch currentInputFenceResult(
                    expectedUID: targetUID,
                    expectedSignalSequence:
                        activeLease.acceptedSignalSequence,
                    registration: activeLease.registration
                ) {
                case .matched:
                    return .acquired

                case .unreadable:
                    return .retryableFailure

                case .changed:
                    if safelyClassifyTargetRemoval(
                        activeLease
                    ) {
                        activeLease.targetWasRemoved = true
                        activeLease.restoreUID = nil
                        activeLease.ownsSelection = false
                        self.activeLease = nil
                        clearRetryBaseline(
                            for: generation
                        )
                        _ = beginDeregistration(
                            generation: generation,
                            registration:
                                activeLease.registration,
                            completion: .released
                        )
                        return .terminalFailure
                    } else {
                        terminalize(
                            activeLease,
                            signalSequence:
                                activeLease.registration
                                    .signal.snapshot()
                        )
                        return .terminalFailure
                    }
                }
            }
        }

        if activeLease != nil {
            _ = releaseLocked(expectedGeneration: nil)
            guard activeLease == nil,
                  pendingDeregistration == nil else {
                return .retryableFailure
            }
        }

        let previousUID: String
        do {
            previousUID =
                try operations.currentDefaultInputUID()
        } catch {
            return .retryableFailure
        }

        if let retryBaseline,
           retryBaseline.generation == generation {
            guard retryBaseline.value.targetUID == targetUID,
                  retryBaseline.value.defaultInputUID
                    == previousUID else {
                clearRetryBaseline(for: generation)
                markTerminal(generation)
                return .terminalFailure
            }
        }

        let registration: Registration
        do {
            registration = try installRegistration(
                generation: generation
            )
        } catch {
            guard currentDefaultInputUIDWithRetries()
                    == previousUID else {
                clearRetryBaseline(for: generation)
                markTerminal(generation)
                return .terminalFailure
            }
            storeRetryBaseline(
                generation: generation,
                targetUID: targetUID,
                defaultInputUID: previousUID
            )
            return .retryableFailure
        }

        switch currentInputFenceResult(
            expectedUID: previousUID,
            expectedSignalSequence: 0,
            registration: registration
        ) {
        case .matched:
            break

        case .unreadable:
            return finishPrewriteFailure(
                generation: generation,
                targetUID: targetUID,
                previousUID: previousUID,
                registration: registration
            )

        case .changed:
            terminalizeBeforeWrite(
                generation: generation,
                registration: registration
            )
            return .terminalFailure
        }

        let targetDeviceID: AudioDeviceID
        do {
            targetDeviceID =
                try operations.resolveDeviceID(uid: targetUID)
        } catch {
            return finishPrewriteFailure(
                generation: generation,
                targetUID: targetUID,
                previousUID: previousUID,
                registration: registration
            )
        }

        switch currentInputFenceResult(
            expectedUID: previousUID,
            expectedSignalSequence: 0,
            registration: registration
        ) {
        case .matched:
            break

        case .unreadable:
            return finishPrewriteFailure(
                generation: generation,
                targetUID: targetUID,
                previousUID: previousUID,
                registration: registration
            )

        case .changed:
            terminalizeBeforeWrite(
                generation: generation,
                registration: registration
            )
            return .terminalFailure
        }

        if previousUID == targetUID {
            activeLease = ActiveLease(
                generation: generation,
                targetUID: targetUID,
                registration: registration,
                restoreUID: nil,
                ownsSelection: false,
                acceptedSignalSequence: 0,
                targetWasRemoved: false
            )
            clearRetryBaseline(for: generation)
            return .acquired
        }

        activeLease = ActiveLease(
            generation: generation,
            targetUID: targetUID,
            registration: registration,
            restoreUID: previousUID,
            ownsSelection: true,
            acceptedSignalSequence: 0,
            targetWasRemoved: false
        )

        switch writeAndProve(
            deviceID: targetDeviceID,
            expectedCurrentUID: previousUID,
            expectedUID: targetUID,
            expectedSignalSequence: 0,
            registration: registration
        ) {
        case .proved(let signalSequence):
            activeLease?.acceptedSignalSequence =
                signalSequence
            clearRetryBaseline(for: generation)
            return .acquired

        case .prewriteReadFailed:
            activeLease = nil
            return finishPrewriteFailure(
                generation: generation,
                targetUID: targetUID,
                previousUID: previousUID,
                registration: registration
            )

        case .prewriteFenceFailed,
             .prewriteInputChanged:
            terminalizeBeforeWrite(
                generation: generation,
                registration: registration
            )
            return .terminalFailure

        case .contentionDetected(let signalSequence):
            if let activeLease {
                terminalize(
                    activeLease,
                    signalSequence: signalSequence
                )
            } else {
                markTerminal(generation)
                _ = beginDeregistration(
                    generation: generation,
                    registration: registration,
                    completion: .terminalized
                )
            }
            return .terminalFailure

        case .failedWithoutMutation:
            activeLease = nil
            return finishPrewriteFailure(
                generation: generation,
                targetUID: targetUID,
                previousUID: previousUID,
                registration: registration
            )

        case .attemptedButUnproved(let signalSequence):
            if var activeLease {
                activeLease.acceptedSignalSequence =
                    signalSequence
                self.activeLease = activeLease
            }
            let restoreResult =
                bestEffortRestoreAfterFailedAcquire(
                    previousUID: previousUID,
                    targetUID: targetUID,
                    expectedSignalSequence:
                        signalSequence,
                    registration: registration
                )
            switch restoreResult {
            case .proved(_),
                 .prewriteFenceFailed,
                 .prewriteInputChanged,
                 .contentionDetected(_):
                activeLease = nil
                markTerminal(generation)
                _ = beginDeregistration(
                    generation: generation,
                    registration: registration,
                    completion: .terminalized
                )

            case .prewriteReadFailed,
                 .failedWithoutMutation,
                 .attemptedButUnproved(_):
                markTerminal(generation)
            }
            return .terminalFailure
        }
    }

    private func installRegistration(
        generation: UInt64
    ) throws -> Registration {
        let signal = ChangeSignal()
        let registrationID = UUID()
        var address = Self.defaultInputAddress
        let listener = CoreAudioPropertyListenerRegistration {
            [weak self, signal] _, _ in
            let signalSequence = signal.record()
            self?.operationQueue.async { [weak self] in
                self?.defaultInputDidChange(
                    generation: generation,
                    registrationID: registrationID,
                    signalSequence: signalSequence
                )
            }
        }
        let status = operations.addDefaultInputListener(
            address: &address,
            queue: listenerQueue,
            listener: listener
        )
        guard status == noErr else {
            throw CaptureError.audioDeviceConfiguration(
                "register default-input lease listener",
                status
            )
        }
        return Registration(
            id: registrationID,
            address: address,
            queue: listenerQueue,
            listener: listener,
            signal: signal
        )
    }

    private func defaultInputDidChange(
        generation: UInt64,
        registrationID: UUID,
        signalSequence: UInt64
    ) {
        guard var activeLease,
              activeLease.generation == generation,
              activeLease.registration.id
                == registrationID,
              signalSequence
                > activeLease.acceptedSignalSequence else {
            return
        }

        if safelyClassifyTargetRemoval(activeLease) {
            activeLease.acceptedSignalSequence =
                signalSequence
            activeLease.restoreUID = nil
            activeLease.ownsSelection = false
            activeLease.targetWasRemoved = true
            self.activeLease = activeLease
            clearRetryBaseline(for: generation)
            return
        }

        terminalize(
            activeLease,
            signalSequence: signalSequence
        )
    }

    private func releaseLocked(
        expectedGeneration: UInt64?
    ) -> BlackHoleDefaultInputLeaseReleaseResult {
        switch retryPendingDeregistration(
            expectedGeneration: expectedGeneration
        ) {
        case .none:
            break

        case .retryableFailure:
            return .retryableFailure

        case .completed(let completed):
            switch completed.completion {
            case .released:
                return .released

            case .externallySuperseded:
                return .externallySuperseded

            case .retryableAcquisition,
                 .terminalized:
                break
            }
        }

        guard var activeLease else {
            if let expectedGeneration {
                clearRetryBaseline(
                    for: expectedGeneration
                )
                if terminalGeneration == expectedGeneration {
                    terminalGeneration = nil
                    retireGeneration(expectedGeneration)
                    return .externallySuperseded
                }
                retireGeneration(expectedGeneration)
            } else if let terminalGeneration {
                self.terminalGeneration = nil
                retireGeneration(terminalGeneration)
                return .externallySuperseded
            }
            return .released
        }
        if let expectedGeneration,
           activeLease.generation != expectedGeneration {
            return .released
        }

        if activeLease.targetWasRemoved
            || !activeLease.ownsSelection
            || activeLease.restoreUID == nil {
            return finishRelease(
                activeLease,
                result: .released
            )
        }

        guard let restoreUID = activeLease.restoreUID else {
            return .retryableFailure
        }

        for attempt in 0..<maximumRestoreAttemptCount {
            guard let currentUID =
                    currentDefaultInputUIDWithRetries() else {
                if attempt + 1
                    < maximumRestoreAttemptCount {
                    continue
                }
                self.activeLease = activeLease
                return .retryableFailure
            }

            if currentUID == restoreUID {
                return finishRelease(
                    activeLease,
                    result: .released
                )
            }

            guard currentUID == activeLease.targetUID else {
                if safelyClassifyTargetRemoval(
                    activeLease,
                    currentUID: currentUID
                ) {
                    activeLease.targetWasRemoved = true
                    activeLease.restoreUID = nil
                    activeLease.ownsSelection = false
                    return finishRelease(
                        activeLease,
                        result: .released
                    )
                }

                return finishRelease(
                    activeLease,
                    result: .externallySuperseded
                )
            }

            let restoreDeviceID: AudioDeviceID
            do {
                restoreDeviceID =
                    try operations.resolveDeviceID(
                        uid: restoreUID
                    )
            } catch {
                if attempt + 1
                    < maximumRestoreAttemptCount {
                    continue
                }
                self.activeLease = activeLease
                return .retryableFailure
            }

            switch writeAndProve(
                deviceID: restoreDeviceID,
                expectedCurrentUID:
                    activeLease.targetUID,
                expectedUID: restoreUID,
                expectedSignalSequence:
                    activeLease.acceptedSignalSequence,
                registration: activeLease.registration
            ) {
            case .proved(_):
                return finishRelease(
                    activeLease,
                    result: .released
                )

            case .failedWithoutMutation,
                 .prewriteReadFailed:
                continue

            case .prewriteFenceFailed,
                 .prewriteInputChanged:
                if let observedUID =
                        currentDefaultInputUIDWithRetries(),
                   safelyClassifyTargetRemoval(
                    activeLease,
                    currentUID: observedUID
                   ) {
                    return finishRelease(
                        activeLease,
                        result: .released
                    )
                }

                return finishRelease(
                    activeLease,
                    result: .externallySuperseded
                )

            case .contentionDetected:
                return finishRelease(
                    activeLease,
                    result: .externallySuperseded
                )

            case .attemptedButUnproved(let signalSequence):
                activeLease.acceptedSignalSequence =
                    signalSequence
                self.activeLease = activeLease
                if currentDefaultInputUIDWithRetries()
                    == restoreUID {
                    return finishRelease(
                        activeLease,
                        result: .released
                    )
                }
            }
        }

        self.activeLease = activeLease
        return .retryableFailure
    }

    private func bestEffortRestoreAfterFailedAcquire(
        previousUID: String,
        targetUID: String,
        expectedSignalSequence: UInt64,
        registration: Registration
    ) -> WriteAndProveResult {
        guard previousUID != targetUID else {
            return .proved(
                signalSequence:
                    expectedSignalSequence
            )
        }
        guard let previousDeviceID =
                try? operations.resolveDeviceID(
                    uid: previousUID
                ) else {
            return .prewriteReadFailed
        }

        return writeAndProve(
            deviceID: previousDeviceID,
            expectedCurrentUID: targetUID,
            expectedUID: previousUID,
            expectedSignalSequence:
                expectedSignalSequence,
            registration: registration
        )
    }

    private func writeAndProve(
        deviceID: AudioDeviceID,
        expectedCurrentUID: String,
        expectedUID: String,
        expectedSignalSequence: UInt64,
        registration: Registration
    ) -> WriteAndProveResult {
        guard deviceID != kAudioObjectUnknown else {
            return .prewriteFenceFailed
        }

        switch currentInputFenceResult(
            expectedUID: expectedCurrentUID,
            expectedSignalSequence:
                expectedSignalSequence,
            registration: registration
        ) {
        case .matched:
            break
        case .changed:
            return .prewriteFenceFailed
        case .unreadable:
            return .prewriteReadFailed
        }

        let mutation = operations
            .compareAndSetDefaultInputDevice(
                deviceID,
                expectedCurrentUID:
                    expectedCurrentUID
            )
        switch mutation {
        case .currentInputMismatch:
            return .prewriteInputChanged
        case .readFailed:
            return .prewriteReadFailed
        case .written(let status):
            guard status == noErr else {
                _ = registration.signal.waitForAdvance(
                    after: expectedSignalSequence,
                    timeout: proofTimeout
                )
                drainListenerQueue(registration)
                let signalSequence =
                    registration.signal.snapshot()
                guard signalSequence
                        == expectedSignalSequence else {
                    return .contentionDetected(
                        signalSequence: signalSequence
                    )
                }
                switch currentInputFenceResult(
                    expectedUID: expectedCurrentUID,
                    expectedSignalSequence:
                        expectedSignalSequence,
                    registration: registration
                ) {
                case .matched:
                    return .failedWithoutMutation
                case .changed:
                    return .contentionDetected(
                        signalSequence:
                            registration.signal.snapshot()
                    )
                case .unreadable:
                    return .attemptedButUnproved(
                        signalSequence:
                            registration.signal.snapshot()
                    )
                }
            }
        }

        // Core Audio exposes no atomic compare-and-set primitive. The system
        // operation performs the narrowest available compare immediately before
        // this input-only write, while this exact listener sequence and readback
        // reject every observable overlapping mutation.
        let expectedProofSequence =
            Self.nextSignalSequence(
                after: expectedSignalSequence
            )
        guard registration.signal.waitForAdvance(
            after: expectedSignalSequence,
            timeout: proofTimeout
        ) else {
            drainListenerQueue(registration)
            let signalSequence =
                registration.signal.snapshot()
            guard signalSequence == expectedSignalSequence
                    || signalSequence == expectedProofSequence else {
                return .contentionDetected(
                    signalSequence: signalSequence
                )
            }
            return .attemptedButUnproved(
                signalSequence: signalSequence
            )
        }

        let deadline = Date().addingTimeInterval(
            proofTimeout
        )
        repeat {
            drainListenerQueue(registration)
            let proofSequence =
                registration.signal.snapshot()
            guard proofSequence == expectedProofSequence else {
                return .contentionDetected(
                    signalSequence: proofSequence
                )
            }
            if currentInputFenceResult(
                expectedUID: expectedUID,
                expectedSignalSequence:
                    proofSequence,
                registration: registration
            ) == .matched {
                return .proved(
                    signalSequence: proofSequence
                )
            }
            Thread.sleep(forTimeInterval: 0.005)
        } while Date() < deadline
        drainListenerQueue(registration)
        let signalSequence =
            registration.signal.snapshot()
        guard signalSequence == expectedProofSequence else {
            return .contentionDetected(
                signalSequence: signalSequence
            )
        }
        return .attemptedButUnproved(
            signalSequence: signalSequence
        )
    }

    private func removeRegistration(
        _ registration: Registration
    ) -> Bool {
        drainListenerQueue(registration)
        for attempt in 0..<maximumListenerRemovalAttemptCount {
            var address = registration.address
            let status =
                operations.removeDefaultInputListener(
                    address: &address,
                    queue: registration.queue,
                    listener: registration.listener
                )
            if status == noErr {
                drainListenerQueue(registration)
                return true
            }
            if attempt + 1
                < maximumListenerRemovalAttemptCount {
                Thread.sleep(
                    forTimeInterval: 0.005
                )
            }
        }
        drainListenerQueue(registration)
        return false
    }

    @discardableResult
    private func beginDeregistration(
        generation: UInt64,
        registration: Registration,
        completion: PendingDeregistrationCompletion
    ) -> Bool {
        guard pendingDeregistration == nil else {
            return false
        }

        let pending = PendingDeregistration(
            generation: generation,
            registration: registration,
            completion: completion
        )
        if removeRegistration(registration) {
            finalizeDeregistration(pending)
            return true
        }

        pendingDeregistration = pending
        return false
    }

    private func retryPendingDeregistration(
        expectedGeneration: UInt64?
    ) -> PendingDeregistrationRetryResult {
        guard let pendingDeregistration else {
            return .none
        }
        if let expectedGeneration,
           pendingDeregistration.generation
                != expectedGeneration {
            return .none
        }
        guard removeRegistration(
            pendingDeregistration.registration
        ) else {
            return .retryableFailure
        }

        self.pendingDeregistration = nil
        finalizeDeregistration(pendingDeregistration)
        return .completed(pendingDeregistration)
    }

    private func finalizeDeregistration(
        _ pending: PendingDeregistration
    ) {
        switch pending.completion {
        case .retryableAcquisition,
             .terminalized:
            break

        case .released:
            clearRetryBaseline(
                for: pending.generation
            )
            retireGeneration(pending.generation)

        case .externallySuperseded:
            if terminalGeneration == pending.generation {
                terminalGeneration = nil
            }
            clearRetryBaseline(
                for: pending.generation
            )
            retireGeneration(pending.generation)
        }
    }

    private func updatePendingDeregistration(
        generation: UInt64,
        registration: Registration,
        completion: PendingDeregistrationCompletion
    ) {
        guard let pendingDeregistration,
              pendingDeregistration.generation
                == generation,
              pendingDeregistration.registration.id
                == registration.id else {
            return
        }

        self.pendingDeregistration =
            PendingDeregistration(
                generation: generation,
                registration: registration,
                completion: completion
            )
    }

    private func finishRelease(
        _ activeLease: ActiveLease,
        result: BlackHoleDefaultInputLeaseReleaseResult
    ) -> BlackHoleDefaultInputLeaseReleaseResult {
        self.activeLease = nil

        let completion: PendingDeregistrationCompletion
        switch result {
        case .released:
            clearRetryBaseline(
                for: activeLease.generation
            )
            completion = .released

        case .externallySuperseded:
            markTerminal(activeLease.generation)
            completion = .externallySuperseded

        case .retryableFailure:
            self.activeLease = activeLease
            return .retryableFailure
        }

        return beginDeregistration(
            generation: activeLease.generation,
            registration: activeLease.registration,
            completion: completion
        )
            ? result
            : .retryableFailure
    }

    private func drainListenerQueue(
        _ registration: Registration
    ) {
        registration.queue.sync {}
    }

    private func currentInputFenceResult(
        expectedUID: String,
        expectedSignalSequence: UInt64,
        registration: Registration
    ) -> CurrentInputFenceResult {
        drainListenerQueue(registration)
        guard registration.signal.snapshot()
                == expectedSignalSequence else {
            return .changed
        }

        let firstUID: String
        do {
            firstUID =
                try operations.currentDefaultInputUID()
        } catch {
            return .unreadable
        }
        guard firstUID == expectedUID else {
            return .changed
        }

        drainListenerQueue(registration)
        guard registration.signal.snapshot()
                == expectedSignalSequence else {
            return .changed
        }

        let secondUID: String
        do {
            secondUID =
                try operations.currentDefaultInputUID()
        } catch {
            return .unreadable
        }
        guard secondUID == expectedUID else {
            return .changed
        }

        drainListenerQueue(registration)
        return registration.signal.snapshot()
                == expectedSignalSequence
            ? .matched
            : .changed
    }

    private func currentDefaultInputUIDWithRetries()
        -> String? {
        for attempt in 0..<maximumReadAttemptCount {
            do {
                return try operations
                    .currentDefaultInputUID()
            } catch {
                if attempt + 1
                    < maximumReadAttemptCount {
                    Thread.sleep(
                        forTimeInterval: 0.005
                    )
                }
            }
        }
        return nil
    }

    private func safelyClassifyTargetRemoval(
        _ activeLease: ActiveLease,
        currentUID: String? = nil
    ) -> Bool {
        guard let restoreUID =
                activeLease.restoreUID,
              let currentUID =
                currentUID
                    ?? currentDefaultInputUIDWithRetries(),
              currentUID == restoreUID else {
            return false
        }
        return (try? operations.resolveDeviceID(
            uid: activeLease.targetUID
        )) == nil
    }

    private func terminalize(
        _ activeLease: ActiveLease,
        signalSequence: UInt64
    ) {
        var activeLease = activeLease
        activeLease.acceptedSignalSequence =
            signalSequence
        activeLease.restoreUID = nil
        activeLease.ownsSelection = false
        activeLease.targetWasRemoved = false
        self.activeLease = nil
        markTerminal(activeLease.generation)
        _ = beginDeregistration(
            generation: activeLease.generation,
            registration: activeLease.registration,
            completion: .terminalized
        )
    }

    private func terminalizeBeforeWrite(
        generation: UInt64,
        registration: Registration
    ) {
        clearRetryBaseline(for: generation)
        markTerminal(generation)
        activeLease = nil
        _ = beginDeregistration(
            generation: generation,
            registration: registration,
            completion: .terminalized
        )
    }

    private func finishPrewriteFailure(
        generation: UInt64,
        targetUID: String,
        previousUID: String,
        registration: Registration
    ) -> BlackHoleDefaultInputLeaseAcquisitionResult {
        switch currentInputFenceResult(
            expectedUID: previousUID,
            expectedSignalSequence: 0,
            registration: registration
        ) {
        case .matched:
            break

        case .changed:
            terminalizeBeforeWrite(
                generation: generation,
                registration: registration
            )
            return .terminalFailure

        case .unreadable:
            break
        }

        let deregistrationCompleted =
            beginDeregistration(
                generation: generation,
                registration: registration,
                completion: .retryableAcquisition
            )

        guard registration.signal.snapshot() == 0,
              currentDefaultInputUIDWithRetries()
                == previousUID else {
            clearRetryBaseline(for: generation)
            markTerminal(generation)
            if !deregistrationCompleted {
                updatePendingDeregistration(
                    generation: generation,
                    registration: registration,
                    completion: .terminalized
                )
            }
            return .terminalFailure
        }

        storeRetryBaseline(
            generation: generation,
            targetUID: targetUID,
            defaultInputUID: previousUID
        )
        return .retryableFailure
    }

    private func storeRetryBaseline(
        generation: UInt64,
        targetUID: String,
        defaultInputUID: String
    ) {
        retryBaseline = (
            generation: generation,
            value: RetryBaseline(
                targetUID: targetUID,
                defaultInputUID: defaultInputUID
            )
        )
    }

    private func clearRetryBaseline(
        for generation: UInt64
    ) {
        guard retryBaseline?.generation
                == generation else {
            return
        }
        retryBaseline = nil
    }

    private func markTerminal(
        _ generation: UInt64
    ) {
        terminalGeneration = generation
        clearRetryBaseline(for: generation)
    }

    private func retireGeneration(
        _ generation: UInt64
    ) {
        highestRetiredGeneration = max(
            highestRetiredGeneration,
            generation
        )
        clearRetryBaseline(for: generation)
    }

    private static func nextSignalSequence(
        after sequence: UInt64
    ) -> UInt64 {
        let next = sequence &+ 1
        return next == 0 ? 1 : next
    }

    private static func reportDegradedCleanup(
        _ message: String
    ) {
        guard let data = (message + "\n").data(
            using: .utf8
        ) else {
            return
        }
        FileHandle.standardError.write(data)
    }

    private func onOperationQueue<T>(
        _ body: () -> T
    ) -> T {
        if DispatchQueue.getSpecific(
            key: operationQueueKey
        ) == operationQueueToken {
            return body()
        }
        return operationQueue.sync(execute: body)
    }

    private static var defaultInputAddress:
        AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector:
                kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

private final class
    SystemBlackHoleDefaultInputLeaseOperations:
    BlackHoleDefaultInputLeaseOperations,
    @unchecked Sendable
{
    private let systemObject =
        AudioObjectID(kAudioObjectSystemObject)

    func addDefaultInputListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListenerRegistration
    ) -> OSStatus {
        AudioObjectAddPropertyListenerBlock(
            systemObject,
            &address,
            queue,
            listener.block
        )
    }

    func removeDefaultInputListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListenerRegistration
    ) -> OSStatus {
        AudioObjectRemovePropertyListenerBlock(
            systemObject,
            &address,
            queue,
            listener.block
        )
    }

    func currentDefaultInputUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector:
                kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID =
            AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(
            MemoryLayout<AudioDeviceID>.size
        )
        let status = AudioObjectGetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr,
              deviceID != kAudioObjectUnknown,
              let uid = deviceUID(deviceID),
              !uid.isEmpty else {
            throw CaptureError.audioDeviceConfiguration(
                "read default input stable UID",
                status
            )
        }
        return uid
    }

    func resolveDeviceID(
        uid: String
    ) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector:
                kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier: CFString = uid as CFString
        var deviceID =
            AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(
            MemoryLayout<AudioDeviceID>.size
        )
        let status = withUnsafePointer(
            to: &qualifier
        ) { pointer in
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
              deviceUID(deviceID) == uid else {
            throw CaptureError.audioDeviceConfiguration(
                "translate stable UID to input device",
                status
            )
        }
        return deviceID
    }

    func compareAndSetDefaultInputDevice(
        _ deviceID: AudioDeviceID,
        expectedCurrentUID: String
    ) -> BlackHoleDefaultInputMutationResult {
        do {
            guard try currentDefaultInputUID()
                    == expectedCurrentUID else {
                return .currentInputMismatch
            }
        } catch {
            return .readFailed
        }

        // Core Audio has no atomic compare-and-set for the default input. Keep
        // the comparison immediately adjacent to the input-only write; the
        // caller's exact listener sequence and readback detect every observable
        // mutation that overlaps this narrow residual window.
        var deviceID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector:
                kAudioHardwarePropertyDefaultInputDevice,
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
                &deviceID
            )
        )
    }

    private func deviceUID(
        _ deviceID: AudioDeviceID
    ) -> String? {
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector:
                kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(
            to: &value
        ) {
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                $0
            )
        }
        guard status == noErr else {
            return nil
        }
        return value as String
    }
}
