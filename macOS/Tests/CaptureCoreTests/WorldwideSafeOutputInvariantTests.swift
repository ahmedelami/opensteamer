import CoreAudio
import Dispatch
import XCTest
@testable import CaptureCore

final class WorldwideSafeOutputInvariantTests: XCTestCase {
    private let blackHole =
        WorldwideSafeOutputInvariant.canonicalBlackHoleUID
    private let hiddenMirror =
        WorldwideSafeOutputInvariant.hiddenMirrorBlackHoleUID
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

    func testSessionMonitoringKeepsExactListenersAcrossAdmissionAndVerification()
        throws {
        let operations = FakeSafeOutputOperations(
            outputUID: speakers,
            systemOutputUID: "headphones"
        )
        let invariant = makeInvariant(operations: operations)
        let probe = SafeOutputSessionProbe()

        let epoch = try invariant.beginSessionMonitoring {
            eventEpoch, eventSequence in
            probe.revoke(
                epoch: eventEpoch,
                eventSequence: eventSequence
            )
        }
        XCTAssertEqual(operations.listenerCount, 2)

        let transaction = try invariant.enforceDuringAdmission(
            monitoringEpoch: epoch,
            admission: {
                probe.record("admission")
                return 41
            },
            rollback: { _ in
                probe.record("rollback")
            },
            commit: { _, authorization in
                probe.commit(authorization)
            }
        )

        XCTAssertEqual(transaction.admission, 41)
        XCTAssertEqual(
            transaction.authorization.monitoringEpoch,
            epoch
        )
        XCTAssertEqual(
            transaction.authorization.listenerSequence,
            0
        )
        XCTAssertEqual(probe.events, ["admission", "commit"])
        XCTAssertTrue(probe.isOpen)
        XCTAssertEqual(operations.listenerCount, 2)

        XCTAssertTrue(
            try invariant.verify(
                monitoringEpoch: epoch
            ).isSatisfied
        )
        XCTAssertTrue(try invariant.verify().isSatisfied)
        XCTAssertEqual(
            try invariant.enforceDuringAdmission(
                admission: { 52 },
                rollback: { _ in
                    XCTFail("A stable reused registration must not roll back.")
                }
            ).admission,
            52
        )
        XCTAssertEqual(operations.listenerCount, 2)
        XCTAssertEqual(
            operations.additionListenerIdentifiers.values
                .flatMap { $0 }.count,
            2,
            "Verification must reuse the session listener pair."
        )
        XCTAssertEqual(
            operations.removalListenerIdentifiers,
            [:]
        )

        operations.setUID("display-audio", for: .output)
        operations.emitChange(.output)
        XCTAssertFalse(
            probe.isOpen,
            "A post-commit selector callback must close the gate before returning."
        )
        XCTAssertEqual(probe.events.last, "uncertain")
        XCTAssertEqual(probe.lastUncertainEpoch, epoch)
        XCTAssertEqual(probe.lastUncertainSequence, 1)

        try invariant.endSessionMonitoring(epoch: epoch)
        XCTAssertEqual(operations.listenerCount, 0)
    }

    func testStaleMonitoringEpochCannotUseReplacementListenerPair()
        throws {
        let operations = FakeSafeOutputOperations(
            outputUID: speakers,
            systemOutputUID: "headphones"
        )
        let invariant = makeInvariant(operations: operations)
        let firstProbe = SafeOutputSessionProbe()
        let firstEpoch = try invariant.beginSessionMonitoring { _, _ in
            firstProbe.revoke()
        }

        firstProbe.revoke()
        try invariant.endSessionMonitoring(epoch: firstEpoch)

        let secondProbe = SafeOutputSessionProbe()
        let secondEpoch = try invariant.beginSessionMonitoring { _, _ in
            secondProbe.revoke()
        }
        XCTAssertNotEqual(firstEpoch, secondEpoch)
        XCTAssertThrowsError(
            try invariant.enforceDuringAdmission(
                monitoringEpoch: firstEpoch,
                admission: { 73 },
                rollback: { _ in
                    XCTFail("A stale epoch must fail before admission.")
                },
                commit: { _, authorization in
                    secondProbe.commit(authorization)
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? WorldwideSafeOutputInvariantError,
                .sessionMonitoringEpochMismatch
            )
        }
        XCTAssertFalse(secondProbe.isOpen)
        XCTAssertEqual(operations.listenerCount, 2)

        secondProbe.revoke()
        try invariant.endSessionMonitoring(epoch: secondEpoch)
    }

    func testSessionListenerSynchronouslyRevokesBeforePublishingContention()
        throws {
        let operations = FakeSafeOutputOperations(
            outputUID: speakers,
            systemOutputUID: "headphones"
        )
        let invariant = makeInvariant(operations: operations)
        let probe = SafeOutputSessionProbe()
        let epoch = try invariant.beginSessionMonitoring { _, _ in
            probe.revoke()
        }

        XCTAssertThrowsError(
            try invariant.enforceDuringAdmission(
                monitoringEpoch: epoch,
                admission: {
                    probe.record("admission")
                    operations.setUID(
                        self.blackHole,
                        for: .output
                    )
                    operations.emitChange(.output)
                    XCTAssertFalse(
                        probe.isOpen,
                        "The listener callback must revoke synchronously."
                    )
                    return 73
                },
                rollback: { _ in
                    probe.record("rollback")
                },
                commit: { _, authorization in
                    probe.commit(authorization)
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? WorldwideSafeOutputInvariantError,
                .observableContention
            )
        }

        XCTAssertEqual(
            probe.events,
            ["admission", "uncertain", "rollback"]
        )
        XCTAssertFalse(probe.isOpen)
        XCTAssertEqual(operations.listenerCount, 2)

        probe.revoke()
        try invariant.endSessionMonitoring(epoch: epoch)
    }

    func testSessionRevokesBeforeFirstRepairMutation() throws {
        let operations = FakeSafeOutputOperations(
            outputUID: blackHole,
            systemOutputUID: hiddenMirror,
            deviceIDsByUID: [speakers: 74]
        )
        let invariant = makeInvariant(operations: operations)
        let probe = SafeOutputSessionProbe()
        let epoch = try invariant.beginSessionMonitoring {
            eventEpoch, eventSequence in
            probe.revoke(
                epoch: eventEpoch,
                eventSequence: eventSequence
            )
        }

        let transaction = try invariant.enforceDuringAdmission(
            monitoringEpoch: epoch,
            beforeFirstMutation: {
                probe.revoke()
                probe.record("before-mutation")
                XCTAssertEqual(operations.writes, [])
            },
            admission: { 41 },
            rollback: { _ in
                probe.record("rollback")
            },
            commit: { _, authorization in
                probe.commit(authorization)
            }
        )

        XCTAssertEqual(
            Array(probe.events.prefix(2)),
            ["uncertain", "before-mutation"]
        )
        XCTAssertEqual(operations.writes.count, 2)
        XCTAssertTrue(probe.isOpen)
        XCTAssertEqual(
            probe.lastUncertainEpoch,
            transaction.authorization.monitoringEpoch
        )
        XCTAssertEqual(
            probe.lastUncertainSequence,
            transaction.authorization.listenerSequence,
            "Repair notifications queued before commit are superseded by the committed sequence."
        )

        probe.revoke()
        try invariant.endSessionMonitoring(epoch: epoch)
    }

    func testActiveSessionRefusesUnfencedRepair() throws {
        let operations = FakeSafeOutputOperations(
            outputUID: blackHole,
            systemOutputUID: speakers,
            deviceIDsByUID: [speakers: 74]
        )
        let invariant = makeInvariant(operations: operations)
        let probe = SafeOutputSessionProbe()
        let epoch = try invariant.beginSessionMonitoring { _, _ in
            probe.revoke()
        }

        XCTAssertThrowsError(try invariant.enforce()) { error in
            XCTAssertEqual(
                error as? WorldwideSafeOutputInvariantError,
                .sessionRepairRequiresAdmissionFence
            )
        }
        XCTAssertEqual(probe.events, [])
        XCTAssertEqual(operations.writes, [])

        probe.revoke()
        try invariant.endSessionMonitoring(epoch: epoch)
    }

    func testUnprovedInputReleaseAbortsBeforeAnyOutputMutation()
        throws {
        let operations = FakeSafeOutputOperations(
            outputUID: blackHole,
            systemOutputUID: hiddenMirror,
            deviceIDsByUID: [speakers: 74]
        )
        let invariant = makeInvariant(operations: operations)
        let probe = SafeOutputSessionProbe()
        let epoch = try invariant.beginSessionMonitoring { _, _ in
            probe.revoke()
        }

        XCTAssertThrowsError(
            try invariant.enforceDuringAdmission(
                monitoringEpoch: epoch,
                beforeFirstMutation: {
                    probe.revoke()
                    throw SafeOutputSessionTestError
                        .inputReleaseUnproved
                },
                admission: {
                    probe.record("admission")
                    return 41
                },
                rollback: { _ in
                    probe.record("rollback")
                },
                commit: { _, authorization in
                    probe.commit(authorization)
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? SafeOutputSessionTestError,
                .inputReleaseUnproved
            )
        }

        XCTAssertEqual(probe.events, ["uncertain"])
        XCTAssertEqual(operations.writes, [])
        XCTAssertEqual(operations.listenerCount, 2)

        probe.revoke()
        try invariant.endSessionMonitoring(epoch: epoch)
    }

    func testSessionEndRetainsExactFailedListenerAndDeactivatesCallback()
        throws {
        let scheduler = SafeOutputCleanupRetrySchedulerFake()
        let cleanupRetainer =
            BlackHoleDeviceAvailabilityListenerCleanupRetainer(
                retryScheduler: scheduler
            )
        let operations = FakeSafeOutputOperations(
            outputUID: speakers,
            systemOutputUID: "headphones"
        )
        let removalFailure = OSStatus(-70_042)
        operations.listenerRemovalFailureStatus = removalFailure
        operations.listenerRemovalFailuresRemaining[.output] = 3
        let invariant = makeInvariant(
            operations: operations,
            listenerCleanupRetainer: cleanupRetainer
        )
        let probe = SafeOutputSessionProbe()
        let epoch = try invariant.beginSessionMonitoring { _, _ in
            probe.revoke()
        }

        probe.revoke()
        XCTAssertThrowsError(
            try invariant.endSessionMonitoring(epoch: epoch)
        ) { error in
            XCTAssertEqual(
                error as? WorldwideSafeOutputInvariantError,
                .listenerRemovalFailed(
                    status: removalFailure
                )
            )
        }

        XCTAssertEqual(operations.listenerCount, 1)
        XCTAssertEqual(cleanupRetainer.retainedJobCount, 1)
        XCTAssertEqual(scheduler.scheduledCount, 1)
        XCTAssertEqual(
            Set(
                operations.removalListenerIdentifiers[.output]
                    ?? []
            ).count,
            1
        )

        let eventCount = probe.events.count
        operations.emitChange(.output)
        XCTAssertEqual(
            probe.events.count,
            eventCount,
            "A logically ended session must not invoke its stale callback."
        )

        scheduler.runNext()
        XCTAssertEqual(operations.listenerCount, 0)
        XCTAssertEqual(cleanupRetainer.retainedJobCount, 0)
        XCTAssertEqual(
            Set(
                operations.removalListenerIdentifiers[.output]
                    ?? []
            ).count,
            1,
            "Deferred cleanup must retain the exact listener identity."
        )
    }

    func testAdmissionKeepsListenersInstalledThroughFinalSafeReadback()
        throws {
        let operations = FakeSafeOutputOperations(
            outputUID: speakers,
            systemOutputUID: "headphones"
        )
        let invariant = makeInvariant(operations: operations)
        var rollbackCount = 0

        let result = try invariant.enforceDuringAdmission(
            admission: {
                XCTAssertEqual(operations.listenerCount, 2)
                return 41
            },
            rollback: { _ in
                rollbackCount += 1
            }
        )

        XCTAssertEqual(result.admission, 41)
        XCTAssertFalse(result.invariant.changedAnything)
        XCTAssertEqual(rollbackCount, 0)
        XCTAssertEqual(operations.listenerCount, 0)
    }

    func testAdmissionRevokesBeforeFirstMutationUnderBothListenersOnlyOnce()
        throws {
        let operations = FakeSafeOutputOperations(
            outputUID: blackHole,
            systemOutputUID: hiddenMirror,
            deviceIDsByUID: [speakers: 74]
        )
        let invariant = makeInvariant(operations: operations)
        var preparationCount = 0

        let result = try invariant.enforceDuringAdmission(
            beforeFirstMutation: {
                preparationCount += 1
                XCTAssertEqual(operations.listenerCount, 2)
                XCTAssertEqual(operations.writes, [])
            },
            admission: { 41 },
            rollback: { _ in
                XCTFail("A proven admission must not roll back.")
            }
        )

        XCTAssertEqual(preparationCount, 1)
        XCTAssertEqual(operations.writes.count, 2)
        XCTAssertTrue(result.invariant.changedAnything)
        XCTAssertEqual(result.admission, 41)
        XCTAssertEqual(operations.listenerCount, 0)
    }

    func testSafeAdmissionDoesNotInvokeBeforeFirstMutationHook()
        throws {
        let operations = FakeSafeOutputOperations(
            outputUID: speakers,
            systemOutputUID: "headphones"
        )
        let invariant = makeInvariant(operations: operations)
        var preparationCount = 0

        _ = try invariant.enforceDuringAdmission(
            beforeFirstMutation: {
                preparationCount += 1
            },
            admission: { 41 },
            rollback: { _ in
                XCTFail("A proven admission must not roll back.")
            }
        )

        XCTAssertEqual(preparationCount, 0)
        XCTAssertEqual(operations.writes, [])
    }

    func testAdmissionRollsBackWhenEitherOutputSelectorChanges()
        throws {
        for kind in BlackHoleDefaultOutputKind.allCases {
            let operations = FakeSafeOutputOperations(
                outputUID: speakers,
                systemOutputUID: "headphones"
            )
            let invariant = makeInvariant(operations: operations)
            var rollbackValues: [Int] = []

            XCTAssertThrowsError(
                try invariant.enforceDuringAdmission(
                    admission: {
                        operations.setUID(
                            kind == .output
                                ? self.hiddenMirror
                                : self.blackHole,
                            for: kind
                        )
                        operations.emitChange(kind)
                        return 73
                    },
                    rollback: { value in
                        rollbackValues.append(value)
                    }
                )
            ) { error in
                XCTAssertEqual(
                    error as? WorldwideSafeOutputInvariantError,
                    .observableContention
                )
            }
            XCTAssertEqual(rollbackValues, [73])
            XCTAssertEqual(operations.listenerCount, 0)
        }
    }

    func testAdmissionRollsBackForNotificationDuringListenerRemoval()
        throws {
        let operations = FakeSafeOutputOperations(
            outputUID: speakers,
            systemOutputUID: "headphones"
        )
        operations.beforeFirstListenerRemoval = {
            operations, _ in
            operations.emitChange(.systemOutput)
        }
        let invariant = makeInvariant(operations: operations)
        var rollbackValues: [Int] = []

        XCTAssertThrowsError(
            try invariant.enforceDuringAdmission(
                admission: { 73 },
                rollback: { rollbackValues.append($0) }
            )
        ) { error in
            XCTAssertEqual(
                error as? WorldwideSafeOutputInvariantError,
                .observableContention
            )
        }
        XCTAssertEqual(rollbackValues, [73])
        XCTAssertEqual(operations.listenerCount, 0)
    }

    func testFailedRemovalRetainsExactListenerForAutonomousRedrive()
        throws {
        let scheduler =
            SafeOutputCleanupRetrySchedulerFake()
        let cleanupRetainer =
            BlackHoleDeviceAvailabilityListenerCleanupRetainer(
                retryScheduler: scheduler
            )
        let operations = FakeSafeOutputOperations(
            outputUID: speakers,
            systemOutputUID: "headphones"
        )
        let removalFailure = OSStatus(-70_041)
        operations.listenerRemovalFailureStatus =
            removalFailure
        operations.listenerRemovalFailuresRemaining[.output] = 3
        let invariant = makeInvariant(
            operations: operations,
            listenerCleanupRetainer: cleanupRetainer
        )
        var rollbackValues: [Int] = []

        XCTAssertThrowsError(
            try invariant.enforceDuringAdmission(
                admission: { 73 },
                rollback: { rollbackValues.append($0) }
            )
        ) { error in
            XCTAssertEqual(
                error as? WorldwideSafeOutputInvariantError,
                .listenerRemovalFailed(
                    status: removalFailure
                )
            )
        }

        XCTAssertEqual(rollbackValues, [73])
        XCTAssertEqual(operations.listenerCount, 1)
        XCTAssertEqual(cleanupRetainer.retainedJobCount, 1)
        XCTAssertEqual(scheduler.scheduledCount, 1)
        XCTAssertEqual(
            operations.removalListenerIdentifiers[.output]?.count,
            3,
            "The synchronous removal budget must be exactly three attempts."
        )
        XCTAssertEqual(
            Set(
                operations.removalListenerIdentifiers[.output]
                    ?? []
            ).count,
            1,
            "Every bounded attempt must retain the exact listener object."
        )

        scheduler.runNext()

        XCTAssertEqual(operations.listenerCount, 0)
        XCTAssertEqual(cleanupRetainer.retainedJobCount, 0)
        XCTAssertEqual(
            Set(
                operations.removalListenerIdentifiers[.output]
                    ?? []
            ).count,
            1,
            "Autonomous cleanup must remove the same exact listener object."
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

    func testVisibleAndHiddenBlackHoleSelectorsAreBothReplaced()
        throws {
        let operations = FakeSafeOutputOperations(
            outputUID: hiddenMirror,
            systemOutputUID: blackHole,
            deviceIDsByUID: [speakers: 74]
        )
        let invariant = makeInvariant(operations: operations)

        let result = try invariant.enforce()

        XCTAssertTrue(result.changedDefaultOutput)
        XCTAssertTrue(result.changedDefaultSystemOutput)
        XCTAssertEqual(
            operations.writes.map(\.expectedUID),
            [hiddenMirror, blackHole]
        )
        XCTAssertEqual(operations.outputUID, speakers)
        XCTAssertEqual(operations.systemOutputUID, speakers)
    }

    func testHiddenMirrorDefaultOutputPrefersCurrentRealSystemOutput()
        throws {
        let operations = FakeSafeOutputOperations(
            outputUID: hiddenMirror,
            systemOutputUID: "headphones",
            deviceIDsByUID: ["headphones": 91]
        )
        let invariant = makeInvariant(operations: operations)

        let result = try invariant.enforce()

        XCTAssertTrue(result.changedDefaultOutput)
        XCTAssertFalse(result.changedDefaultSystemOutput)
        XCTAssertEqual(operations.outputUID, "headphones")
        XCTAssertEqual(operations.systemOutputUID, "headphones")
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
        operations: FakeSafeOutputOperations,
        listenerCleanupRetainer:
            any BlackHoleDeviceAvailabilityListenerCleanupRetaining =
                BlackHoleDeviceAvailabilityListenerCleanupRetainer()
    ) -> WorldwideSafeOutputInvariant {
        WorldwideSafeOutputInvariant(
            operations: operations,
            operationQueue: DispatchQueue(
                label: "test.WorldwideSafeOutputInvariant"
            ),
            listenerQueue: DispatchQueue(
                label: "test.WorldwideSafeOutputInvariant.listener"
            ),
            proofTimeout: 0.01,
            listenerCleanupRetainer:
                listenerCleanupRetainer
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
    var beforeFirstListenerRemoval:
        ((FakeSafeOutputOperations, BlackHoleDefaultOutputKind) -> Void)?
    var listenerRemovalFailureStatus = OSStatus(-70_040)
    var listenerRemovalFailuresRemaining:
        [BlackHoleDefaultOutputKind: Int] = [:]
    var removalListenerIdentifiers: [
        BlackHoleDefaultOutputKind: [ObjectIdentifier]
    ] = [:]
    var additionListenerIdentifiers: [
        BlackHoleDefaultOutputKind: [ObjectIdentifier]
    ] = [:]
    private var totalReadCount = 0
    private var successfulWriteReadCount: Int?
    private var listeners: [
        BlackHoleDefaultOutputKind:
            CoreAudioPropertyListenerRegistration
    ] = [:]

    var listenerCount: Int {
        listeners.count
    }

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
        additionListenerIdentifiers[kind, default: []]
            .append(ObjectIdentifier(listener))
        listeners[kind] = listener
        return noErr
    }

    func removeDefaultOutputListener(
        kind: BlackHoleDefaultOutputKind,
        queue _: DispatchQueue,
        listener: CoreAudioPropertyListenerRegistration
    ) -> OSStatus {
        removalListenerIdentifiers[kind, default: []]
            .append(ObjectIdentifier(listener))
        if let beforeFirstListenerRemoval {
            self.beforeFirstListenerRemoval = nil
            beforeFirstListenerRemoval(self, kind)
        }
        let remaining =
            listenerRemovalFailuresRemaining[kind] ?? 0
        if remaining > 0 {
            listenerRemovalFailuresRemaining[kind] =
                remaining - 1
            return listenerRemovalFailureStatus
        }
        guard listeners[kind] === listener else {
            return kAudio_ParamError
        }
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

private enum SafeOutputSessionTestError:
    Error,
    Equatable
{
    case inputReleaseUnproved
}

private final class SafeOutputSessionProbe:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var gateIsOpen = false
    private var authorization:
        WorldwideSafeOutputInvariantAuthorization?
    private var recordedUncertainEpoch:
        WorldwideSafeOutputInvariantMonitoringEpoch?
    private var recordedUncertainSequence: UInt64?

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gateIsOpen
    }

    var lastUncertainEpoch:
        WorldwideSafeOutputInvariantMonitoringEpoch? {
        lock.lock()
        defer { lock.unlock() }
        return recordedUncertainEpoch
    }

    var lastUncertainSequence: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return recordedUncertainSequence
    }

    func record(_ event: String) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }

    func revoke() {
        lock.lock()
        gateIsOpen = false
        authorization = nil
        recordedEvents.append("uncertain")
        lock.unlock()
    }

    func revoke(
        epoch: WorldwideSafeOutputInvariantMonitoringEpoch,
        eventSequence: UInt64
    ) {
        lock.lock()
        gateIsOpen = false
        authorization = nil
        recordedUncertainEpoch = epoch
        recordedUncertainSequence = eventSequence
        recordedEvents.append("uncertain")
        lock.unlock()
    }

    func commit(
        _ authorization:
            WorldwideSafeOutputInvariantAuthorization
    ) {
        lock.lock()
        self.authorization = authorization
        gateIsOpen = true
        recordedEvents.append("commit")
        lock.unlock()
    }
}

private final class SafeOutputCleanupRetrySchedulerFake:
    BlackHoleDeferredCleanupRetryScheduling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var scheduledWork:
        [@Sendable () -> Void] = []

    var scheduledCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return scheduledWork.count
    }

    func schedule(
        after _: TimeInterval,
        work: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        scheduledWork.append(work)
        lock.unlock()
    }

    func runNext() {
        let work: (@Sendable () -> Void)?
        lock.lock()
        work = scheduledWork.isEmpty
            ? nil
            : scheduledWork.removeFirst()
        lock.unlock()
        work?()
    }
}
