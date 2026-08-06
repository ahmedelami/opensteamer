import CoreAudio
import Foundation

/// The two output defaults that must remain non-BlackHole during worldwide duplex audio.
enum BlackHoleDefaultOutputKind: CaseIterable, Hashable, Sendable {
    case output
    case systemOutput

    var selector: AudioObjectPropertySelector {
        switch self {
        case .output:
            kAudioHardwarePropertyDefaultOutputDevice
        case .systemOutput:
            kAudioHardwarePropertyDefaultSystemOutputDevice
        }
    }
}

enum BlackHoleDefaultOutputMutationResult: Equatable, Sendable {
    case written(OSStatus)
    case currentOutputMismatch
    case readFailed
}

protocol WorldwideSafeOutputInvariantOperations: AnyObject, Sendable {
    func addDefaultOutputListener(
        kind: BlackHoleDefaultOutputKind,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListenerRegistration
    ) -> OSStatus

    func removeDefaultOutputListener(
        kind: BlackHoleDefaultOutputKind,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListenerRegistration
    ) -> OSStatus

    func currentDefaultOutputUID(
        _ kind: BlackHoleDefaultOutputKind
    ) throws -> String

    /// Resolves and validates one alive device with at least one output channel.
    func resolveUsableOutputDeviceID(uid: String) throws -> AudioDeviceID

    /// Keeps the last read immediately adjacent to the selector-specific write.
    func compareAndSetDefaultOutputDevice(
        _ deviceID: AudioDeviceID,
        kind: BlackHoleDefaultOutputKind,
        expectedCurrentUID: String
    ) -> BlackHoleDefaultOutputMutationResult
}

/// Summary of one worldwide safe-output invariant check.
public struct WorldwideSafeOutputInvariantResult:
    Equatable,
    Sendable
{
    public let changedDefaultOutput: Bool
    public let changedDefaultSystemOutput: Bool

    public var changedAnything: Bool {
        changedDefaultOutput || changedDefaultSystemOutput
    }
}

/// Stable two-selector observation used by the healthy-session invariant monitor.
public struct WorldwideSafeOutputInvariantVerification:
    Equatable,
    Sendable
{
    public let isSatisfied: Bool
    public let changedSincePreviousObservation: Bool
}

/// Enforces the worldwide duplex invariant that BlackHole may be the input, never an output.
///
/// When exactly one selector is BlackHole, the other current usable output supplies the preferred
/// replacement. When both are BlackHole, the built-in speaker is the deterministic fallback. The
/// default-input selector is deliberately absent from this type. Core Audio has no atomic
/// compare-and-set; an exact listener sequence plus readback rejects every observable overlap.
public final class WorldwideSafeOutputInvariant: @unchecked Sendable {
    public static let canonicalBlackHoleUID = "BlackHole2ch_UID"
    public static let builtInSpeakerUID = "BuiltInSpeakerDevice"

    private struct Snapshot: Equatable {
        let outputUID: String
        let systemOutputUID: String

        func uid(for kind: BlackHoleDefaultOutputKind) -> String {
            switch kind {
            case .output:
                outputUID
            case .systemOutput:
                systemOutputUID
            }
        }

        var isSafe: Bool {
            outputUID != WorldwideSafeOutputInvariant.canonicalBlackHoleUID
                && systemOutputUID
                    != WorldwideSafeOutputInvariant.canonicalBlackHoleUID
        }

        var preferredSafeUID: String? {
            if outputUID
                != WorldwideSafeOutputInvariant.canonicalBlackHoleUID {
                return outputUID
            }
            if systemOutputUID
                != WorldwideSafeOutputInvariant.canonicalBlackHoleUID {
                return systemOutputUID
            }
            return nil
        }
    }

    private final class ChangeSignal: @unchecked Sendable {
        private let condition = NSCondition()
        private var count: UInt64 = 0

        func record() {
            condition.lock()
            count &+= 1
            if count == 0 { count = 1 }
            condition.broadcast()
            condition.unlock()
        }

        func snapshot() -> UInt64 {
            condition.lock()
            defer { condition.unlock() }
            return count
        }

        func waitForAdvance(
            after previous: UInt64,
            timeout: TimeInterval
        ) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock()
            defer { condition.unlock() }
            while count <= previous {
                guard condition.wait(until: deadline) else {
                    return count > previous
                }
            }
            return true
        }
    }

    private struct Registration {
        let queue: DispatchQueue
        let signal: ChangeSignal
        let listeners: [
            BlackHoleDefaultOutputKind:
                CoreAudioPropertyListenerRegistration
        ]
    }

    private enum WriteProof {
        case proved
        case retryable
        case attemptedButUnproved
        case observableContention
    }

    private let operations:
        any WorldwideSafeOutputInvariantOperations
    private let operationQueue: DispatchQueue
    private let listenerQueue: DispatchQueue
    private let proofTimeout: TimeInterval
    private let operationQueueKey = DispatchSpecificKey<UUID>()
    private let operationQueueToken = UUID()
    private let maximumAttemptCount: Int
    private var lastObservedSnapshot: Snapshot?

    public convenience init() {
        self.init(
            operations: SystemWorldwideSafeOutputInvariantOperations(),
            operationQueue: DispatchQueue(
                label: "opensteamer.WorldwideSafeOutputInvariant.operations"
            ),
            listenerQueue: DispatchQueue(
                label: "opensteamer.WorldwideSafeOutputInvariant.listener"
            ),
            proofTimeout: 0.5,
            maximumAttemptCount: 3
        )
    }

    init(
        operations:
            any WorldwideSafeOutputInvariantOperations,
        operationQueue: DispatchQueue,
        listenerQueue: DispatchQueue = DispatchQueue(
            label: "opensteamer.WorldwideSafeOutputInvariant.listener.test"
        ),
        proofTimeout: TimeInterval = 0.05,
        maximumAttemptCount: Int = 3
    ) {
        self.operations = operations
        self.operationQueue = operationQueue
        self.listenerQueue = listenerQueue
        self.proofTimeout = max(0.001, proofTimeout)
        self.maximumAttemptCount = max(1, maximumAttemptCount)
        operationQueue.setSpecific(
            key: operationQueueKey,
            value: operationQueueToken
        )
    }

    /// Returns only after both output selectors are known not to reference BlackHole.
    public func enforce()
        throws -> WorldwideSafeOutputInvariantResult {
        try onOperationQueue {
            try withRegistration { registration in
                try enforceLocked(registration: registration)
            }
        }
    }

    /// Observes both selectors without mutation and reports a stable route change.
    public func verify()
        throws -> WorldwideSafeOutputInvariantVerification {
        try onOperationQueue {
            try withRegistration { registration in
                let current = try fencedSnapshot(
                    registration: registration
                )
                let changed = lastObservedSnapshot.map {
                    $0 != current
                } ?? true
                lastObservedSnapshot = current
                return WorldwideSafeOutputInvariantVerification(
                    isSatisfied: current.isSafe,
                    changedSincePreviousObservation: changed
                )
            }
        }
    }

    private func enforceLocked(registration: Registration)
        throws -> WorldwideSafeOutputInvariantResult {
        var changedDefaultOutput = false
        var changedDefaultSystemOutput = false

        for _ in 0..<maximumAttemptCount {
            let before = try fencedSnapshot(
                registration: registration
            )
            if before.isSafe {
                lastObservedSnapshot = before
                return WorldwideSafeOutputInvariantResult(
                    changedDefaultOutput: changedDefaultOutput,
                    changedDefaultSystemOutput:
                        changedDefaultSystemOutput
                )
            }

            let (safeUID, safeDeviceID) = try safeOutputTarget(
                for: before
            )

            var shouldRetry = false
            for kind in BlackHoleDefaultOutputKind.allCases
                where before.uid(for: kind) == Self.canonicalBlackHoleUID {
                switch writeAndProve(
                    deviceID: safeDeviceID,
                    kind: kind,
                    expectedUID: safeUID,
                    registration: registration
                ) {
                case .proved:
                    switch kind {
                    case .output:
                        changedDefaultOutput = true
                    case .systemOutput:
                        changedDefaultSystemOutput = true
                    }
                case .retryable:
                    shouldRetry = true
                case .attemptedButUnproved:
                    throw WorldwideSafeOutputInvariantError
                        .mutationUnproved
                case .observableContention:
                    throw WorldwideSafeOutputInvariantError
                        .observableContention
                }
            }

            let after = try fencedSnapshot(
                registration: registration
            )
            if after.isSafe {
                lastObservedSnapshot = after
                return WorldwideSafeOutputInvariantResult(
                    changedDefaultOutput: changedDefaultOutput,
                    changedDefaultSystemOutput:
                        changedDefaultSystemOutput
                )
            }
            if !shouldRetry {
                break
            }
        }

        throw WorldwideSafeOutputInvariantError
            .didNotConverge
    }

    private func snapshot() throws -> Snapshot {
        Snapshot(
            outputUID: try operations.currentDefaultOutputUID(.output),
            systemOutputUID:
                try operations.currentDefaultOutputUID(.systemOutput)
        )
    }

    /// Fences every two-selector observation with one exact listener sequence.
    private func fencedSnapshot(
        registration: Registration
    ) throws -> Snapshot {
        drainListenerQueue(registration)
        let sequence = registration.signal.snapshot()
        let first = try snapshot()
        drainListenerQueue(registration)
        guard registration.signal.snapshot() == sequence else {
            throw WorldwideSafeOutputInvariantError
                .observableContention
        }
        let second = try snapshot()
        drainListenerQueue(registration)
        guard registration.signal.snapshot() == sequence,
              second == first else {
            throw WorldwideSafeOutputInvariantError
                .observableContention
        }
        return second
    }

    private func safeOutputTarget(
        for snapshot: Snapshot
    ) throws -> (uid: String, deviceID: AudioDeviceID) {
        if let preferredUID = snapshot.preferredSafeUID,
           preferredUID != Self.builtInSpeakerUID,
           let preferredDeviceID = try? operations
            .resolveUsableOutputDeviceID(uid: preferredUID) {
            return (preferredUID, preferredDeviceID)
        }

        let deviceID = try operations.resolveUsableOutputDeviceID(
            uid: Self.builtInSpeakerUID
        )
        return (Self.builtInSpeakerUID, deviceID)
    }

    private func installRegistration() throws -> Registration {
        let signal = ChangeSignal()
        var installed: [
            BlackHoleDefaultOutputKind:
                CoreAudioPropertyListenerRegistration
        ] = [:]

        for kind in BlackHoleDefaultOutputKind.allCases {
            let listener = CoreAudioPropertyListenerRegistration {
                [signal] _, _ in
                signal.record()
            }
            let status = operations.addDefaultOutputListener(
                kind: kind,
                queue: listenerQueue,
                listener: listener
            )
            guard status == noErr else {
                for (installedKind, installedListener) in installed {
                    _ = operations.removeDefaultOutputListener(
                        kind: installedKind,
                        queue: listenerQueue,
                        listener: installedListener
                    )
                }
                throw WorldwideSafeOutputInvariantError
                    .listenerRegistrationFailed(
                        kind: kind,
                        status: status
                    )
            }
            installed[kind] = listener
        }

        return Registration(
            queue: listenerQueue,
            signal: signal,
            listeners: installed
        )
    }

    private func withRegistration<T>(
        _ body: (Registration) throws -> T
    ) throws -> T {
        let registration = try installRegistration()
        let result = Result {
            try body(registration)
        }
        let removalStatus = removeRegistration(registration)
        guard removalStatus == noErr else {
            throw WorldwideSafeOutputInvariantError
                .listenerRemovalFailed(status: removalStatus)
        }
        return try result.get()
    }

    private func removeRegistration(
        _ registration: Registration
    ) -> OSStatus {
        drainListenerQueue(registration)
        var firstFailure = noErr
        for kind in BlackHoleDefaultOutputKind.allCases {
            guard let listener = registration.listeners[kind] else {
                continue
            }
            let status = operations.removeDefaultOutputListener(
                kind: kind,
                queue: registration.queue,
                listener: listener
            )
            if status != noErr, firstFailure == noErr {
                firstFailure = status
            }
        }
        drainListenerQueue(registration)
        return firstFailure
    }

    private func writeAndProve(
        deviceID: AudioDeviceID,
        kind: BlackHoleDefaultOutputKind,
        expectedUID: String,
        registration: Registration
    ) -> WriteProof {
        drainListenerQueue(registration)
        let before = registration.signal.snapshot()
        guard outputFenceMatches(
            kind: kind,
            expectedUID: Self.canonicalBlackHoleUID,
            sequence: before,
            registration: registration
        ) else {
            return .retryable
        }

        let mutation = operations.compareAndSetDefaultOutputDevice(
            deviceID,
            kind: kind,
            expectedCurrentUID: Self.canonicalBlackHoleUID
        )
        switch mutation {
        case .currentOutputMismatch, .readFailed:
            return .retryable
        case .written(let status):
            guard status == noErr else {
                return .retryable
            }
        }

        // Core Audio has no atomic compare-and-set. The immediate comparison,
        // exact listener sequence, and stable readback detect observable overlap
        // across the residual read/write window; they do not claim atomicity.
        let expectedProof = Self.nextSignalSequence(after: before)
        guard registration.signal.waitForAdvance(
            after: before,
            timeout: proofTimeout
        ) else {
            return .attemptedButUnproved
        }

        let deadline = Date().addingTimeInterval(proofTimeout)
        repeat {
            drainListenerQueue(registration)
            let observed = registration.signal.snapshot()
            guard observed == expectedProof else {
                return .observableContention
            }
            if outputFenceMatches(
                kind: kind,
                expectedUID: expectedUID,
                sequence: observed,
                registration: registration
            ) {
                return .proved
            }
            Thread.sleep(forTimeInterval: 0.005)
        } while Date() < deadline

        drainListenerQueue(registration)
        return registration.signal.snapshot() == expectedProof
            ? .attemptedButUnproved
            : .observableContention
    }

    private func outputFenceMatches(
        kind: BlackHoleDefaultOutputKind,
        expectedUID: String,
        sequence: UInt64,
        registration: Registration
    ) -> Bool {
        drainListenerQueue(registration)
        guard registration.signal.snapshot() == sequence,
              (try? operations.currentDefaultOutputUID(kind))
                == expectedUID else {
            return false
        }
        drainListenerQueue(registration)
        guard registration.signal.snapshot() == sequence,
              (try? operations.currentDefaultOutputUID(kind))
                == expectedUID else {
            return false
        }
        drainListenerQueue(registration)
        return registration.signal.snapshot() == sequence
    }

    private func drainListenerQueue(_ registration: Registration) {
        registration.queue.sync {}
    }

    private static func nextSignalSequence(after value: UInt64) -> UInt64 {
        let next = value &+ 1
        return next == 0 ? 1 : next
    }

    private func onOperationQueue<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        if DispatchQueue.getSpecific(key: operationQueueKey)
            == operationQueueToken {
            return try body()
        }
        return try operationQueue.sync(execute: body)
    }
}

enum WorldwideSafeOutputInvariantError:
    LocalizedError,
    Equatable,
    Sendable
{
    case safeOutputUnavailable
    case listenerRegistrationFailed(
        kind: BlackHoleDefaultOutputKind,
        status: OSStatus
    )
    case listenerRemovalFailed(status: OSStatus)
    case mutationUnproved
    case observableContention
    case didNotConverge

    var errorDescription: String? {
        switch self {
        case .safeOutputUnavailable:
            "No usable non-BlackHole output device is available."
        case .listenerRegistrationFailed(let kind, let status):
            "Registering the \(kind.label) safety listener failed with "
                + "Core Audio status \(status)."
        case .listenerRemovalFailed(let status):
            "Removing a safe-output listener failed with Core Audio "
                + "status \(status)."
        case .mutationUnproved:
            "A safe-output mutation could not be proven by its exact "
                + "notification and readback."
        case .observableContention:
            "An overlapping output-route change was observed; microphone "
                + "admission is deferred."
        case .didNotConverge:
            "The worldwide safe-output invariant did not converge."
        }
    }
}

private extension BlackHoleDefaultOutputKind {
    var label: String {
        switch self {
        case .output:
            "default output"
        case .systemOutput:
            "default system output"
        }
    }
}

private final class SystemWorldwideSafeOutputInvariantOperations:
    WorldwideSafeOutputInvariantOperations,
    @unchecked Sendable
{
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    func addDefaultOutputListener(
        kind: BlackHoleDefaultOutputKind,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListenerRegistration
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kind.selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectAddPropertyListenerBlock(
            systemObject,
            &address,
            queue,
            listener.block
        )
    }

    func removeDefaultOutputListener(
        kind: BlackHoleDefaultOutputKind,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListenerRegistration
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kind.selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectRemovePropertyListenerBlock(
            systemObject,
            &address,
            queue,
            listener.block
        )
    }

    func currentDefaultOutputUID(
        _ kind: BlackHoleDefaultOutputKind
    ) throws -> String {
        let deviceID = try currentDefaultDeviceID(kind)
        guard let uid = deviceUID(deviceID), !uid.isEmpty else {
            throw CaptureError.audioDeviceConfiguration(
                "read \(kind.label) stable UID",
                kAudio_ParamError
            )
        }
        return uid
    }

    func resolveUsableOutputDeviceID(uid: String) throws -> AudioDeviceID {
        guard uid != WorldwideSafeOutputInvariant.canonicalBlackHoleUID
        else {
            throw WorldwideSafeOutputInvariantError
                .safeOutputUnavailable
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier: CFString = uid as CFString
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
        guard status == noErr,
              deviceID != kAudioObjectUnknown,
              deviceUID(deviceID) == uid,
              try isAlive(deviceID),
              try outputChannelCount(deviceID) > 0 else {
            throw WorldwideSafeOutputInvariantError
                .safeOutputUnavailable
        }
        return deviceID
    }

    func compareAndSetDefaultOutputDevice(
        _ deviceID: AudioDeviceID,
        kind: BlackHoleDefaultOutputKind,
        expectedCurrentUID: String
    ) -> BlackHoleDefaultOutputMutationResult {
        do {
            guard try currentDefaultOutputUID(kind)
                    == expectedCurrentUID else {
                return .currentOutputMismatch
            }
        } catch {
            return .readFailed
        }

        // This is the narrowest comparison/write window Core Audio exposes.
        // The caller's listener sequence and readback fence observable overlap.
        var mutableDeviceID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kind.selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return .written(
            AudioObjectSetPropertyData(
                systemObject,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<AudioDeviceID>.size),
                &mutableDeviceID
            )
        )
    }

    private func currentDefaultDeviceID(
        _ kind: BlackHoleDefaultOutputKind
    ) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kind.selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr,
              deviceID != kAudioObjectUnknown else {
            throw CaptureError.audioDeviceConfiguration(
                "read \(kind.label)",
                status
            )
        }
        return deviceID
    }

    private func isAlive(_ deviceID: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
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
                "read output-device liveness",
                status
            )
        }
        return value != 0
    }

    private func outputChannelCount(
        _ deviceID: AudioDeviceID
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        )
        guard status == noErr, size > 0 else {
            throw CaptureError.audioDeviceConfiguration(
                "read output stream-configuration size",
                status
            )
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            storage
        )
        guard status == noErr else {
            throw CaptureError.audioDeviceConfiguration(
                "read output stream configuration",
                status
            )
        }

        let buffers = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.reduce(0) { partial, buffer in
            partial &+ buffer.mNumberChannels
        }
    }

    private func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
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
        guard status == noErr else { return nil }
        return value as String
    }
}
