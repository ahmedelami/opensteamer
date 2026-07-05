import AVFoundation
import Foundation

@MainActor
final class AudioSessionManager {
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: (() -> Void)?
    var onRouteChanged: ((String) -> Void)?

    private var notificationTokens: [NSObjectProtocol] = []

    var currentRouteDescription: String {
        #if os(iOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else { return "No output route" }
        return outputs
            .map { "\($0.portName) (\($0.portType.rawValue))" }
            .joined(separator: ", ")
        #else
        return "Default output"
        #endif
    }

    func activate() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true, options: [])
        #endif
    }

    func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [])
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
                }
            }
        )
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
    private func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard
            let typeValue,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }

        switch type {
        case .began:
            onInterruptionBegan?()
        case .ended:
            if let optionsValue {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    onInterruptionEnded?()
                }
            } else {
                onInterruptionEnded?()
            }
        @unknown default:
            break
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
