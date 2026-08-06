import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation

/// One atomic observation of a Core Audio process object. Optional running values preserve
/// property-read failure as unknown instead of accidentally treating it as activity.
struct CoreAudioFaceTimeProcessActivitySnapshot: Equatable, Sendable {
    let processObjectID: AudioObjectID
    let bundleIdentifier: String?
    let hasRunningInputListener: Bool
    let hasRunningOutputListener: Bool
    let isRunningInput: Bool?
    let isRunningOutput: Bool?
}

/// One authoritative duplex scan. Unknown is distinct from a known empty active set so a native
/// read or listener failure can never masquerade as an inactive baseline.
enum CoreAudioFaceTimeDuplexActivityScan: Equatable, Sendable {
    case known(activeProcessObjectIDs: Set<AudioObjectID>)
    case unknown
}

/// Pure, fail-closed evidence policy for a Mac-hosted FaceTime call.
enum CoreAudioFaceTimeDuplexActivityPolicy {
    static let preferredMediaServiceBundleIdentifier =
        "com.apple.avconferenced"
    static let fallbackBundleIdentifiers: Set<String> = [
        "com.apple.FaceTime.FTConversationService",
        "com.apple.FaceTime",
    ]
    static let allowedBundleIdentifiers =
        fallbackBundleIdentifiers.union([
            preferredMediaServiceBundleIdentifier,
        ])

    static func scan(
        from snapshots: [CoreAudioFaceTimeProcessActivitySnapshot]?
    ) -> CoreAudioFaceTimeDuplexActivityScan {
        guard let snapshots else { return .unknown }
        var seenProcessObjectIDs: Set<AudioObjectID> = []
        var preferredProcessIsPresent = false
        var preferredActiveProcessObjectIDs: Set<AudioObjectID> = []
        var fallbackActiveProcessObjectIDs: Set<AudioObjectID> = []
        for snapshot in snapshots {
            guard snapshot.processObjectID != kAudioObjectUnknown,
                  seenProcessObjectIDs.insert(snapshot.processObjectID)
                    .inserted,
                  let bundleIdentifier = snapshot.bundleIdentifier else {
                return .unknown
            }
            guard allowedBundleIdentifiers.contains(bundleIdentifier) else {
                continue
            }
            guard snapshot.hasRunningInputListener,
                  snapshot.hasRunningOutputListener,
                  let isRunningInput = snapshot.isRunningInput,
                  let isRunningOutput = snapshot.isRunningOutput else {
                return .unknown
            }
            let isPreferred = bundleIdentifier
                == preferredMediaServiceBundleIdentifier
            preferredProcessIsPresent = preferredProcessIsPresent
                || isPreferred
            guard isRunningInput && isRunningOutput else { continue }
            if isPreferred {
                preferredActiveProcessObjectIDs.insert(
                    snapshot.processObjectID
                )
            } else {
                fallbackActiveProcessObjectIDs.insert(
                    snapshot.processObjectID
                )
            }
        }
        // macOS 26 may briefly expose FaceTime itself as duplex before the long-lived media
        // service owns the call. Once that exact service is in the authoritative inventory, do
        // not let the legacy fallback bind the epoch during the handoff window. Older systems
        // that do not expose the service continue to use the exact FaceTime bundle identifiers.
        return .known(
            activeProcessObjectIDs: preferredProcessIsPresent
                ? preferredActiveProcessObjectIDs
                : fallbackActiveProcessObjectIDs
        )
    }
}

/// Privacy-minimal state emitted by the causal epoch binder. Exact Core Audio process identity is
/// retained only inside the binder and never leaves CaptureCore.
struct CoreAudioFaceTimeCausalBindingUpdate: Equatable, Sendable {
    let challenge: SystemAudioMacFaceTimeActivityChallenge?
    let causalBindingID: UUID?
    let didPhaseChange: Bool
}

/// Binds one viewer call epoch only when a known-zero baseline is followed by exactly one duplex
/// FaceTime process. Once an epoch becomes ambiguous, it remains poisoned until a newer epoch.
struct CoreAudioFaceTimeCausalEpochBinder: Sendable {
    enum Phase: Equatable, Sendable {
        case noEpoch
        case armed
        case bound(
            processObjectID: AudioObjectID,
            causalBindingID: UUID
        )
        case poisoned
    }

    private(set) var currentChallenge:
        SystemAudioMacFaceTimeActivityChallenge?
    private(set) var phase: Phase = .noEpoch

    func acceptsChallenge(
        _ challenge: SystemAudioMacFaceTimeActivityChallenge
    ) -> Bool {
        guard let currentChallenge else { return true }
        return challenge.sequence > currentChallenge.sequence
    }

    /// A stale challenge is rejected before `authoritativeScan` runs. For an accepted challenge,
    /// the scan completes before challenge identity changes, preventing pre-existing activity from
    /// becoming a synthetic transition in a new epoch.
    mutating func installChallenge(
        _ challenge: SystemAudioMacFaceTimeActivityChallenge,
        authoritativeScan: () -> CoreAudioFaceTimeDuplexActivityScan,
        makeCausalBindingID: () -> UUID = UUID.init
    ) -> CoreAudioFaceTimeCausalBindingUpdate? {
        guard acceptsChallenge(challenge) else { return nil }
        let baseline = authoritativeScan()
        let previousPhase = phase
        let isSameEpoch = currentChallenge?.callEpochNonce
            == challenge.callEpochNonce

        if isSameEpoch {
            apply(
                baseline,
                makeCausalBindingID: makeCausalBindingID
            )
        } else {
            switch baseline {
            case .known(let activeProcessObjectIDs)
                where activeProcessObjectIDs.isEmpty:
                phase = .armed
            case .known, .unknown:
                phase = .poisoned
            }
        }
        currentChallenge = challenge
        return update(
            didPhaseChange: !isSameEpoch || phase != previousPhase
        )
    }

    mutating func observe(
        _ scan: CoreAudioFaceTimeDuplexActivityScan,
        makeCausalBindingID: () -> UUID = UUID.init
    ) -> CoreAudioFaceTimeCausalBindingUpdate? {
        guard currentChallenge != nil else { return nil }
        let previousPhase = phase
        apply(scan, makeCausalBindingID: makeCausalBindingID)
        return update(didPhaseChange: phase != previousPhase)
    }

    /// Revocation deliberately retains the last challenge only in the emitted result, then clears
    /// all binder state so no binding can survive a listener gap or native stop.
    mutating func revoke() -> CoreAudioFaceTimeCausalBindingUpdate {
        let revokedChallenge = currentChallenge
        let didPhaseChange = phase != .noEpoch
            || currentChallenge != nil
        currentChallenge = nil
        phase = .noEpoch
        return CoreAudioFaceTimeCausalBindingUpdate(
            challenge: revokedChallenge,
            causalBindingID: nil,
            didPhaseChange: didPhaseChange
        )
    }

    private mutating func apply(
        _ scan: CoreAudioFaceTimeDuplexActivityScan,
        makeCausalBindingID: () -> UUID
    ) {
        switch phase {
        case .noEpoch:
            return
        case .armed:
            switch scan {
            case .known(let activeProcessObjectIDs)
                where activeProcessObjectIDs.isEmpty:
                return
            case .known(let activeProcessObjectIDs)
                where activeProcessObjectIDs.count == 1:
                guard let processObjectID =
                    activeProcessObjectIDs.first else {
                    phase = .poisoned
                    return
                }
                phase = .bound(
                    processObjectID: processObjectID,
                    causalBindingID: makeCausalBindingID()
                )
            case .known, .unknown:
                phase = .poisoned
            }
        case .bound(let processObjectID, _):
            guard case .known(let activeProcessObjectIDs) = scan,
                  activeProcessObjectIDs == [processObjectID] else {
                phase = .poisoned
                return
            }
        case .poisoned:
            return
        }
    }

    private func update(
        didPhaseChange: Bool
    ) -> CoreAudioFaceTimeCausalBindingUpdate {
        let causalBindingID: UUID?
        if case .bound(_, let bindingID) = phase {
            causalBindingID = bindingID
        } else {
            causalBindingID = nil
        }
        return CoreAudioFaceTimeCausalBindingUpdate(
            challenge: currentChallenge,
            causalBindingID: causalBindingID,
            didPhaseChange: didPhaseChange
        )
    }
}

/// Read-only device evidence used to select the aggregate tap's clock source.
struct CoreAudioProcessTapClockDeviceSnapshot: Equatable, Sendable {
    let deviceID: AudioObjectID
    let uid: String
    let isAlive: Bool
    let isDefaultOutput: Bool
    let inputChannelCount: UInt32
    let outputChannelCount: UInt32
}

/// A clock subdevice must contribute no input channels to the tap aggregate. A duplex default
/// such as BlackHole is therefore never selected; another live output-only device is used or
/// startup fails closed.
enum CoreAudioProcessTapClockDeviceSelectionPolicy {
    static func select(
        from snapshots: [CoreAudioProcessTapClockDeviceSnapshot]
    ) -> CoreAudioProcessTapClockDeviceSnapshot? {
        snapshots
            .filter {
                $0.deviceID != kAudioObjectUnknown
                    && !$0.uid.isEmpty
                    && $0.isAlive
                    && $0.inputChannelCount == 0
                    && $0.outputChannelCount > 0
            }
            .min { lhs, rhs in
                if lhs.isDefaultOutput != rhs.isDefaultOutput {
                    return lhs.isDefaultOutput
                }
                if lhs.uid != rhs.uid {
                    return lhs.uid < rhs.uid
                }
                return lhs.deviceID < rhs.deviceID
            }
    }
}

/// Closes the startup race between the tap's first exclusion inventory and process-list listener
/// registration. Once the listener is installed, one more inventory covers every process launch
/// that happened in the gap; later launches are delivered through the listener.
enum CoreAudioProcessTapStartupExclusionFence {
    static func installListenerThenRefresh(
        installListener: () throws -> Void,
        refreshExclusions: () throws -> Void
    ) rethrows {
        try installListener()
        try refreshExclusions()
    }
}

/// The process-list listener is the only authoritative way to discover Core Audio process
/// objects created after startup on macOS 14.2 through 15.x. macOS 26 can instead restore the
/// exclusion by exact bundle identifier inside Core Audio itself.
enum CoreAudioProcessTapProcessListListenerPolicy {
    static func permitsCapture(
        listenerRegistrationStatus: OSStatus,
        bundleIdentifierRestorationAvailable: Bool
    ) -> Bool {
        listenerRegistrationStatus == noErr
            || bundleIdentifierRestorationAvailable
    }
}

/// Runs all native evidence and exclusion work independently from the PCM callback. Keeping the
/// inventory and property write in one `syncControl` operation also prevents an older inventory
/// from being applied after a newer one.
final class CoreAudioProcessTapQueueTopology: @unchecked Sendable {
    let ioCallbackQueue: DispatchQueue
    let controlQueue: DispatchQueue

    private let ioCallbackQueueKey = DispatchSpecificKey<Void>()
    private let controlQueueKey = DispatchSpecificKey<Void>()

    init(
        labelPrefix: String = "opensteamer.CoreAudioProcessTap",
        ioQoS: DispatchQoS = .userInteractive,
        controlQoS: DispatchQoS = .userInitiated
    ) {
        ioCallbackQueue = DispatchQueue(
            label: labelPrefix + ".PCM",
            qos: ioQoS
        )
        controlQueue = DispatchQueue(
            label: labelPrefix + ".Control",
            qos: controlQoS
        )
        ioCallbackQueue.setSpecific(
            key: ioCallbackQueueKey,
            value: ()
        )
        controlQueue.setSpecific(key: controlQueueKey, value: ())
    }

    func asyncControl(_ operation: @escaping @Sendable () -> Void) {
        controlQueue.async(execute: operation)
    }

    func syncControl<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        if DispatchQueue.getSpecific(key: controlQueueKey) != nil {
            return try operation()
        }
        return try controlQueue.sync(execute: operation)
    }

    /// Waits for every PCM callback admitted before the fence. Calling from the PCM queue is
    /// already inside that serialized callback stream and must not synchronously redispatch.
    func drainIOCallbacks() {
        guard DispatchQueue.getSpecific(key: ioCallbackQueueKey) == nil else {
            return
        }
        ioCallbackQueue.sync {}
    }
}

/// Publishes native resource identity only after listener installation, then guarantees that a
/// failing post-registration exclusion refresh rolls the publication back before the native
/// objects are destroyed by the caller.
enum CoreAudioProcessTapStartupTransaction {
    static func installListenerPublishAndRefresh(
        installListener: () throws -> Void,
        publishResources: () -> Void,
        refreshExclusions: () throws -> Void,
        rollbackPublishedResources: () -> Void
    ) rethrows {
        var didPublishResources = false
        do {
            try CoreAudioProcessTapStartupExclusionFence
                .installListenerThenRefresh(
                    installListener: {
                        try installListener()
                        publishResources()
                        didPublishResources = true
                    },
                    refreshExclusions: refreshExclusions
                )
        } catch {
            if didPublishResources {
                rollbackPublishedResources()
            }
            throw error
        }
    }
}

/// Captures the complete outgoing Core Audio process mix without changing the selected output
/// device. Unlike a display-associated ScreenCaptureKit mix, a global process tap also contains
/// audio rendered by headless services such as FaceTime's conversation process.
final class CoreAudioProcessTapSystemAudioSource: @unchecked Sendable {
    static var isSupported: Bool {
        if #available(macOS 14.2, *) {
            true
        } else {
            false
        }
    }

    private let consumer: any SystemAudioSampleConsumer
    private let logger: any Logger
    private let faceTimeDuplexActivityHandler:
        @Sendable (SystemAudioMacFaceTimeActivityObservation) -> Void
    private let queues = CoreAudioProcessTapQueueTopology()
    private let lock = NSLock()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUUID: UUID?
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false
    // Accessed only on queues.controlQueue.
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var faceTimeProcessListeners:
        [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var faceTimeCausalEpochBinder =
        CoreAudioFaceTimeCausalEpochBinder()
    private var nextFaceTimeObservationSequence: UInt64 = 1
    private var faceTimeHeartbeatTimer: DispatchSourceTimer?

    init(
        consumer: any SystemAudioSampleConsumer,
        logger: any Logger,
        faceTimeDuplexActivityHandler:
            @escaping @Sendable (
                SystemAudioMacFaceTimeActivityObservation
            ) -> Void
    ) {
        self.consumer = consumer
        self.logger = logger
        self.faceTimeDuplexActivityHandler =
            faceTimeDuplexActivityHandler
    }

    // MARK: - Mac-hosted FaceTime evidence

    /// Installs process-list and exact duplex-property listeners. Before macOS 26 the process-list
    /// listener is also required to keep feedback exclusions current, so registration failure
    /// aborts startup. macOS 26 may continue using Core Audio's bundle-ID restoration while the
    /// evidence lane remains fail-closed and inactive.
    @available(macOS 14.2, *)
    private func startFaceTimeActivityMonitoring() throws {
        let listener: AudioObjectPropertyListenerBlock = {
            [weak self] _, _ in
            guard let self else { return }
            refreshFaceTimeActivity(emitActiveHeartbeat: true)
            do {
                try refreshExcludedProcesses()
            } catch CoreAudioProcessTapError.notRunning {
                // Normal teardown won the race with this queued invalidation.
            } catch {
                logger.error(
                    "Core Audio process-tap exclusion refresh failed: "
                        + error.localizedDescription
                )
            }
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queues.controlQueue,
            listener
        )
        guard status == noErr else {
            queues.syncControl {
                revokeFaceTimeActivity()
            }
            logger.error(
                "Mac FaceTime activity monitoring unavailable: OSStatus \(status)"
            )
            let bundleIdentifierRestorationAvailable: Bool
            if #available(macOS 26.0, *) {
                bundleIdentifierRestorationAvailable = true
            } else {
                bundleIdentifierRestorationAvailable = false
            }
            guard CoreAudioProcessTapProcessListListenerPolicy
                .permitsCapture(
                    listenerRegistrationStatus: status,
                    bundleIdentifierRestorationAvailable:
                        bundleIdentifierRestorationAvailable
                ) else {
                throw CoreAudioProcessTapError.operationFailed(
                    operation: "register Core Audio process-list listener",
                    status: status
                )
            }
            return
        }

        queues.syncControl {
            processListListener = listener
            refreshFaceTimeActivity(emitActiveHeartbeat: false)

            let timer = DispatchSource.makeTimerSource(
                queue: queues.controlQueue
            )
            timer.schedule(
                deadline: .now() + .seconds(1),
                repeating: .seconds(1),
                leeway: .milliseconds(100)
            )
            timer.setEventHandler { [weak self] in
                self?.refreshFaceTimeActivity(emitActiveHeartbeat: true)
            }
            faceTimeHeartbeatTimer = timer
            timer.resume()
        }
    }

    @available(macOS 14.2, *)
    private func stopFaceTimeActivityMonitoring() {
        queues.syncControl {
            faceTimeHeartbeatTimer?.setEventHandler {}
            faceTimeHeartbeatTimer?.cancel()
            faceTimeHeartbeatTimer = nil

            var listenerRemovalFailed = false
            for (processID, listener) in faceTimeProcessListeners {
                if !Self.removeFaceTimeProcessListeners(
                    processID: processID,
                    queue: queues.controlQueue,
                    listener: listener
                ) {
                    listenerRemovalFailed = true
                }
            }
            faceTimeProcessListeners.removeAll(keepingCapacity: false)

            if let processListListener {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyProcessObjectList,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                let status = AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    queues.controlQueue,
                    processListListener
                )
                if status != noErr {
                    listenerRemovalFailed = true
                }
                self.processListListener = nil
            }

            if listenerRemovalFailed {
                logger.error(
                    "Mac FaceTime listener teardown reported a gap"
                )
            }
            revokeFaceTimeActivity()
        }
    }

    /// Applies one authoritative scan to the current epoch. Only a binding transition, poison
    /// transition, or bound heartbeat is emitted; all state remains serialized on controlQueue.
    @available(macOS 14.2, *)
    private func refreshFaceTimeActivity(
        emitActiveHeartbeat: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(queues.controlQueue))
        let scan = scanFaceTimeDuplexActivity()
        guard let update = faceTimeCausalEpochBinder.observe(scan) else {
            return
        }
        if update.didPhaseChange
            || (emitActiveHeartbeat && update.causalBindingID != nil) {
            emitFaceTimeActivity(update)
        }
    }

    /// Produces known(active exact process IDs) only when the complete process inventory, every
    /// bundle read, and every required property/listener operation succeeds.
    @available(macOS 14.2, *)
    private func scanFaceTimeDuplexActivity()
        -> CoreAudioFaceTimeDuplexActivityScan {
        dispatchPrecondition(condition: .onQueue(queues.controlQueue))
        guard processListListener != nil else {
            logger.error(
                "Mac FaceTime process scan is unknown without its process-list listener"
            )
            return .unknown
        }

        let processObjectIDs: [AudioObjectID]
        do {
            processObjectIDs = try Self.audioObjectIDArrayProperty(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyProcessObjectList
            )
        } catch {
            logger.error(
                "Mac FaceTime process enumeration is unknown: "
                    + error.localizedDescription
            )
            return .unknown
        }

        var seenProcessObjectIDs: Set<AudioObjectID> = []
        var processIdentities: [(AudioObjectID, String)] = []
        for processObjectID in processObjectIDs {
            guard processObjectID != kAudioObjectUnknown,
                  seenProcessObjectIDs.insert(processObjectID).inserted else {
                logger.error(
                    "Mac FaceTime process enumeration returned an invalid identity"
                )
                return .unknown
            }
            do {
                processIdentities.append((
                    processObjectID,
                    try Self.stringProperty(
                        objectID: processObjectID,
                        selector: kAudioProcessPropertyBundleID
                    )
                ))
            } catch {
                logger.error(
                    "Mac FaceTime bundle scan is unknown: "
                        + error.localizedDescription
                )
                return .unknown
            }
        }

        let matchingProcessIDs = Set(
            processIdentities.compactMap { processObjectID, bundleID in
                CoreAudioFaceTimeDuplexActivityPolicy
                    .allowedBundleIdentifiers.contains(bundleID)
                    ? processObjectID
                    : nil
            }
        )

        var listenerOperationFailed = false
        for processID in Array(faceTimeProcessListeners.keys)
            where !matchingProcessIDs.contains(processID) {
            guard let listener = faceTimeProcessListeners.removeValue(
                forKey: processID
            ) else {
                continue
            }
            if !Self.removeFaceTimeProcessListeners(
                processID: processID,
                queue: queues.controlQueue,
                listener: listener
            ) {
                listenerOperationFailed = true
            }
        }

        for processID in matchingProcessIDs.sorted()
            where faceTimeProcessListeners[processID] == nil {
            if let listener = installFaceTimeProcessListeners(
                processID: processID
            ) {
                faceTimeProcessListeners[processID] = listener
            } else {
                listenerOperationFailed = true
            }
        }
        guard !listenerOperationFailed else {
            logger.error(
                "Mac FaceTime process scan is unknown after a listener failure"
            )
            return .unknown
        }

        let snapshots = processIdentities.map { processID, bundleID in
            let isAllowed = CoreAudioFaceTimeDuplexActivityPolicy
                .allowedBundleIdentifiers.contains(bundleID)
            let hasRequiredListeners = isAllowed
                && faceTimeProcessListeners[processID] != nil
            let runningInput = isAllowed
                ? try? Self.uint32Property(
                    objectID: processID,
                    selector: kAudioProcessPropertyIsRunningInput
                )
                : nil
            let runningOutput = isAllowed
                ? try? Self.uint32Property(
                    objectID: processID,
                    selector: kAudioProcessPropertyIsRunningOutput
                )
                : nil
            return CoreAudioFaceTimeProcessActivitySnapshot(
                processObjectID: processID,
                bundleIdentifier: bundleID,
                hasRunningInputListener: hasRequiredListeners,
                hasRunningOutputListener: hasRequiredListeners,
                isRunningInput: runningInput.map { $0 != 0 },
                isRunningOutput: runningOutput.map { $0 != 0 }
            )
        }
        let scan = CoreAudioFaceTimeDuplexActivityPolicy.scan(
            from: snapshots
        )
        if scan == .unknown {
            logger.error(
                "Mac FaceTime process scan is unknown after a property read failure"
            )
        }
        return scan
    }

    @available(macOS 14.2, *)
    private func installFaceTimeProcessListeners(
        processID: AudioObjectID
    ) -> AudioObjectPropertyListenerBlock? {
        let listener: AudioObjectPropertyListenerBlock = {
            [weak self] _, _ in
            self?.refreshFaceTimeActivity(emitActiveHeartbeat: false)
        }
        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectAddPropertyListenerBlock(
            processID,
            &inputAddress,
            queues.controlQueue,
            listener
        ) == noErr else {
            return nil
        }

        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectAddPropertyListenerBlock(
            processID,
            &outputAddress,
            queues.controlQueue,
            listener
        ) == noErr else {
            AudioObjectRemovePropertyListenerBlock(
                processID,
                &inputAddress,
                queues.controlQueue,
                listener
            )
            return nil
        }
        return listener
    }

    @available(macOS 14.2, *)
    private static func removeFaceTimeProcessListeners(
        processID: AudioObjectID,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> Bool {
        var allRemovalsSucceeded = true
        for selector in [
            kAudioProcessPropertyIsRunningInput,
            kAudioProcessPropertyIsRunningOutput,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectRemovePropertyListenerBlock(
                processID,
                &address,
                queue,
                listener
            )
            if status != noErr {
                allRemovalsSucceeded = false
            }
        }
        return allRemovalsSucceeded
    }

    /// Stamps observations on the native control queue so independently scheduled actor tasks
    /// cannot turn an older active sample into newer evidence.
    private func emitFaceTimeActivity(
        _ update: CoreAudioFaceTimeCausalBindingUpdate
    ) {
        dispatchPrecondition(condition: .onQueue(queues.controlQueue))
        let sequence = nextFaceTimeObservationSequence
        nextFaceTimeObservationSequence &+= 1
        if nextFaceTimeObservationSequence == 0 {
            nextFaceTimeObservationSequence = 1
        }
        faceTimeDuplexActivityHandler(
            SystemAudioMacFaceTimeActivityObservation(
                challenge: update.challenge,
                observationSequence: sequence,
                causalBindingID: update.causalBindingID
            )
        )
    }

    private func revokeFaceTimeActivity() {
        dispatchPrecondition(condition: .onQueue(queues.controlQueue))
        let update = faceTimeCausalEpochBinder.revoke()
        emitFaceTimeActivity(update)
    }

    /// Ignores stale challenges before scanning. Every accepted challenge receives an
    /// authoritative scan before its identity is installed; a new epoch can arm only from known
    /// zero, while a same-epoch rotation preserves the existing causal state.
    func installFaceTimeActivityChallenge(
        _ challenge: SystemAudioMacFaceTimeActivityChallenge
    ) {
        queues.asyncControl { [weak self] in
            guard let self,
                  lock.withLock({ isRunning }) else {
                return
            }
            if #available(macOS 14.2, *) {
                var binder = faceTimeCausalEpochBinder
                guard binder.acceptsChallenge(challenge) else {
                    return
                }
                let baseline = scanFaceTimeDuplexActivity()
                guard let update = binder.installChallenge(
                    challenge,
                    authoritativeScan: { baseline }
                ) else {
                    return
                }
                faceTimeCausalEpochBinder = binder
                emitFaceTimeActivity(update)
            }
        }
    }

    deinit {
        if #available(macOS 14.2, *) {
            try? stop()
        }
    }

    /// Creates a private, unmuted global tap and starts its private aggregate device.
    @available(macOS 14.2, *)
    func start() throws -> AudioStreamBasicDescription {
        guard lock.withLock({ !isRunning && tapID == kAudioObjectUnknown }) else {
            throw CoreAudioProcessTapError.alreadyRunning
        }

        let excludedBundleIdentifiers =
            SystemAudioApplicationExclusionPolicy.excludedBundleIdentifiers(
                currentBundleIdentifier: Bundle.main.bundleIdentifier
            )
        let excludedProcessIDs = try Self.processObjectIDs(
            matchingBundleIdentifiers: Set(excludedBundleIdentifiers)
        )
        let createdTapUUID = UUID()
        let tapDescription = Self.makeTapDescription(
            uuid: createdTapUUID,
            excludedProcessIDs: excludedProcessIDs,
            excludedBundleIdentifiers: excludedBundleIdentifiers
        )

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        try Self.requireNoError(
            AudioHardwareCreateProcessTap(tapDescription, &createdTapID),
            operation: "create Core Audio process tap"
        )

        var createdAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        var createdIOProcID: AudioDeviceIOProcID?
        do {
            let tapUID = try Self.stringProperty(
                objectID: createdTapID,
                selector: kAudioTapPropertyUID
            )
            let clockDevice = try Self.aggregateClockDevice()
            let aggregateUID =
                "com.elamin.opensteamer.SystemAudioTap.\(UUID().uuidString)"
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "opensteamer System Audio Tap",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceMainSubDeviceKey: clockDevice.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[
                    kAudioSubDeviceUIDKey: clockDevice.uid,
                ]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceIsPrivateKey: true,
            ]
            try Self.requireNoError(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary,
                    &createdAggregateDeviceID
                ),
                operation: "create process-tap aggregate audio device"
            )

            let format = try Self.streamFormat(
                objectID: createdTapID,
                selector: kAudioTapPropertyFormat,
                scope: kAudioObjectPropertyScopeGlobal
            )
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mSampleRate > 0,
                  format.mChannelsPerFrame == 2,
                  format.mBytesPerFrame > 0 else {
                throw CoreAudioProcessTapError.unsupportedFormat(format)
            }

            let consumer = self.consumer
            let callbackFormat = format
            let callback: AudioDeviceIOBlock = {
                _, inputData, inputTime, _, _ in
                guard let frameCount =
                    CoreAudioProcessTapBufferPolicy.frameCount(
                        audioBufferList: inputData,
                        format: callbackFormat
                    ) else {
                    return
                }
                let presentationTime =
                    CoreAudioProcessTapBufferPolicy.presentationTime(
                        inputTime: inputTime,
                        sampleRate: callbackFormat.mSampleRate
                    )
                consumer.consumeSystemAudioFrames(
                    inputData,
                    format: callbackFormat,
                    frameCount: frameCount,
                    presentationTime: presentationTime
                )
            }
            try Self.requireNoError(
                AudioDeviceCreateIOProcIDWithBlock(
                    &createdIOProcID,
                    createdAggregateDeviceID,
                    queues.ioCallbackQueue,
                    callback
                ),
                operation: "create process-tap IO callback"
            )
            guard let createdIOProcID else {
                throw CoreAudioProcessTapError.missingIOProcedure
            }
            try Self.requireNoError(
                AudioDeviceStart(
                    createdAggregateDeviceID,
                    createdIOProcID
                ),
                operation: "start process-tap aggregate audio device"
            )

            try CoreAudioProcessTapStartupTransaction
                .installListenerPublishAndRefresh(
                    installListener: {
                        try startFaceTimeActivityMonitoring()
                    },
                    publishResources: {
                        lock.withLock {
                            tapID = createdTapID
                            tapUUID = createdTapUUID
                            aggregateDeviceID = createdAggregateDeviceID
                            ioProcID = createdIOProcID
                            isRunning = true
                        }
                    },
                    refreshExclusions: {
                        try refreshExcludedProcesses()
                    },
                    rollbackPublishedResources: {
                        rollbackPublishedStartupResources(
                            expectedTapID: createdTapID
                        )
                    }
                )
            logger.info(
                "Starting Core Audio global process tap at "
                    + "\(Int(format.mSampleRate.rounded())) Hz, "
                    + "\(format.mChannelsPerFrame) channels"
            )
            return format
        } catch {
            if let createdIOProcID {
                // Stop is harmless if startup failed before the device began running and keeps
                // cleanup correct if Core Audio partially activated before returning an error.
                AudioDeviceStop(createdAggregateDeviceID, createdIOProcID)
                AudioDeviceDestroyIOProcID(
                    createdAggregateDeviceID,
                    createdIOProcID
                )
                queues.drainIOCallbacks()
            }
            if createdAggregateDeviceID != kAudioObjectUnknown {
                AudioHardwareDestroyAggregateDevice(createdAggregateDeviceID)
            }
            AudioHardwareDestroyProcessTap(createdTapID)
            throw error
        }
    }

    /// Refreshes PID exclusions for pre-macOS-26 processes that appeared after tap creation.
    @available(macOS 14.2, *)
    func refreshExcludedProcesses() throws {
        try queues.syncControl {
            let excludedBundleIdentifiers =
                SystemAudioApplicationExclusionPolicy
                .excludedBundleIdentifiers(
                    currentBundleIdentifier: Bundle.main.bundleIdentifier
                )
            let excludedProcessIDs = try Self.processObjectIDs(
                matchingBundleIdentifiers: Set(
                    excludedBundleIdentifiers
                )
            )

            try lock.withLock {
                guard isRunning,
                      tapID != kAudioObjectUnknown,
                      let tapUUID else {
                    throw CoreAudioProcessTapError.notRunning
                }
                let description = Self.makeTapDescription(
                    uuid: tapUUID,
                    excludedProcessIDs: excludedProcessIDs,
                    excludedBundleIdentifiers: excludedBundleIdentifiers
                )
                var value: Unmanaged<CATapDescription>? =
                    Unmanaged.passUnretained(description)
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioTapPropertyDescription,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                try Self.requireNoError(
                    AudioObjectSetPropertyData(
                        tapID,
                        &address,
                        0,
                        nil,
                        UInt32(MemoryLayout.size(ofValue: value)),
                        &value
                    ),
                    operation: "refresh Core Audio process-tap exclusions"
                )
            }
            logger.info(
                "Core Audio process-tap exclusions refreshed for "
                    + excludedBundleIdentifiers.joined(separator: ",")
            )
        }
    }

    /// Clears a failed startup publication before removing every installed listener. The exact
    /// tap identity prevents a stale failure path from clearing a later successful start.
    @available(macOS 14.2, *)
    private func rollbackPublishedStartupResources(
        expectedTapID: AudioObjectID
    ) {
        let didClearResources = lock.withLock { () -> Bool in
            guard tapID == expectedTapID else { return false }
            tapID = AudioObjectID(kAudioObjectUnknown)
            tapUUID = nil
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            ioProcID = nil
            isRunning = false
            return true
        }
        if didClearResources {
            stopFaceTimeActivityMonitoring()
        }
    }

    /// Stops callbacks before destroying the aggregate device and process tap.
    @available(macOS 14.2, *)
    func stop() throws {
        let resources = lock.withLock {
            () -> (AudioObjectID, AudioObjectID, AudioDeviceIOProcID?)? in
            guard tapID != kAudioObjectUnknown else { return nil }
            let resources = (tapID, aggregateDeviceID, ioProcID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            tapUUID = nil
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            ioProcID = nil
            isRunning = false
            return resources
        }
        guard let (tapID, aggregateDeviceID, ioProcID) = resources else {
            return
        }

        stopFaceTimeActivityMonitoring()

        var firstError: CoreAudioProcessTapError?
        if aggregateDeviceID != kAudioObjectUnknown,
           let ioProcID {
            let stopStatus = AudioDeviceStop(aggregateDeviceID, ioProcID)
            if stopStatus != noErr {
                firstError = .operationFailed(
                    operation: "stop process-tap aggregate audio device",
                    status: stopStatus
                )
            }
            let destroyIOStatus = AudioDeviceDestroyIOProcID(
                aggregateDeviceID,
                ioProcID
            )
            if destroyIOStatus != noErr, firstError == nil {
                firstError = .operationFailed(
                    operation: "destroy process-tap IO callback",
                    status: destroyIOStatus
                )
            }
            queues.drainIOCallbacks()
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            let aggregateStatus =
                AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if aggregateStatus != noErr, firstError == nil {
                firstError = .operationFailed(
                    operation: "destroy process-tap aggregate audio device",
                    status: aggregateStatus
                )
            }
        }
        let tapStatus = AudioHardwareDestroyProcessTap(tapID)
        if tapStatus != noErr, firstError == nil {
            firstError = .operationFailed(
                operation: "destroy Core Audio process tap",
                status: tapStatus
            )
        }
        logger.info("Stopping Core Audio global process tap")
        if let firstError {
            throw firstError
        }
    }

    private static func processObjectIDs(
        matchingBundleIdentifiers identifiers: Set<String>
    ) throws -> [AudioObjectID] {
        guard !identifiers.isEmpty else { return [] }
        let objectIDs = try audioObjectIDArrayProperty(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        )
        return objectIDs.filter { objectID in
            guard let bundleIdentifier = try? stringProperty(
                objectID: objectID,
                selector: kAudioProcessPropertyBundleID
            ) else {
                return false
            }
            return identifiers.contains(bundleIdentifier)
        }
    }

    @available(macOS 14.2, *)
    private static func makeTapDescription(
        uuid: UUID,
        excludedProcessIDs: [AudioObjectID],
        excludedBundleIdentifiers: [String]
    ) -> CATapDescription {
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: excludedProcessIDs
        )
        description.name = "opensteamer System Audio"
        description.uuid = uuid
        description.isPrivate = true
        description.isExclusive = true
        description.muteBehavior = .unmuted
        if #available(macOS 26.0, *) {
            description.bundleIDs = excludedBundleIdentifiers
            description.isProcessRestoreEnabled = true
        }
        return description
    }

    private static func defaultOutputDeviceID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var byteCount = UInt32(MemoryLayout<AudioObjectID>.stride)
        try requireNoError(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteCount,
                &deviceID
            ),
            operation: "read default output device"
        )
        guard deviceID != kAudioObjectUnknown else {
            throw CoreAudioProcessTapError.defaultOutputUnavailable
        }
        return deviceID
    }

    /// Inventories devices without changing any default or per-device route property.
    private static func aggregateClockDevice() throws
        -> CoreAudioProcessTapClockDeviceSnapshot {
        let currentDefaultOutputDeviceID = try? defaultOutputDeviceID()
        let deviceIDs = try audioObjectIDArrayProperty(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )
        let snapshots: [CoreAudioProcessTapClockDeviceSnapshot] =
            deviceIDs.compactMap { deviceID
                -> CoreAudioProcessTapClockDeviceSnapshot? in
            guard let uid = try? stringProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceUID
            ),
            let isAlive = try? uint32Property(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceIsAlive
            ),
            let inputChannelCount = try? channelCount(
                objectID: deviceID,
                scope: kAudioDevicePropertyScopeInput
            ),
            let outputChannelCount = try? channelCount(
                objectID: deviceID,
                scope: kAudioDevicePropertyScopeOutput
            ) else {
                return nil
            }
            return CoreAudioProcessTapClockDeviceSnapshot(
                deviceID: deviceID,
                uid: uid,
                isAlive: isAlive != 0,
                isDefaultOutput: deviceID == currentDefaultOutputDeviceID,
                inputChannelCount: inputChannelCount,
                outputChannelCount: outputChannelCount
            )
        }
        guard let selected = CoreAudioProcessTapClockDeviceSelectionPolicy
            .select(from: snapshots) else {
            throw CoreAudioProcessTapError.safeClockDeviceUnavailable
        }
        return selected
    }

    private static func audioObjectIDArrayProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        try requireNoError(
            AudioObjectGetPropertyDataSize(
                objectID,
                &address,
                0,
                nil,
                &byteCount
            ),
            operation: "read Core Audio object-list size"
        )
        guard byteCount % UInt32(MemoryLayout<AudioObjectID>.stride) == 0 else {
            throw CoreAudioProcessTapError.invalidPropertySize
        }
        var values = [AudioObjectID](
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(byteCount) / MemoryLayout<AudioObjectID>.stride
        )
        try requireNoError(
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &byteCount,
                &values
            ),
            operation: "read Core Audio object list"
        )
        return values
    }

    private static func channelCount(
        objectID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        try requireNoError(
            AudioObjectGetPropertyDataSize(
                objectID,
                &address,
                0,
                nil,
                &byteCount
            ),
            operation: "read Core Audio stream-configuration size"
        )
        guard byteCount >= UInt32(MemoryLayout<UInt32>.size) else {
            throw CoreAudioProcessTapError.invalidPropertySize
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteCount),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        try requireNoError(
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &byteCount,
                storage
            ),
            operation: "read Core Audio stream configuration"
        )

        guard byteCount >= UInt32(MemoryLayout<UInt32>.size) else {
            throw CoreAudioProcessTapError.invalidPropertySize
        }
        let bufferCount = Int(storage.load(as: UInt32.self))
        guard bufferCount > 0 else { return 0 }
        guard let bufferOffset = MemoryLayout<AudioBufferList>.offset(
            of: \.mBuffers
        ),
        bufferCount <= (Int.max - bufferOffset)
            / MemoryLayout<AudioBuffer>.stride,
        Int(byteCount) >= bufferOffset
            + bufferCount * MemoryLayout<AudioBuffer>.stride else {
            throw CoreAudioProcessTapError.invalidPropertySize
        }

        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        var totalChannelCount: UInt64 = 0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            totalChannelCount += UInt64(buffer.mNumberChannels)
        }
        guard totalChannelCount <= UInt64(UInt32.max) else {
            throw CoreAudioProcessTapError.invalidPropertySize
        }
        return UInt32(totalChannelCount)
    }

    private static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.stride)
        try requireNoError(
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &byteCount,
                &value
            ),
            operation: "read Core Audio string property"
        )
        guard let value else {
            throw CoreAudioProcessTapError.missingStringProperty
        }
        return value.takeRetainedValue() as String
    }

    private static func uint32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.stride)
        try requireNoError(
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &byteCount,
                &value
            ),
            operation: "read Core Audio UInt32 property"
        )
        return value
    }

    private static func streamFormat(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var byteCount = UInt32(
            MemoryLayout<AudioStreamBasicDescription>.stride
        )
        try requireNoError(
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &byteCount,
                &format
            ),
            operation: "read process-tap stream format"
        )
        return format
    }

    private static func requireNoError(
        _ status: OSStatus,
        operation: String
    ) throws {
        guard status == noErr else {
            throw CoreAudioProcessTapError.operationFailed(
                operation: operation,
                status: status
            )
        }
    }
}

/// Pure callback validation used before any no-copy PCM wrapper is created.
enum CoreAudioProcessTapBufferPolicy {
    static func frameCount(
        audioBufferList: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription
    ) -> UInt32? {
        guard format.mBytesPerFrame > 0 else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        guard !buffers.isEmpty else { return nil }
        var commonFrameCount: UInt32?
        for buffer in buffers {
            guard buffer.mData != nil,
                  buffer.mDataByteSize > 0,
                  buffer.mDataByteSize % format.mBytesPerFrame == 0 else {
                return nil
            }
            let frameCount = buffer.mDataByteSize / format.mBytesPerFrame
            guard frameCount > 0 else { return nil }
            if let commonFrameCount,
               commonFrameCount != frameCount {
                return nil
            }
            commonFrameCount = frameCount
        }
        return commonFrameCount
    }

    static func presentationTime(
        inputTime: UnsafePointer<AudioTimeStamp>,
        sampleRate: Double
    ) -> CMTime {
        let timestamp = inputTime.pointee
        if timestamp.mFlags.contains(.sampleTimeValid),
           timestamp.mSampleTime.isFinite,
           timestamp.mSampleTime >= 0,
           sampleRate > 0 {
            return CMTime(
                seconds: timestamp.mSampleTime / sampleRate,
                preferredTimescale: 1_000_000_000
            )
        }
        if timestamp.mFlags.contains(.hostTimeValid) {
            let nanoseconds = AudioConvertHostTimeToNanos(
                timestamp.mHostTime
            )
            guard nanoseconds <= UInt64(Int64.max) else {
                return .invalid
            }
            return CMTime(
                value: Int64(nanoseconds),
                timescale: 1_000_000_000
            )
        }
        return .invalid
    }
}

enum CoreAudioProcessTapError: LocalizedError {
    case unsupportedOperatingSystem
    case alreadyRunning
    case notRunning
    case defaultOutputUnavailable
    case safeClockDeviceUnavailable
    case missingIOProcedure
    case invalidPropertySize
    case missingStringProperty
    case unsupportedFormat(AudioStreamBasicDescription)
    case operationFailed(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedOperatingSystem:
            "Core Audio process taps require macOS 14.2 or later"
        case .alreadyRunning:
            "The Core Audio process tap is already running"
        case .notRunning:
            "The Core Audio process tap is not running"
        case .defaultOutputUnavailable:
            "Core Audio did not report a default output device"
        case .safeClockDeviceUnavailable:
            "Core Audio did not report a live output-only aggregate clock device"
        case .missingIOProcedure:
            "Core Audio did not return a process-tap IO callback"
        case .invalidPropertySize:
            "Core Audio returned an invalid object-list size"
        case .missingStringProperty:
            "Core Audio returned an empty string property"
        case .unsupportedFormat(let format):
            "The Core Audio process tap returned unsupported format "
                + "id=\(format.mFormatID) rate=\(format.mSampleRate) "
                + "channels=\(format.mChannelsPerFrame)"
        case .operationFailed(let operation, let status):
            "\(operation) failed with OSStatus \(status)"
        }
    }
}
