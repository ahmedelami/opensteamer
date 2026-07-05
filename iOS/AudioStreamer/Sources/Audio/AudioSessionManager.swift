import AVFoundation
import Foundation

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

@MainActor
final class AudioSessionManager {
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: ((Bool) -> Void)?
    var onRouteChanged: ((String) -> Void)?
    var onEngineConfigurationChanged: (() -> Void)?
    var onMediaServicesReset: (() -> Void)?
    var onSnapshotChanged: ((AudioSessionSnapshot) -> Void)?

    private var notificationTokens: [NSObjectProtocol] = []

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
            .playback,
            mode: .moviePlayback,
            policy: .longFormAudio,
            options: [.mixWithOthers, .allowAirPlay]
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

    func startObserving() {
        stopObserving()

        #if os(iOS)
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                Task { @MainActor in
                    self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue)
                }
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
                Task { @MainActor in
                    self?.onRouteChanged?(message)
                    self?.emitSnapshot(event: message)
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
                Task { @MainActor in
                    self?.emitSnapshot(event: "Media services lost")
                }
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.emitSnapshot(event: "Audio engine configuration changed")
                    self?.onEngineConfigurationChanged?()
                }
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.emitSnapshot(event: "Media services reset")
                    self?.onMediaServicesReset?()
                }
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
    }

    #if os(iOS)
    private func emitSnapshot(event: String) {
        onSnapshotChanged?(Self.snapshot(for: AVAudioSession.sharedInstance(), event: event))
    }

    private func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard
            let typeValue,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }

        switch type {
        case .began:
            emitSnapshot(event: "Audio interruption began")
            onInterruptionBegan?()
        case .ended:
            let shouldResume: Bool
            if let optionsValue {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                shouldResume = options.contains(.shouldResume)
            } else {
                shouldResume = true
            }
            emitSnapshot(event: shouldResume ? "Audio interruption ended" : "Audio interruption ended without resume flag")
            onInterruptionEnded?(shouldResume)
        @unknown default:
            break
        }
    }

    nonisolated private static func snapshot(
        for session: AVAudioSession,
        event: String
    ) -> AudioSessionSnapshot {
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
