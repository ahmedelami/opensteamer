import AVFoundation
import Foundation
import WebRTCTransport

enum AudioSessionInterruptionBeganReason: Equatable, Sendable {
    case `default`
    case other(rawValue: UInt)
    case unavailable
}

/// Human-readable AVAudioSession state captured for the diagnostics surface.
/// Strings are intentional: the snapshot crosses only UI/test boundaries and should remain stable
/// even when Apple adds enum cases that older application code cannot model exhaustively.
struct AudioSessionSnapshot: Equatable {
    let outputRoute: String
    let inputRoute: String
    let category: String
    let mode: String
    let routeSharingPolicy: String
    let sampleRate: String
    let ioBufferDuration: String
    let secondaryAudio: String
    let otherAudio: String
    let lastEvent: String

    static let inactive = AudioSessionSnapshot(
        outputRoute: "Inactive",
        inputRoute: "Inactive",
        category: "Inactive",
        mode: "Inactive",
        routeSharingPolicy: "Inactive",
        sampleRate: "Inactive",
        ioBufferDuration: "Inactive",
        secondaryAudio: "Inactive",
        otherAudio: "Inactive",
        lastEvent: "Inactive"
    )
}

struct AudioSessionCategoryChangeIngress: Equatable, Sendable {
    let notificationSequence: UInt64
    let audioPolicyEpoch: UInt64
}

/// Captures category-notification provenance on the posting thread, before a main-queue delivery
/// can cross one or more policy changes. Enqueueing while holding the same lock preserves sequence
/// order even when NotificationCenter invokes observers concurrently.
private final class AudioSessionCategoryChangeIngressTracker:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var notificationSequence: UInt64 = 0
    private var audioPolicyEpoch: UInt64 = 0

    func reset(audioPolicyEpoch: UInt64) {
        lock.lock()
        notificationSequence = 0
        self.audioPolicyEpoch = audioPolicyEpoch
        lock.unlock()
    }

    func updateAudioPolicyEpoch(_ audioPolicyEpoch: UInt64) {
        lock.lock()
        self.audioPolicyEpoch = audioPolicyEpoch
        lock.unlock()
    }

    var latestNotificationSequence: UInt64 {
        lock.lock()
        let value = notificationSequence
        lock.unlock()
        return value
    }

    func capture() -> AudioSessionCategoryChangeIngress {
        lock.lock()
        let ingress = nextIngressWhileHoldingLock()
        lock.unlock()
        return ingress
    }

    func enqueueOnMain(
        _ categoryChange: AudioSessionCategoryChange,
        delivery: @escaping @Sendable (
            AudioSessionCategoryChange,
            AudioSessionCategoryChangeIngress
        ) -> Void
    ) {
        lock.lock()
        let ingress = nextIngressWhileHoldingLock()
        DispatchQueue.main.async {
            delivery(categoryChange, ingress)
        }
        lock.unlock()
    }

    private func nextIngressWhileHoldingLock()
        -> AudioSessionCategoryChangeIngress {
        notificationSequence &+= 1
        if notificationSequence == 0 {
            notificationSequence = 1
        }
        return AudioSessionCategoryChangeIngress(
            notificationSequence: notificationSequence,
            audioPolicyEpoch: audioPolicyEpoch
        )
    }
}

/// Configures the legacy playback-only AVAudioSession and translates system notifications into
/// lifecycle callbacks. All callbacks are delivered on the main actor so session owners can update
/// SwiftUI state without establishing a second synchronization policy.
@MainActor
final class AudioSessionManager {
    var onInterruptionBegan: ((AudioSessionInterruptionBeganReason) -> Void)?
    var onInterruptionEnded: ((Bool) -> Void)?
    var onRouteChanged: ((String) -> Void)?
    var onCategoryChanged: ((AudioSessionCategoryChange) -> Void)?
    var onEngineConfigurationChanged: (() -> Void)?
    var onMediaServicesLost: (() -> Void)?
    var onMediaServicesReset: (() -> Void)?
    var onSnapshotChanged: ((AudioSessionSnapshot) -> Void)?

    private var notificationTokens: [NSObjectProtocol] = []
    private enum CategoryChangeOperationState: Equatable {
        case armed
        case delivered
        case cancelled
    }

    private enum CategoryChangeOperationMatch {
        case none
        case exact(UUID)
        case ambiguous(
            blockingTombstoneOperationID: UUID?,
            predecessorOperationID: UUID?
        )
    }

    private struct CategoryChangeOperation {
        let operationID: UUID
        let category: String
        let mode: String
        let categoryOptionsRawValue: UInt
        let audioPolicyEpoch: UInt64
        let notificationSequenceBaseline: UInt64
        var state: CategoryChangeOperationState
        var terminalNotificationSequenceCeiling: UInt64?
    }
    private var categoryChangeOperations: [CategoryChangeOperation] = []
    private var lastDeliveredCategoryChangeNotificationSequence: UInt64 = 0
    nonisolated private let categoryChangeIngressTracker =
        AudioSessionCategoryChangeIngressTracker()

    #if os(iOS)
    /// Native reason-8 arbitration normally resolves in the same notification turn. The bound is
    /// only a fail-safe: unresolved evidence must eventually use ordinary Swift route recovery.
    private static let routeConfigurationChangeArbitrationTimeout: TimeInterval = 0.25
    private var routeConfigurationChangeObserver:
        WebRTCRouteConfigurationChangeObserver?
    private var observationGeneration: UInt64 = 0
    private var routeConfigurationChangePolicyEpoch: UInt64 = 0
    private var lastHandledRouteConfigurationChangeSequence: UInt64 = 0
    #endif

    #if os(iOS)
    static let playbackCategory: AVAudioSession.Category = .playback
    static let playbackMode: AVAudioSession.Mode = .moviePlayback
    static let playbackRouteSharingPolicy: AVAudioSession.RouteSharingPolicy = .longFormAudio
    static let playbackCategoryOptions: AVAudioSession.CategoryOptions = []
    #endif

    nonisolated static func interruptionBeganReason(
        rawValue: UInt?
    ) -> AudioSessionInterruptionBeganReason {
        guard let rawValue else {
            return .unavailable
        }
        if rawValue == 0 {
            return .default
        }
        return .other(rawValue: rawValue)
    }

    var currentRouteDescription: String {
        #if os(iOS)
        Self.routeDescription(AVAudioSession.sharedInstance().currentRoute.outputs, emptyValue: "No output route")
        #else
        return "Default output"
        #endif
    }

    var snapshot: AudioSessionSnapshot {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        return Self.snapshot(for: session, event: "Snapshot")
        #else
        return .inactive
        #endif
    }

    func activate() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            Self.playbackCategory,
            mode: Self.playbackMode,
            policy: Self.playbackRouteSharingPolicy,
            // Apple permits no category options with the long-form route-sharing policy.
            // Playback supports AirPlay without explicitly requesting `allowAirPlay`.
            options: Self.playbackCategoryOptions
        )
        try session.setActive(true, options: [])
        emitSnapshot(event: "Audio session active")
        #endif
    }

    func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [])
        emitSnapshot(event: "Audio session inactive")
        #endif
    }

    func armCategoryChangeOperation(
        _ operationID: UUID,
        category: String,
        mode: String,
        categoryOptionsRawValue: UInt = 0
    ) {
        categoryChangeOperations.removeAll {
            $0.operationID == operationID
        }
        categoryChangeOperations.append(
            CategoryChangeOperation(
                operationID: operationID,
                category: category,
                mode: mode,
                categoryOptionsRawValue: categoryOptionsRawValue,
                audioPolicyEpoch: routeConfigurationChangePolicyEpoch,
                notificationSequenceBaseline:
                    categoryChangeIngressTracker
                        .latestNotificationSequence,
                state: .armed,
                terminalNotificationSequenceCeiling: nil
            )
        )
    }

    func armCategoryChangeOperation(_ operationID: UUID) {
        armCategoryChangeOperation(
            operationID,
            category: "*",
            mode: "*",
            categoryOptionsRawValue: UInt.max
        )
    }

    func cancelCategoryChangeOperation(_ operationID: UUID) {
        guard let index = categoryChangeOperations.firstIndex(where: {
            $0.operationID == operationID
        }) else {
            return
        }

        switch categoryChangeOperations[index].state {
        case .armed:
            // Preserve only the exact ingress interval that already existed when cancellation ran.
            // A later same-target notification cannot borrow this predecessor's identity.
            categoryChangeOperations[index].state = .cancelled
            categoryChangeOperations[index]
                .terminalNotificationSequenceCeiling =
                    categoryChangeIngressTracker
                        .latestNotificationSequence
        case .delivered, .cancelled:
            break
        }
    }

    func updateRouteConfigurationChangePolicyEpoch(_ epoch: UInt64) {
        routeConfigurationChangePolicyEpoch = epoch
        categoryChangeIngressTracker.updateAudioPolicyEpoch(epoch)
        routeConfigurationChangeObserver?
            .updateAudioPolicyEpoch(epoch)
    }

    func startObserving() {
        // Re-registration replaces the prior token set instead of multiplying callbacks after an
        // app foreground/background cycle.
        stopObserving()

        #if os(iOS)
        observationGeneration &+= 1
        lastHandledRouteConfigurationChangeSequence = 0
        lastDeliveredCategoryChangeNotificationSequence = 0
        categoryChangeIngressTracker.reset(
            audioPolicyEpoch: routeConfigurationChangePolicyEpoch
        )
        let registeredObservationGeneration = observationGeneration
        routeConfigurationChangeObserver =
            WebRTCRouteConfigurationChangeObserver(
                timeout: Self.routeConfigurationChangeArbitrationTimeout
            ) { [weak self] observation in
                Task { @MainActor [weak self] in
                    self?.handleRouteConfigurationChangeDisposition(
                        observation,
                        registeredObservationGeneration:
                            registeredObservationGeneration,
                        latestNotificationSequence:
                            self?.routeConfigurationChangeObserver?
                                .latestNotificationSequence
                    )
                }
            }
        routeConfigurationChangeObserver?
            .updateAudioPolicyEpoch(
                routeConfigurationChangePolicyEpoch
            )

        let center = NotificationCenter.default
        let categoryIngressTracker = categoryChangeIngressTracker
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] notification in
                let reasonValue = Self.unsignedIntegerValue(
                    notification.userInfo?[AVAudioSessionRouteChangeReasonKey]
                )
                guard reasonValue
                    == AVAudioSession.RouteChangeReason
                        .categoryChange.rawValue else {
                    return
                }
                let session = AVAudioSession.sharedInstance()
                let categoryChange = AudioSessionCategoryChange(
                    category: session.category.rawValue,
                    mode: session.mode.rawValue,
                    categoryOptionsRawValue:
                        session.categoryOptions.rawValue
                )
                let message = Self.routeChangeDescription(
                    reasonValue: reasonValue
                )
                categoryIngressTracker.enqueueOnMain(
                    categoryChange
                ) { [weak self] categoryChange, ingress in
                    _ = self?
                        .deliverCategoryChangeSynchronouslyOnRegisteredMainQueue(
                            categoryChange,
                            ingress: ingress,
                            registeredObservationGeneration:
                                registeredObservationGeneration,
                            message: message
                        )
                }
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                let userInfo = notification.userInfo
                let typeValue = Self.unsignedIntegerValue(
                    userInfo?[AVAudioSessionInterruptionTypeKey]
                )
                let optionsValue = Self.unsignedIntegerValue(
                    userInfo?[AVAudioSessionInterruptionOptionKey]
                )
                let reasonValue: UInt?
                if typeValue
                    == AVAudioSession.InterruptionType.began.rawValue,
                   #available(iOS 14.5, *) {
                    reasonValue = Self.unsignedIntegerValue(
                        userInfo?[AVAudioSessionInterruptionReasonKey]
                    )
                } else {
                    reasonValue = nil
                }
                _ = self?
                    .deliverInterruptionSynchronouslyOnRegisteredMainQueue(
                        typeValue: typeValue,
                        optionsValue: optionsValue,
                        reasonValue: reasonValue
                    )
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                let reasonValue = Self.unsignedIntegerValue(
                    notification.userInfo?[AVAudioSessionRouteChangeReasonKey]
                )
                // Reason 8 has per-notification native ownership. Category changes are captured
                // on the posting thread above so their policy epoch cannot be rewritten by main-
                // queue latency. This observer handles every remaining route reason.
                guard reasonValue
                    != AVAudioSession.RouteChangeReason
                        .routeConfigurationChange.rawValue,
                      reasonValue
                        != AVAudioSession.RouteChangeReason
                            .categoryChange.rawValue
                else {
                    return
                }
                let message = Self.routeChangeDescription(reasonValue: reasonValue)
                self?
                    .deliverRouteChangeSynchronouslyOnRegisteredMainQueue(
                        message
                    )
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.silenceSecondaryAudioHintNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                let typeValue = notification.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt
                let message = Self.secondaryAudioHintDescription(typeValue: typeValue)
                Task { @MainActor in
                    self?.emitSnapshot(event: message)
                }
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereLostNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                self?
                    .deliverMediaServicesLostSynchronouslyOnRegisteredMainQueue()
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?
                    .deliverEngineConfigurationChangeSynchronouslyOnRegisteredMainQueue()
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                self?
                    .deliverMediaServicesResetSynchronouslyOnRegisteredMainQueue()
            }
        )
        emitSnapshot(event: "Observing audio session")
        #endif
    }

    func stopObserving() {
        #if os(iOS)
        observationGeneration &+= 1
        routeConfigurationChangeObserver?.invalidate()
        routeConfigurationChangeObserver = nil

        let center = NotificationCenter.default
        for token in notificationTokens {
            center.removeObserver(token)
        }
        #endif
        notificationTokens.removeAll()
        categoryChangeOperations.removeAll(keepingCapacity: false)
        lastDeliveredCategoryChangeNotificationSequence = 0
    }

    #if os(iOS)
    // MARK: - Notification translation

    private func handleRouteConfigurationChangeDisposition(
        _ observation: WebRTCRouteConfigurationChangeObservation,
        registeredObservationGeneration: UInt64,
        latestNotificationSequence: UInt64?
    ) {
        guard registeredObservationGeneration == observationGeneration else {
            return
        }

        switch observation.disposition {
        case .consumed,
             .liveRejectionOwnedByWaiter,
             .staleSuppressed:
            break
        case .generic,
             .uninitialized,
             .timedOut:
            if let latestNotificationSequence {
                guard observation.notificationSequence != 0,
                      observation.notificationSequence
                        == latestNotificationSequence,
                      observation.audioPolicyEpoch
                        == routeConfigurationChangePolicyEpoch,
                      observation.notificationSequence
                        > lastHandledRouteConfigurationChangeSequence else {
                    return
                }
                lastHandledRouteConfigurationChangeSequence =
                    observation.notificationSequence
            }
            let message = Self.routeChangeDescription(
                .routeConfigurationChange
            )
            onRouteChanged?(message)
            emitSnapshot(event: message)
        }
    }

    @discardableResult
    nonisolated private func
        deliverInterruptionSynchronouslyOnRegisteredMainQueue(
            typeValue: UInt?,
            optionsValue: UInt?,
            reasonValue: UInt?
        ) -> AudioSessionInterruptionBeganReason? {
        dispatchPrecondition(condition: .onQueue(.main))
        return MainActor.assumeIsolated {
            self.handleInterruption(
                typeValue: typeValue,
                optionsValue: optionsValue,
                reasonValue: reasonValue
            )
        }
    }

    @discardableResult
    nonisolated private func
        deliverCategoryChangeSynchronouslyOnRegisteredMainQueue(
            _ categoryChange: AudioSessionCategoryChange,
            ingress: AudioSessionCategoryChangeIngress,
            registeredObservationGeneration: UInt64?,
            message: String
        ) -> UUID? {
        dispatchPrecondition(condition: .onQueue(.main))
        return MainActor.assumeIsolated {
            if let registeredObservationGeneration,
               registeredObservationGeneration
                != self.observationGeneration {
                return nil
            }
            let operationMatch =
                self.consumeCategoryChangeOperation(
                    category: categoryChange.category,
                    mode: categoryChange.mode,
                    categoryOptionsRawValue:
                        categoryChange.categoryOptionsRawValue,
                    ingress: ingress
                )
            let operationID: UUID?
            let operationIDIsAmbiguous: Bool
            let ambiguousPredecessorOperationID: UUID?
            let blockingTombstoneOperationID: UUID?
            switch operationMatch {
            case .none:
                operationID = nil
                operationIDIsAmbiguous = false
                ambiguousPredecessorOperationID = nil
                blockingTombstoneOperationID = nil
            case let .exact(exactOperationID):
                operationID = exactOperationID
                operationIDIsAmbiguous = false
                ambiguousPredecessorOperationID = nil
                blockingTombstoneOperationID = nil
            case let .ambiguous(
                blockingTombstoneOperationID: blocker,
                predecessorOperationID: predecessorOperationID
            ):
                // Do not invent a causal operation ID for an OS notification.
                operationID = nil
                operationIDIsAmbiguous = true
                ambiguousPredecessorOperationID =
                    predecessorOperationID
                blockingTombstoneOperationID = blocker
            }
            self.onCategoryChanged?(
                AudioSessionCategoryChange(
                    category: categoryChange.category,
                    mode: categoryChange.mode,
                    categoryOptionsRawValue:
                        categoryChange.categoryOptionsRawValue,
                    operationID: operationID,
                    operationIDIsAmbiguous:
                        operationIDIsAmbiguous,
                    ambiguousPredecessorOperationID:
                        ambiguousPredecessorOperationID,
                    blockingTombstoneOperationID:
                        blockingTombstoneOperationID
                )
            )
            self.emitSnapshot(event: message)
            return operationID
        }
    }

    nonisolated private func
        deliverRouteChangeSynchronouslyOnRegisteredMainQueue(
            _ message: String
        ) {
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            self.onRouteChanged?(message)
            self.emitSnapshot(event: message)
        }
    }

    nonisolated private func
        deliverEngineConfigurationChangeSynchronouslyOnRegisteredMainQueue() {
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            self.emitSnapshot(
                event: "Audio engine configuration changed"
            )
            self.onEngineConfigurationChanged?()
        }
    }

    nonisolated private func
        deliverMediaServicesLostSynchronouslyOnRegisteredMainQueue() {
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            // Revoke ownership before diagnostics observers can perform unrelated work.
            self.onMediaServicesLost?()
            self.emitSnapshot(event: "Media services lost")
        }
    }

    nonisolated private func
        deliverMediaServicesResetSynchronouslyOnRegisteredMainQueue() {
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            self.emitSnapshot(event: "Media services reset")
            self.onMediaServicesReset?()
        }
    }

    #if DEBUG
    var debugObservationGenerationForTests: UInt64 {
        observationGeneration
    }

    var debugRouteConfigurationChangePolicyEpochForTests: UInt64 {
        routeConfigurationChangePolicyEpoch
    }

    func debugDeliverRouteConfigurationChangeDispositionForTests(
        _ disposition: WebRTCRouteConfigurationChangeDisposition,
        registeredObservationGeneration: UInt64,
        notificationSequence: UInt64? = nil,
        audioPolicyEpoch: UInt64? = nil,
        latestNotificationSequence: UInt64? = nil
    ) {
        handleRouteConfigurationChangeDisposition(
            WebRTCRouteConfigurationChangeObservation(
                disposition: disposition,
                notificationSequence:
                    notificationSequence ?? 0,
                audioPolicyEpoch:
                    audioPolicyEpoch
                        ?? routeConfigurationChangePolicyEpoch
            ),
            registeredObservationGeneration:
                registeredObservationGeneration,
            latestNotificationSequence:
                notificationSequence == nil
                    ? nil
                    : latestNotificationSequence
        )
    }

    nonisolated func debugDeliverOrdinaryRouteChangeSynchronouslyForTests(
        reasonValue: UInt
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard reasonValue
            != AVAudioSession.RouteChangeReason
                .routeConfigurationChange.rawValue
        else {
            return
        }
        deliverRouteChangeSynchronouslyOnRegisteredMainQueue(
            Self.routeChangeDescription(reasonValue: reasonValue)
        )
    }

    @discardableResult
    nonisolated func
        debugDeliverInterruptionSynchronouslyForTests(
            typeValue: UInt,
            optionsValue: UInt? = nil,
            reasonValue: UInt? = nil
        ) -> AudioSessionInterruptionBeganReason? {
        deliverInterruptionSynchronouslyOnRegisteredMainQueue(
            typeValue: typeValue,
            optionsValue: optionsValue,
            reasonValue: reasonValue
        )
    }

    @discardableResult
    nonisolated func
        debugDeliverCategoryChangeSynchronouslyForTests(
            _ categoryChange: AudioSessionCategoryChange,
            message: String = "Audio route changed: category"
        ) -> UUID? {
        let ingress = categoryChangeIngressTracker.capture()
        return deliverCategoryChangeSynchronouslyOnRegisteredMainQueue(
            categoryChange,
            ingress: ingress,
            registeredObservationGeneration: nil,
            message: message
        )
    }

    func debugCaptureCategoryChangeIngressForTests()
        -> AudioSessionCategoryChangeIngress {
        categoryChangeIngressTracker.capture()
    }

    @discardableResult
    nonisolated func
        debugDeliverCategoryChangeSynchronouslyForTests(
            _ categoryChange: AudioSessionCategoryChange,
            ingress: AudioSessionCategoryChangeIngress,
            message: String = "Audio route changed: category"
        ) -> UUID? {
        return deliverCategoryChangeSynchronouslyOnRegisteredMainQueue(
            categoryChange,
            ingress: ingress,
            registeredObservationGeneration: nil,
            message: message
        )
    }

    nonisolated func
        debugDeliverMediaServicesLostSynchronouslyForTests() {
        deliverMediaServicesLostSynchronouslyOnRegisteredMainQueue()
    }
    #endif

    private func emitSnapshot(event: String) {
        onSnapshotChanged?(Self.snapshot(for: AVAudioSession.sharedInstance(), event: event))
    }

    private func consumeCategoryChangeOperation(
        category: String,
        mode: String,
        categoryOptionsRawValue: UInt,
        ingress: AudioSessionCategoryChangeIngress
    ) -> CategoryChangeOperationMatch {
        guard ingress.notificationSequence != 0,
              ingress.notificationSequence
                > lastDeliveredCategoryChangeNotificationSequence else {
            return .ambiguous(
                blockingTombstoneOperationID: nil,
                predecessorOperationID: nil
            )
        }
        defer {
            lastDeliveredCategoryChangeNotificationSequence =
                ingress.notificationSequence
            // A terminal marker is needed only until the ordered main consumer passes every
            // notification that had already entered at retirement. Keep an equal ceiling for one
            // turn so a later noncausal same-target event is rejected before a newer operation.
            categoryChangeOperations.removeAll {
                guard $0.state != .armed,
                      let ceiling =
                        $0.terminalNotificationSequenceCeiling else {
                    return false
                }
                return ceiling < ingress.notificationSequence
            }
        }

        let matchingIndices = categoryChangeOperations.indices.filter {
            categoryChangeOperation(
                categoryChangeOperations[$0],
                matchesCategory: category,
                mode: mode,
                categoryOptionsRawValue:
                    categoryOptionsRawValue
            )
        }
        guard let firstIndex = matchingIndices.first else {
            return .none
        }

        switch categoryChangeOperations[firstIndex].state {
        case .armed:
            let operation = categoryChangeOperations[firstIndex]
            guard operation.audioPolicyEpoch
                    == ingress.audioPolicyEpoch,
                  ingress.notificationSequence
                    > operation.notificationSequenceBaseline else {
                return .ambiguous(
                    blockingTombstoneOperationID: nil,
                    predecessorOperationID: nil
                )
            }
            let anotherArmedOperationMatches =
                matchingIndices.dropFirst().contains {
                    categoryChangeOperations[$0].state == .armed
                }
            guard !anotherArmedOperationMatches else {
                return .ambiguous(
                    blockingTombstoneOperationID: nil,
                    predecessorOperationID: nil
                )
            }

            let operationID =
                categoryChangeOperations[firstIndex].operationID
            // Retain one delivered tombstone. A duplicate delivery must be rejected before a
            // subsequently armed same-target operation can be considered. Its ceiling includes
            // only notifications already admitted on the posting thread at this exact delivery.
            categoryChangeOperations[firstIndex].state = .delivered
            categoryChangeOperations[firstIndex]
                .terminalNotificationSequenceCeiling = max(
                    ingress.notificationSequence,
                    categoryChangeIngressTracker
                        .latestNotificationSequence
                )
            return .exact(operationID)

        case .delivered, .cancelled:
            let operation = categoryChangeOperations[firstIndex]
            let predecessorIsCausallyBound =
                operation.audioPolicyEpoch
                    == ingress.audioPolicyEpoch
                && ingress.notificationSequence
                    > operation.notificationSequenceBaseline
                && operation.terminalNotificationSequenceCeiling
                    .map {
                        ingress.notificationSequence <= $0
                    } == true
            categoryChangeOperations.remove(at: firstIndex)
            return .ambiguous(
                blockingTombstoneOperationID:
                    operation.operationID,
                predecessorOperationID:
                    predecessorIsCausallyBound
                        ? operation.operationID
                        : nil
            )
        }
    }

    private func categoryChangeOperation(
        _ operation: CategoryChangeOperation,
        matchesCategory category: String,
        mode: String,
        categoryOptionsRawValue: UInt
    ) -> Bool {
        (
            operation.category == category
                && operation.mode == mode
                && operation.categoryOptionsRawValue
                    == categoryOptionsRawValue
        )
            || (
                operation.category == "*"
                    && operation.mode == "*"
                    && operation.categoryOptionsRawValue == UInt.max
            )
    }

    @discardableResult
    private func handleInterruption(
        typeValue: UInt?,
        optionsValue: UInt?,
        reasonValue: UInt?
    ) -> AudioSessionInterruptionBeganReason? {
        guard
            let typeValue,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return nil
        }

        switch type {
        case .began:
            let reason = Self.interruptionBeganReason(
                rawValue: reasonValue
            )
            emitSnapshot(event: "Audio interruption began")
            onInterruptionBegan?(reason)
            return reason
        case .ended:
            let shouldResume: Bool
            if let optionsValue {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                shouldResume = options.contains(.shouldResume)
            } else {
                // Absence of the resume option is not permission to restart audible playback.
                shouldResume = false
            }
            emitSnapshot(event: shouldResume ? "Audio interruption ended" : "Audio interruption ended without resume flag")
            onInterruptionEnded?(shouldResume)
            return nil
        @unknown default:
            return nil
        }
    }

    nonisolated private static func unsignedIntegerValue(
        _ value: Any?
    ) -> UInt? {
        switch value {
        case let value as UInt:
            return value
        case let value as NSNumber:
            return value.uintValue
        case let value as Int where value >= 0:
            return UInt(value)
        default:
            return nil
        }
    }

    nonisolated private static func snapshot(
        for session: AVAudioSession,
        event: String
    ) -> AudioSessionSnapshot {
        // These helpers are nonisolated because AVAudioSession notification closures can describe
        // immutable values before their MainActor delivery without touching manager state.
        AudioSessionSnapshot(
            outputRoute: routeDescription(session.currentRoute.outputs, emptyValue: "No output route"),
            inputRoute: routeDescription(session.currentRoute.inputs, emptyValue: "No input route"),
            category: session.category.rawValue,
            mode: session.mode.rawValue,
            routeSharingPolicy: "\(session.routeSharingPolicy)",
            sampleRate: "\(Int(session.sampleRate.rounded())) Hz",
            ioBufferDuration: String(format: "%.3f s", session.ioBufferDuration),
            secondaryAudio: session.secondaryAudioShouldBeSilencedHint ? "Silenced by system" : "Not silenced",
            otherAudio: session.isOtherAudioPlaying ? "Other audio playing" : "No other audio",
            lastEvent: event
        )
    }

    nonisolated private static func routeDescription(
        _ descriptions: [AVAudioSessionPortDescription],
        emptyValue: String
    ) -> String {
        guard !descriptions.isEmpty else { return emptyValue }
        return descriptions
            .map { "\($0.portName) (\($0.portType.rawValue))" }
            .joined(separator: ", ")
    }

    nonisolated private static func secondaryAudioHintDescription(typeValue: UInt?) -> String {
        guard
            let typeValue,
            let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: typeValue)
        else {
            return "Secondary audio hint changed"
        }

        switch type {
        case .begin:
            return "Secondary audio silencing began"
        case .end:
            return "Secondary audio silencing ended"
        @unknown default:
            return "Secondary audio hint changed"
        }
    }

    nonisolated private static func routeChangeDescription(reasonValue: UInt?) -> String {
        guard
            let reasonValue,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else {
            return "Audio route changed"
        }

        return routeChangeDescription(reason)
    }

    nonisolated private static func routeChangeDescription(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable:
            "Audio route changed: new device"
        case .oldDeviceUnavailable:
            "Audio route changed: device unavailable"
        case .categoryChange:
            "Audio route changed: category"
        case .override:
            "Audio route changed: override"
        case .wakeFromSleep:
            "Audio route changed: wake from sleep"
        case .noSuitableRouteForCategory:
            "Audio route changed: no suitable route"
        case .routeConfigurationChange:
            "Audio route configuration changed"
        case .unknown:
            "Audio route changed"
        @unknown default:
            "Audio route changed"
        }
    }
    #endif
}
