import AVFoundation
import Foundation

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
        case ambiguous
    }

    private struct CategoryChangeOperation {
        let operationID: UUID
        let category: String
        let mode: String
        let categoryOptionsRawValue: UInt
        var state: CategoryChangeOperationState
    }
    private var categoryChangeOperations: [CategoryChangeOperation] = []

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
                state: .armed
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
            // Preserve a tombstone. AVAudioSession does not attach an app operation ID, so a
            // notification already queued for this operation must be absorbed instead of being
            // attributed to a newer same-target operation.
            categoryChangeOperations[index].state = .cancelled
        case .delivered, .cancelled:
            break
        }
    }

    func startObserving() {
        // Re-registration replaces the prior token set instead of multiplying callbacks after an
        // app foreground/background cycle.
        stopObserving()

        #if os(iOS)
        let center = NotificationCenter.default
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
                let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                let message = Self.routeChangeDescription(reasonValue: reasonValue)
                let categoryChange: AudioSessionCategoryChange?
                if reasonValue
                    == AVAudioSession.RouteChangeReason.categoryChange.rawValue {
                    let session = AVAudioSession.sharedInstance()
                    categoryChange = AudioSessionCategoryChange(
                        category: session.category.rawValue,
                        mode: session.mode.rawValue,
                        categoryOptionsRawValue:
                            session.categoryOptions.rawValue
                    )
                } else {
                    categoryChange = nil
                }
                if let categoryChange {
                    _ = self?
                        .deliverCategoryChangeSynchronouslyOnRegisteredMainQueue(
                            categoryChange,
                            message: message
                        )
                } else {
                    self?
                        .deliverRouteChangeSynchronouslyOnRegisteredMainQueue(
                            message
                        )
                }
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
        let center = NotificationCenter.default
        for token in notificationTokens {
            center.removeObserver(token)
        }
        #endif
        notificationTokens.removeAll()
        categoryChangeOperations.removeAll(keepingCapacity: false)
    }

    #if os(iOS)
    // MARK: - Notification translation

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
            message: String
        ) -> UUID? {
        dispatchPrecondition(condition: .onQueue(.main))
        return MainActor.assumeIsolated {
            let operationMatch =
                self.consumeCategoryChangeOperation(
                    category: categoryChange.category,
                    mode: categoryChange.mode,
                    categoryOptionsRawValue:
                        categoryChange.categoryOptionsRawValue
                )
            let operationID: UUID?
            let operationIDIsAmbiguous: Bool
            switch operationMatch {
            case .none:
                operationID = nil
                operationIDIsAmbiguous = false
            case let .exact(exactOperationID):
                operationID = exactOperationID
                operationIDIsAmbiguous = false
            case .ambiguous:
                // Do not invent a causal operation ID for an OS notification.
                operationID = nil
                operationIDIsAmbiguous = true
            }
            self.onCategoryChanged?(
                AudioSessionCategoryChange(
                    category: categoryChange.category,
                    mode: categoryChange.mode,
                    categoryOptionsRawValue:
                        categoryChange.categoryOptionsRawValue,
                    operationID: operationID,
                    operationIDIsAmbiguous:
                        operationIDIsAmbiguous
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
        deliverCategoryChangeSynchronouslyOnRegisteredMainQueue(
            categoryChange,
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
        categoryOptionsRawValue: UInt
    ) -> CategoryChangeOperationMatch {
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
            let anotherArmedOperationMatches =
                matchingIndices.dropFirst().contains {
                    categoryChangeOperations[$0].state == .armed
                }
            guard !anotherArmedOperationMatches else {
                return .ambiguous
            }

            let operationID =
                categoryChangeOperations[firstIndex].operationID
            // Retain one delivered tombstone. A duplicate delivery must be rejected before a
            // subsequently armed same-target operation can be considered.
            categoryChangeOperations[firstIndex].state = .delivered
            return .exact(operationID)

        case .delivered, .cancelled:
            // This delivery may be a duplicate or a queued notification from a retired operation.
            // Consume only the tombstone; never consume the newer matching operation behind it.
            categoryChangeOperations.remove(at: firstIndex)
            return .ambiguous
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
