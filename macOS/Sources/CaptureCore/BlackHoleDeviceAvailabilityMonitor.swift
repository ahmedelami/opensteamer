import CoreAudio
import Foundation

/// Observes Core Audio's device inventory without changing any default route.
///
/// The listener is registered before the initial inventory read. Every successful
/// start receives a fresh epoch, and every distinct identity state in that epoch
/// receives a strictly increasing generation. Factual absence publishes unavailable;
/// transient inventory failures preserve the last factual state and keep one token-fenced retry outstanding until a factual read, stop, or newer event.
public final class BlackHoleDeviceAvailabilityMonitor: @unchecked Sendable {
    public typealias Observer =
        @Sendable (BlackHoleDeviceAvailabilitySnapshot) -> Void
    public typealias UncertaintyObserver =
        @Sendable (_ monitorEpoch: UUID, _ eventSequence: UInt64) -> Void

    typealias InventoryRetryScheduler =
        @Sendable (@escaping @Sendable () -> Void) -> Void

    private struct InventoryRetry {
        let epoch: UUID
        let token: UUID
    }

    /// Advances on the dedicated HAL listener queue before inventory refresh is
    /// dispatched to the monitor queue. Inventory publication compares this
    /// sequence across the complete endpoint-pair read so a device-list change
    /// observed during that read is never admitted as one factual generation.
    private final class InventoryChangeSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var sequence: UInt64 = 0
        private var isActive = true

        /// Serializes active-state revocation with the synchronous uncertainty
        /// notification. Once `deactivate()` returns, an old registration can
        /// no longer notify a caller that may already own a replacement gate.
        @discardableResult
        func recordAndNotifyIfActive(
            _ notify: (UInt64) -> Void
        ) -> Bool {
            lock.withLock {
                guard isActive else { return false }
                sequence &+= 1
                if sequence == 0 {
                    sequence = 1
                }
                notify(sequence)
                return true
            }
        }

        func snapshot() -> UInt64 {
            lock.withLock { sequence }
        }

        func deactivate() {
            lock.withLock {
                isActive = false
            }
        }
    }

    private struct Registration: @unchecked Sendable {
        let id: UUID
        var address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let listener: CoreAudioPropertyListenerRegistration
        let inventoryChangeSignal: InventoryChangeSignal
        let epoch: UUID
    }

    private let operations:
        any BlackHoleDeviceAvailabilityMonitoringOperations
    private let callbackQueue: DispatchQueue
    private let listenerQueue: DispatchQueue
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
    private var lastPublishedInventoryChangeSequence: UInt64?
    private var latestSnapshot: BlackHoleDeviceAvailabilitySnapshot?
    private var inventoryRetry: InventoryRetry?
    private var deferredCleanupIDs: Set<UUID> = []
    private let maximumListenerRemovalAttemptCount = 3

    public convenience init() {
        let callbackQueue = DispatchQueue(
            label: "opensteamer.BlackHoleDeviceAvailabilityMonitor"
        )
        let listenerQueue = DispatchQueue(
            label: "opensteamer.BlackHoleDeviceAvailabilityMonitor.listener"
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
            },
            listenerQueue: listenerQueue
        )
    }

    convenience init(
        operations:
            any BlackHoleDeviceAvailabilityMonitoringOperations,
        callbackQueue: DispatchQueue,
        makeEpoch: @escaping @Sendable () -> UUID,
        listenerCleanupRetainer:
            any BlackHoleDeviceAvailabilityListenerCleanupRetaining =
                BlackHoleDeviceAvailabilityListenerCleanupRetainer.shared,
        listenerQueue: DispatchQueue? = nil
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
                listenerCleanupRetainer,
            listenerQueue: listenerQueue
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
                BlackHoleDeviceAvailabilityListenerCleanupRetainer.shared,
        listenerQueue: DispatchQueue? = nil
    ) {
        self.operations = operations
        self.callbackQueue = callbackQueue
        self.listenerQueue = listenerQueue ?? callbackQueue
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
        try start(
            onUncertain: { _, _ in },
            observer: observer
        )
    }

    /// Registers the raw device-list uncertainty callback before reading the
    /// initial pair. `onUncertain` runs synchronously on the HAL listener
    /// queue, before refresh dispatch, so callers can revoke realtime writer
    /// authorization without waiting for an actor hop. It must remain
    /// nonblocking and must not reenter this monitor's lifecycle methods.
    @discardableResult
    public func start(
        onUncertain: @escaping UncertaintyObserver,
        observer: @escaping Observer
    ) throws -> UUID {
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
            lastPublishedInventoryChangeSequence = nil
            latestSnapshot = nil
            inventoryRetry = nil
            self.observer = observer

            var address = Self.devicesAddress
            let inventoryChangeSignal = InventoryChangeSignal()
            let listener = CoreAudioPropertyListenerRegistration {
                [weak self, inventoryChangeSignal] _, _ in
                guard inventoryChangeSignal.recordAndNotifyIfActive({
                    eventSequence in
                    onUncertain(epoch, eventSequence)
                }) else {
                    return
                }
                self?.devicesDidChange(epoch: epoch)
            }
            let status = operations.addDevicesListener(
                address: &address,
                queue: listenerQueue,
                listener: listener
            )
            guard status == noErr else {
                inventoryChangeSignal.deactivate()
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
                queue: listenerQueue,
                listener: listener,
                inventoryChangeSignal: inventoryChangeSignal,
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
            lastPublishedInventoryChangeSequence = nil
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
            registration.inventoryChangeSignal.deactivate()
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
        lastPublishedInventoryChangeSequence = nil
        latestSnapshot = nil
        inventoryRetry = nil
        guard let registration else { return }
        registration.inventoryChangeSignal.deactivate()
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

    /// Synchronously re-resolves and validates both exact endpoints without
    /// waiting for a global Core Audio device-list notification.
    ///
    /// A factual topology change publishes a new generation before this call
    /// returns. A transient property-read failure is explicit, preserves the
    /// last factual snapshot for diagnostics, and schedules the same
    /// token-fenced retry used by callbacks. An inactive monitor performs no
    /// inventory read.
    @discardableResult
    public func revalidateCurrentSnapshot()
        -> BlackHoleDeviceAvailabilityRevalidationResult {
        onCallbackQueue {
            guard let epoch = currentEpoch,
                  registration?.epoch == epoch else {
                return .inactive
            }
            guard refreshInventory(
                epoch: epoch,
                invalidatesPendingRetry: true
            ) else {
                return .validationFailed
            }
            guard let latestSnapshot,
                  latestSnapshot.monitorEpoch == epoch else {
                return .validationFailed
            }
            return .validated(latestSnapshot)
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

    @discardableResult
    private func refreshInventory(
        epoch: UUID,
        invalidatesPendingRetry: Bool
    ) -> Bool {
        guard currentEpoch == epoch,
              let registration,
              registration.epoch == epoch else {
            return false
        }

        if invalidatesPendingRetry {
            inventoryRetry = nil
        }

        drainListenerQueueIfNeeded(registration)
        let initialInventoryChangeSequence =
            registration.inventoryChangeSignal.snapshot()

        var resolvedEndpointPair: BlackHoleDeviceEndpointPair?
        var resolutionError: (any Error)?
        do {
            resolvedEndpointPair = try operations
                .resolveBlackHole2ChannelEndpointPair()
        } catch {
            resolutionError = error
        }

        drainListenerQueueIfNeeded(registration)
        guard registration.inventoryChangeSignal.snapshot()
                == initialInventoryChangeSequence else {
            scheduleInventoryRetryIfNeeded(
                epoch: epoch
            )
            return false
        }

        let endpointPair: BlackHoleDeviceEndpointPair?
        if let resolutionError {
            guard Self.isFactualDeviceAbsence(resolutionError) else {
                scheduleInventoryRetryIfNeeded(
                    epoch: epoch
                )
                return false
            }
            endpointPair = nil
        } else {
            guard let resolvedEndpointPair else {
                scheduleInventoryRetryIfNeeded(
                    epoch: epoch
                )
                return false
            }
            endpointPair = resolvedEndpointPair
        }

        inventoryRetry = nil

        let isAvailable = endpointPair != nil
        let inventorySequenceAdvanced =
            lastPublishedInventoryChangeSequence.map {
                $0 != initialInventoryChangeSequence
            } ?? false
        if let latestSnapshot,
           latestSnapshot.isAvailable == isAvailable,
           latestSnapshot.defaultInputEndpoint
                == endpointPair?.defaultInputEndpoint,
           latestSnapshot.hiddenMirrorSinkEndpoint
                == endpointPair?.hiddenMirrorSinkEndpoint,
           !inventorySequenceAdvanced {
            return true
        }

        nextDeviceGeneration &+= 1
        if nextDeviceGeneration == 0 {
            nextDeviceGeneration = 1
        }
        // AudioDeviceID is opaque and may be reused after endpoint
        // recreation. The device-list signal is therefore part of the
        // incarnation evidence even when the resolved IDs and properties are
        // byte-for-byte identical to the preceding snapshot.
        lastPublishedInventoryChangeSequence =
            initialInventoryChangeSequence

        if let endpointPair {
            publishIfCurrent(
                BlackHoleDeviceAvailabilitySnapshot(
                    monitorEpoch: epoch,
                    deviceGeneration: nextDeviceGeneration,
                    defaultInputEndpoint:
                        endpointPair.defaultInputEndpoint,
                    hiddenMirrorSinkEndpoint:
                        endpointPair.hiddenMirrorSinkEndpoint,
                    acceptedInventoryChangeSequence:
                        initialInventoryChangeSequence
                )
            )
        } else {
            publishIfCurrent(
                BlackHoleDeviceAvailabilitySnapshot(
                    monitorEpoch: epoch,
                    deviceGeneration: nextDeviceGeneration,
                    isAvailable: false,
                    deviceUID: nil,
                    acceptedInventoryChangeSequence:
                        initialInventoryChangeSequence
                )
            )
        }
        return true
    }

    /// Production registers on a distinct listener queue so callbacks can
    /// advance the sequence while the monitor queue is resolving properties.
    /// Tests may deliberately reuse the callback queue to exercise legacy
    /// synchronous delivery; synchronizing that same queue would deadlock.
    private func drainListenerQueueIfNeeded(
        _ registration: Registration
    ) {
        guard registration.queue !== callbackQueue else {
            return
        }
        registration.queue.sync {}
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

    func resolveBlackHole2ChannelEndpointPair() throws
        -> BlackHoleDeviceEndpointPair
}

struct BlackHoleDeviceEndpointProperties: Equatable, Sendable {
    let identity: BlackHoleDeviceEndpointIdentity
    let modelUID: String
    let isAlive: Bool
    let isHidden: Bool
    let inputChannelCount: UInt32
    let outputChannelCount: UInt32
    let nominalSampleRate: Double
    let clockDomain: UInt32
    /// Every public Core Audio stream object in this endpoint's active role
    /// scope. Pair admission requires exactly one and validates both of that
    /// stream object's exact ASBDs.
    let roleStreams: [BlackHoleDeviceRoleStreamProperties]
}

/// Value-semantic copy of every field in one AudioStreamBasicDescription.
/// Keeping this in the full endpoint observation makes virtual/physical
/// format changes participate in the existing two-pass stability fence.
struct BlackHoleDeviceStreamFormat: Equatable, Sendable {
    let sampleRate: Double
    let formatID: AudioFormatID
    let formatFlags: AudioFormatFlags
    let bytesPerPacket: UInt32
    let framesPerPacket: UInt32
    let bytesPerFrame: UInt32
    let channelsPerFrame: UInt32
    let bitsPerChannel: UInt32
    let reserved: UInt32

    init(
        sampleRate: Double,
        formatID: AudioFormatID,
        formatFlags: AudioFormatFlags,
        bytesPerPacket: UInt32,
        framesPerPacket: UInt32,
        bytesPerFrame: UInt32,
        channelsPerFrame: UInt32,
        bitsPerChannel: UInt32,
        reserved: UInt32
    ) {
        self.sampleRate = sampleRate
        self.formatID = formatID
        self.formatFlags = formatFlags
        self.bytesPerPacket = bytesPerPacket
        self.framesPerPacket = framesPerPacket
        self.bytesPerFrame = bytesPerFrame
        self.channelsPerFrame = channelsPerFrame
        self.bitsPerChannel = bitsPerChannel
        self.reserved = reserved
    }

    init(_ description: AudioStreamBasicDescription) {
        self.init(
            sampleRate: description.mSampleRate,
            formatID: description.mFormatID,
            formatFlags: description.mFormatFlags,
            bytesPerPacket: description.mBytesPerPacket,
            framesPerPacket: description.mFramesPerPacket,
            bytesPerFrame: description.mBytesPerFrame,
            channelsPerFrame: description.mChannelsPerFrame,
            bitsPerChannel: description.mBitsPerChannel,
            reserved: description.mReserved
        )
    }

    var isCanonicalNativeFloatPackedMono: Bool {
        sampleRate
            == WorldwideBlackHoleMicrophoneEndpointContract
                .nominalSampleRate
            && formatID == kAudioFormatLinearPCM
            && formatFlags == kAudioFormatFlagsNativeFloatPacked
            && bytesPerPacket == 4
            && framesPerPacket == 1
            && bytesPerFrame == 4
            && channelsPerFrame == 1
            && bitsPerChannel == 32
            && reserved == 0
    }
}

struct BlackHoleDeviceRoleStreamProperties: Equatable, Sendable {
    let streamID: AudioStreamID
    let virtualFormat: BlackHoleDeviceStreamFormat
    let physicalFormat: BlackHoleDeviceStreamFormat
}

protocol BlackHoleDeviceEndpointPropertyReading:
    AnyObject,
    Sendable
{
    /// Returns nil only when the exact stable UID does not currently resolve.
    /// Property-read failures throw so the monitor preserves its last factual
    /// snapshot and schedules a token-fenced retry.
    func endpointProperties(
        exactUID: String
    ) throws -> BlackHoleDeviceEndpointProperties?
}

struct BlackHoleDeviceEndpointPairResolver: Sendable {
    let propertyReader:
        any BlackHoleDeviceEndpointPropertyReading

    private struct EndpointPairObservation: Equatable {
        let defaultInput: BlackHoleDeviceEndpointProperties?
        let hiddenMirrorSink: BlackHoleDeviceEndpointProperties?
    }

    func resolveValidatedPair() throws
        -> BlackHoleDeviceEndpointPair {
        let first = try endpointPairObservation()
        let second = try endpointPairObservation()
        guard first == second else {
            throw CaptureError.audioRouteUnhealthy(
                "the exact BlackHole endpoint pair changed across consecutive validation passes"
            )
        }
        return try validatedPair(from: second)
    }

    private func endpointPairObservation() throws
        -> EndpointPairObservation {
        let defaultInput = try propertyReader.endpointProperties(
            exactUID:
                WorldwideBlackHoleMicrophoneEndpointContract
                    .visibleDefaultInputDeviceUID
        )
        let hiddenMirrorSink = try propertyReader.endpointProperties(
            exactUID:
                WorldwideBlackHoleMicrophoneEndpointContract
                    .hiddenMirrorSinkDeviceUID
        )
        return EndpointPairObservation(
            defaultInput: defaultInput,
            hiddenMirrorSink: hiddenMirrorSink
        )
    }

    private func validatedPair(
        from observation: EndpointPairObservation
    ) throws
        -> BlackHoleDeviceEndpointPair {
        guard let defaultInput = observation.defaultInput else {
            throw Self.invalidTopology(
                "the visible default-input endpoint is absent"
            )
        }
        guard let hiddenMirrorSink =
                observation.hiddenMirrorSink else {
            throw Self.invalidTopology(
                "the hidden mirror sink endpoint is absent"
            )
        }

        guard defaultInput.roleStreams.count == 1,
              hiddenMirrorSink.roleStreams.count == 1,
              let defaultInputRoleStream =
                defaultInput.roleStreams.first,
              let hiddenMirrorRoleStream =
                hiddenMirrorSink.roleStreams.first else {
            throw Self.invalidTopology(
                "each endpoint must expose exactly one stream object in its active role scope"
            )
        }

        guard defaultInput.identity.deviceID != kAudioObjectUnknown,
              hiddenMirrorSink.identity.deviceID != kAudioObjectUnknown,
              defaultInput.identity.deviceID
                != hiddenMirrorSink.identity.deviceID,
              defaultInput.identity.deviceUID
                == WorldwideBlackHoleMicrophoneEndpointContract
                    .visibleDefaultInputDeviceUID,
              hiddenMirrorSink.identity.deviceUID
                == WorldwideBlackHoleMicrophoneEndpointContract
                    .hiddenMirrorSinkDeviceUID,
              defaultInput.identity.deviceUID
                != hiddenMirrorSink.identity.deviceUID,
              defaultInput.modelUID
                == WorldwideBlackHoleMicrophoneEndpointContract
                    .modelUID,
              hiddenMirrorSink.modelUID
                == WorldwideBlackHoleMicrophoneEndpointContract
                    .modelUID,
              defaultInput.modelUID == hiddenMirrorSink.modelUID,
              defaultInput.isAlive,
              hiddenMirrorSink.isAlive,
              !defaultInput.isHidden,
              hiddenMirrorSink.isHidden,
              defaultInput.inputChannelCount
                == WorldwideBlackHoleMicrophoneEndpointContract
                    .visibleInputChannelCount,
              defaultInput.outputChannelCount
                == WorldwideBlackHoleMicrophoneEndpointContract
                    .visibleOutputChannelCount,
              hiddenMirrorSink.inputChannelCount
                == WorldwideBlackHoleMicrophoneEndpointContract
                    .hiddenInputChannelCount,
              hiddenMirrorSink.outputChannelCount
                == WorldwideBlackHoleMicrophoneEndpointContract
                    .hiddenOutputChannelCount,
              defaultInput.nominalSampleRate
                == WorldwideBlackHoleMicrophoneEndpointContract
                    .nominalSampleRate,
              hiddenMirrorSink.nominalSampleRate
                == WorldwideBlackHoleMicrophoneEndpointContract
                    .nominalSampleRate,
              defaultInput.clockDomain
                == WorldwideBlackHoleMicrophoneEndpointContract
                    .clockDomain,
              hiddenMirrorSink.clockDomain
                == WorldwideBlackHoleMicrophoneEndpointContract
                    .clockDomain,
              defaultInput.clockDomain == hiddenMirrorSink.clockDomain,
              defaultInputRoleStream.virtualFormat
                .isCanonicalNativeFloatPackedMono,
              defaultInputRoleStream.physicalFormat
                .isCanonicalNativeFloatPackedMono,
              defaultInputRoleStream.virtualFormat
                == defaultInputRoleStream.physicalFormat,
              hiddenMirrorRoleStream.virtualFormat
                .isCanonicalNativeFloatPackedMono,
              hiddenMirrorRoleStream.physicalFormat
                .isCanonicalNativeFloatPackedMono,
              hiddenMirrorRoleStream.virtualFormat
                == hiddenMirrorRoleStream.physicalFormat,
              defaultInputRoleStream.virtualFormat
                == hiddenMirrorRoleStream.virtualFormat,
              defaultInputRoleStream.physicalFormat
                == hiddenMirrorRoleStream.physicalFormat else {
            throw Self.invalidTopology(
                "the exact endpoint pair does not match the required model, liveness, visibility, role topology, sample rate, clock domain, exact native-Float packed-interleaved mono stream formats, and distinct-identity contract"
            )
        }

        return BlackHoleDeviceEndpointPair(
            defaultInputEndpoint: defaultInput.identity,
            hiddenMirrorSinkEndpoint: hiddenMirrorSink.identity
        )
    }

    private static func invalidTopology(
        _ detail: String
    ) -> CaptureError {
        CaptureError.audioDeviceNotFound(
            "validated opensteamer virtual-microphone topology: \(detail)"
        )
    }
}

private final class SystemBlackHoleDeviceEndpointPropertyReader:
    BlackHoleDeviceEndpointPropertyReading,
    @unchecked Sendable
{
    private let systemObject =
        AudioObjectID(kAudioObjectSystemObject)

    func endpointProperties(
        exactUID: String
    ) throws -> BlackHoleDeviceEndpointProperties? {
        guard let deviceID = try resolveDeviceID(
            exactUID: exactUID
        ) else {
            return nil
        }
        let roleScope: AudioObjectPropertyScope
        switch exactUID {
        case WorldwideBlackHoleMicrophoneEndpointContract
            .visibleDefaultInputDeviceUID:
            roleScope = kAudioDevicePropertyScopeInput
        case WorldwideBlackHoleMicrophoneEndpointContract
            .hiddenMirrorSinkDeviceUID:
            roleScope = kAudioDevicePropertyScopeOutput
        default:
            throw CaptureError.audioDeviceConfiguration(
                "select virtual-microphone endpoint role scope",
                kAudio_ParamError
            )
        }

        return BlackHoleDeviceEndpointProperties(
            identity: BlackHoleDeviceEndpointIdentity(
                deviceID: deviceID,
                deviceUID: try stringProperty(
                    deviceID,
                    selector: kAudioDevicePropertyDeviceUID,
                    operation: "read BlackHole endpoint stable UID"
                )
            ),
            modelUID: try stringProperty(
                deviceID,
                selector: kAudioDevicePropertyModelUID,
                operation: "read BlackHole endpoint model UID"
            ),
            isAlive: try uint32Property(
                deviceID,
                selector: kAudioDevicePropertyDeviceIsAlive,
                operation: "read BlackHole endpoint liveness"
            ) != 0,
            isHidden: try uint32Property(
                deviceID,
                selector: kAudioDevicePropertyIsHidden,
                operation: "read BlackHole endpoint visibility"
            ) != 0,
            inputChannelCount: try channelCount(
                deviceID,
                scope: kAudioDevicePropertyScopeInput,
                operationLabel: "input"
            ),
            outputChannelCount: try channelCount(
                deviceID,
                scope: kAudioDevicePropertyScopeOutput,
                operationLabel: "output"
            ),
            nominalSampleRate: try doubleProperty(
                deviceID,
                selector: kAudioDevicePropertyNominalSampleRate,
                operation: "read BlackHole endpoint nominal sample rate"
            ),
            clockDomain: try uint32Property(
                deviceID,
                selector: kAudioDevicePropertyClockDomain,
                operation: "read virtual-microphone endpoint clock domain"
            ),
            roleStreams: try roleStreamProperties(
                deviceID,
                scope: roleScope
            )
        )
    }

    private func resolveDeviceID(
        exactUID: String
    ) throws -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier: CFString = exactUID as CFString
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
        guard status == noErr else {
            throw CaptureError.audioDeviceConfiguration(
                "translate exact BlackHole endpoint stable UID",
                status
            )
        }
        guard deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    private func stringProperty(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        operation: String
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
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
        guard status == noErr else {
            throw CaptureError.audioDeviceConfiguration(
                operation,
                status
            )
        }
        return value as String
    }

    private func uint32Property(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        operation: String
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
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
                operation,
                status
            )
        }
        return value
    }

    private func doubleProperty(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        operation: String
    ) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
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
                operation,
                status
            )
        }
        return value
    }

    private func channelCount(
        _ deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        operationLabel: String
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &byteCount
        )
        guard status == noErr,
              byteCount >= UInt32(MemoryLayout<UInt32>.size) else {
            throw CaptureError.audioDeviceConfiguration(
                "read BlackHole endpoint \(operationLabel) stream-configuration size",
                status == noErr ? kAudio_ParamError : status
            )
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteCount),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }

        status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &byteCount,
            storage
        )
        guard status == noErr,
              byteCount >= UInt32(MemoryLayout<UInt32>.size) else {
            throw CaptureError.audioDeviceConfiguration(
                "read BlackHole endpoint \(operationLabel) stream configuration",
                status == noErr ? kAudio_ParamError : status
            )
        }

        let bufferCount = Int(storage.load(as: UInt32.self))
        guard let bufferOffset = MemoryLayout<AudioBufferList>.offset(
            of: \AudioBufferList.mBuffers
        ),
        bufferCount >= 0,
        bufferCount <= (Int.max - bufferOffset)
            / MemoryLayout<AudioBuffer>.stride,
        Int(byteCount) >= bufferOffset
            + bufferCount * MemoryLayout<AudioBuffer>.stride else {
            throw CaptureError.audioDeviceConfiguration(
                "validate BlackHole endpoint \(operationLabel) stream configuration",
                kAudio_ParamError
            )
        }

        let buffers = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self)
        )
        var total: UInt64 = 0
        for buffer in buffers {
            total += UInt64(buffer.mNumberChannels)
        }
        guard total <= UInt64(UInt32.max) else {
            throw CaptureError.audioDeviceConfiguration(
                "sum BlackHole endpoint \(operationLabel) channels",
                kAudio_ParamError
            )
        }
        return UInt32(total)
    }

    private func roleStreamProperties(
        _ deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) throws -> [BlackHoleDeviceRoleStreamProperties] {
        let streamIDs = try audioObjectIDs(
            deviceID,
            selector: kAudioDevicePropertyStreams,
            scope: scope,
            operation: "read virtual-microphone role stream objects"
        )
        return try streamIDs.map { streamID in
            BlackHoleDeviceRoleStreamProperties(
                streamID: AudioStreamID(streamID),
                virtualFormat: try streamFormat(
                    AudioStreamID(streamID),
                    selector: kAudioStreamPropertyVirtualFormat,
                    operation: "read virtual-microphone stream virtual format"
                ),
                physicalFormat: try streamFormat(
                    AudioStreamID(streamID),
                    selector: kAudioStreamPropertyPhysicalFormat,
                    operation: "read virtual-microphone stream physical format"
                )
            )
        }
    }

    private func audioObjectIDs(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        operation: String
    ) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            objectID,
            &address,
            0,
            nil,
            &byteCount
        )
        let stride = UInt32(MemoryLayout<AudioObjectID>.stride)
        guard status == noErr,
              byteCount % stride == 0 else {
            throw CaptureError.audioDeviceConfiguration(
                "\(operation) size",
                status == noErr ? kAudio_ParamError : status
            )
        }
        guard byteCount > 0 else {
            return []
        }

        var values = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(byteCount / stride)
        )
        status = values.withUnsafeMutableBytes { storage in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &byteCount,
                storage.baseAddress!
            )
        }
        guard status == noErr,
              byteCount == UInt32(values.count) * stride,
              values.allSatisfy({ $0 != kAudioObjectUnknown }) else {
            throw CaptureError.audioDeviceConfiguration(
                operation,
                status == noErr ? kAudio_ParamError : status
            )
        }
        return values
    }

    private func streamFormat(
        _ streamID: AudioStreamID,
        selector: AudioObjectPropertySelector,
        operation: String
    ) throws -> BlackHoleDeviceStreamFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var size = UInt32(
            MemoryLayout<AudioStreamBasicDescription>.size
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(streamID),
            &address,
            0,
            nil,
            &size,
            &description
        )
        guard status == noErr,
              size == UInt32(
                MemoryLayout<AudioStreamBasicDescription>.size
              ) else {
            throw CaptureError.audioDeviceConfiguration(
                operation,
                status == noErr ? kAudio_ParamError : status
            )
        }
        return BlackHoleDeviceStreamFormat(description)
    }
}

private final class SystemBlackHoleDeviceAvailabilityOperations:
    BlackHoleDeviceAvailabilityMonitoringOperations,
    @unchecked Sendable
{
    private let endpointPairResolver =
        BlackHoleDeviceEndpointPairResolver(
            propertyReader:
                SystemBlackHoleDeviceEndpointPropertyReader()
        )

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

    func resolveBlackHole2ChannelEndpointPair() throws
        -> BlackHoleDeviceEndpointPair {
        try endpointPairResolver.resolveValidatedPair()
    }
}
