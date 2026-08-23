import CoreAudio
import CryptoKit
import Darwin
import Foundation

private enum Contract {
    static let schema = "opensteamer.v7-default-route-guardian.v1"
    static let stateSchema = "opensteamer.v7-default-route-snapshot.v1"
    static let visibleUID = "com.elamin.opensteamer.virtual-microphone.input"
    static let writerUID = "com.elamin.opensteamer.virtual-microphone.writer"
    static let legacyVisibleUID = "BlackHole2ch_UID"
    static let legacyWriterUID = "BlackHole2ch_2_UID"
    static let liveOptIn = "I_UNDERSTAND_THIS_TEMPORARILY_CHANGES_DEFAULT_INPUT"
    static let maximumUIDBytes = 1_024
    static let restorationDeadlineSeconds = 3.0
    static let brokerIdleSeconds = 9_900.0
    static let brokerMaximumSeconds = 20_000.0
    static let evidenceRoot = "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v7"
    static let stateRelativeSuffix = "/probes/vpio-default-route-state.json"
    static let evidenceOwnerUID: uid_t = 501
    static let maximumStateBytes = 16_384
}

private struct GuardianError: Error {
    let code: String
}

private struct Defaults: Codable, Equatable {
    let inputUID: String
    let outputUID: String
    let systemOutputUID: String
}

private struct SnapshotState: Codable {
    let schema: String
    let createdAtMonotonicNs: UInt64
    let listenerSequenceAtSnapshot: UInt64
    let defaults: Defaults
}

private struct ListenerCheckpoint: Codable, Equatable {
    let sequence: UInt64
    let inputNotifications: UInt64
    let outputNotifications: UInt64
    let systemOutputNotifications: UInt64
    let overflowed: Bool

    static let zero = ListenerCheckpoint(
        sequence: 0,
        inputNotifications: 0,
        outputNotifications: 0,
        systemOutputNotifications: 0,
        overflowed: false
    )

    func delta(since earlier: ListenerCheckpoint) -> ListenerCheckpoint? {
        guard !overflowed, !earlier.overflowed,
              sequence >= earlier.sequence,
              inputNotifications >= earlier.inputNotifications,
              outputNotifications >= earlier.outputNotifications,
              systemOutputNotifications >= earlier.systemOutputNotifications else {
            return nil
        }
        return ListenerCheckpoint(
            sequence: sequence - earlier.sequence,
            inputNotifications: inputNotifications
                - earlier.inputNotifications,
            outputNotifications: outputNotifications
                - earlier.outputNotifications,
            systemOutputNotifications: systemOutputNotifications
                - earlier.systemOutputNotifications,
            overflowed: false
        )
    }
}

private struct ListenerEvidence: Codable {
    let sequenceAtSnapshot: UInt64
    let finalSequence: UInt64
    let inputNotifications: UInt64
    let outputNotifications: UInt64
    let systemOutputNotifications: UInt64
    let postPublishEpochEstablished: Bool
    let postPublishEpoch: ListenerCheckpoint
    let postPublishEpochFingerprint: String
    let absoluteFinal: ListenerCheckpoint
    let countersMonotonic: Bool
    let preEpochBaselineArmed: Bool
    let preEpochUIDMismatchOrReadFailure: Bool
    let removedAndDrained: Bool
}

private struct GuardianResult: Codable {
    let schema: String
    let mode: String
    let passed: Bool
    let childExitCode: Int32
    let childTimedOut: Bool
    let baselineStable: Bool
    let baselineInputFingerprint: String
    let baselineOutputFingerprint: String
    let baselineSystemOutputFingerprint: String
    let finalInputFingerprint: String
    let finalOutputFingerprint: String
    let finalSystemOutputFingerprint: String
    let inputRestored: Bool
    let restorationAttempted: Bool
    let restorationListenerObserved: Bool
    let newerInputChoicePreserved: Bool
    let outputsUnchanged: Bool
    let hiddenEndpointNeverDefault: Bool
    let virtualEndpointsNeverOutputDefault: Bool
    let listener: ListenerEvidence
    let failureCode: String
}

private enum InputDecision: String {
    case alreadyRestored
    case restoreOwnedProduct
    case preserveNewerChoice
    case rejectUnsafeBaseline
    case rejectUnsafeCurrent
}

private enum RestoreFenceDecision: String {
    case proceed
    case alreadyRestored
    case preserveNewerChoice
    case rejectUnsafeBaseline
    case rejectUnsafeCurrent
    case rejectOutputDrift
    case rejectSequenceDrift
}

private enum DecisionModel {
    static func inputDecision(baseline: String, current: String) -> InputDecision {
        if isForbiddenRestorationInput(baseline) {
            return .rejectUnsafeBaseline
        }
        if current == baseline {
            return .alreadyRestored
        }
        if current == Contract.visibleUID {
            return .restoreOwnedProduct
        }
        if isForbiddenRestorationInput(current) {
            return .rejectUnsafeCurrent
        }
        return .preserveNewerChoice
    }

    static func isForbiddenOutput(_ uid: String) -> Bool {
        [
            Contract.visibleUID,
            Contract.writerUID,
            Contract.legacyVisibleUID,
            Contract.legacyWriterUID,
        ].contains(uid)
    }

    static func isForbiddenRestorationInput(_ uid: String) -> Bool {
        [Contract.writerUID, Contract.legacyWriterUID].contains(uid)
    }

    static func safeOutputs(_ defaults: Defaults) -> Bool {
        !isForbiddenOutput(defaults.outputUID)
            && !isForbiddenOutput(defaults.systemOutputUID)
    }

    static func hiddenNeverDefault(_ defaults: Defaults) -> Bool {
        ![
            defaults.inputUID,
            defaults.outputUID,
            defaults.systemOutputUID,
        ].contains(Contract.writerUID)
            && ![
                defaults.inputUID,
                defaults.outputUID,
                defaults.systemOutputUID,
            ].contains(Contract.legacyWriterUID)
    }

    static func restorationOwnershipSafe(
        restored: Bool,
        newerChoicePreserved: Bool
    ) -> Bool {
        restored || newerChoicePreserved
    }

    static func postPublishFenceSafe(
        baseline: Defaults,
        first: Defaults,
        second: Defaults,
        before: ListenerCheckpoint,
        after: ListenerCheckpoint
    ) -> Bool {
        !before.overflowed
            && before == after
            && first == baseline
            && second == baseline
            && safeOutputs(first)
            && safeOutputs(second)
            && hiddenNeverDefault(first)
            && hiddenNeverDefault(second)
            && !isForbiddenRestorationInput(first.inputUID)
    }

    static func postPublishOutputNotificationsUnchanged(
        epoch: ListenerCheckpoint,
        final: ListenerCheckpoint
    ) -> Bool {
        guard let delta = final.delta(since: epoch) else { return false }
        return delta.outputNotifications == 0
            && delta.systemOutputNotifications == 0
    }

    static func ownedRestoreFence(
        baseline: Defaults,
        initial: Defaults,
        adjacent: Defaults,
        initialSequenceBefore: UInt64,
        initialSequenceAfter: UInt64,
        adjacentSequenceBefore: UInt64,
        adjacentSequenceAfter: UInt64
    ) -> RestoreFenceDecision {
        guard safeOutputs(baseline),
              !isForbiddenRestorationInput(baseline.inputUID) else {
            return .rejectUnsafeBaseline
        }
        let initialDecision = inputDecision(
            baseline: baseline.inputUID,
            current: initial.inputUID
        )
        switch initialDecision {
        case .alreadyRestored: return .alreadyRestored
        case .preserveNewerChoice: return .preserveNewerChoice
        case .rejectUnsafeBaseline: return .rejectUnsafeBaseline
        case .rejectUnsafeCurrent: return .rejectUnsafeCurrent
        case .restoreOwnedProduct: break
        }
        guard initial.outputUID == baseline.outputUID,
              initial.systemOutputUID == baseline.systemOutputUID,
              adjacent.outputUID == baseline.outputUID,
              adjacent.systemOutputUID == baseline.systemOutputUID,
              safeOutputs(initial), safeOutputs(adjacent),
              hiddenNeverDefault(initial), hiddenNeverDefault(adjacent) else {
            return .rejectOutputDrift
        }
        guard initialSequenceBefore == initialSequenceAfter,
              initialSequenceAfter == adjacentSequenceBefore,
              adjacentSequenceBefore == adjacentSequenceAfter else {
            return .rejectSequenceDrift
        }
        switch inputDecision(
            baseline: baseline.inputUID,
            current: adjacent.inputUID
        ) {
        case .restoreOwnedProduct: return .proceed
        case .alreadyRestored: return .alreadyRestored
        case .preserveNewerChoice: return .preserveNewerChoice
        case .rejectUnsafeBaseline: return .rejectUnsafeBaseline
        case .rejectUnsafeCurrent: return .rejectUnsafeCurrent
        }
    }
}

private enum CoreAudioDefaults {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func snapshot() throws -> Defaults {
        Defaults(
            inputUID: try defaultUID(kAudioHardwarePropertyDefaultInputDevice),
            outputUID: try defaultUID(kAudioHardwarePropertyDefaultOutputDevice),
            systemOutputUID: try defaultUID(kAudioHardwarePropertyDefaultSystemOutputDevice)
        )
    }

    static func defaultUID(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            system,
            &address,
            0,
            nil,
            &size,
            &device
        ) == noErr, device != kAudioObjectUnknown else {
            throw GuardianError(code: "default_device_read_failed")
        }
        return try uid(device)
    }

    static func uid(_ device: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr, let value else {
            throw GuardianError(code: "device_uid_read_failed")
        }
        let result = value.takeUnretainedValue() as String
        guard !result.isEmpty,
              result.utf8.count <= Contract.maximumUIDBytes,
              result.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }) else {
            throw GuardianError(code: "device_uid_invalid")
        }
        return result
    }

    static func resolve(_ uid: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier: CFString = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var outputSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let qualifierSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(
                system,
                &address,
                qualifierSize,
                pointer,
                &outputSize,
                &device
            )
        }
        guard status == noErr,
              outputSize == UInt32(MemoryLayout<AudioDeviceID>.size),
              device != kAudioObjectUnknown,
              try self.uid(device) == uid else {
            throw GuardianError(code: "saved_input_uid_unavailable")
        }
        return device
    }

    static func isAvailable(_ uid: String) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier: CFString = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var outputSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let qualifierSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(
                system,
                &address,
                qualifierSize,
                pointer,
                &outputSize,
                &device
            )
        }
        if status != noErr || device == kAudioObjectUnknown { return false }
        guard outputSize == UInt32(MemoryLayout<AudioDeviceID>.size) else {
            throw GuardianError(code: "device_translation_size_invalid")
        }
        return try self.uid(device) == uid
    }

    static func prepareDefaultInputWrite(_ uid: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(system, &address, &settable) == noErr,
              settable.boolValue else {
            throw GuardianError(code: "default_input_not_settable")
        }
        return try resolve(uid)
    }

    static func setPreparedDefaultInput(_ device: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = device
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectSetPropertyData(
            system,
            &address,
            0,
            nil,
            size,
            &device
        ) == noErr else {
            throw GuardianError(code: "default_input_restore_write_failed")
        }
    }
}

private final class ListenerCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var input: UInt64 = 0
    private var output: UInt64 = 0
    private var systemOutput: UInt64 = 0
    private var overflowed = false
    private var preEpochBaseline: Defaults?
    private var preEpochUIDMismatchOrReadFailure = false
    private var preEpochClosed = false

    private static func increment(_ value: UInt64) -> (UInt64, Bool) {
        guard value < UInt64.max else { return (value, true) }
        return (value + 1, false)
    }

    func record(
        _ addresses: UnsafePointer<AudioObjectPropertyAddress>?,
        count: UInt32,
        observedDefaults: Defaults?
    ) {
        lock.lock()
        defer { lock.unlock() }
        if count == 0 || addresses == nil {
            overflowed = true
            if preEpochBaseline != nil, !preEpochClosed {
                preEpochUIDMismatchOrReadFailure = true
            }
        }
        if let baseline = preEpochBaseline, !preEpochClosed,
           observedDefaults != baseline {
            preEpochUIDMismatchOrReadFailure = true
        }
        for index in 0..<Int(count) {
            let sequenceIncrement = Self.increment(sequence)
            sequence = sequenceIncrement.0
            overflowed = overflowed || sequenceIncrement.1
            guard let addresses else {
                overflowed = true
                continue
            }
            switch addresses[index].mSelector {
            case kAudioHardwarePropertyDefaultInputDevice:
                let increment = Self.increment(input)
                input = increment.0
                overflowed = overflowed || increment.1
            case kAudioHardwarePropertyDefaultOutputDevice:
                let increment = Self.increment(output)
                output = increment.0
                overflowed = overflowed || increment.1
            case kAudioHardwarePropertyDefaultSystemOutputDevice:
                let increment = Self.increment(systemOutput)
                systemOutput = increment.0
                overflowed = overflowed || increment.1
            default: overflowed = true
            }
        }
    }

    private func checkpointWithoutLock() -> ListenerCheckpoint {
        ListenerCheckpoint(
            sequence: sequence,
            inputNotifications: input,
            outputNotifications: output,
            systemOutputNotifications: systemOutput,
            overflowed: overflowed
        )
    }

    func snapshot() -> ListenerCheckpoint {
        lock.lock()
        defer { lock.unlock() }
        return checkpointWithoutLock()
    }

    func armPreEpochBaseline(
        _ baseline: Defaults,
        expected: ListenerCheckpoint
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard preEpochBaseline == nil,
              !preEpochClosed,
              !overflowed,
              checkpointWithoutLock() == expected else {
            return false
        }
        preEpochBaseline = baseline
        return true
    }

    func commitPostPublishEpoch(expected: ListenerCheckpoint) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard preEpochBaseline != nil,
              !preEpochClosed,
              !preEpochUIDMismatchOrReadFailure,
              !overflowed,
              checkpointWithoutLock() == expected else {
            return false
        }
        preEpochClosed = true
        return true
    }

    func preEpochStatus() -> (armed: Bool, failed: Bool, closed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (
            preEpochBaseline != nil,
            preEpochUIDMismatchOrReadFailure,
            preEpochClosed
        )
    }

}

private final class DefaultListener {
    private let queue = DispatchQueue(label: "com.elamin.opensteamer.v7-default-route-guardian")
    private let counters = ListenerCounters()
    private var block: AudioObjectPropertyListenerBlock?
    private var addresses: [AudioObjectPropertyAddress] = []
    private var activePostPublishEpoch: ListenerCheckpoint?

    func install() throws {
        guard block == nil, addresses.isEmpty else {
            throw GuardianError(code: "listener_already_installed")
        }
        let counters = self.counters
        let callback: AudioObjectPropertyListenerBlock = { count, addresses in
            counters.record(
                addresses,
                count: count,
                observedDefaults: try? CoreAudioDefaults.snapshot()
            )
        }
        block = callback
        for selector in [
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectAddPropertyListenerBlock(
                CoreAudioDefaults.system,
                &address,
                queue,
                callback
            ) == noErr else {
                _ = removeAndDrain()
                throw GuardianError(code: "listener_install_failed")
            }
            addresses.append(address)
        }
    }

    func evidence(sequenceAtSnapshot: UInt64, removedAndDrained: Bool) -> ListenerEvidence {
        makeEvidence(
            sequenceAtSnapshot: sequenceAtSnapshot,
            absolute: counters.snapshot(),
            epoch: activePostPublishEpoch,
            removedAndDrained: removedAndDrained
        )
    }

    private func makeEvidence(
        sequenceAtSnapshot: UInt64,
        absolute: ListenerCheckpoint,
        epoch: ListenerCheckpoint?,
        removedAndDrained: Bool
    ) -> ListenerEvidence {
        let effectiveEpoch = epoch ?? .zero
        let delta = absolute.delta(since: effectiveEpoch)
        let preEpochStatus = counters.preEpochStatus()
        return ListenerEvidence(
            sequenceAtSnapshot: sequenceAtSnapshot,
            finalSequence: absolute.sequence,
            inputNotifications: delta?.inputNotifications ?? UInt64.max,
            outputNotifications: delta?.outputNotifications ?? UInt64.max,
            systemOutputNotifications:
                delta?.systemOutputNotifications ?? UInt64.max,
            postPublishEpochEstablished: epoch != nil,
            postPublishEpoch: effectiveEpoch,
            postPublishEpochFingerprint:
                listenerCheckpointFingerprint(effectiveEpoch),
            absoluteFinal: absolute,
            countersMonotonic: delta != nil,
            preEpochBaselineArmed: preEpochStatus.armed,
            preEpochUIDMismatchOrReadFailure: preEpochStatus.failed,
            removedAndDrained: removedAndDrained
        )
    }

    func sequence() -> UInt64 { counters.snapshot().sequence }

    func drainAndCheckpoint() -> ListenerCheckpoint {
        queue.sync {}
        return counters.snapshot()
    }

    func armPreEpochBaseline(_ baseline: Defaults) -> Bool {
        var armed = false
        queue.sync {
            let checkpoint = counters.snapshot()
            armed = checkpoint == .zero
                && counters.armPreEpochBaseline(
                    baseline,
                    expected: checkpoint
                )
        }
        return armed
    }

    func preparePostPublishEpoch(
        baseline: Defaults
    ) throws -> (ListenerCheckpoint, ListenerEvidence) {
        guard activePostPublishEpoch == nil else {
            throw GuardianError(code: "post_publish_epoch_already_established")
        }
        let before = drainAndCheckpoint()
        let first = try CoreAudioDefaults.snapshot()
        Thread.sleep(forTimeInterval: 0.10)
        let second = try CoreAudioDefaults.snapshot()
        let after = drainAndCheckpoint()
        let preEpochStatus = counters.preEpochStatus()
        guard DecisionModel.postPublishFenceSafe(
            baseline: baseline,
            first: first,
            second: second,
            before: before,
            after: after
        ), preEpochStatus.armed,
           !preEpochStatus.failed,
           !preEpochStatus.closed else {
            throw GuardianError(code: "post_publish_default_fence_changed")
        }
        return (
            after,
            makeEvidence(
                sequenceAtSnapshot: after.sequence,
                absolute: after,
                epoch: after,
                removedAndDrained: false
            )
        )
    }

    func commitPostPublishEpoch(expected: ListenerCheckpoint) -> Bool {
        var committed = false
        queue.sync {
            let current = counters.snapshot()
            if activePostPublishEpoch == nil,
               !current.overflowed,
               current == expected,
               counters.commitPostPublishEpoch(expected: expected) {
                activePostPublishEpoch = expected
                committed = true
            }
        }
        return committed
    }

    func hasPostPublishEpoch() -> Bool {
        activePostPublishEpoch != nil
    }

    func removeAndDrain() -> Bool {
        guard let callback = block else { return addresses.isEmpty }
        var remaining: [AudioObjectPropertyAddress] = []
        for stored in addresses {
            var address = stored
            if AudioObjectRemovePropertyListenerBlock(
                CoreAudioDefaults.system,
                &address,
                queue,
                callback
            ) != noErr {
                remaining.append(stored)
            }
        }
        queue.sync {}
        addresses = remaining
        if addresses.isEmpty { block = nil }
        return addresses.isEmpty
    }

    deinit { _ = removeAndDrain() }
}

private struct Restoration {
    let final: Defaults
    let restored: Bool
    let attempted: Bool
    let listenerObserved: Bool
    let newerChoicePreserved: Bool
    let outputsUnchanged: Bool
    let hiddenNeverDefault: Bool
    let virtualNeverOutput: Bool
    let failureCode: String?
}

private enum Restorer {
    static func restore(
        baseline: Defaults,
        listener: DefaultListener
    ) -> Restoration {
        do {
            let initialSequenceBefore = listener.sequence()
            let initial = try CoreAudioDefaults.snapshot()
            let initialSequenceAfter = listener.sequence()
            let outputsUnchanged = initial.outputUID == baseline.outputUID
                && initial.systemOutputUID == baseline.systemOutputUID
            let hiddenSafe = DecisionModel.hiddenNeverDefault(initial)
            let outputsSafe = DecisionModel.safeOutputs(initial)
            guard DecisionModel.safeOutputs(baseline),
                  !DecisionModel.isForbiddenRestorationInput(baseline.inputUID),
                  outputsUnchanged, hiddenSafe, outputsSafe else {
                return Restoration(
                    final: initial,
                    restored: false,
                    attempted: false,
                    listenerObserved: false,
                    newerChoicePreserved: false,
                    outputsUnchanged: outputsUnchanged,
                    hiddenNeverDefault: hiddenSafe,
                    virtualNeverOutput: outputsSafe,
                    failureCode: "unsafe_or_changed_output_route"
                )
            }
            guard initialSequenceBefore == initialSequenceAfter else {
                return Restoration(
                    final: initial,
                    restored: false,
                    attempted: false,
                    listenerObserved: true,
                    newerChoicePreserved: false,
                    outputsUnchanged: true,
                    hiddenNeverDefault: true,
                    virtualNeverOutput: true,
                    failureCode: "default_route_sequence_changed_during_snapshot"
                )
            }

            switch DecisionModel.inputDecision(
                baseline: baseline.inputUID,
                current: initial.inputUID
            ) {
            case .alreadyRestored:
                return Restoration(
                    final: initial,
                    restored: true,
                    attempted: false,
                    listenerObserved: false,
                    newerChoicePreserved: false,
                    outputsUnchanged: true,
                    hiddenNeverDefault: true,
                    virtualNeverOutput: true,
                    failureCode: nil
                )
            case .preserveNewerChoice:
                return Restoration(
                    final: initial,
                    restored: false,
                    attempted: false,
                    listenerObserved: false,
                    newerChoicePreserved: true,
                    outputsUnchanged: true,
                    hiddenNeverDefault: true,
                    virtualNeverOutput: true,
                    failureCode: "newer_input_choice_preserved"
                )
            case .rejectUnsafeBaseline:
                return Restoration(
                    final: initial,
                    restored: false,
                    attempted: false,
                    listenerObserved: false,
                    newerChoicePreserved: false,
                    outputsUnchanged: true,
                    hiddenNeverDefault: hiddenSafe,
                    virtualNeverOutput: true,
                    failureCode: "unsafe_input_restore_baseline"
                )
            case .rejectUnsafeCurrent:
                return Restoration(
                    final: initial,
                    restored: false,
                    attempted: false,
                    listenerObserved: false,
                    newerChoicePreserved: false,
                    outputsUnchanged: true,
                    hiddenNeverDefault: hiddenSafe,
                    virtualNeverOutput: true,
                    failureCode: "unowned_virtual_input_choice"
                )
            case .restoreOwnedProduct:
                // Resolve and prove the saved physical endpoint before taking the adjacent
                // compare-and-set fence. No lookup or other fallible work is allowed between
                // the second snapshot and the property write.
                let preparedDevice = try CoreAudioDefaults.prepareDefaultInputWrite(
                    baseline.inputUID
                )
                let adjacentSequenceBefore = listener.sequence()
                let adjacent = try CoreAudioDefaults.snapshot()
                let adjacentSequenceAfter = listener.sequence()
                let fence = DecisionModel.ownedRestoreFence(
                    baseline: baseline,
                    initial: initial,
                    adjacent: adjacent,
                    initialSequenceBefore: initialSequenceBefore,
                    initialSequenceAfter: initialSequenceAfter,
                    adjacentSequenceBefore: adjacentSequenceBefore,
                    adjacentSequenceAfter: adjacentSequenceAfter
                )
                switch fence {
                case .alreadyRestored:
                    return Restoration(
                        final: adjacent,
                        restored: true,
                        attempted: false,
                        listenerObserved: false,
                        newerChoicePreserved: false,
                        outputsUnchanged: true,
                        hiddenNeverDefault: true,
                        virtualNeverOutput: true,
                        failureCode: nil
                    )
                case .preserveNewerChoice:
                    return Restoration(
                        final: adjacent,
                        restored: false,
                        attempted: false,
                        listenerObserved: false,
                        newerChoicePreserved: true,
                        outputsUnchanged: true,
                        hiddenNeverDefault: true,
                        virtualNeverOutput: true,
                        failureCode: "newer_input_choice_preserved_at_write_fence"
                    )
                case .rejectUnsafeBaseline:
                    return restorationFailure(
                        final: adjacent,
                        code: "unsafe_input_restore_baseline"
                    )
                case .rejectUnsafeCurrent:
                    return restorationFailure(
                        final: adjacent,
                        code: "unowned_virtual_input_choice_at_write_fence"
                    )
                case .rejectOutputDrift:
                    return restorationFailure(
                        final: adjacent,
                        code: "output_route_changed_at_write_fence"
                    )
                case .rejectSequenceDrift:
                    return restorationFailure(
                        final: adjacent,
                        code: "default_route_sequence_changed_at_write_fence"
                    )
                case .proceed: break
                }

                let beforeSequence = adjacentSequenceAfter
                try CoreAudioDefaults.setPreparedDefaultInput(preparedDevice)
                let deadline = ProcessInfo.processInfo.systemUptime
                    + Contract.restorationDeadlineSeconds
                var observed = false
                while ProcessInfo.processInfo.systemUptime < deadline {
                    let after = try CoreAudioDefaults.snapshot()
                    observed = observed || listener.sequence() > beforeSequence
                    let outputsRemain = after.outputUID == baseline.outputUID
                        && after.systemOutputUID == baseline.systemOutputUID
                    let hiddenRemain = DecisionModel.hiddenNeverDefault(after)
                    let virtualOutputsRemain = DecisionModel.safeOutputs(after)
                    if !outputsRemain || !hiddenRemain || !virtualOutputsRemain {
                        return Restoration(
                            final: after,
                            restored: false,
                            attempted: true,
                            listenerObserved: observed,
                            newerChoicePreserved: false,
                            outputsUnchanged: outputsRemain,
                            hiddenNeverDefault: hiddenRemain,
                            virtualNeverOutput: virtualOutputsRemain,
                            failureCode: "route_changed_during_input_restore"
                        )
                    }
                    if after.inputUID == baseline.inputUID, observed {
                        return Restoration(
                            final: after,
                            restored: true,
                            attempted: true,
                            listenerObserved: true,
                            newerChoicePreserved: false,
                            outputsUnchanged: outputsRemain,
                            hiddenNeverDefault: hiddenRemain,
                            virtualNeverOutput: virtualOutputsRemain,
                            failureCode: nil
                        )
                    }
                    if after.inputUID != Contract.visibleUID,
                       after.inputUID != baseline.inputUID {
                        return Restoration(
                            final: after,
                            restored: false,
                            attempted: true,
                            listenerObserved: observed,
                            newerChoicePreserved: !DecisionModel.isForbiddenRestorationInput(
                                after.inputUID
                            ),
                            outputsUnchanged: true,
                            hiddenNeverDefault: true,
                            virtualNeverOutput: true,
                            failureCode: "newer_input_choice_observed_after_restore_write"
                        )
                    }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                let after = try CoreAudioDefaults.snapshot()
                return Restoration(
                    final: after,
                    restored: false,
                    attempted: true,
                    listenerObserved: observed,
                    newerChoicePreserved: false,
                    outputsUnchanged: after.outputUID == baseline.outputUID
                        && after.systemOutputUID == baseline.systemOutputUID,
                    hiddenNeverDefault: DecisionModel.hiddenNeverDefault(after),
                    virtualNeverOutput: DecisionModel.safeOutputs(after),
                    failureCode: "conditional_input_restore_unproved"
                )
            }
        } catch let error as GuardianError {
            let unavailable = Defaults(
                inputUID: "unavailable",
                outputUID: "unavailable",
                systemOutputUID: "unavailable"
            )
            return Restoration(
                final: unavailable,
                restored: false,
                attempted: false,
                listenerObserved: false,
                newerChoicePreserved: false,
                outputsUnchanged: false,
                hiddenNeverDefault: false,
                virtualNeverOutput: false,
                failureCode: error.code
            )
        } catch {
            let unavailable = Defaults(
                inputUID: "unavailable",
                outputUID: "unavailable",
                systemOutputUID: "unavailable"
            )
            return Restoration(
                final: unavailable,
                restored: false,
                attempted: false,
                listenerObserved: false,
                newerChoicePreserved: false,
                outputsUnchanged: false,
                hiddenNeverDefault: false,
                virtualNeverOutput: false,
                failureCode: "unexpected_restore_failure"
            )
        }
    }

    private static func restorationFailure(
        final: Defaults,
        code: String
    ) -> Restoration {
        Restoration(
            final: final,
            restored: false,
            attempted: false,
            listenerObserved: false,
            newerChoicePreserved: false,
            outputsUnchanged: false,
            hiddenNeverDefault: DecisionModel.hiddenNeverDefault(final),
            virtualNeverOutput: DecisionModel.safeOutputs(final),
            failureCode: code
        )
    }
}

private enum FileIO {
    static func write<T: Encodable>(_ value: T, to path: String) throws {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096 else {
            throw GuardianError(code: "unsafe_result_path")
        }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: parent.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw GuardianError(code: "result_parent_unavailable")
        }
        let temporary = parent.appendingPathComponent(
            ".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw GuardianError(code: "result_create_failed")
        }
        defer {
            _ = Darwin.close(descriptor)
            _ = unlink(temporary.path)
        }
        guard geteuid() == Contract.evidenceOwnerUID,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw GuardianError(code: "result_metadata_set_failed")
        }
        let wrote = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard wrote == data.count, Darwin.fsync(descriptor) == 0 else {
            throw GuardianError(code: "result_write_failed")
        }
        guard Darwin.link(temporary.path, url.path) == 0 else {
            throw GuardianError(code: "result_publish_failed")
        }
        guard unlink(temporary.path) == 0 else {
            throw GuardianError(code: "result_temporary_unlink_failed")
        }
    }

    static func readState(
        _ path: String,
        expectedSHA256: String
    ) throws -> SnapshotState {
        try requireExactStatePath(path)
        guard expectedSHA256.count == 64,
              expectedSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw GuardianError(code: "snapshot_state_hash_invalid")
        }
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw GuardianError(code: "snapshot_state_open_failed")
        }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == Contract.evidenceOwnerUID,
              before.st_nlink == 1,
              before.st_mode & 0o777 == 0o600,
              before.st_size >= 0,
              before.st_size <= Contract.maximumStateBytes else {
            throw GuardianError(code: "snapshot_state_metadata_invalid")
        }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { storage in
                Darwin.read(
                    descriptor,
                    storage.baseAddress?.advanced(by: offset),
                    remaining
                )
            }
            guard count > 0 else {
                throw GuardianError(code: "snapshot_state_read_failed")
            }
            offset += count
        }
        var trailing: UInt8 = 0
        guard Darwin.read(descriptor, &trailing, 1) == 0 else {
            throw GuardianError(code: "snapshot_state_changed_during_read")
        }
        var after = stat()
        var named = stat()
        guard fstat(descriptor, &after) == 0,
              lstat(path, &named) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_dev == named.st_dev,
              before.st_ino == named.st_ino,
              (named.st_mode & S_IFMT) == S_IFREG,
              named.st_uid == Contract.evidenceOwnerUID,
              named.st_nlink == 1,
              named.st_mode & 0o777 == 0o600 else {
            throw GuardianError(code: "snapshot_state_replaced_during_read")
        }
        let data = Data(bytes)
        let observedSHA256 = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        guard observedSHA256 == expectedSHA256 else {
            throw GuardianError(code: "snapshot_state_hash_mismatch")
        }
        guard data.count <= Contract.maximumStateBytes else {
            throw GuardianError(code: "snapshot_state_too_large")
        }
        let state = try JSONDecoder().decode(SnapshotState.self, from: data)
        guard state.schema == Contract.stateSchema,
              state.createdAtMonotonicNs > 0,
              state.listenerSequenceAtSnapshot == 0,
              DecisionModel.safeOutputs(state.defaults),
              DecisionModel.hiddenNeverDefault(state.defaults),
              !DecisionModel.isForbiddenRestorationInput(state.defaults.inputUID) else {
            throw GuardianError(code: "snapshot_state_invalid")
        }
        return state
    }

    static func requireExactStatePath(_ path: String) throws {
        guard path.hasPrefix(Contract.evidenceRoot + "/"),
              path.utf8.count <= 4_096,
              URL(fileURLWithPath: path).standardizedFileURL.path == path,
              path.hasSuffix(Contract.stateRelativeSuffix) else {
            throw GuardianError(code: "snapshot_state_path_invalid")
        }
        let relative = String(path.dropFirst(Contract.evidenceRoot.count + 1))
        guard relative.hasPrefix("paired-v7-update-"),
              relative.filter({ $0 == "/" }).count == 2,
              relative.hasSuffix(Contract.stateRelativeSuffix),
              !relative.utf8.contains(0) else {
            throw GuardianError(code: "snapshot_state_path_invalid")
        }
    }
}

private struct ChildOutcome {
    let status: Int32
    let timedOut: Bool
}

private enum ChildRunner {
    static func run(
        executable: String,
        stdoutPath: String,
        stderrPath: String,
        timeoutSeconds: Double
    ) throws -> ChildOutcome {
        guard executable.hasPrefix("/"),
              URL(fileURLWithPath: executable).lastPathComponent
                == "opensteamer-public-vpio-probe" else {
            throw GuardianError(code: "unexpected_child_executable")
        }
        let stdout = Darwin.open(
            stdoutPath,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard stdout >= 0 else { throw GuardianError(code: "child_stdout_create_failed") }
        let stderr = Darwin.open(
            stderrPath,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard stderr >= 0 else {
            _ = Darwin.close(stdout)
            throw GuardianError(code: "child_stderr_create_failed")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--live", "--acknowledge-default-input-mutation"]
        process.environment = [
            "LC_ALL": "C",
            "OSVA_PUBLIC_VPIO_LIVE": Contract.liveOptIn,
        ]
        process.standardOutput = FileHandle(fileDescriptor: stdout, closeOnDealloc: true)
        process.standardError = FileHandle(fileDescriptor: stderr, closeOnDealloc: true)
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            let termDeadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning,
                  ProcessInfo.processInfo.systemUptime < termDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        return ChildOutcome(status: process.terminationStatus, timedOut: timedOut)
    }
}

private enum Program {
    static func main() -> Int32 {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let mode = arguments.first else { throw GuardianError(code: "usage") }
            let values = try pairs(Array(arguments.dropFirst()))
            switch mode {
            case "run": return try run(values)
            case "snapshot": return try snapshot(values)
            case "run-prepared": return try runPrepared(values)
            case "broker": return try broker(values)
            case "repair": return try repair(values)
            case "verify-product-absent": return try verifyProductAbsent(values)
            case "self-test": return try selfTest(values)
            default: throw GuardianError(code: "usage")
            }
        } catch let error as GuardianError {
            FileHandle.standardError.write(Data("\(error.code)\n".utf8))
            return 64
        } catch {
            FileHandle.standardError.write(Data("unexpected_guardian_failure\n".utf8))
            return 74
        }
    }

    private static func verifyProductAbsent(
        _ values: [String: String]
    ) throws -> Int32 {
        guard values.isEmpty else { throw GuardianError(code: "usage") }
        let first = try CoreAudioDefaults.snapshot()
        Thread.sleep(forTimeInterval: 0.10)
        let second = try CoreAudioDefaults.snapshot()
        guard first == second,
              !(try CoreAudioDefaults.isAvailable(Contract.visibleUID)),
              !(try CoreAudioDefaults.isAvailable(Contract.writerUID)),
              try CoreAudioDefaults.isAvailable(Contract.legacyVisibleUID),
              try CoreAudioDefaults.isAvailable(Contract.legacyWriterUID),
              first.inputUID != Contract.visibleUID,
              first.inputUID != Contract.writerUID,
              DecisionModel.safeOutputs(first),
              DecisionModel.hiddenNeverDefault(first) else {
            throw GuardianError(code: "product_hal_absence_or_legacy_pair_unproved")
        }
        FileHandle.standardOutput.write(
            Data("PRODUCT_ENDPOINTS_ABSENT_AND_LEGACY_PAIR_AVAILABLE\n".utf8)
        )
        return 0
    }

    private static func broker(_ values: [String: String]) throws -> Int32 {
        let required = Set([
            "--child", "--state", "--snapshot-result", "--run-result",
            "--fence-result", "--post-publish-fence-result", "--repair-result",
            "--final-result", "--child-stdout", "--child-stderr",
            "--timeout-seconds", "--maximum-seconds",
        ])
        guard Set(values.keys) == required,
              let child = values["--child"],
              let statePath = values["--state"],
              let snapshotResultPath = values["--snapshot-result"],
              let runResultPath = values["--run-result"],
              let fenceResultPath = values["--fence-result"],
              let postPublishFenceResultPath =
                values["--post-publish-fence-result"],
              let repairResultPath = values["--repair-result"],
              let finalResultPath = values["--final-result"],
              let childStdout = values["--child-stdout"],
              let childStderr = values["--child-stderr"],
              let timeoutText = values["--timeout-seconds"],
              let timeout = Double(timeoutText), timeout >= 5, timeout <= 60,
              let maximumText = values["--maximum-seconds"],
              let maximum = Double(maximumText), maximum >= 60,
              maximum <= Contract.brokerMaximumSeconds else {
            throw GuardianError(code: "usage")
        }
        try FileIO.requireExactStatePath(statePath)
        let listener = DefaultListener()
        try listener.install()
        let first = try CoreAudioDefaults.snapshot()
        guard listener.armPreEpochBaseline(first) else {
            _ = listener.removeAndDrain()
            throw GuardianError(code: "unstable_pre_epoch_default_baseline")
        }
        Thread.sleep(forTimeInterval: 0.10)
        let second = try CoreAudioDefaults.snapshot()
        let snapshotSequence = listener.sequence()
        let baselineStable = first == second && snapshotSequence == 0
            && DecisionModel.safeOutputs(first)
            && DecisionModel.hiddenNeverDefault(first)
            && !DecisionModel.isForbiddenRestorationInput(first.inputUID)
        guard baselineStable else {
            _ = listener.removeAndDrain()
            throw GuardianError(code: "unstable_or_unsafe_default_baseline")
        }
        let createdAtMonotonicNs = monotonicNanoseconds()
        guard createdAtMonotonicNs > 0 else {
            _ = listener.removeAndDrain()
            throw GuardianError(code: "monotonic_snapshot_timestamp_invalid")
        }
        try FileIO.write(
            SnapshotState(
                schema: Contract.stateSchema,
                createdAtMonotonicNs: createdAtMonotonicNs,
                listenerSequenceAtSnapshot: snapshotSequence,
                defaults: first
            ),
            to: statePath
        )
        let armedEvidence = listener.evidence(
            sequenceAtSnapshot: snapshotSequence,
            removedAndDrained: false
        )
        let unchanged = Restoration(
            final: first,
            restored: true,
            attempted: false,
            listenerObserved: false,
            newerChoicePreserved: false,
            outputsUnchanged: true,
            hiddenNeverDefault: true,
            virtualNeverOutput: true,
            failureCode: nil
        )
        try FileIO.write(
            result(
                mode: "broker-snapshot",
                passed: true,
                child: ChildOutcome(status: -1, timedOut: false),
                baselineStable: true,
                baseline: first,
                restoration: unchanged,
                listener: armedEvidence,
                failureCode: "none"
            ),
            to: snapshotResultPath
        )
        FileHandle.standardOutput.write(Data("GUARDIAN_BROKER_READY\n".utf8))

        var lastRestoration: Restoration?
        var repairWritten = false
        var prestopChecked = false
        var postPublishEpochEstablished = false
        var vpioRan = false
        var evidenceSequenceAtSnapshot = snapshotSequence
        let absoluteDeadline = ProcessInfo.processInfo.systemUptime + maximum

        func writeRepairIfNeeded() throws -> Restoration {
            let restoration = Restorer.restore(baseline: first, listener: listener)
            let safe = DecisionModel.restorationOwnershipSafe(
                restored: restoration.restored,
                newerChoicePreserved: restoration.newerChoicePreserved
            ) && restoration.outputsUnchanged
                && restoration.hiddenNeverDefault && restoration.virtualNeverOutput
            guard safe else {
                throw GuardianError(
                    code: restoration.failureCode ?? "broker_repair_unproved"
                )
            }
            if !repairWritten {
                let evidence = listener.evidence(
                    sequenceAtSnapshot: evidenceSequenceAtSnapshot,
                    removedAndDrained: false
                )
                try FileIO.write(
                    result(
                        mode: "broker-repair",
                        passed: true,
                        child: ChildOutcome(status: -1, timedOut: false),
                        baselineStable: true,
                        baseline: first,
                        restoration: restoration,
                        listener: evidence,
                        failureCode: "none"
                    ),
                    to: repairResultPath
                )
                repairWritten = true
            }
            lastRestoration = restoration
            return restoration
        }

        func finishAfterRepair() throws -> Int32 {
            let restoration = try writeRepairIfNeeded()
            let removed = listener.removeAndDrain()
            let evidence = listener.evidence(
                sequenceAtSnapshot: evidenceSequenceAtSnapshot,
                removedAndDrained: removed
            )
            let safe = DecisionModel.restorationOwnershipSafe(
                restored: restoration.restored,
                newerChoicePreserved: restoration.newerChoicePreserved
            ) && restoration.outputsUnchanged
                && restoration.hiddenNeverDefault && restoration.virtualNeverOutput
                && listener.hasPostPublishEpoch()
                    == postPublishEpochEstablished
                && (!postPublishEpochEstablished
                    || (evidence.postPublishEpochEstablished
                        && evidence.countersMonotonic
                        && evidence.preEpochBaselineArmed
                        && !evidence.preEpochUIDMismatchOrReadFailure))
                && evidence.outputNotifications == 0
                && evidence.systemOutputNotifications == 0 && removed
            try FileIO.write(
                result(
                    mode: "broker-final",
                    passed: safe,
                    child: ChildOutcome(status: -1, timedOut: false),
                    baselineStable: true,
                    baseline: first,
                    restoration: restoration,
                    listener: evidence,
                    failureCode: safe ? "none" : "broker_final_repair_unproved"
                ),
                to: finalResultPath
            )
            return safe ? 0 : 1
        }

        do {
          while true {
            let remaining = absoluteDeadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 {
                return try finishAfterRepair()
            }
            var descriptor = pollfd(
                fd: STDIN_FILENO,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            // The local one-shot controller's longest single root-owned phase is bounded at
            // 9,000 seconds. This 9,900-second idle fence leaves a strict supervision margin;
            // EOF and the independent absolute deadline still trigger immediate repair.
            let milliseconds = Int32(min(remaining, Contract.brokerIdleSeconds) * 1_000.0)
            let status = Darwin.poll(&descriptor, 1, milliseconds)
            if status == 0 {
                return try finishAfterRepair()
            }
            guard status > 0, descriptor.revents & Int16(POLLIN) != 0,
                  let command = readLine(strippingNewline: true) else {
                return try finishAfterRepair()
            }
            switch command {
            case "PING":
                FileHandle.standardOutput.write(Data("GUARDIAN_BROKER_PONG\n".utf8))
            case "CHECK":
                guard !prestopChecked,
                      !postPublishEpochEstablished,
                      !vpioRan,
                      !repairWritten else {
                    throw GuardianError(code: "broker_prestop_fence_out_of_order")
                }
                let sequenceBefore = listener.sequence()
                let current = try CoreAudioDefaults.snapshot()
                let sequenceAfter = listener.sequence()
                guard current == first,
                      sequenceBefore == snapshotSequence,
                      sequenceAfter == snapshotSequence,
                      DecisionModel.safeOutputs(current),
                      DecisionModel.hiddenNeverDefault(current) else {
                    throw GuardianError(code: "broker_prestop_fence_changed")
                }
                let fenceEvidence = listener.evidence(
                    sequenceAtSnapshot: snapshotSequence,
                    removedAndDrained: false
                )
                try FileIO.write(
                    result(
                        mode: "broker-fence",
                        passed: true,
                        child: ChildOutcome(status: -1, timedOut: false),
                        baselineStable: true,
                        baseline: first,
                        restoration: unchanged,
                        listener: fenceEvidence,
                        failureCode: "none"
                    ),
                    to: fenceResultPath
                )
                prestopChecked = true
                FileHandle.standardOutput.write(Data("GUARDIAN_BROKER_CHECKED\n".utf8))
            case "POST_PUBLISH_FENCE":
                guard prestopChecked,
                      !postPublishEpochEstablished,
                      !vpioRan,
                      !repairWritten else {
                    throw GuardianError(code: "broker_post_publish_fence_out_of_order")
                }
                let (candidateEpoch, fenceEvidence) =
                    try listener.preparePostPublishEpoch(
                    baseline: first
                )
                guard fenceEvidence.postPublishEpochEstablished,
                      fenceEvidence.countersMonotonic,
                      fenceEvidence.preEpochBaselineArmed,
                      !fenceEvidence.preEpochUIDMismatchOrReadFailure,
                      fenceEvidence.sequenceAtSnapshot
                        == fenceEvidence.postPublishEpoch.sequence,
                      fenceEvidence.finalSequence
                        == fenceEvidence.postPublishEpoch.sequence,
                      fenceEvidence.inputNotifications == 0,
                      fenceEvidence.outputNotifications == 0,
                      fenceEvidence.systemOutputNotifications == 0 else {
                    throw GuardianError(
                        code: "broker_post_publish_notification_epoch_unproved"
                    )
                }
                try FileIO.write(
                    result(
                        mode: "broker-post-publish-fence",
                        passed: true,
                        child: ChildOutcome(status: -1, timedOut: false),
                        baselineStable: true,
                        baseline: first,
                        restoration: unchanged,
                        listener: fenceEvidence,
                        failureCode: "none"
                    ),
                    to: postPublishFenceResultPath
                )
                guard listener.commitPostPublishEpoch(
                    expected: candidateEpoch
                ) else {
                    throw GuardianError(
                        code: "broker_post_publish_epoch_commit_changed"
                    )
                }
                evidenceSequenceAtSnapshot =
                    fenceEvidence.postPublishEpoch.sequence
                postPublishEpochEstablished = true
                FileHandle.standardOutput.write(
                    Data("GUARDIAN_BROKER_POST_PUBLISH_FENCED\n".utf8)
                )
            case "RUN_VPIO":
                guard postPublishEpochEstablished,
                      !vpioRan,
                      !repairWritten else {
                    throw GuardianError(code: "broker_vpio_before_post_publish_fence")
                }
                let preparation = Restorer.restore(
                    baseline: first,
                    listener: listener
                )
                guard preparation.restored else {
                    throw GuardianError(
                        code: preparation.failureCode
                            ?? "broker_prepared_baseline_unproved"
                    )
                }
                let childOutcome = try ChildRunner.run(
                    executable: child,
                    stdoutPath: childStdout,
                    stderrPath: childStderr,
                    timeoutSeconds: timeout
                )
                let restoration = Restorer.restore(
                    baseline: first,
                    listener: listener
                )
                let evidence = listener.evidence(
                    sequenceAtSnapshot: evidenceSequenceAtSnapshot,
                    removedAndDrained: false
                )
                let passed = childOutcome.status == 0 && !childOutcome.timedOut
                    && restoration.restored && restoration.outputsUnchanged
                    && restoration.hiddenNeverDefault && restoration.virtualNeverOutput
                    && evidence.postPublishEpochEstablished
                    && evidence.countersMonotonic
                    && evidence.preEpochBaselineArmed
                    && !evidence.preEpochUIDMismatchOrReadFailure
                    && evidence.outputNotifications == 0
                    && evidence.systemOutputNotifications == 0
                try FileIO.write(
                    result(
                        mode: "broker-run",
                        passed: passed,
                        child: childOutcome,
                        baselineStable: true,
                        baseline: first,
                        restoration: restoration,
                        listener: evidence,
                        failureCode: passed ? "none" : "broker_vpio_or_restore_failed"
                    ),
                    to: runResultPath
                )
                guard passed else {
                    throw GuardianError(code: "broker_vpio_or_restore_failed")
                }
                vpioRan = true
                lastRestoration = restoration
                FileHandle.standardOutput.write(Data("GUARDIAN_BROKER_VPIO_PASSED\n".utf8))
            case "REPAIR":
                _ = try writeRepairIfNeeded()
                FileHandle.standardOutput.write(Data("GUARDIAN_BROKER_REPAIRED\n".utf8))
            case "STOP":
                _ = lastRestoration
                let finalStatus = try finishAfterRepair()
                FileHandle.standardOutput.write(Data("GUARDIAN_BROKER_STOPPED\n".utf8))
                return finalStatus
            default:
                throw GuardianError(code: "broker_unreviewed_command")
            }
          }
        } catch {
            let original = error
            _ = try? finishAfterRepair()
            throw original
        }
    }

    private static func snapshot(_ values: [String: String]) throws -> Int32 {
        guard Set(values.keys) == Set(["--state", "--result"]),
              let statePath = values["--state"],
              let resultPath = values["--result"] else {
            throw GuardianError(code: "usage")
        }
        try FileIO.requireExactStatePath(statePath)
        let listener = DefaultListener()
        try listener.install()
        let first = try CoreAudioDefaults.snapshot()
        Thread.sleep(forTimeInterval: 0.10)
        let second = try CoreAudioDefaults.snapshot()
        let sequence = listener.sequence()
        let baselineStable = first == second && sequence == 0
            && DecisionModel.safeOutputs(first)
            && DecisionModel.hiddenNeverDefault(first)
            && !DecisionModel.isForbiddenRestorationInput(first.inputUID)
        guard baselineStable else {
            _ = listener.removeAndDrain()
            throw GuardianError(code: "unstable_or_unsafe_default_baseline")
        }
        let createdAtMonotonicNs = monotonicNanoseconds()
        guard createdAtMonotonicNs > 0 else {
            _ = listener.removeAndDrain()
            throw GuardianError(code: "monotonic_snapshot_timestamp_invalid")
        }
        try FileIO.write(
            SnapshotState(
                schema: Contract.stateSchema,
                createdAtMonotonicNs: createdAtMonotonicNs,
                listenerSequenceAtSnapshot: sequence,
                defaults: first
            ),
            to: statePath
        )
        let removed = listener.removeAndDrain()
        let evidence = listener.evidence(
            sequenceAtSnapshot: sequence,
            removedAndDrained: removed
        )
        let passed = removed && evidence.finalSequence == sequence
            && evidence.inputNotifications == 0
            && evidence.outputNotifications == 0
            && evidence.systemOutputNotifications == 0
        let unchanged = Restoration(
            final: first,
            restored: true,
            attempted: false,
            listenerObserved: false,
            newerChoicePreserved: false,
            outputsUnchanged: true,
            hiddenNeverDefault: true,
            virtualNeverOutput: true,
            failureCode: passed ? nil : "snapshot_listener_changed"
        )
        try FileIO.write(
            result(
                mode: "snapshot",
                passed: passed,
                child: ChildOutcome(status: -1, timedOut: false),
                baselineStable: baselineStable,
                baseline: first,
                restoration: unchanged,
                listener: evidence,
                failureCode: passed ? "none" : "snapshot_listener_changed"
            ),
            to: resultPath
        )
        return passed ? 0 : 1
    }

    private static func runPrepared(_ values: [String: String]) throws -> Int32 {
        let required = Set([
            "--child", "--state", "--expected-state-sha256", "--result",
            "--child-stdout", "--child-stderr", "--timeout-seconds",
        ])
        guard Set(values.keys) == required,
              let child = values["--child"],
              let statePath = values["--state"],
              let expectedStateSHA256 = values["--expected-state-sha256"],
              let resultPath = values["--result"],
              let childStdout = values["--child-stdout"],
              let childStderr = values["--child-stderr"],
              let timeoutText = values["--timeout-seconds"],
              let timeout = Double(timeoutText),
              timeout >= 5, timeout <= 60 else {
            throw GuardianError(code: "usage")
        }
        let state = try FileIO.readState(
            statePath,
            expectedSHA256: expectedStateSHA256
        )
        let listener = DefaultListener()
        try listener.install()
        let sequence = listener.sequence()
        let preparation = Restorer.restore(
            baseline: state.defaults,
            listener: listener
        )
        guard preparation.restored else {
            let removed = listener.removeAndDrain()
            let evidence = listener.evidence(
                sequenceAtSnapshot: sequence,
                removedAndDrained: removed
            )
            try FileIO.write(
                result(
                    mode: "run-prepared",
                    passed: false,
                    child: ChildOutcome(status: -1, timedOut: false),
                    baselineStable: true,
                    baseline: state.defaults,
                    restoration: preparation,
                    listener: evidence,
                    failureCode: preparation.failureCode
                        ?? "prepared_baseline_restore_unproved"
                ),
                to: resultPath
            )
            return 1
        }

        let childOutcome: ChildOutcome
        do {
            childOutcome = try ChildRunner.run(
                executable: child,
                stdoutPath: childStdout,
                stderrPath: childStderr,
                timeoutSeconds: timeout
            )
        } catch {
            let restoration = Restorer.restore(
                baseline: state.defaults,
                listener: listener
            )
            _ = listener.removeAndDrain()
            guard restoration.restored else {
                throw GuardianError(
                    code: restoration.failureCode
                        ?? "prepared_child_launch_and_restore_failed"
                )
            }
            throw error
        }
        let restoration = Restorer.restore(
            baseline: state.defaults,
            listener: listener
        )
        let removed = listener.removeAndDrain()
        let evidence = listener.evidence(
            sequenceAtSnapshot: sequence,
            removedAndDrained: removed
        )
        let passed = childOutcome.status == 0 && !childOutcome.timedOut
            && restoration.restored && restoration.outputsUnchanged
            && restoration.hiddenNeverDefault && restoration.virtualNeverOutput
            && evidence.outputNotifications == 0
            && evidence.systemOutputNotifications == 0 && removed
        let failure = !restoration.restored
            ? (restoration.failureCode ?? "input_restore_unproved")
            : childOutcome.timedOut
                ? "public_vpio_probe_timeout"
                : childOutcome.status != 0
                    ? "public_vpio_probe_failed"
                    : evidence.outputNotifications != 0
                        || evidence.systemOutputNotifications != 0
                        ? "output_route_listener_observed_change"
                        : !removed ? "listener_teardown_failed" : "none"
        try FileIO.write(
            result(
                mode: "run-prepared",
                passed: passed,
                child: childOutcome,
                baselineStable: true,
                baseline: state.defaults,
                restoration: restoration,
                listener: evidence,
                failureCode: failure
            ),
            to: resultPath
        )
        return passed ? 0 : 1
    }

    private static func run(_ values: [String: String]) throws -> Int32 {
        let required = Set([
            "--child", "--state", "--result", "--child-stdout",
            "--child-stderr", "--timeout-seconds",
        ])
        guard Set(values.keys) == required,
              let child = values["--child"],
              let statePath = values["--state"],
              let resultPath = values["--result"],
              let childStdout = values["--child-stdout"],
              let childStderr = values["--child-stderr"],
              let timeoutText = values["--timeout-seconds"],
              let timeout = Double(timeoutText),
              timeout >= 5, timeout <= 60 else {
            throw GuardianError(code: "usage")
        }
        try FileIO.requireExactStatePath(statePath)
        let listener = DefaultListener()
        try listener.install()
        let first = try CoreAudioDefaults.snapshot()
        Thread.sleep(forTimeInterval: 0.10)
        let second = try CoreAudioDefaults.snapshot()
        let baselineSequence = listener.sequence()
        let baselineStable = first == second && baselineSequence == 0
            && DecisionModel.safeOutputs(first)
            && DecisionModel.hiddenNeverDefault(first)
            && !DecisionModel.isForbiddenRestorationInput(first.inputUID)
        guard baselineStable else {
            _ = listener.removeAndDrain()
            throw GuardianError(code: "unstable_or_unsafe_default_baseline")
        }
        let createdAtMonotonicNs = monotonicNanoseconds()
        guard createdAtMonotonicNs > 0 else {
            _ = listener.removeAndDrain()
            throw GuardianError(code: "monotonic_snapshot_timestamp_invalid")
        }
        let state = SnapshotState(
            schema: Contract.stateSchema,
            createdAtMonotonicNs: createdAtMonotonicNs,
            listenerSequenceAtSnapshot: baselineSequence,
            defaults: first
        )
        try FileIO.write(state, to: statePath)

        let childOutcome: ChildOutcome
        do {
            childOutcome = try ChildRunner.run(
                executable: child,
                stdoutPath: childStdout,
                stderrPath: childStderr,
                timeoutSeconds: timeout
            )
        } catch {
            let restoration = Restorer.restore(baseline: first, listener: listener)
            _ = listener.removeAndDrain()
            guard restoration.restored else {
                throw GuardianError(code: restoration.failureCode ?? "child_launch_and_restore_failed")
            }
            throw error
        }
        let restoration = Restorer.restore(baseline: first, listener: listener)
        let removed = listener.removeAndDrain()
        let listenerEvidence = listener.evidence(
            sequenceAtSnapshot: baselineSequence,
            removedAndDrained: removed
        )
        let passed = childOutcome.status == 0 && !childOutcome.timedOut
            && restoration.restored && restoration.outputsUnchanged
            && restoration.hiddenNeverDefault && restoration.virtualNeverOutput
            && listenerEvidence.outputNotifications == 0
            && listenerEvidence.systemOutputNotifications == 0 && removed
        let failure = !restoration.restored
            ? (restoration.failureCode ?? "input_restore_unproved")
            : childOutcome.timedOut
                ? "public_vpio_probe_timeout"
                : childOutcome.status != 0
                    ? "public_vpio_probe_failed"
                    : listenerEvidence.outputNotifications != 0
                        || listenerEvidence.systemOutputNotifications != 0
                        ? "output_route_listener_observed_change"
                        : !removed ? "listener_teardown_failed" : "none"
        try FileIO.write(
            result(
                mode: "run",
                passed: passed,
                child: childOutcome,
                baselineStable: baselineStable,
                baseline: first,
                restoration: restoration,
                listener: listenerEvidence,
                failureCode: failure
            ),
            to: resultPath
        )
        return passed ? 0 : 1
    }

    private static func repair(_ values: [String: String]) throws -> Int32 {
        guard Set(values.keys) == Set([
            "--state", "--expected-state-sha256", "--result",
        ]),
              let statePath = values["--state"],
              let expectedStateSHA256 = values["--expected-state-sha256"],
              let resultPath = values["--result"] else {
            throw GuardianError(code: "usage")
        }
        let state = try FileIO.readState(
            statePath,
            expectedSHA256: expectedStateSHA256
        )
        let listener = DefaultListener()
        try listener.install()
        let sequence = listener.sequence()
        let restoration = Restorer.restore(
            baseline: state.defaults,
            listener: listener
        )
        let removed = listener.removeAndDrain()
        let evidence = listener.evidence(
            sequenceAtSnapshot: sequence,
            removedAndDrained: removed
        )
        let passed = DecisionModel.restorationOwnershipSafe(
            restored: restoration.restored,
            newerChoicePreserved: restoration.newerChoicePreserved
        ) && restoration.outputsUnchanged
            && restoration.hiddenNeverDefault && restoration.virtualNeverOutput
            && evidence.outputNotifications == 0
            && evidence.systemOutputNotifications == 0 && removed
        try FileIO.write(
            result(
                mode: "repair",
                passed: passed,
                child: ChildOutcome(status: -1, timedOut: false),
                baselineStable: true,
                baseline: state.defaults,
                restoration: restoration,
                listener: evidence,
                failureCode: passed
                    ? "none"
                    : restoration.failureCode ?? "repair_unproved"
            ),
            to: resultPath
        )
        return passed ? 0 : 1
    }

    private static func selfTest(_ values: [String: String]) throws -> Int32 {
        guard Set(values.keys) == Set(["--result"]),
              let resultPath = values["--result"] else {
            throw GuardianError(code: "usage")
        }
        let real = "real-input"
        let cases: [(String, String, InputDecision)] = [
            (real, real, .alreadyRestored),
            (real, Contract.visibleUID, .restoreOwnedProduct),
            (real, "newer-real-input", .preserveNewerChoice),
            (Contract.visibleUID, Contract.visibleUID, .alreadyRestored),
            (real, Contract.writerUID, .rejectUnsafeCurrent),
            (real, Contract.legacyVisibleUID, .preserveNewerChoice),
            (real, Contract.legacyWriterUID, .rejectUnsafeCurrent),
            (Contract.legacyVisibleUID, Contract.visibleUID, .restoreOwnedProduct),
            (Contract.legacyVisibleUID, Contract.legacyVisibleUID, .alreadyRestored),
            (Contract.legacyWriterUID, Contract.visibleUID, .rejectUnsafeBaseline),
        ]
        let baseline = Defaults(
            inputUID: real,
            outputUID: "speaker",
            systemOutputUID: "speaker"
        )
        let owned = Defaults(
            inputUID: Contract.visibleUID,
            outputUID: "speaker",
            systemOutputUID: "speaker"
        )
        let newer = Defaults(
            inputUID: "newer-real-input",
            outputUID: "speaker",
            systemOutputUID: "speaker"
        )
        let outputDrift = Defaults(
            inputUID: Contract.visibleUID,
            outputUID: "new-speaker",
            systemOutputUID: "speaker"
        )
        let legacyVisibleBaseline = Defaults(
            inputUID: Contract.legacyVisibleUID,
            outputUID: "speaker",
            systemOutputUID: "speaker"
        )
        let fenceCases: [(Defaults, UInt64, UInt64, RestoreFenceDecision)] = [
            (owned, 0, 0, .proceed),
            (baseline, 0, 0, .alreadyRestored),
            (newer, 0, 0, .preserveNewerChoice),
            (outputDrift, 0, 0, .rejectOutputDrift),
            (owned, 0, 1, .rejectSequenceDrift),
        ]
        func record(
            _ counters: ListenerCounters,
            selector: AudioObjectPropertySelector,
            observed: Defaults?
        ) {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            withUnsafePointer(to: &address) {
                counters.record($0, count: 1, observedDefaults: observed)
            }
        }
        let stableCounters = ListenerCounters()
        let stableArmed = stableCounters.armPreEpochBaseline(
            baseline,
            expected: .zero
        )
        for selector in [
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
        ] {
            record(stableCounters, selector: selector, observed: baseline)
        }
        let stableCheckpoint = stableCounters.snapshot()
        let stableStatus = stableCounters.preEpochStatus()
        let stableCommitted = stableCounters.commitPostPublishEpoch(
            expected: stableCheckpoint
        )
        let stableCommitIsOneShot = !stableCounters.commitPostPublishEpoch(
            expected: stableCheckpoint
        )
        let UIDMismatchLatchPasses = [
            Defaults(
                inputUID: "changed-input",
                outputUID: baseline.outputUID,
                systemOutputUID: baseline.systemOutputUID
            ),
            Defaults(
                inputUID: baseline.inputUID,
                outputUID: "changed-output",
                systemOutputUID: baseline.systemOutputUID
            ),
            Defaults(
                inputUID: baseline.inputUID,
                outputUID: baseline.outputUID,
                systemOutputUID: "changed-system-output"
            ),
        ].allSatisfy { observed in
            let counters = ListenerCounters()
            guard counters.armPreEpochBaseline(baseline, expected: .zero) else {
                return false
            }
            record(
                counters,
                selector: kAudioHardwarePropertyDefaultInputDevice,
                observed: observed
            )
            let status = counters.preEpochStatus()
            return status.failed
                && !counters.commitPostPublishEpoch(
                    expected: counters.snapshot()
                )
        }
        let nilReadCounters = ListenerCounters()
        let nilReadArmed = nilReadCounters.armPreEpochBaseline(
            baseline,
            expected: .zero
        )
        record(
            nilReadCounters,
            selector: kAudioHardwarePropertyDefaultInputDevice,
            observed: nil
        )
        let nilReadRejected = nilReadCounters.preEpochStatus().failed
            && !nilReadCounters.commitPostPublishEpoch(
                expected: nilReadCounters.snapshot()
            )
        let unknownCounters = ListenerCounters()
        let unknownArmed = unknownCounters.armPreEpochBaseline(
            baseline,
            expected: .zero
        )
        record(
            unknownCounters,
            selector: AudioObjectPropertySelector(0x7a7a_7a7a),
            observed: baseline
        )
        let unknownRejected = unknownCounters.snapshot().overflowed
            && !unknownCounters.commitPostPublishEpoch(
                expected: unknownCounters.snapshot()
            )
        let nilAddressCounters = ListenerCounters()
        let nilAddressArmed = nilAddressCounters.armPreEpochBaseline(
            baseline,
            expected: .zero
        )
        nilAddressCounters.record(
            nil,
            count: 1,
            observedDefaults: baseline
        )
        let nilAddressRejected = nilAddressCounters.snapshot().overflowed
            && nilAddressCounters.preEpochStatus().failed
            && !nilAddressCounters.commitPostPublishEpoch(
                expected: nilAddressCounters.snapshot()
            )
        let racedCounters = ListenerCounters()
        let racedArmed = racedCounters.armPreEpochBaseline(
            baseline,
            expected: .zero
        )
        let candidateCheckpoint = racedCounters.snapshot()
        record(
            racedCounters,
            selector: kAudioHardwarePropertyDefaultInputDevice,
            observed: baseline
        )
        let racedCommitRejected = !racedCounters.commitPostPublishEpoch(
            expected: candidateCheckpoint
        )
        let passed = cases.allSatisfy {
            DecisionModel.inputDecision(baseline: $0.0, current: $0.1) == $0.2
        } && fenceCases.allSatisfy {
            DecisionModel.ownedRestoreFence(
                baseline: baseline,
                initial: owned,
                adjacent: $0.0,
                initialSequenceBefore: 0,
                initialSequenceAfter: 0,
                adjacentSequenceBefore: $0.1,
                adjacentSequenceAfter: $0.2
            ) == $0.3
        } && DecisionModel.ownedRestoreFence(
            baseline: legacyVisibleBaseline,
            initial: owned,
            adjacent: owned,
            initialSequenceBefore: 0,
            initialSequenceAfter: 0,
            adjacentSequenceBefore: 0,
            adjacentSequenceAfter: 0
        ) == .proceed
        && DecisionModel.inputDecision(
            baseline: Contract.legacyVisibleUID,
            current: Contract.visibleUID
        ) == .restoreOwnedProduct
        && DecisionModel.restorationOwnershipSafe(
            restored: true,
            newerChoicePreserved: false
        )
        && DecisionModel.restorationOwnershipSafe(
            restored: false,
            newerChoicePreserved: true
        )
        && !DecisionModel.restorationOwnershipSafe(
            restored: false,
            newerChoicePreserved: false
        )
        && DecisionModel.safeOutputs(baseline) && !DecisionModel.safeOutputs(
            Defaults(inputUID: real, outputUID: Contract.writerUID, systemOutputUID: "speaker")
        )
        && DecisionModel.postPublishFenceSafe(
            baseline: baseline,
            first: baseline,
            second: baseline,
            before: ListenerCheckpoint(
                sequence: 3,
                inputNotifications: 1,
                outputNotifications: 1,
                systemOutputNotifications: 1,
                overflowed: false
            ),
            after: ListenerCheckpoint(
                sequence: 3,
                inputNotifications: 1,
                outputNotifications: 1,
                systemOutputNotifications: 1,
                overflowed: false
            )
        )
        && !DecisionModel.postPublishFenceSafe(
            baseline: baseline,
            first: baseline,
            second: outputDrift,
            before: ListenerCheckpoint.zero,
            after: ListenerCheckpoint.zero
        )
        && !DecisionModel.postPublishFenceSafe(
            baseline: baseline,
            first: baseline,
            second: baseline,
            before: ListenerCheckpoint.zero,
            after: ListenerCheckpoint(
                sequence: 1,
                inputNotifications: 0,
                outputNotifications: 1,
                systemOutputNotifications: 0,
                overflowed: false
            )
        )
        && DecisionModel.postPublishOutputNotificationsUnchanged(
            epoch: ListenerCheckpoint(
                sequence: 3,
                inputNotifications: 1,
                outputNotifications: 1,
                systemOutputNotifications: 1,
                overflowed: false
            ),
            final: ListenerCheckpoint(
                sequence: 4,
                inputNotifications: 2,
                outputNotifications: 1,
                systemOutputNotifications: 1,
                overflowed: false
            )
        )
        && !DecisionModel.postPublishOutputNotificationsUnchanged(
            epoch: ListenerCheckpoint(
                sequence: 3,
                inputNotifications: 1,
                outputNotifications: 1,
                systemOutputNotifications: 1,
                overflowed: false
            ),
            final: ListenerCheckpoint(
                sequence: 4,
                inputNotifications: 1,
                outputNotifications: 2,
                systemOutputNotifications: 1,
                overflowed: false
            )
        )
        && ListenerCheckpoint.zero.delta(
            since: ListenerCheckpoint(
                sequence: 1,
                inputNotifications: 0,
                outputNotifications: 0,
                systemOutputNotifications: 0,
                overflowed: false
            )
        ) == nil
        && stableArmed
        && !stableStatus.failed
        && stableCheckpoint.sequence == 3
        && stableCheckpoint.inputNotifications == 1
        && stableCheckpoint.outputNotifications == 1
        && stableCheckpoint.systemOutputNotifications == 1
        && stableCommitted
        && stableCommitIsOneShot
        && UIDMismatchLatchPasses
        && nilReadArmed
        && nilReadRejected
        && unknownArmed
        && unknownRejected
        && nilAddressArmed
        && nilAddressRejected
        && racedArmed
        && racedCommitRejected
        let value = [
            "schema": Contract.schema,
            "mode": "self-test",
            "passed": passed ? "true" : "false",
            "cases": String(cases.count + fenceCases.count + 24),
        ]
        try FileIO.write(value, to: resultPath)
        return passed ? 0 : 1
    }

    private static func result(
        mode: String,
        passed: Bool,
        child: ChildOutcome,
        baselineStable: Bool,
        baseline: Defaults,
        restoration: Restoration,
        listener: ListenerEvidence,
        failureCode: String
    ) -> GuardianResult {
        GuardianResult(
            schema: Contract.schema,
            mode: mode,
            passed: passed,
            childExitCode: child.status,
            childTimedOut: child.timedOut,
            baselineStable: baselineStable,
            baselineInputFingerprint: fingerprint(baseline.inputUID),
            baselineOutputFingerprint: fingerprint(baseline.outputUID),
            baselineSystemOutputFingerprint: fingerprint(baseline.systemOutputUID),
            finalInputFingerprint: fingerprint(restoration.final.inputUID),
            finalOutputFingerprint: fingerprint(restoration.final.outputUID),
            finalSystemOutputFingerprint: fingerprint(restoration.final.systemOutputUID),
            inputRestored: restoration.restored,
            restorationAttempted: restoration.attempted,
            restorationListenerObserved: restoration.listenerObserved,
            newerInputChoicePreserved: restoration.newerChoicePreserved,
            outputsUnchanged: restoration.outputsUnchanged,
            hiddenEndpointNeverDefault: restoration.hiddenNeverDefault,
            virtualEndpointsNeverOutputDefault: restoration.virtualNeverOutput,
            listener: listener,
            failureCode: failureCode
        )
    }

    private static func pairs(_ arguments: [String]) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else {
            throw GuardianError(code: "usage")
        }
        var result: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            let value = arguments[index + 1]
            guard key.hasPrefix("--"), result[key] == nil, !value.isEmpty else {
                throw GuardianError(code: "usage")
            }
            result[key] = value
            index += 2
        }
        return result
    }
}

private func fingerprint(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func listenerCheckpointFingerprint(
    _ checkpoint: ListenerCheckpoint
) -> String {
    fingerprint(
        "sequence=\(checkpoint.sequence)\n"
            + "input=\(checkpoint.inputNotifications)\n"
            + "output=\(checkpoint.outputNotifications)\n"
            + "system_output=\(checkpoint.systemOutputNotifications)\n"
            + "overflowed=\(checkpoint.overflowed ? 1 : 0)\n"
    )
}

private func monotonicNanoseconds() -> UInt64 {
    var value = timespec()
    guard clock_gettime(CLOCK_MONOTONIC_RAW, &value) == 0 else { return 0 }
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

Darwin.exit(Program.main())
