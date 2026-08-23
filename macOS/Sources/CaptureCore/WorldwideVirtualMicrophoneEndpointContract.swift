import CoreAudio
import Foundation

/// Exact installed endpoint contract for worldwide iPhone microphone routing.
public enum WorldwideVirtualMicrophoneEndpointContract {
    public static let visibleDefaultInputDeviceUID =
        "com.elamin.opensteamer.virtual-microphone.input"
    public static let hiddenMirrorSinkDeviceUID =
        "com.elamin.opensteamer.virtual-microphone.writer"
    public static let modelUID =
        "com.elamin.opensteamer.virtual-microphone.model"
    public static let visibleInputChannelCount: UInt32 = 1
    public static let visibleOutputChannelCount: UInt32 = 0
    public static let hiddenInputChannelCount: UInt32 = 0
    public static let hiddenOutputChannelCount: UInt32 = 1
    public static let nominalSampleRate: Double = 48_000
    public static let clockDomain: UInt32 = 0x6F73564D
    public static let retiredLegacyVisibleDeviceUID =
        "BlackHole2ch_UID"
    public static let retiredLegacyHiddenWriterDeviceUID =
        "BlackHole2ch_2_UID"
}

/// One stable Core Audio identity participating in the BlackHole microphone path.
public struct BlackHoleDeviceEndpointIdentity: Equatable, Sendable {
    public let deviceID: AudioDeviceID
    public let deviceUID: String

    public init(
        deviceID: AudioDeviceID,
        deviceUID: String
    ) {
        self.deviceID = deviceID
        self.deviceUID = deviceUID
    }
}

/// One read-only observation of the exact visible-input/hidden-sink pair.
public struct BlackHoleDeviceAvailabilitySnapshot: Equatable, Sendable {
    public let monitorEpoch: UUID
    public let deviceGeneration: UInt64
    /// Exact Core Audio device-list event sequence incorporated by the
    /// endpoint-pair read that produced this snapshot. Sequence zero is the
    /// listener-fenced initial inventory; every raw callback advances it
    /// before any asynchronous refresh work is dispatched.
    public let acceptedInventoryChangeSequence: UInt64
    /// Availability is derived from a complete, role-correct pair. It cannot
    /// be asserted independently by a caller.
    public var isAvailable: Bool {
        guard let defaultInputEndpoint,
              let hiddenMirrorSinkEndpoint else {
            return false
        }
        return defaultInputEndpoint.deviceID != kAudioObjectUnknown
            && hiddenMirrorSinkEndpoint.deviceID != kAudioObjectUnknown
            && defaultInputEndpoint.deviceID
                != hiddenMirrorSinkEndpoint.deviceID
            && defaultInputEndpoint.deviceUID
                == WorldwideVirtualMicrophoneEndpointContract
                    .visibleDefaultInputDeviceUID
            && hiddenMirrorSinkEndpoint.deviceUID
                == WorldwideVirtualMicrophoneEndpointContract
                    .hiddenMirrorSinkDeviceUID
    }

    public let defaultInputEndpoint: BlackHoleDeviceEndpointIdentity?
    public let hiddenMirrorSinkEndpoint: BlackHoleDeviceEndpointIdentity?

    /// Records the endpoint observations for one inventory generation. Only
    /// a complete, role-correct pair makes `isAvailable` true.
    public init(
        monitorEpoch: UUID,
        deviceGeneration: UInt64,
        defaultInputEndpoint: BlackHoleDeviceEndpointIdentity?,
        hiddenMirrorSinkEndpoint: BlackHoleDeviceEndpointIdentity?,
        acceptedInventoryChangeSequence: UInt64 = 0
    ) {
        self.monitorEpoch = monitorEpoch
        self.deviceGeneration = deviceGeneration
        self.acceptedInventoryChangeSequence =
            acceptedInventoryChangeSequence
        self.defaultInputEndpoint = defaultInputEndpoint
        self.hiddenMirrorSinkEndpoint = hiddenMirrorSinkEndpoint
    }
}

struct BlackHoleDeviceEndpointPair: Equatable, Sendable {
    let defaultInputEndpoint: BlackHoleDeviceEndpointIdentity
    let hiddenMirrorSinkEndpoint: BlackHoleDeviceEndpointIdentity
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

/// Outcome of one synchronous exact-pair validation at a healthy media boundary.
public enum BlackHoleDeviceAvailabilityRevalidationResult:
    Equatable,
    Sendable
{
    case validated(BlackHoleDeviceAvailabilitySnapshot)
    case validationFailed
    case inactive
}
