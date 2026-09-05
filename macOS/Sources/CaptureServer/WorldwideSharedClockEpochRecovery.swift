import CoreAudio
import CaptureCore
import Foundation

struct WorldwideSharedClockEpochRecoveryIdentity:
    Equatable,
    Sendable
{
    let monitorEpoch: UUID
    let deviceGeneration: UInt64
    let peerGeneration: UInt64

    init(_ key: WorldwideIPhoneMicrophoneForwardingKey) {
        monitorEpoch = key.monitorEpoch
        deviceGeneration = key.deviceGeneration
        peerGeneration = key.peerGeneration
    }
}

enum WorldwideSharedClockEpochRecoveryDecision:
    Equatable,
    Sendable
{
    case recover(attempt: Int, maximumAttemptCount: Int)
    case failClosed
}

/// Allows a bounded fresh-epoch retry only for the one clock rejection that
/// stopping every client can repair. All malformed, discontinuous, or
/// rate-unsafe clocks retain the existing deterministic fail-closed behavior.
struct WorldwideSharedClockEpochRecoveryPolicy: Sendable {
    static let maximumAttemptCount = 1
    private var identity:
        WorldwideSharedClockEpochRecoveryIdentity?
    private var attemptCount = 0

    mutating func registerFailure(
        key: WorldwideIPhoneMicrophoneForwardingKey,
        rejection: BlackHoleFaceTimeClockRejection
    ) -> WorldwideSharedClockEpochRecoveryDecision {
        guard Self.canRecover(rejection) else {
            return .failClosed
        }

        let incomingIdentity =
            WorldwideSharedClockEpochRecoveryIdentity(key)
        if identity != incomingIdentity {
            identity = incomingIdentity
            attemptCount = 0
        }
        guard attemptCount < Self.maximumAttemptCount else {
            return .failClosed
        }
        attemptCount += 1
        return .recover(
            attempt: attemptCount,
            maximumAttemptCount: Self.maximumAttemptCount
        )
    }

    mutating func reset() {
        identity = nil
        attemptCount = 0
    }

    static func canRecover(
        _ rejection: BlackHoleFaceTimeClockRejection
    ) -> Bool {
        if case .insufficientSigned32Headroom = rejection {
            return true
        }
        return false
    }
}

struct WorldwideSharedClockEpochRecoveryParkingRoute:
    Equatable,
    Sendable
{
    let defaultInputUID: String

    init?(defaultInputUID: String) {
        guard !defaultInputUID.isEmpty,
              defaultInputUID
                != WorldwideVirtualMicrophoneEndpointContract
                    .visibleDefaultInputDeviceUID,
              defaultInputUID
                != WorldwideVirtualMicrophoneEndpointContract
                    .hiddenMirrorSinkDeviceUID,
              defaultInputUID
                != WorldwideVirtualMicrophoneEndpointContract
                    .retiredLegacyHiddenWriterDeviceUID else {
            return nil
        }
        self.defaultInputUID = defaultInputUID
    }
}

enum WorldwideSharedClockEpochRecoveryAdmissionPolicy {
    static func expectedReplacementKey(
        after rejectedKey: WorldwideIPhoneMicrophoneForwardingKey
    ) -> WorldwideIPhoneMicrophoneForwardingKey {
        WorldwideIPhoneMicrophoneForwardingKey(
            monitorEpoch: rejectedKey.monitorEpoch,
            deviceGeneration: rejectedKey.deviceGeneration,
            peerGeneration: rejectedKey.peerGeneration,
            transportAuthorizationEpoch:
                nextNonzero(rejectedKey.transportAuthorizationEpoch),
            trackGeneration: rejectedKey.trackGeneration
        )
    }

    static func accepts(
        snapshot: WorldwideIPhoneMicrophoneForwardingHostSnapshot,
        after rejectedKey: WorldwideIPhoneMicrophoneForwardingKey
    ) -> Bool {
        accepts(
            currentKey: snapshot.currentKey,
            transportAuthorized: snapshot.transportAuthorized,
            queueRunning: snapshot.queueRunning,
            exactTrackAdmitted: snapshot.exactTrackAdmitted,
            after: rejectedKey
        )
    }

    static func accepts(
        currentKey: WorldwideIPhoneMicrophoneForwardingKey?,
        transportAuthorized: Bool,
        queueRunning: Bool,
        exactTrackAdmitted: Bool,
        after rejectedKey: WorldwideIPhoneMicrophoneForwardingKey
    ) -> Bool {
        transportAuthorized
            && queueRunning
            && exactTrackAdmitted
            && currentKey
                == expectedReplacementKey(after: rejectedKey)
    }

    static func diagnosticDescription(
        snapshot: WorldwideIPhoneMicrophoneForwardingHostSnapshot,
        after rejectedKey: WorldwideIPhoneMicrophoneForwardingKey
    ) -> String {
        let expectedOwnership = snapshot.currentKey
            == expectedReplacementKey(after: rejectedKey)
        return "expectedOwnership=\(expectedOwnership) "
            + "transportAuthorized=\(snapshot.transportAuthorized) "
            + "queueRunning=\(snapshot.queueRunning) "
            + "exactTrackAdmitted=\(snapshot.exactTrackAdmitted) "
            + "phase=\(snapshot.phase.rawValue) "
            + "lastFailure=\(snapshot.lastFailureCategory?.rawValue ?? "none")"
    }

    private static func nextNonzero(_ value: UInt64) -> UInt64 {
        let next = value &+ 1
        return next == 0 ? 1 : next
    }
}

enum WorldwideVirtualMicrophoneEpochStateReadError:
    Error,
    Equatable,
    Sendable
{
    case invalidDevice
    case coreAudioStatus(OSStatus)
    case unexpectedPropertySize(UInt32)
    case invalidDefaultInputUID
    case driverDiagnostics(WorldwideVirtualMicrophoneDriverDiagnosticError)
}

struct WorldwideVirtualMicrophoneEpochStateObservation:
    Equatable,
    Sendable
{
    let defaultInputUIDFirstPass: String
    let visibleInputRunningFirstPass: Bool
    let hiddenWriterRunningFirstPass: Bool
    let hiddenWriterRunningSecondPass: Bool
    let visibleInputRunningSecondPass: Bool
    let defaultInputUIDSecondPass: String
    let driverIdleProven: Bool

    func provesGlobalIdleCandidate(
        parkedOn route:
            WorldwideSharedClockEpochRecoveryParkingRoute
    ) -> Bool {
        defaultInputUIDFirstPass == route.defaultInputUID
            && defaultInputUIDSecondPass == route.defaultInputUID
            && !visibleInputRunningFirstPass
            && !hiddenWriterRunningFirstPass
            && !hiddenWriterRunningSecondPass
            && !visibleInputRunningSecondPass
            && driverIdleProven
    }
}

/// Requires mirrored public running flags and coherent driver snapshots; HAL
/// can report idle while a retained driver client still owns the clock epoch.
/// This retry gate never replaces the post-start clock proof before PCM admission.
struct WorldwideVirtualMicrophoneEpochStateReader: Sendable {
    typealias UInt32PropertyRead = @Sendable (
        AudioDeviceID,
        AudioObjectPropertyAddress,
        inout UInt32,
        inout UInt32
    ) -> OSStatus
    typealias DeviceRunningRead = @Sendable (
        AudioDeviceID
    ) -> Result<
        Bool,
        WorldwideVirtualMicrophoneEpochStateReadError
    >
    typealias DefaultInputUIDRead = @Sendable () -> Result<
        String,
        WorldwideVirtualMicrophoneEpochStateReadError
    >
    typealias DriverDiagnosticRead = @Sendable (AudioDeviceID) -> Result<
        WorldwideVirtualMicrophoneDriverDiagnosticSnapshot,
        WorldwideVirtualMicrophoneDriverDiagnosticError
    >

    private let readDeviceRunning: DeviceRunningRead
    private let readDefaultInputUID: DefaultInputUIDRead
    private let readDriverDiagnostic: DriverDiagnosticRead

    init() {
        self.init(
            readUInt32Property: { deviceID, address, size, value in
                var address = address
                return AudioObjectGetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    &size,
                    &value
                )
            },
            readDefaultInputUID: {
                Self.systemDefaultInputUID()
            },
            readDriverDiagnostic: { deviceID in
                WorldwideVirtualMicrophoneDriverDiagnosticReader().read(deviceID)
            }
        )
    }

    init(
        readUInt32Property: @escaping UInt32PropertyRead,
        readDefaultInputUID: @escaping DefaultInputUIDRead,
        readDriverDiagnostic: @escaping DriverDiagnosticRead
    ) {
        readDeviceRunning = { deviceID in
            Self.systemDeviceRunning(
                deviceID,
                readUInt32Property: readUInt32Property
            )
        }
        self.readDefaultInputUID = readDefaultInputUID
        self.readDriverDiagnostic = readDriverDiagnostic
    }

    init(
        readDeviceRunning: @escaping DeviceRunningRead,
        readDefaultInputUID: @escaping DefaultInputUIDRead,
        readDriverDiagnostic: @escaping DriverDiagnosticRead
    ) {
        self.readDeviceRunning = readDeviceRunning
        self.readDefaultInputUID = readDefaultInputUID
        self.readDriverDiagnostic = readDriverDiagnostic
    }

    func observe(
        visibleInputDeviceID: AudioDeviceID,
        hiddenWriterDeviceID: AudioDeviceID
    ) -> Result<
        WorldwideVirtualMicrophoneEpochStateObservation,
        WorldwideVirtualMicrophoneEpochStateReadError
    > {
        guard visibleInputDeviceID != kAudioObjectUnknown,
              hiddenWriterDeviceID != kAudioObjectUnknown,
              visibleInputDeviceID != hiddenWriterDeviceID else {
            return .failure(.invalidDevice)
        }

        let defaultInputUIDFirstPass: String
        switch readDefaultInputUID() {
        case .success(let value):
            defaultInputUIDFirstPass = value
        case .failure(let error):
            return .failure(error)
        }

        let visibleFirst: Bool
        switch readDeviceRunning(visibleInputDeviceID) {
        case .success(let value):
            visibleFirst = value
        case .failure(let error):
            return .failure(error)
        }

        let hiddenFirst: Bool
        switch readDeviceRunning(hiddenWriterDeviceID) {
        case .success(let value):
            hiddenFirst = value
        case .failure(let error):
            return .failure(error)
        }

        let hiddenSecond: Bool
        switch readDeviceRunning(hiddenWriterDeviceID) {
        case .success(let value):
            hiddenSecond = value
        case .failure(let error):
            return .failure(error)
        }

        let visibleSecond: Bool
        switch readDeviceRunning(visibleInputDeviceID) {
        case .success(let value):
            visibleSecond = value
        case .failure(let error):
            return .failure(error)
        }

        var driverObservations: [WorldwideVirtualMicrophoneDriverDiagnosticSnapshot] = []
        for deviceID in [visibleInputDeviceID, hiddenWriterDeviceID,
                         hiddenWriterDeviceID, visibleInputDeviceID] {
            switch readDriverDiagnostic(deviceID) {
            case .success(let observation):
                driverObservations.append(observation)
            case .failure(let error):
                return .failure(.driverDiagnostics(error))
            }
        }

        let defaultInputUIDSecondPass: String
        switch readDefaultInputUID() {
        case .success(let value):
            defaultInputUIDSecondPass = value
        case .failure(let error):
            return .failure(error)
        }

        return .success(
            WorldwideVirtualMicrophoneEpochStateObservation(
                defaultInputUIDFirstPass:
                    defaultInputUIDFirstPass,
                visibleInputRunningFirstPass: visibleFirst,
                hiddenWriterRunningFirstPass: hiddenFirst,
                hiddenWriterRunningSecondPass: hiddenSecond,
                visibleInputRunningSecondPass: visibleSecond,
                defaultInputUIDSecondPass:
                    defaultInputUIDSecondPass,
                driverIdleProven:
                    WorldwideVirtualMicrophoneDriverDiagnosticSnapshot
                        .provesMirroredIdle(driverObservations)
            )
        )
    }

    private static func systemDefaultInputUID()
        -> Result<
            String,
            WorldwideVirtualMicrophoneEpochStateReadError
        > {
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            0,
            nil,
            &deviceIDSize,
            &deviceID
        )
        guard deviceStatus == noErr else {
            return .failure(.coreAudioStatus(deviceStatus))
        }
        guard deviceIDSize == UInt32(MemoryLayout<AudioDeviceID>.size) else {
            return .failure(.unexpectedPropertySize(deviceIDSize))
        }
        guard deviceID != kAudioObjectUnknown else {
            return .failure(.invalidDevice)
        }

        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let uidStatus = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &uidAddress,
                0,
                nil,
                &uidSize,
                pointer
            )
        }
        guard uidStatus == noErr else {
            return .failure(.coreAudioStatus(uidStatus))
        }
        guard uidSize == UInt32(MemoryLayout<CFString>.size) else {
            return .failure(.unexpectedPropertySize(uidSize))
        }
        let value = uid as String
        guard !value.isEmpty else {
            return .failure(.invalidDefaultInputUID)
        }
        return .success(value)
    }

    private static func systemDeviceRunning(
        _ deviceID: AudioDeviceID,
        readUInt32Property: UInt32PropertyRead
    ) -> Result<
        Bool,
        WorldwideVirtualMicrophoneEpochStateReadError
    > {
        guard deviceID != kAudioObjectUnknown else {
            return .failure(.invalidDevice)
        }
        // The host's own IO can be stopped while another process still pins
        // the shared epoch. Only system-wide inactivity permits this retry.
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = readUInt32Property(
            deviceID,
            address,
            &size,
            &value
        )
        guard status == noErr else {
            return .failure(.coreAudioStatus(status))
        }
        guard size == UInt32(MemoryLayout<UInt32>.size) else {
            return .failure(.unexpectedPropertySize(size))
        }
        return .success(value != 0)
    }
}

enum WorldwideVirtualMicrophoneEpochQuiescenceSample:
    Equatable,
    Sendable
{
    case idle
    case active
    case unreadable
}

struct WorldwideVirtualMicrophoneEpochQuiescenceProof: Sendable {
    private let requiredConsecutiveIdleObservations: Int
    private var consecutiveIdleObservationCount = 0

    init(requiredConsecutiveIdleObservations: Int = 2) {
        self.requiredConsecutiveIdleObservations = max(
            1,
            requiredConsecutiveIdleObservations
        )
    }

    mutating func consume(
        _ sample: WorldwideVirtualMicrophoneEpochQuiescenceSample
    ) -> Bool {
        switch sample {
        case .idle:
            consecutiveIdleObservationCount += 1
        case .active, .unreadable:
            consecutiveIdleObservationCount = 0
        }
        return consecutiveIdleObservationCount
            >= requiredConsecutiveIdleObservations
    }
}

enum WorldwideSharedClockEpochRecoveryPollOutcome:
    Equatable,
    Sendable
{
    case idleProven
    case staleOwner
    case timedOut
    case cancelled
}

struct WorldwideSharedClockEpochRecoveryPoller: Sendable {
    let maximumPollCount: Int
    let requiredConsecutiveIdleObservations: Int

    init(
        maximumPollCount: Int,
        requiredConsecutiveIdleObservations: Int
    ) {
        self.maximumPollCount = max(1, maximumPollCount)
        self.requiredConsecutiveIdleObservations = max(
            1,
            requiredConsecutiveIdleObservations
        )
    }

    func wait(
        isolation: isolated (any Actor)? = #isolation,
        sleep: () async throws -> Void,
        isCurrent: () -> Bool,
        sample: () -> WorldwideVirtualMicrophoneEpochQuiescenceSample
    ) async -> WorldwideSharedClockEpochRecoveryPollOutcome {
        var proof = WorldwideVirtualMicrophoneEpochQuiescenceProof(
            requiredConsecutiveIdleObservations:
                requiredConsecutiveIdleObservations
        )

        for _ in 0..<maximumPollCount {
            do {
                try await sleep()
            } catch {
                return .cancelled
            }
            guard isCurrent() else {
                return .staleOwner
            }
            guard proof.consume(sample()) else {
                continue
            }
            return isCurrent() ? .idleProven : .staleOwner
        }
        return isCurrent() ? .timedOut : .staleOwner
    }
}
