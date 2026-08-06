import CoreAudio
import Dispatch
import XCTest
@testable import CaptureCore

final class WorldwideSafeOutputInvariantTests: XCTestCase {
    private let blackHole =
        WorldwideSafeOutputInvariant.canonicalBlackHoleUID
    private let speakers =
        WorldwideSafeOutputInvariant.builtInSpeakerUID

    func testHealthyRealOutputsArePreservedWithoutResolutionOrWrites()
        throws {
        let operations = FakeSafeOutputOperations(
            outputUID: "headphones",
            systemOutputUID: "BuiltInSpeakerDevice"
        )
        let invariant = makeInvariant(operations: operations)

        let result = try invariant.enforce()

        XCTAssertFalse(result.changedAnything)
        XCTAssertEqual(operations.resolvedUIDs, [])
        XCTAssertEqual(operations.writes, [])
        XCTAssertEqual(operations.outputUID, "headphones")
        XCTAssertEqual(
            operations.systemOutputUID,
            "BuiltInSpeakerDevice"
        )
    }

    func testBothUnsafeSelectorsMoveToBuiltInSpeakersOnly() throws {
        let operations = FakeSafeOutputOperations(
            outputUID: blackHole,
            systemOutputUID: blackHole,
            deviceIDsByUID: [speakers: 74]
        )
        let invariant = makeInvariant(operations: operations)

        let result = try invariant.enforce()

        XCTAssertTrue(result.changedDefaultOutput)
        XCTAssertTrue(result.changedDefaultSystemOutput)
        XCTAssertEqual(operations.resolvedUIDs, [speakers])
        XCTAssertEqual(
            operations.writes,
            [
                .init(
                    kind: .output,
                    expectedUID: blackHole,
                    targetDeviceID: 74
                ),
                .init(
                    kind: .systemOutput,
                    expectedUID: blackHole,
                    targetDeviceID: 74
                ),
            ]
        )
        XCTAssertEqual(operations.outputUID, speakers)
        XCTAssertEqual(operations.systemOutputUID, speakers)
    }

    func testBlackHoleDefaultOutputPrefersCurrentRealSystemOutput()
        throws {
        let operations = FakeSafeOutputOperations(
            outputUID: blackHole,
            systemOutputUID: "headphones",
            deviceIDsByUID: ["headphones": 91]
        )
        let invariant = makeInvariant(operations: operations)

        let result = try invariant.enforce()

        XCTAssertTrue(result.changedDefaultOutput)
        XCTAssertFalse(result.changedDefaultSystemOutput)
        XCTAssertEqual(operations.resolvedUIDs, ["headphones"])
        XCTAssertEqual(operations.writes.map(\.kind), [.output])
        XCTAssertEqual(operations.outputUID, "headphones")
        XCTAssertEqual(operations.systemOutputUID, "headphones")
    }

    func testBlackHoleSystemOutputPrefersCurrentRealDefaultOutput()
        throws {
        let operations = FakeSafeOutputOperations(
            outputUID: "display-audio",
            systemOutputUID: blackHole,
            deviceIDsByUID: ["display-audio": 92]
        )
        let invariant = makeInvariant(operations: operations)

        let result = try invariant.enforce()

        XCTAssertFalse(result.changedDefaultOutput)
        XCTAssertTrue(result.changedDefaultSystemOutput)
        XCTAssertEqual(operations.resolvedUIDs, ["display-audio"])
        XCTAssertEqual(operations.writes.map(\.kind), [.systemOutput])
        XCTAssertEqual(operations.outputUID, "display-audio")
        XCTAssertEqual(operations.systemOutputUID, "display-audio")
    }

    func testUnusableCurrentRealOutputFallsBackToBuiltInSpeakers()
        throws {
        let operations = FakeSafeOutputOperations(
            outputUID: blackHole,
            systemOutputUID: "disconnected-headphones",
            deviceIDsByUID: [speakers: 74]
        )
        let invariant = makeInvariant(operations: operations)

        let result = try invariant.enforce()

        XCTAssertTrue(result.changedDefaultOutput)
        XCTAssertEqual(
            operations.resolvedUIDs,
            ["disconnected-headphones", speakers]
        )
        XCTAssertEqual(operations.outputUID, speakers)
        XCTAssertEqual(
            operations.systemOutputUID,
            "disconnected-headphones"
        )
    }

    func testChoiceChangedBeforeImmediateComparisonIsNotMutated() throws {
        let operations = FakeSafeOutputOperations(
            outputUID: blackHole,
            systemOutputUID: speakers,
            deviceIDsByUID: [speakers: 74]
        )
        operations.beforeFirstMutation = { operations, kind in
            XCTAssertEqual(kind, .output)
            operations.outputUID = "user-headphones"
        }
        let invariant = makeInvariant(operations: operations)

        let result = try invariant.enforce()

        XCTAssertFalse(result.changedAnything)
        XCTAssertEqual(operations.outputUID, "user-headphones")
        XCTAssertEqual(operations.writes.count, 1)
        XCTAssertEqual(
            operations.writes.first?.result,
            .currentOutputMismatch
        )
    }

    func testObservableMutationAfterLastComparisonFailsClosed() {
        let operations = FakeSafeOutputOperations(
            outputUID: blackHole,
            systemOutputUID: speakers,
            deviceIDsByUID: [speakers: 74]
        )
        operations.afterFirstComparisonBeforeWrite = {
            operations, kind in
            operations.setUID("user-headphones", for: kind)
            operations.emitChange(kind)
        }
        let invariant = makeInvariant(operations: operations)

        XCTAssertThrowsError(try invariant.enforce()) { error in
            XCTAssertEqual(
                error as? WorldwideSafeOutputInvariantError,
                .observableContention
            )
        }
        XCTAssertEqual(operations.outputUID, speakers)
        XCTAssertEqual(operations.writes.count, 1)
    }

    func testSafeFastPathRejectsChangeBetweenTwoSelectorReads() {
        let operations = FakeSafeOutputOperations(
            outputUID: speakers,
            systemOutputUID: "headphones"
        )
        operations.afterTotalReadCount = { operations, count in
            guard count == 2 else { return }
            operations.afterTotalReadCount = nil
            operations.outputUID = self.blackHole
            operations.emitChange(.output)
        }
        let invariant = makeInvariant(operations: operations)

        XCTAssertThrowsError(try invariant.enforce()) { error in
            XCTAssertEqual(
                error as? WorldwideSafeOutputInvariantError,
                .observableContention
            )
        }
        XCTAssertEqual(operations.writes, [])
    }

    func testFinalConvergenceRejectsChangeDuringTwoSelectorReadback() {
        let operations = FakeSafeOutputOperations(
            outputUID: blackHole,
            systemOutputUID: speakers,
            deviceIDsByUID: [speakers: 74]
        )
        operations.afterSuccessfulWriteReadCount = {
            operations, count in
            guard count == 4 else { return }
            operations.afterSuccessfulWriteReadCount = nil
            operations.systemOutputUID = self.blackHole
            operations.emitChange(.systemOutput)
        }
        let invariant = makeInvariant(operations: operations)

        XCTAssertThrowsError(try invariant.enforce()) { error in
            XCTAssertEqual(
                error as? WorldwideSafeOutputInvariantError,
                .observableContention
            )
        }
        XCTAssertEqual(operations.writes.count, 1)
    }

    func testVerificationReportsStableRouteChangesWithoutWriting() throws {
        let operations = FakeSafeOutputOperations(
            outputUID: speakers,
            systemOutputUID: speakers
        )
        let invariant = makeInvariant(operations: operations)

        XCTAssertEqual(
            try invariant.verify(),
            .init(
                isSatisfied: true,
                changedSincePreviousObservation: true
            )
        )
        XCTAssertEqual(
            try invariant.verify(),
            .init(
                isSatisfied: true,
                changedSincePreviousObservation: false
            )
        )
        operations.outputUID = blackHole
        XCTAssertEqual(
            try invariant.verify(),
            .init(
                isSatisfied: false,
                changedSincePreviousObservation: true
            )
        )
        XCTAssertEqual(operations.writes, [])
    }

    func testUnavailableBuiltInFallbackFailsWithoutWriting() {
        let operations = FakeSafeOutputOperations(
            outputUID: blackHole,
            systemOutputUID: blackHole
        )
        let invariant = makeInvariant(operations: operations)

        XCTAssertThrowsError(try invariant.enforce()) { error in
            XCTAssertEqual(
                error as? WorldwideSafeOutputInvariantError,
                .safeOutputUnavailable
            )
        }
        XCTAssertEqual(operations.writes, [])
        XCTAssertEqual(operations.outputUID, blackHole)
        XCTAssertEqual(operations.systemOutputUID, blackHole)
    }

    private func makeInvariant(
        operations: FakeSafeOutputOperations
    ) -> WorldwideSafeOutputInvariant {
        WorldwideSafeOutputInvariant(
            operations: operations,
            operationQueue: DispatchQueue(
                label: "test.WorldwideSafeOutputInvariant"
            ),
            listenerQueue: DispatchQueue(
                label: "test.WorldwideSafeOutputInvariant.listener"
            ),
            proofTimeout: 0.01
        )
    }
}

private final class FakeSafeOutputOperations:
    WorldwideSafeOutputInvariantOperations,
    @unchecked Sendable
{
    struct Write: Equatable {
        let kind: BlackHoleDefaultOutputKind
        let expectedUID: String
        let targetDeviceID: AudioDeviceID
        var result: BlackHoleDefaultOutputMutationResult = .written(noErr)
    }

    var outputUID: String
    var systemOutputUID: String
    var deviceIDsByUID: [String: AudioDeviceID]
    var resolvedUIDs: [String] = []
    var writes: [Write] = []
    var beforeFirstMutation:
        ((FakeSafeOutputOperations, BlackHoleDefaultOutputKind) -> Void)?
    var afterFirstComparisonBeforeWrite:
        ((FakeSafeOutputOperations, BlackHoleDefaultOutputKind) -> Void)?
    var afterTotalReadCount:
        ((FakeSafeOutputOperations, Int) -> Void)?
    var afterSuccessfulWriteReadCount:
        ((FakeSafeOutputOperations, Int) -> Void)?
    private var totalReadCount = 0
    private var successfulWriteReadCount: Int?
    private var listeners: [
        BlackHoleDefaultOutputKind:
            CoreAudioPropertyListenerRegistration
    ] = [:]

    init(
        outputUID: String,
        systemOutputUID: String,
        deviceIDsByUID: [String: AudioDeviceID] = [:]
    ) {
        self.outputUID = outputUID
        self.systemOutputUID = systemOutputUID
        self.deviceIDsByUID = deviceIDsByUID
    }

    func addDefaultOutputListener(
        kind: BlackHoleDefaultOutputKind,
        queue _: DispatchQueue,
        listener: CoreAudioPropertyListenerRegistration
    ) -> OSStatus {
        listeners[kind] = listener
        return noErr
    }

    func removeDefaultOutputListener(
        kind: BlackHoleDefaultOutputKind,
        queue _: DispatchQueue,
        listener _: CoreAudioPropertyListenerRegistration
    ) -> OSStatus {
        listeners[kind] = nil
        return noErr
    }

    func currentDefaultOutputUID(
        _ kind: BlackHoleDefaultOutputKind
    ) throws -> String {
        let uid: String
        switch kind {
        case .output:
            uid = outputUID
        case .systemOutput:
            uid = systemOutputUID
        }
        totalReadCount += 1
        afterTotalReadCount?(self, totalReadCount)
        if let count = successfulWriteReadCount {
            let next = count + 1
            successfulWriteReadCount = next
            afterSuccessfulWriteReadCount?(self, next)
        }
        return uid
    }

    func resolveUsableOutputDeviceID(uid: String) throws -> AudioDeviceID {
        resolvedUIDs.append(uid)
        guard let deviceID = deviceIDsByUID[uid] else {
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
        if writes.isEmpty, let beforeFirstMutation {
            self.beforeFirstMutation = nil
            beforeFirstMutation(self, kind)
        }

        let currentUID: String
        switch kind {
        case .output:
            currentUID = outputUID
        case .systemOutput:
            currentUID = systemOutputUID
        }
        guard currentUID == expectedCurrentUID else {
            writes.append(
                Write(
                    kind: kind,
                    expectedUID: expectedCurrentUID,
                    targetDeviceID: deviceID,
                    result: .currentOutputMismatch
                )
            )
            return .currentOutputMismatch
        }
        if let afterFirstComparisonBeforeWrite {
            self.afterFirstComparisonBeforeWrite = nil
            afterFirstComparisonBeforeWrite(self, kind)
        }
        guard let targetUID = deviceIDsByUID.first(where: {
            $0.value == deviceID
        })?.key else {
            writes.append(
                Write(
                    kind: kind,
                    expectedUID: expectedCurrentUID,
                    targetDeviceID: deviceID,
                    result: .readFailed
                )
            )
            return .readFailed
        }

        switch kind {
        case .output:
            outputUID = targetUID
        case .systemOutput:
            systemOutputUID = targetUID
        }
        emitChange(kind)
        writes.append(
            Write(
                kind: kind,
                expectedUID: expectedCurrentUID,
                targetDeviceID: deviceID
            )
        )
        if successfulWriteReadCount == nil {
            successfulWriteReadCount = 0
        }
        return .written(noErr)
    }

    func setUID(
        _ uid: String,
        for kind: BlackHoleDefaultOutputKind
    ) {
        switch kind {
        case .output:
            outputUID = uid
        case .systemOutput:
            systemOutputUID = uid
        }
    }

    func emitChange(_ kind: BlackHoleDefaultOutputKind) {
        guard let listener = listeners[kind] else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kind.selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        withUnsafePointer(to: &address) {
            listener.block(1, $0)
        }
    }
}
