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

/// Observes Core Audio's device inventory without changing any default route.
///
/// The listener is registered before the initial inventory read. Every successful
/// start receives a fresh epoch, and every read in that epoch receives a strictly
/// increasing generation. Lookup failures are published as unavailable.
public final class BlackHoleDeviceAvailabilityMonitor: @unchecked Sendable {
    public typealias Observer =
        @Sendable (BlackHoleDeviceAvailabilitySnapshot) -> Void

    private struct Registration {
        var address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let block: AudioObjectPropertyListenerBlock
        let epoch: UUID
    }

    private let operations:
        any BlackHoleDeviceAvailabilityMonitoringOperations
    private let callbackQueue: DispatchQueue
    private let makeEpoch: @Sendable () -> UUID
    private let queueKey = DispatchSpecificKey<UUID>()
    private let queueToken = UUID()

    private var registration: Registration?
    private var observer: Observer?
    private var currentEpoch: UUID?
    private var nextDeviceGeneration: UInt64 = 0
    private var lastPublishedGeneration: UInt64 = 0
    private var latestSnapshot: BlackHoleDeviceAvailabilitySnapshot?

    public convenience init() {
        self.init(
            operations: SystemBlackHoleDeviceAvailabilityOperations(),
            callbackQueue: DispatchQueue(
                label: "opensteamer.BlackHoleDeviceAvailabilityMonitor"
            ),
            makeEpoch: { UUID() }
        )
    }

    init(
        operations:
            any BlackHoleDeviceAvailabilityMonitoringOperations,
        callbackQueue: DispatchQueue,
        makeEpoch: @escaping @Sendable () -> UUID
    ) {
        self.operations = operations
        self.callbackQueue = callbackQueue
        self.makeEpoch = makeEpoch
        callbackQueue.setSpecific(
            key: queueKey,
            value: queueToken
        )
    }

    deinit {
        stop()
    }

    /// Registers the listener first, then publishes the initial inventory.
    @discardableResult
    public func start(observer: @escaping Observer) throws -> UUID {
        try onCallbackQueue {
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
            self.observer = observer

            var address = Self.devicesAddress
            let block: AudioObjectPropertyListenerBlock = {
                [weak self] _, _ in
                self?.devicesDidChange(epoch: epoch)
            }
            let status = operations.addDevicesListener(
                address: &address,
                queue: callbackQueue,
                block: block
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
                address: address,
                queue: callbackQueue,
                block: block,
                epoch: epoch
            )

            refreshInventory(epoch: epoch)
            return epoch
        }
    }

    /// Fences the current epoch before removing the exact listener registration.
    public func stop() {
        onCallbackQueue {
            currentEpoch = nil
            observer = nil
            nextDeviceGeneration = 0
            lastPublishedGeneration = 0
            latestSnapshot = nil

            guard let registration else { return }
            self.registration = nil
            var address = registration.address
            _ = operations.removeDevicesListener(
                address: &address,
                queue: registration.queue,
                block: registration.block
            )
        }
    }

    /// Returns the newest snapshot published by the current monitor epoch.
    public func currentSnapshot() -> BlackHoleDeviceAvailabilitySnapshot? {
        onCallbackQueue {
            latestSnapshot
        }
    }

    private func devicesDidChange(epoch: UUID) {
        if isOnCallbackQueue {
            refreshInventory(epoch: epoch)
        } else {
            callbackQueue.async { [weak self] in
                self?.refreshInventory(epoch: epoch)
            }
        }
    }

    private func refreshInventory(epoch: UUID) {
        guard currentEpoch == epoch,
              registration?.epoch == epoch else {
            return
        }

        nextDeviceGeneration &+= 1
        if nextDeviceGeneration == 0 {
            nextDeviceGeneration = 1
        }

        let uid: String?
        do {
            uid = try operations.resolveBlackHole2ChannelDeviceUID()
        } catch {
            uid = nil
        }

        publishIfCurrent(
            BlackHoleDeviceAvailabilitySnapshot(
                monitorEpoch: epoch,
                deviceGeneration: nextDeviceGeneration,
                isAvailable: uid != nil,
                deviceUID: uid
            )
        )
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

protocol BlackHoleDeviceAvailabilityMonitoringOperations:
    AnyObject,
    Sendable
{
    func addDevicesListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus

    func removeDevicesListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
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
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
    }

    func removeDevicesListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
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
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus

    func removeDefaultInputListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus

    func currentDefaultInputUID() throws -> String
    func resolveDeviceID(uid: String) throws -> AudioDeviceID
    func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> OSStatus
}

/// Owns one generation-bound, input-only Core Audio default selection.
///
/// The exact default-input listener is installed before every owned write. A write
/// succeeds only after both a listener notification and stable-UID readback. Release
/// restores a freshly resolved prior UID only while the current input remains the
/// lease's BlackHole target.
public final class BlackHoleDefaultInputLease:
    @unchecked Sendable
{
    public static let canonicalDeviceUID = "BlackHole2ch_UID"

    private final class ChangeSignal:
        @unchecked Sendable
    {
        private let condition = NSCondition()
        private var count: UInt64 = 0

        func record() {
            condition.lock()
            count &+= 1
            if count == 0 {
                count = 1
            }
            condition.broadcast()
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
    }

    private struct Registration {
        var address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let block: AudioObjectPropertyListenerBlock
        let signal: ChangeSignal
    }

    private struct ActiveLease {
        let generation: UInt64
        let targetUID: String
        let registration: Registration
        var restoreUID: String?
        var ownsSelection: Bool
    }

    private let operations:
        any BlackHoleDefaultInputLeaseOperations
    private let operationQueue: DispatchQueue
    private let listenerQueue: DispatchQueue
    private let proofTimeout: TimeInterval
    private let operationQueueKey =
        DispatchSpecificKey<UUID>()
    private let operationQueueToken = UUID()
    private var activeLease: ActiveLease?
    private var relinquishedGenerations: Set<UInt64> = []

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
        proofTimeout: TimeInterval
    ) {
        self.operations = operations
        self.operationQueue = operationQueue
        self.listenerQueue = listenerQueue
        self.proofTimeout = max(0.001, proofTimeout)
        operationQueue.setSpecific(
            key: operationQueueKey,
            value: operationQueueToken
        )
    }

    deinit {
        shutdown()
    }

    /// Selects the supplied stable UID for one current connection generation.
    @discardableResult
    public func acquire(
        generation: UInt64,
        targetUID: String =
            BlackHoleDefaultInputLease.canonicalDeviceUID
    ) -> Bool {
        onOperationQueue {
            acquireLocked(
                generation: generation,
                targetUID: targetUID
            )
        }
    }

    /// Releases only the exact generation supplied by its owner.
    public func release(generation: UInt64) {
        onOperationQueue {
            releaseLocked(expectedGeneration: generation)
        }
    }

    /// Releases any remaining generation during graceful owner teardown.
    public func shutdown() {
        onOperationQueue {
            releaseLocked(expectedGeneration: nil)
        }
    }

    #if DEBUG
    func drainForTesting() {
        onOperationQueue {}
    }
    #endif

    private func acquireLocked(
        generation: UInt64,
        targetUID: String
    ) -> Bool {
        guard generation > 0, !targetUID.isEmpty else {
            return false
        }
        guard !relinquishedGenerations.contains(generation) else {
            return false
        }

        if var activeLease,
           activeLease.generation == generation,
           activeLease.targetUID == targetUID {
            guard (try? operations.currentDefaultInputUID())
                    == targetUID else {
                relinquishedGenerations.insert(generation)
                activeLease.restoreUID = nil
                activeLease.ownsSelection = false
                self.activeLease = activeLease
                return false
            }
            return true
        }

        releaseLocked(expectedGeneration: nil)

        let registration: Registration
        do {
            registration = try installRegistration(
                generation: generation
            )
        } catch {
            return false
        }

        do {
            let previousUID =
                try operations.currentDefaultInputUID()
            let targetDeviceID =
                try operations.resolveDeviceID(uid: targetUID)

            if previousUID == targetUID {
                activeLease = ActiveLease(
                    generation: generation,
                    targetUID: targetUID,
                    registration: registration,
                    restoreUID: nil,
                    ownsSelection: false
                )
                return true
            }

            activeLease = ActiveLease(
                generation: generation,
                targetUID: targetUID,
                registration: registration,
                restoreUID: previousUID,
                ownsSelection: true
            )

            guard writeAndProve(
                deviceID: targetDeviceID,
                expectedUID: targetUID,
                registration: registration
            ) else {
                bestEffortRestoreAfterFailedAcquire(
                    previousUID: previousUID,
                    targetUID: targetUID,
                    registration: registration
                )
                // Retain uncertain ownership until its generation is released.
                return false
            }

            return true
        } catch {
            removeRegistration(registration)
            return false
        }
    }

    private func installRegistration(
        generation: UInt64
    ) throws -> Registration {
        let signal = ChangeSignal()
        var address = Self.defaultInputAddress
        let block: AudioObjectPropertyListenerBlock = {
            [weak self, signal] _, _ in
            signal.record()
            self?.operationQueue.async { [weak self] in
                self?.defaultInputDidChange(
                    generation: generation
                )
            }
        }
        let status = operations.addDefaultInputListener(
            address: &address,
            queue: listenerQueue,
            block: block
        )
        guard status == noErr else {
            throw CaptureError.audioDeviceConfiguration(
                "register default-input lease listener",
                status
            )
        }
        return Registration(
            address: address,
            queue: listenerQueue,
            block: block,
            signal: signal
        )
    }

    private func defaultInputDidChange(
        generation: UInt64
    ) {
        guard var activeLease,
              activeLease.generation == generation else {
            return
        }

        guard let currentUID =
                try? operations.currentDefaultInputUID(),
              currentUID != activeLease.targetUID else {
            return
        }

        // A newer user or application choice ends this lease's ownership.
        // The listener remains registered until the connection generation
        // releases, but this generation never reasserts BlackHole or
        // restores over the newer choice. If the user later selects
        // BlackHole manually, that selection also remains user-owned.
        relinquishedGenerations.insert(generation)
        activeLease.restoreUID = nil
        activeLease.ownsSelection = false
        self.activeLease = activeLease
    }

    private func releaseLocked(
        expectedGeneration: UInt64?
    ) {
        guard let activeLease else {
            return
        }
        if let expectedGeneration,
           activeLease.generation != expectedGeneration {
            return
        }

        self.activeLease = nil
        defer {
            removeRegistration(activeLease.registration)
        }

        guard activeLease.ownsSelection,
              let restoreUID = activeLease.restoreUID,
              let currentUID =
                try? operations.currentDefaultInputUID(),
              currentUID == activeLease.targetUID,
              let restoreDeviceID =
                try? operations.resolveDeviceID(
                    uid: restoreUID
                ),
              (try? operations.currentDefaultInputUID())
                == activeLease.targetUID else {
            return
        }

        _ = writeAndProve(
            deviceID: restoreDeviceID,
            expectedUID: restoreUID,
            registration: activeLease.registration
        )
    }

    private func bestEffortRestoreAfterFailedAcquire(
        previousUID: String,
        targetUID: String,
        registration: Registration
    ) {
        guard previousUID != targetUID,
              (try? operations.currentDefaultInputUID())
                == targetUID,
              let previousDeviceID =
                try? operations.resolveDeviceID(
                    uid: previousUID
                ),
              (try? operations.currentDefaultInputUID())
                == targetUID else {
            return
        }

        _ = writeAndProve(
            deviceID: previousDeviceID,
            expectedUID: previousUID,
            registration: registration
        )
    }

    private func writeAndProve(
        deviceID: AudioDeviceID,
        expectedUID: String,
        registration: Registration
    ) -> Bool {
        guard deviceID != kAudioObjectUnknown else {
            return false
        }

        let notificationBefore =
            registration.signal.snapshot()
        guard operations.setDefaultInputDevice(deviceID)
                == noErr else {
            return false
        }
        guard registration.signal.waitForAdvance(
            after: notificationBefore,
            timeout: proofTimeout
        ) else {
            return false
        }

        let deadline = Date().addingTimeInterval(
            proofTimeout
        )
        repeat {
            if (try? operations.currentDefaultInputUID())
                == expectedUID {
                return true
            }
            Thread.sleep(forTimeInterval: 0.005)
        } while Date() < deadline
        return false
    }

    private func removeRegistration(
        _ registration: Registration
    ) {
        var address = registration.address
        _ = operations.removeDefaultInputListener(
            address: &address,
            queue: registration.queue,
            block: registration.block
        )
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
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        AudioObjectAddPropertyListenerBlock(
            systemObject,
            &address,
            queue,
            block
        )
    }

    func removeDefaultInputListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        AudioObjectRemovePropertyListenerBlock(
            systemObject,
            &address,
            queue,
            block
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

    func setDefaultInputDevice(
        _ deviceID: AudioDeviceID
    ) -> OSStatus {
        var deviceID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector:
                kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
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
