#if os(iOS)
import Foundation
import IOSWebRTCAudioDeviceShim

/// Native ownership of one exact reason-8 AVAudioSession route-change notification.
///
/// The native observer preserves the notification object's identity while waiting asynchronously
/// for the audio-device observer to classify it. Outcomes already owned by the native transaction
/// are suppressed by the app lifecycle; fallback outcomes still require ordinary route recovery.
public enum WebRTCRouteConfigurationChangeDisposition: Equatable, Sendable {
    case consumed
    case liveRejectionOwnedByWaiter
    case staleSuppressed
    case generic
    case uninitialized
    case timedOut

    fileprivate init(native: ASIOSRouteConfigurationChangeDisposition) {
        switch native {
        case .consumed:
            self = .consumed
        case .liveRejectionOwnedByWaiter:
            self = .liveRejectionOwnedByWaiter
        case .staleSuppressed:
            self = .staleSuppressed
        case .generic:
            self = .generic
        case .uninitialized:
            self = .uninitialized
        case .timedOut:
            self = .timedOut
        @unknown default:
            // Unknown native outcomes must retain the conservative generic-recovery path.
            self = .uninitialized
        }
    }

    #if DEBUG
    fileprivate var native: ASIOSRouteConfigurationChangeDisposition {
        switch self {
        case .consumed:
            .consumed
        case .liveRejectionOwnedByWaiter:
            .liveRejectionOwnedByWaiter
        case .staleSuppressed:
            .staleSuppressed
        case .generic:
            .generic
        case .uninitialized:
            .uninitialized
        case .timedOut:
            .timedOut
        }
    }
    #endif
}

/// Immutable ingress provenance for one exact reason-8 notification.
public struct WebRTCRouteConfigurationChangeObservation: Equatable, Sendable {
    public let disposition: WebRTCRouteConfigurationChangeDisposition
    public let notificationSequence: UInt64
    public let audioPolicyEpoch: UInt64

    public init(
        disposition: WebRTCRouteConfigurationChangeDisposition,
        notificationSequence: UInt64,
        audioPolicyEpoch: UInt64
    ) {
        self.disposition = disposition
        self.notificationSequence = notificationSequence
        self.audioPolicyEpoch = audioPolicyEpoch
    }
}

/// Nonblocking bridge for native reason-8 notification arbitration.
///
/// The handler can arrive on any queue. Owners that expose actor-isolated state must perform their
/// own actor hop and fence the callback against their current observation generation.
public final class WebRTCRouteConfigurationChangeObserver: @unchecked Sendable {
    private let native: ASIOSRouteConfigurationChangeObserver

    public init(
        timeout: TimeInterval,
        handler: @escaping @Sendable (
            WebRTCRouteConfigurationChangeObservation
        ) -> Void
    ) {
        native = ASIOSRouteConfigurationChangeObserver(
            timeout: timeout
        ) { nativeDisposition, notificationSequence, audioPolicyEpoch in
            handler(
                WebRTCRouteConfigurationChangeObservation(
                    disposition:
                        WebRTCRouteConfigurationChangeDisposition(
                            native: nativeDisposition
                        ),
                    notificationSequence: notificationSequence,
                    audioPolicyEpoch: audioPolicyEpoch
                )
            )
        }
    }

    public var latestNotificationSequence: UInt64 {
        native.latestNotificationSequence
    }

    public func updateAudioPolicyEpoch(_ audioPolicyEpoch: UInt64) {
        native.updateAudioPolicyEpoch(audioPolicyEpoch)
    }

    public func invalidate() {
        native.invalidate()
    }

    deinit {
        native.invalidate()
    }
}

#if DEBUG
/// Deterministic exact-notification arbitration coverage without AVAudioSession hardware.
public final class WebRTCRouteConfigurationChangeArbitrationTestHarness:
    @unchecked Sendable
{
    private let native =
        ASIOSRouteConfigurationChangeArbitrationTestHarness()

    public init() {}

    public func debugWaiterFirstResolvesForTesting(
        _ disposition: WebRTCRouteConfigurationChangeDisposition
    ) -> Bool {
        native.debugWaiterFirstResolvesForTesting(disposition.native)
    }

    public func debugNativeFirstResolvesForTesting(
        _ disposition: WebRTCRouteConfigurationChangeDisposition
    ) -> Bool {
        native.debugNativeFirstResolvesForTesting(disposition.native)
    }

    public func debugNativeFirstResolverReplacementPreservesDispositionForTesting(
        _ disposition: WebRTCRouteConfigurationChangeDisposition
    ) -> Bool {
        native
            .debugNativeFirstResolverReplacementPreservesDispositionForTesting(
                disposition.native
            )
    }

    public func debugExactNotificationIdentityRejectsStaleResolutionForTesting()
        -> Bool
    {
        native
            .debugExactNotificationIdentityRejectsStaleResolutionForTesting()
    }

    public func debugTimeoutCompletesExactlyOnceForTesting() -> Bool {
        native.debugTimeoutCompletesExactlyOnceForTesting()
    }

    public func debugTimeoutBeforeNativeBindThenLateResolutionCompletesExactlyOnceForTesting()
        -> Bool
    {
        native
            .debugTimeoutBeforeNativeBindThenLateResolutionCompletesExactlyOnceForTesting()
    }

    public func debugArbitrationRecordCountForTesting() -> UInt {
        native.debugArbitrationRecordCountForTesting()
    }
}
#endif
#endif
