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
