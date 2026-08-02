#if os(macOS)
import CoreAudio
import Foundation
import XCTest
@testable import CaptureCore

final class BlackHoleDeviceAvailabilityMonitorTests:
    XCTestCase
{
    func testListenerRegistersBeforeInitialInventoryAndUsesExactRemovalIdentity()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("BlackHole2ch_UID"),
            ]
        )
        let ledger = BlackHoleSnapshotLedger()
        let queue = DispatchQueue(
            label: "test.BlackHoleDeviceAvailabilityMonitor.order"
        )
        let epoch = UUID()
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: queue,
            makeEpoch: { epoch }
        )

        let returnedEpoch = try monitor.start {
            ledger.append($0)
        }

        XCTAssertEqual(returnedEpoch, epoch)
        XCTAssertEqual(
            operations.events,
            ["register", "inventory"]
        )
        XCTAssertTrue(operations.registeredExactDevicesAddress)
        XCTAssertEqual(
            ledger.snapshots,
            [
                BlackHoleDeviceAvailabilitySnapshot(
                    monitorEpoch: epoch,
                    deviceGeneration: 1,
                    isAvailable: true,
                    deviceUID: "BlackHole2ch_UID"
                ),
            ]
        )
        XCTAssertEqual(monitor.currentSnapshot(), ledger.snapshots.last)
        XCTAssertEqual(operations.defaultDeviceWriteCount, 0)

        monitor.stop()
        XCTAssertNil(monitor.currentSnapshot())
        XCTAssertTrue(operations.removedExactRegistration)
        XCTAssertEqual(
            operations.events,
            ["register", "inventory", "remove"]
        )
    }

    func testRemovalExhaustionRetainsExactRegistrationAndPermitsRestart()
        throws {
        let cleanupRetryScheduler =
            BlackHoleDeferredCleanupRetrySchedulerFake()
        let cleanupRetainer =
            BlackHoleDeviceAvailabilityListenerCleanupRetainer(
                retryScheduler: cleanupRetryScheduler
            )
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("BlackHole2ch_UID"),
                .uid("BlackHole2ch_UID"),
            ]
        )
        let epochs = [UUID(), UUID()]
        let epochSource = LockedEpochSource(epochs)
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label: "test.BlackHoleDeviceAvailabilityMonitor.pending-removal"
            ),
            makeEpoch: { epochSource.next() },
            listenerCleanupRetainer: cleanupRetainer
        )

        _ = try monitor.start { _ in }
        XCTAssertEqual(
            operations.listenerRegistrationCount,
            1
        )

        operations.listenerRemovalFailuresRemaining = 3
        XCTAssertEqual(
            monitor.stop(),
            .retryableFailure
        )

        XCTAssertNil(monitor.currentSnapshot())
        XCTAssertEqual(monitor.deferredListenerCleanupCount, 1)
        XCTAssertEqual(cleanupRetainer.retainedJobCount, 1)
        XCTAssertEqual(
            operations.removalListenerIdentifiers.count,
            3
        )
        XCTAssertEqual(
            Set(operations.removalListenerIdentifiers).count,
            1,
            "Every bounded removal attempt must reuse the identical listener object."
        )
        XCTAssertEqual(
            Set(operations.removalQueueIdentifiers).count,
            1,
            "Every bounded removal attempt must reuse the identical callback queue."
        )
        XCTAssertFalse(operations.removedExactRegistration)

        _ = try monitor.start { _ in }
        XCTAssertEqual(
            operations.listenerRegistrationCount,
            2,
            "A replacement listener must not be blocked by an inert retained cleanup."
        )
        XCTAssertEqual(cleanupRetainer.retainedJobCount, 0)
        XCTAssertTrue(operations.removedExactRegistration)
        XCTAssertEqual(
            operations.removalListenerIdentifiers.count,
            4
        )
        XCTAssertEqual(
            Set(operations.removalListenerIdentifiers).count,
            1,
            "The restart redrive must retry the exact retained listener object."
        )
        XCTAssertEqual(
            Set(operations.removalQueueIdentifiers).count,
            1
        )
        XCTAssertEqual(
            monitor.stop(),
            .stopped
        )
    }

    func testPersistentCleanupFailureDuringRestartDoesNotPoisonNewSession()
        throws {
        let cleanupRetryScheduler =
            BlackHoleDeferredCleanupRetrySchedulerFake()
        let cleanupRetainer =
            BlackHoleDeviceAvailabilityListenerCleanupRetainer(
                retryScheduler: cleanupRetryScheduler
            )
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("BlackHole2ch_UID"),
                .uid("BlackHole2ch_UID"),
                .unavailable,
            ]
        )
        let ledger = BlackHoleSnapshotLedger()
        let epochs = [UUID(), UUID()]
        let epochSource = LockedEpochSource(epochs)
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label: "test.BlackHoleDeviceAvailabilityMonitor.nonpoison"
            ),
            makeEpoch: { epochSource.next() },
            listenerCleanupRetainer: cleanupRetainer
        )

        _ = try monitor.start {
            ledger.append($0)
        }
        operations.listenerRemovalFailuresRemaining = 6
        XCTAssertEqual(
            monitor.stop(),
            .retryableFailure
        )
        XCTAssertEqual(monitor.deferredListenerCleanupCount, 1)
        XCTAssertEqual(cleanupRetainer.retainedJobCount, 1)
        XCTAssertFalse(operations.removedExactRegistration)
        XCTAssertEqual(operations.removalListenerIdentifiers.count, 3)

        _ = try monitor.start {
            ledger.append($0)
        }
        XCTAssertEqual(
            operations.listenerRegistrationCount,
            2,
            "A persistently failing inert cleanup must not suppress a new monitor session."
        )
        XCTAssertEqual(cleanupRetainer.retainedJobCount, 1)
        XCTAssertFalse(operations.removedExactRegistration)
        XCTAssertEqual(
            operations.removalListenerIdentifiers.count,
            4,
            "The restart redrive budget of one must equal one underlying Core Audio removal."
        )

        operations.emitRegisteredListener(at: 0)
        XCTAssertEqual(
            ledger.snapshots.count,
            2,
            "The logically stopped epoch must remain inert while its exact listener cleanup is deferred."
        )
        operations.emitRegisteredListener(at: 1)
        XCTAssertEqual(ledger.snapshots.count, 3)
        XCTAssertEqual(ledger.snapshots.last?.isAvailable, false)

        operations.listenerRemovalFailuresRemaining = 0
        XCTAssertEqual(
            cleanupRetainer.redriveRetained(maximumAttemptCount: 1),
            0
        )
        XCTAssertTrue(operations.removedExactRegistration)
        XCTAssertEqual(
            operations.listenerRegistrationCount,
            2,
            "Deferred inert cleanup must not tear down the active replacement listener."
        )
        XCTAssertEqual(
            monitor.stop(),
            .stopped
        )
    }

    func testDeinitRedrivesExactRegistrationAfterExplicitStopExhaustion()
        throws {
        let cleanupRetryScheduler =
            BlackHoleDeferredCleanupRetrySchedulerFake()
        let cleanupRetainer =
            BlackHoleDeviceAvailabilityListenerCleanupRetainer(
                retryScheduler: cleanupRetryScheduler
            )
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("BlackHole2ch_UID"),
            ]
        )
        var monitor: BlackHoleDeviceAvailabilityMonitor? =
            BlackHoleDeviceAvailabilityMonitor(
                operations: operations,
                callbackQueue: DispatchQueue(
                    label:
                        "test.BlackHoleDeviceAvailabilityMonitor.deinit-redrive"
                ),
                makeEpoch: { UUID() },
                listenerCleanupRetainer: cleanupRetainer
            )

        _ = try monitor!.start { _ in }
        operations.listenerRemovalFailuresRemaining = 3

        XCTAssertEqual(
            monitor!.stop(),
            .retryableFailure
        )
        XCTAssertFalse(operations.removedExactRegistration)
        XCTAssertEqual(cleanupRetainer.retainedJobCount, 1)
        XCTAssertEqual(
            operations.removalListenerIdentifiers.count,
            3
        )

        monitor = nil
        XCTAssertEqual(
            cleanupRetainer.retainedJobCount,
            0,
            "Deinit must redrive, not discard, the exact deferred cleanup registration."
        )
        XCTAssertTrue(operations.removedExactRegistration)
        XCTAssertEqual(
            operations.removalListenerIdentifiers.count,
            4
        )
        XCTAssertEqual(
            Set(operations.removalListenerIdentifiers).count,
            1
        )
        XCTAssertEqual(
            Set(operations.removalQueueIdentifiers).count,
            1
        )
    }

    func testCallbackTriggeredDeinitDefersExactListenerCleanupWithoutSynchronousRemoval()
        throws {
        let cleanupRetryScheduler =
            BlackHoleDeferredCleanupRetrySchedulerFake()
        let cleanupRetainer =
            BlackHoleDeviceAvailabilityListenerCleanupRetainer(
                retryScheduler: cleanupRetryScheduler
            )
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("BlackHole2ch_UID"),
                .unavailable,
            ]
        )
        let strongBox = BlackHoleAvailabilityMonitorStrongBox()
        var monitor: BlackHoleDeviceAvailabilityMonitor? =
            BlackHoleDeviceAvailabilityMonitor(
                operations: operations,
                callbackQueue: DispatchQueue(
                    label:
                        "test.BlackHoleDeviceAvailabilityMonitor.callback-deinit"
                ),
                makeEpoch: { UUID() },
                listenerCleanupRetainer: cleanupRetainer
            )

        try monitor!.start { _ in
            strongBox.clear()
        }
        strongBox.store(monitor!)
        monitor = nil

        operations.emitCurrentListener()

        XCTAssertEqual(cleanupRetainer.retainedJobCount, 1)
        XCTAssertFalse(
            operations.events.contains("remove"),
            "Callback-triggered deinit must not synchronously deregister from inside the Core Audio listener callback."
        )
        XCTAssertEqual(
            cleanupRetainer.redriveRetained(maximumAttemptCount: 1),
            0
        )
        XCTAssertTrue(operations.removedExactRegistration)
    }

    func testDeferredCleanupAutonomouslyRetriesOneRemovalPerBoundedTick()
        throws {
        let cleanupRetryScheduler =
            BlackHoleDeferredCleanupRetrySchedulerFake()
        let cleanupRetainer =
            BlackHoleDeviceAvailabilityListenerCleanupRetainer(
                retryScheduler: cleanupRetryScheduler
            )
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("BlackHole2ch_UID"),
            ]
        )
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label:
                    "test.BlackHoleDeviceAvailabilityMonitor.autonomous-cleanup"
            ),
            makeEpoch: { UUID() },
            listenerCleanupRetainer: cleanupRetainer
        )

        _ = try monitor.start { _ in }
        operations.listenerRemovalFailuresRemaining = 4
        XCTAssertEqual(monitor.stop(), .retryableFailure)
        XCTAssertEqual(operations.removalListenerIdentifiers.count, 3)
        XCTAssertEqual(monitor.deferredListenerCleanupCount, 1)
        XCTAssertEqual(cleanupRetryScheduler.scheduledCount, 1)

        cleanupRetryScheduler.runNext()
        XCTAssertEqual(
            operations.removalListenerIdentifiers.count,
            4,
            "One autonomous retry tick must spend exactly one underlying removal attempt."
        )
        XCTAssertEqual(cleanupRetainer.retainedJobCount, 1)
        XCTAssertEqual(cleanupRetryScheduler.scheduledCount, 1)

        cleanupRetryScheduler.runNext()
        XCTAssertEqual(operations.removalListenerIdentifiers.count, 5)
        XCTAssertEqual(cleanupRetainer.retainedJobCount, 0)
        XCTAssertEqual(cleanupRetryScheduler.scheduledCount, 0)
        XCTAssertTrue(operations.removedExactRegistration)
        XCTAssertEqual(
            cleanupRetryScheduler.scheduledDelays,
            [0.1, 0.2],
            "Persistent cleanup uses bounded backoff instead of a tight retry loop."
        )
    }

    func testCleanupRetainerNeverExecutesOneJobConcurrently()
        throws {
        let cleanupRetryScheduler =
            BlackHoleDeferredCleanupRetrySchedulerFake()
        let cleanupRetainer =
            BlackHoleDeviceAvailabilityListenerCleanupRetainer(
                retryScheduler: cleanupRetryScheduler
            )
        let probe = BlockingCleanupAttemptProbe()
        let id = UUID()
        cleanupRetainer.retain(id: id) {
            probe.attempt()
        }

        let explicitRedrive = DispatchGroup()
        explicitRedrive.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            cleanupRetainer.redrive(id: id)
            explicitRedrive.leave()
        }
        XCTAssertEqual(
            probe.entered.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(probe.attemptCount, 1)
        XCTAssertEqual(
            cleanupRetainer.debugInFlightJobCountForTesting,
            1
        )

        XCTAssertEqual(
            cleanupRetainer.redriveRetained(maximumAttemptCount: 1),
            1
        )
        XCTAssertEqual(
            probe.attemptCount,
            1,
            "Round-robin redrive must not execute a job already owned by explicit redrive."
        )

        probe.release()
        XCTAssertEqual(
            explicitRedrive.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(probe.maximumConcurrentAttemptCount, 1)
        XCTAssertEqual(cleanupRetainer.retainedJobCount, 1)
    }

    func testStoppedAndOldEpochCallbacksAreFenced() throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("BlackHole2ch_UID"),
                .uid("BlackHole2ch_UID"),
                .unavailable,
            ]
        )
        let ledger = BlackHoleSnapshotLedger()
        let epochs = [UUID(), UUID()]
        let epochSource = LockedEpochSource(epochs)
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label: "test.BlackHoleDeviceAvailabilityMonitor.epoch"
            ),
            makeEpoch: { epochSource.next() }
        )

        let firstEpoch = try monitor.start {
            ledger.append($0)
        }
        monitor.stop()
        let secondEpoch = try monitor.start {
            ledger.append($0)
        }
        XCTAssertNotEqual(firstEpoch, secondEpoch)
        XCTAssertEqual(ledger.snapshots.count, 2)

        operations.emitRetiredListener(at: 0)
        XCTAssertEqual(
            ledger.snapshots.count,
            2,
            "A callback retained from the stopped epoch must be ignored."
        )

        operations.emitCurrentListener()
        XCTAssertEqual(ledger.snapshots.count, 3)
        XCTAssertEqual(
            ledger.snapshots.last?.monitorEpoch,
            secondEpoch
        )
        XCTAssertEqual(ledger.snapshots.last?.isAvailable, false)
        monitor.stop()
    }

    func testLookupFailureAndDeviceReinstallPublishMonotonicGenerations()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("BlackHole2ch_UID"),
                .unavailable,
                .uid("BlackHole2ch_UID"),
            ]
        )
        let ledger = BlackHoleSnapshotLedger()
        let epoch = UUID()
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label: "test.BlackHoleDeviceAvailabilityMonitor.reinstall"
            ),
            makeEpoch: { epoch }
        )

        try monitor.start {
            ledger.append($0)
        }
        operations.emitCurrentListener()
        operations.emitCurrentListener()

        XCTAssertEqual(
            ledger.snapshots.map(\.deviceGeneration),
            [1, 2, 3]
        )
        XCTAssertEqual(
            ledger.snapshots.map(\.isAvailable),
            [true, false, true]
        )
        XCTAssertEqual(
            ledger.snapshots.map(\.deviceUID),
            [
                "BlackHole2ch_UID",
                nil,
                "BlackHole2ch_UID",
            ]
        )
        XCTAssertEqual(operations.defaultDeviceWriteCount, 0)
        monitor.stop()
    }

    func testTransientInventoryConfigurationFailurePreservesLastFactualSnapshotAndClearsRetryAfterFactualRead()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("BlackHole2ch_UID"),
                .configurationFailure,
                .uid("BlackHole2ch_UID"),
            ]
        )
        let retryScheduler =
            BlackHoleInventoryRetryScheduler()
        let ledger = BlackHoleSnapshotLedger()
        let epoch = UUID()
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label:
                    "test.BlackHoleDeviceAvailabilityMonitor.transient-retry"
            ),
            makeEpoch: { epoch },
            scheduleInventoryRetry: { work in
                retryScheduler.schedule(work)
            }
        )

        try monitor.start {
            ledger.append($0)
        }
        operations.emitCurrentListener()

        XCTAssertEqual(
            ledger.snapshots.map(\.deviceGeneration),
            [1],
            "A transient Core Audio inventory error must preserve the last factual identity."
        )
        XCTAssertEqual(
            retryScheduler.scheduledCount,
            1
        )

        retryScheduler.runNext()
        _ = monitor.currentSnapshot()

        XCTAssertEqual(
            ledger.snapshots.map(\.deviceGeneration),
            [1],
            "A successful retry that resolves the same identity must not synthesize a generation."
        )
        XCTAssertEqual(
            operations.events.filter {
                $0 == "inventory"
            }.count,
            3
        )
        XCTAssertEqual(
            retryScheduler.scheduledCount,
            0,
            "A factual retry result clears the outstanding token."
        )
        monitor.stop()
    }

    func testTransientFailureRetryKeepsConvergingUntilFactualAbsence()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("BlackHole2ch_UID"),
                .configurationFailure,
                .configurationFailure,
                .unavailable,
            ]
        )
        let retryScheduler =
            BlackHoleInventoryRetryScheduler()
        let ledger = BlackHoleSnapshotLedger()
        let epoch = UUID()
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label:
                    "test.BlackHoleDeviceAvailabilityMonitor.converging-retry"
            ),
            makeEpoch: { epoch },
            scheduleInventoryRetry: { work in
                retryScheduler.schedule(work)
            }
        )

        try monitor.start {
            ledger.append($0)
        }
        operations.emitCurrentListener()

        XCTAssertEqual(
            ledger.snapshots.map(\.isAvailable),
            [true]
        )
        XCTAssertEqual(retryScheduler.scheduledCount, 1)

        retryScheduler.runNext()
        _ = monitor.currentSnapshot()
        XCTAssertEqual(
            ledger.snapshots.map(\.isAvailable),
            [true],
            "A second transient retry failure must preserve the last factual availability."
        )
        XCTAssertEqual(
            retryScheduler.scheduledCount,
            1,
            "Retry failure must schedule a fresh token-fenced retry instead of exhausting after one attempt."
        )

        retryScheduler.runNext()
        _ = monitor.currentSnapshot()
        XCTAssertEqual(
            ledger.snapshots.map(\.deviceGeneration),
            [1, 2]
        )
        XCTAssertEqual(
            ledger.snapshots.map(\.isAvailable),
            [true, false]
        )
        XCTAssertEqual(retryScheduler.scheduledCount, 0)
        monitor.stop()
    }

    func testNotificationCoalescesAndFencesStaleInventoryRetry()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("BlackHole2ch_UID"),
                .configurationFailure,
                .configurationFailure,
                .unavailable,
            ]
        )
        let retryScheduler =
            BlackHoleInventoryRetryScheduler()
        let ledger = BlackHoleSnapshotLedger()
        let epoch = UUID()
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label:
                    "test.BlackHoleDeviceAvailabilityMonitor.coalesced-retry"
            ),
            makeEpoch: { epoch },
            scheduleInventoryRetry: { work in
                retryScheduler.schedule(work)
            }
        )

        try monitor.start {
            ledger.append($0)
        }
        operations.emitCurrentListener()
        XCTAssertEqual(retryScheduler.scheduledCount, 1)

        operations.emitCurrentListener()
        XCTAssertEqual(
            retryScheduler.scheduledCount,
            2,
            "A newer notification must replace the outstanding token and schedule its own retry."
        )

        retryScheduler.runNext()
        _ = monitor.currentSnapshot()
        XCTAssertEqual(
            ledger.snapshots.map(\.isAvailable),
            [true],
            "The stale retry token from the older event must be fenced."
        )
        XCTAssertEqual(retryScheduler.scheduledCount, 1)

        retryScheduler.runNext()
        _ = monitor.currentSnapshot()
        XCTAssertEqual(
            ledger.snapshots.map(\.isAvailable),
            [true, false]
        )
        XCTAssertEqual(retryScheduler.scheduledCount, 0)
        monitor.stop()
    }

    func testStoppedTransientInventoryRetryIsFencedFromReplacementEpoch()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .configurationFailure,
                .uid("BlackHole2ch_UID"),
            ]
        )
        let retryScheduler =
            BlackHoleInventoryRetryScheduler()
        let epochs = [UUID(), UUID()]
        let epochSource = LockedEpochSource(epochs)
        let ledger = BlackHoleSnapshotLedger()
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label:
                    "test.BlackHoleDeviceAvailabilityMonitor.stale-retry"
            ),
            makeEpoch: { epochSource.next() },
            scheduleInventoryRetry: { work in
                retryScheduler.schedule(work)
            }
        )

        _ = try monitor.start {
            ledger.append($0)
        }
        XCTAssertEqual(retryScheduler.scheduledCount, 1)
        XCTAssertTrue(ledger.snapshots.isEmpty)

        XCTAssertEqual(monitor.stop(), .stopped)
        let replacementEpoch = try monitor.start {
            ledger.append($0)
        }
        XCTAssertEqual(ledger.snapshots.count, 1)
        XCTAssertEqual(
            ledger.snapshots[0].monitorEpoch,
            replacementEpoch
        )

        retryScheduler.runNext()
        _ = monitor.currentSnapshot()
        XCTAssertEqual(
            ledger.snapshots.count,
            1,
            "A retry scheduled by a stopped epoch must not consume inventory or publish into its replacement."
        )
        monitor.stop()
    }

    func testUnchangedIdentityCallbacksDoNotPublishOrAdvanceGeneration()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: Array(
                repeating: .uid("BlackHole2ch_UID"),
                count: 513
            )
        )
        let ledger = BlackHoleSnapshotLedger()
        let epoch = UUID()
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label: "test.BlackHoleDeviceAvailabilityMonitor.dedup"
            ),
            makeEpoch: { epoch }
        )

        try monitor.start {
            ledger.append($0)
        }
        for _ in 0..<512 {
            operations.emitCurrentListener()
        }

        XCTAssertEqual(ledger.snapshots.count, 1)
        XCTAssertEqual(
            ledger.snapshots.map(\.deviceGeneration),
            [1]
        )
        XCTAssertEqual(
            operations.events.filter { $0 == "inventory" }.count,
            513
        )
        XCTAssertEqual(operations.defaultDeviceWriteCount, 0)
        monitor.stop()
    }

    func testNonIncreasingGenerationAndForeignEpochAreRejected()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("BlackHole2ch_UID"),
            ]
        )
        let ledger = BlackHoleSnapshotLedger()
        let epoch = UUID()
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label: "test.BlackHoleDeviceAvailabilityMonitor.generation"
            ),
            makeEpoch: { epoch }
        )

        try monitor.start {
            ledger.append($0)
        }
        monitor.publishForTesting(
            BlackHoleDeviceAvailabilitySnapshot(
                monitorEpoch: epoch,
                deviceGeneration: 3,
                isAvailable: true,
                deviceUID: "BlackHole2ch_UID"
            )
        )
        monitor.publishForTesting(
            BlackHoleDeviceAvailabilitySnapshot(
                monitorEpoch: epoch,
                deviceGeneration: 2,
                isAvailable: false,
                deviceUID: nil
            )
        )
        monitor.publishForTesting(
            BlackHoleDeviceAvailabilitySnapshot(
                monitorEpoch: UUID(),
                deviceGeneration: 4,
                isAvailable: false,
                deviceUID: nil
            )
        )

        XCTAssertEqual(
            ledger.snapshots.map(\.deviceGeneration),
            [1, 3]
        )
        XCTAssertTrue(ledger.snapshots.last?.isAvailable == true)
        monitor.stop()
    }
}

final class BlackHoleDefaultInputLeaseTests:
    XCTestCase
{
    func testListenerPrecedesOwnedWriteAndReleaseRestoresPriorUID() {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(operations)

        XCTAssertTrue(lease.acquire(generation: 1))
        XCTAssertEqual(
            operations.currentUID,
            BlackHoleDefaultInputLease.canonicalDeviceUID
        )
        let events = operations.events
        let firstRead = try? XCTUnwrap(
            events.firstIndex(of: "read")
        )
        let registration = try? XCTUnwrap(
            events.firstIndex(of: "register")
        )
        let write = try? XCTUnwrap(
            events.firstIndex(of: "write:2")
        )
        XCTAssertNotNil(firstRead)
        XCTAssertNotNil(registration)
        XCTAssertNotNil(write)
        if let firstRead, let registration, let write {
            XCTAssertLessThan(
                firstRead,
                registration,
                "A pre-registration read closes the listener-registration gap."
            )
            XCTAssertLessThan(
                registration,
                write,
                "The listener and post-registration fence must precede the owned write."
            )
        }

        lease.release(generation: 1)
        XCTAssertEqual(operations.currentUID, "BuiltInMic_UID")
        XCTAssertEqual(operations.writtenDeviceIDs, [2, 1])
        XCTAssertTrue(operations.removedExactRegistration)
        XCTAssertTrue(operations.registeredExactInputAddress)
    }

    func testNoErrWithoutNotificationProofDegradesAndRestoresBestEffort() {
        let operations = DefaultInputLeaseOperationsFake()
        operations.emitsNotifications = false
        let lease = makeLease(
            operations,
            proofTimeout: 0.01
        )

        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .terminalFailure
        )
        XCTAssertEqual(operations.currentUID, "BuiltInMic_UID")
        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .terminalFailure
        )
        lease.release(generation: 1)
        XCTAssertTrue(operations.removedExactRegistration)
    }

    func testListenerRegistrationFailureIsProvablyRetryable() {
        let operations = DefaultInputLeaseOperationsFake()
        operations.listenerRegistrationFailuresRemaining = 1
        let lease = makeLease(operations)

        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .retryableFailure
        )
        XCTAssertTrue(operations.writtenDeviceIDs.isEmpty)
        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .acquired
        )
        XCTAssertEqual(
            operations.currentUID,
            BlackHoleDefaultInputLease.canonicalDeviceUID
        )
    }

    func testQueuedExternalChoiceDuringRegistrationTerminalizesWithoutWriting() {
        let operations = DefaultInputLeaseOperationsFake()
        operations.deliversNotificationsAsynchronously = true
        operations.onListenerRegistered = {
            [weak operations] in
            operations?.externalSelect(deviceID: 3)
            operations?.externalSelect(deviceID: 1)
        }
        let lease = makeLease(operations)

        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .terminalFailure
        )
        XCTAssertEqual(
            operations.currentUID,
            "BuiltInMic_UID",
            "Sequence fencing must catch an external round trip even when the UID readback returns to its baseline."
        )
        XCTAssertTrue(operations.writtenDeviceIDs.isEmpty)
    }

    func testQueuedExternalChoiceDuringResolutionTerminalizesWithoutWriting() {
        let operations = DefaultInputLeaseOperationsFake()
        operations.deliversNotificationsAsynchronously = true
        operations.onResolveDeviceID = {
            [weak operations] uid in
            guard uid
                    == BlackHoleDefaultInputLease
                        .canonicalDeviceUID else {
                return
            }
            operations?.externalSelect(deviceID: 3)
            operations?.externalSelect(deviceID: 1)
        }
        let lease = makeLease(operations)

        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .terminalFailure
        )
        XCTAssertEqual(
            operations.currentUID,
            "BuiltInMic_UID"
        )
        XCTAssertTrue(operations.writtenDeviceIDs.isEmpty)
        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .terminalFailure
        )
    }

    func testOwnedWriteProofRejectsQueuedExternalRoundTripToTarget() {
        let operations = DefaultInputLeaseOperationsFake()
        operations.deliversNotificationsAsynchronously = true
        operations.onDefaultInputWritten = {
            [weak operations] deviceID in
            guard deviceID == 2 else { return }
            operations?.externalSelect(deviceID: 3)
            operations?.externalSelect(deviceID: 2)
        }
        let lease = makeLease(operations)

        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .terminalFailure
        )
        XCTAssertEqual(
            operations.currentUID,
            BlackHoleDefaultInputLease.canonicalDeviceUID,
            "The final BlackHole choice is external/user-owned."
        )
        XCTAssertEqual(
            operations.writtenDeviceIDs,
            [2],
            "Multiple queued notifications must not be accepted as one " +
                "owned-write proof or trigger cleanup over the external choice."
        )
        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .terminalFailure
        )
        XCTAssertEqual(operations.writtenDeviceIDs, [2])

        lease.release(generation: 1)
        XCTAssertEqual(operations.writtenDeviceIDs, [2])
    }

    func testReleaseDoesNotRestoreAfterQueuedExternalRoundTripToTarget() {
        let operations = DefaultInputLeaseOperationsFake()
        operations.deliversNotificationsAsynchronously = true
        let lease = makeLease(operations)
        XCTAssertTrue(lease.acquire(generation: 1))

        operations.externalSelect(deviceID: 3)
        operations.externalSelect(deviceID: 2)
        lease.release(generation: 1)

        XCTAssertEqual(
            operations.currentUID,
            BlackHoleDefaultInputLease.canonicalDeviceUID,
            "The final BlackHole choice is external/user-owned."
        )
        XCTAssertEqual(
            operations.writtenDeviceIDs,
            [2],
            "Release must not overwrite a post-proof notification even when readback returned to the target UID."
        )
    }

    func testFailedAcquireRestoreDoesNotOverwriteQueuedExternalRoundTrip() {
        let operations = DefaultInputLeaseOperationsFake()
        operations.emitsNotifications = false
        operations.deliversNotificationsAsynchronously = true
        operations.onResolveDeviceID = {
            [weak operations] uid in
            guard uid == "BuiltInMic_UID" else {
                return
            }
            operations?.externalSelect(deviceID: 3)
            operations?.externalSelect(deviceID: 2)
        }
        let lease = makeLease(
            operations,
            proofTimeout: 0.01
        )

        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .terminalFailure
        )
        XCTAssertEqual(
            operations.currentUID,
            BlackHoleDefaultInputLease.canonicalDeviceUID,
            "The failed-acquire cleanup must not restore over queued contention."
        )
        XCTAssertEqual(operations.writtenDeviceIDs, [2])
        lease.release(generation: 1)
        XCTAssertEqual(operations.writtenDeviceIDs, [2])
    }

    func testExternalChoiceBetweenRetryableAttemptsTerminalizesGeneration() {
        let operations = DefaultInputLeaseOperationsFake()
        operations.listenerRegistrationFailuresRemaining = 1
        let lease = makeLease(operations)

        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .retryableFailure
        )
        operations.externalSelect(deviceID: 3)

        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .terminalFailure
        )
        XCTAssertEqual(operations.currentUID, "USBMic_UID")
        XCTAssertTrue(operations.writtenDeviceIDs.isEmpty)
    }

    func testTargetResolutionFailureIsRetryableOnlyWithStableBaseline() {
        let operations = DefaultInputLeaseOperationsFake()
        operations.targetResolutionFailuresRemaining = 1
        let lease = makeLease(operations)

        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .retryableFailure
        )
        XCTAssertTrue(operations.writtenDeviceIDs.isEmpty)
        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .acquired
        )
    }

    func testInitialReadFailureRetriesOnlyThroughFreshFencedBaseline() {
        let operations = DefaultInputLeaseOperationsFake()
        operations.currentReadFailuresRemaining = 1
        let lease = makeLease(operations)

        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .retryableFailure
        )
        XCTAssertEqual(
            operations.currentUID,
            "BuiltInMic_UID"
        )
        XCTAssertTrue(operations.writtenDeviceIDs.isEmpty)

        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .acquired
        )
        XCTAssertEqual(
            operations.currentUID,
            BlackHoleDefaultInputLease.canonicalDeviceUID
        )
        XCTAssertEqual(operations.writtenDeviceIDs, [2])
    }

    func testFailedWriteWithoutMutationIsProvablyRetryable() {
        let operations = DefaultInputLeaseOperationsFake()
        operations.defaultInputWriteFailuresRemaining = 1
        let lease = makeLease(operations)

        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .retryableFailure
        )
        XCTAssertEqual(
            operations.currentUID,
            "BuiltInMic_UID"
        )
        XCTAssertTrue(operations.writtenDeviceIDs.isEmpty)

        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .acquired
        )
        XCTAssertEqual(
            operations.currentUID,
            BlackHoleDefaultInputLease.canonicalDeviceUID
        )
        XCTAssertEqual(operations.writtenDeviceIDs, [2])
    }

    func testExternalChoiceIsNotOverwrittenOrRestored() {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(operations)
        XCTAssertTrue(lease.acquire(generation: 1))

        operations.externalSelect(deviceID: 3)
        lease.drainForTesting()
        XCTAssertEqual(
            operations.currentUID,
            "USBMic_UID"
        )

        lease.release(generation: 1)
        XCTAssertEqual(operations.currentUID, "USBMic_UID")
        let writesBeforeRejectedReacquire =
            operations.writtenDeviceIDs
        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .terminalFailure
        )
        XCTAssertEqual(operations.currentUID, "USBMic_UID")
        XCTAssertEqual(
            operations.writtenDeviceIDs,
            writesBeforeRejectedReacquire,
            "A relinquished generation must not issue another default-input write."
        )
    }

    func testStaleGenerationCannotRestoreOverReplacement() {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(operations)
        XCTAssertTrue(lease.acquire(generation: 1))
        XCTAssertTrue(lease.acquire(generation: 2))

        lease.release(generation: 1)
        XCTAssertEqual(
            operations.currentUID,
            BlackHoleDefaultInputLease.canonicalDeviceUID
        )

        lease.release(generation: 2)
        XCTAssertEqual(operations.currentUID, "BuiltInMic_UID")
    }


    func testReleaseRetriesRestoreWithoutLosingCapturedBaseline() {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(
            operations,
            proofTimeout: 0.01
        )
        XCTAssertTrue(lease.acquire(generation: 1))
        operations.writeFailuresByDeviceID[1] = 1

        XCTAssertEqual(
            lease.release(generation: 1),
            .released
        )

        XCTAssertEqual(operations.currentUID, "BuiltInMic_UID")
        XCTAssertEqual(operations.writtenDeviceIDs, [2, 1])
        XCTAssertEqual(
            operations.events.filter { $0 == "write:1" }.count,
            2,
            "A rejected restoration write must retry under the same captured baseline."
        )
        XCTAssertTrue(operations.removedExactRegistration)
    }

    func testExhaustedRestoreBudgetRetainsOwnershipForReconnectRetry() {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(
            operations,
            proofTimeout: 0.01
        )
        XCTAssertTrue(lease.acquire(generation: 1))
        operations.writeFailuresByDeviceID[1] = 3

        XCTAssertEqual(
            lease.release(generation: 1),
            .retryableFailure
        )

        XCTAssertEqual(
            operations.currentUID,
            BlackHoleDefaultInputLease.canonicalDeviceUID
        )
        XCTAssertEqual(operations.writtenDeviceIDs, [2])
        XCTAssertFalse(
            operations.removedExactRegistration,
            "Retryable restoration exhaustion must retain the listener and baseline."
        )

        XCTAssertEqual(
            lease.acquisitionResult(generation: 2),
            .acquired
        )

        XCTAssertEqual(
            operations.writtenDeviceIDs,
            [2, 1, 2],
            "The replacement generation must first restore the retained baseline, then acquire BlackHole."
        )
        XCTAssertEqual(
            lease.release(generation: 2),
            .released
        )
        XCTAssertEqual(operations.currentUID, "BuiltInMic_UID")
    }

    func testTransientReleaseReadAndResolutionFailuresRetrySafely() {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(operations)
        XCTAssertTrue(lease.acquire(generation: 1))
        operations.currentReadFailuresRemaining = 1
        operations.restoreResolutionFailuresRemaining = 1

        lease.release(generation: 1)

        XCTAssertEqual(operations.currentUID, "BuiltInMic_UID")
        XCTAssertEqual(operations.writtenDeviceIDs, [2, 1])
        XCTAssertTrue(operations.removedExactRegistration)
    }

    func testTransientListenerRemovalFailureIsRetried() {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(operations)
        XCTAssertTrue(lease.acquire(generation: 1))
        operations.listenerRemovalFailuresRemaining = 1

        lease.release(generation: 1)

        XCTAssertEqual(operations.currentUID, "BuiltInMic_UID")
        XCTAssertTrue(operations.removedExactRegistration)
        XCTAssertEqual(
            operations.events.filter {
                $0 == "remove-failed" || $0 == "remove"
            }.count,
            2
        )
    }

    func testRemovalExhaustionRetainsExactIdentityBlocksNewWorkAndRetriesDeregistrationOnly()
    {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(
            operations,
            proofTimeout: 0.01
        )
        XCTAssertTrue(lease.acquire(generation: 1))
        XCTAssertEqual(
            operations.listenerRegistrationCount,
            1
        )

        operations.listenerRemovalFailuresRemaining = 6
        XCTAssertEqual(
            lease.release(generation: 1),
            .retryableFailure
        )

        XCTAssertEqual(
            operations.currentUID,
            "BuiltInMic_UID",
            "Route restoration succeeds before listener removal is retried."
        )
        XCTAssertEqual(
            operations.writtenDeviceIDs,
            [2, 1]
        )
        XCTAssertEqual(
            operations.removalListenerIdentifiers.count,
            3
        )
        XCTAssertEqual(
            Set(operations.removalListenerIdentifiers).count,
            1
        )
        XCTAssertEqual(
            Set(operations.removalQueueIdentifiers).count,
            1
        )

        XCTAssertEqual(
            lease.acquisitionResult(generation: 2),
            .retryableFailure,
            "A replacement generation must not register or write while old deregistration remains pending."
        )
        XCTAssertEqual(
            operations.listenerRegistrationCount,
            1
        )
        XCTAssertEqual(
            operations.writtenDeviceIDs,
            [2, 1]
        )
        XCTAssertEqual(
            operations.removalListenerIdentifiers.count,
            6
        )
        XCTAssertEqual(
            Set(operations.removalListenerIdentifiers).count,
            1,
            "A later bounded invocation must still reuse the exact listener object."
        )

        operations.externalSelect(deviceID: 3)
        lease.drainForTesting()

        XCTAssertEqual(
            lease.release(generation: 1),
            .released
        )
        XCTAssertEqual(
            operations.currentUID,
            "USBMic_UID",
            "Once route restoration succeeded, later cleanup retries must deregister only and preserve a newer user choice."
        )
        XCTAssertEqual(
            operations.writtenDeviceIDs,
            [2, 1],
            "Pending listener cleanup must never repeat route restoration."
        )
        XCTAssertEqual(
            operations.listenerRegistrationCount,
            1
        )
        XCTAssertEqual(
            operations.removalListenerIdentifiers.count,
            7
        )
        XCTAssertEqual(
            Set(operations.removalListenerIdentifiers).count,
            1
        )
        XCTAssertEqual(
            Set(operations.removalQueueIdentifiers).count,
            1
        )
        XCTAssertTrue(operations.removedExactRegistration)
    }

    func testExternallySupersededOutcomeSurvivesPendingDeregistrationUntilShutdown()
    {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(operations)
        XCTAssertTrue(lease.acquire(generation: 1))

        operations.listenerRemovalFailuresRemaining = 3
        operations.externalSelect(deviceID: 3)
        lease.drainForTesting()

        XCTAssertEqual(operations.currentUID, "USBMic_UID")
        XCTAssertEqual(operations.writtenDeviceIDs, [2])
        XCTAssertEqual(
            operations.removalListenerIdentifiers.count,
            3
        )
        XCTAssertEqual(
            Set(operations.removalListenerIdentifiers).count,
            1
        )

        XCTAssertEqual(
            lease.shutdown(),
            .externallySuperseded,
            "The externally-superseded semantic must survive until exact listener removal completes."
        )
        XCTAssertEqual(operations.currentUID, "USBMic_UID")
        XCTAssertEqual(
            operations.writtenDeviceIDs,
            [2],
            "Shutdown must not restore over the newer external input."
        )
        XCTAssertEqual(
            operations.removalListenerIdentifiers.count,
            4
        )
        XCTAssertEqual(
            Set(operations.removalListenerIdentifiers).count,
            1
        )
        XCTAssertEqual(
            Set(operations.removalQueueIdentifiers).count,
            1
        )
        XCTAssertTrue(operations.removedExactRegistration)
    }

    func testBlackHoleRemovalAndReappearanceRequireFreshGeneration() {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(operations)
        XCTAssertTrue(lease.acquire(generation: 7))

        operations.removeDevice(deviceID: 2)
        operations.externalSelect(deviceID: 1)
        lease.drainForTesting()
        XCTAssertEqual(
            lease.release(generation: 7),
            .released
        )

        operations.installDevice(
            deviceID: 2,
            uid: BlackHoleDefaultInputLease.canonicalDeviceUID
        )
        XCTAssertEqual(
            lease.acquisitionResult(generation: 7),
            .terminalFailure
        )
        XCTAssertEqual(
            lease.acquisitionResult(generation: 8),
            .acquired
        )
        XCTAssertEqual(
            operations.currentUID,
            BlackHoleDefaultInputLease.canonicalDeviceUID
        )
        XCTAssertEqual(
            operations.writtenDeviceIDs,
            [2, 2]
        )

        XCTAssertEqual(
            lease.release(generation: 8),
            .released
        )
        XCTAssertEqual(operations.currentUID, "BuiltInMic_UID")
    }

    func testUserChoiceDuringBlackHoleRemovalTerminalizesGeneration() {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(operations)
        XCTAssertTrue(lease.acquire(generation: 7))

        operations.removeDevice(deviceID: 2)
        operations.externalSelect(deviceID: 3)
        lease.drainForTesting()
        lease.release(generation: 7)
        operations.installDevice(
            deviceID: 2,
            uid: BlackHoleDefaultInputLease.canonicalDeviceUID
        )

        XCTAssertEqual(
            lease.acquisitionResult(generation: 7),
            .terminalFailure
        )
        XCTAssertEqual(operations.currentUID, "USBMic_UID")
        XCTAssertEqual(operations.writtenDeviceIDs, [2])
    }

    func testPreWriteExternalChoiceSurvivesCompareAndSetFence() {
        let operations = DefaultInputLeaseOperationsFake()
        var injected = false
        operations.onBeforeDefaultInputCompareAndWrite = {
            [weak operations] deviceID, _ in
            guard deviceID == 2, !injected else {
                return
            }
            injected = true
            operations?.externalSelect(deviceID: 3)
        }
        let lease = makeLease(operations)

        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .terminalFailure
        )
        XCTAssertEqual(operations.currentUID, "USBMic_UID")
        XCTAssertTrue(
            operations.writtenDeviceIDs.isEmpty,
            "The input-only compare fence must reject the mutation after a newer user choice."
        )
        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .terminalFailure
        )
        XCTAssertTrue(operations.writtenDeviceIDs.isEmpty)
    }

    func testOlderGenerationCannotReacquireAfterReplacementRetirement() {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(operations)
        XCTAssertTrue(lease.acquire(generation: 1))
        lease.release(generation: 1)
        XCTAssertTrue(lease.acquire(generation: 2))
        lease.release(generation: 2)
        let writesBeforeStaleAttempt =
            operations.writtenDeviceIDs

        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .terminalFailure
        )
        XCTAssertEqual(
            operations.writtenDeviceIDs,
            writesBeforeStaleAttempt
        )
        XCTAssertEqual(
            lease.debugHighestGenerationForTesting,
            2
        )
    }

    func testGenerationBookkeepingIsBoundedAcrossRetirementStress() {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(operations)

        for generation in UInt64(1)...UInt64(512) {
            operations.listenerRegistrationFailuresRemaining = 1
            XCTAssertEqual(
                lease.acquisitionResult(
                    generation: generation
                ),
                .retryableFailure
            )
            XCTAssertLessThanOrEqual(
                lease.debugBookkeepingEntryCountForTesting,
                1
            )
            lease.release(generation: generation)
            XCTAssertEqual(
                lease.debugBookkeepingEntryCountForTesting,
                0
            )
        }

        XCTAssertEqual(
            lease.debugHighestGenerationForTesting,
            512
        )
        let writesBeforeStaleAttempt =
            operations.writtenDeviceIDs
        XCTAssertEqual(
            lease.acquisitionResult(generation: 511),
            .terminalFailure
        )
        XCTAssertEqual(
            operations.writtenDeviceIDs,
            writesBeforeStaleAttempt
        )
    }

    func testShutdownRetainsOwnershipWhenRestoreBudgetIsExhausted() {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(
            operations,
            proofTimeout: 0.01
        )
        XCTAssertTrue(lease.acquire(generation: 1))
        operations.writeFailuresByDeviceID[1] = 3

        XCTAssertEqual(
            lease.shutdown(),
            .retryableFailure
        )
        XCTAssertEqual(
            operations.currentUID,
            BlackHoleDefaultInputLease.canonicalDeviceUID
        )
        XCTAssertFalse(operations.removedExactRegistration)

        XCTAssertEqual(
            lease.shutdown(),
            .released
        )
        XCTAssertEqual(operations.currentUID, "BuiltInMic_UID")
        XCTAssertTrue(operations.removedExactRegistration)
    }

    func testDeinitRedrivesRetainedRestoreAfterExplicitShutdownExhaustion()
    {
        let operations = DefaultInputLeaseOperationsFake()
        let cleanupRetainer =
            BlackHoleDefaultInputLeaseDeferredCleanupRetainer()
        var lease: BlackHoleDefaultInputLease? = makeLease(
            operations,
            proofTimeout: 0.01,
            deferredCleanupRetainer:
                cleanupRetainer
        )
        XCTAssertTrue(lease!.acquire(generation: 1))
        operations.writeFailuresByDeviceID[1] = 3

        XCTAssertEqual(
            lease!.shutdown(),
            .retryableFailure
        )
        XCTAssertEqual(
            operations.currentUID,
            BlackHoleDefaultInputLease.canonicalDeviceUID
        )
        XCTAssertFalse(operations.removedExactRegistration)

        lease = nil

        XCTAssertEqual(
            operations.listenerRemovalCompleted.wait(
                timeout: .now() + .seconds(1)
            ),
            .success
        )
        XCTAssertEqual(
            operations.currentUID,
            "BuiltInMic_UID",
            "Deferred deinitialization cleanup must redrive the retained restoration baseline after the exhausted explicit shutdown episode."
        )
        XCTAssertEqual(
            operations.writtenDeviceIDs,
            [2, 1]
        )
        XCTAssertTrue(operations.removedExactRegistration)
        XCTAssertEqual(
            cleanupRetainer.retainedJobCount,
            0
        )
    }

    func testLastReferenceReleasedOnListenerQueueReturnsAndEventuallyCleansExactRegistration()
    {
        let operations = DefaultInputLeaseOperationsFake()
        let cleanupRetainer =
            BlackHoleDefaultInputLeaseDeferredCleanupRetainer()
        let strongBox = BlackHoleLeaseStrongBox()
        let weakBox = BlackHoleWeakLeaseBox()
        let callbackReturned =
            DispatchSemaphore(value: 0)

        do {
            let lease = makeLease(
                operations,
                deferredCleanupRetainer:
                    cleanupRetainer
            )
            XCTAssertTrue(lease.acquire(generation: 1))
            strongBox.store(lease)
            weakBox.lease = lease
        }

        operations.onListenerQueueBeforeCallback = {
            strongBox.clear()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            operations.externalSelect(deviceID: 3)
            callbackReturned.signal()
        }

        XCTAssertEqual(
            callbackReturned.wait(
                timeout: .now() + .seconds(1)
            ),
            .success,
            "Dropping the final lease reference inside the listener callback must not wait synchronously back on listenerQueue."
        )
        XCTAssertNil(weakBox.lease)

        XCTAssertEqual(
            operations.listenerRemovalCompleted.wait(
                timeout: .now() + .seconds(1)
            ),
            .success,
            "The externally retained cleanup owner must run after callback return and remove the exact registration."
        )
        XCTAssertEqual(
            cleanupRetainer.retainedJobCount,
            0
        )
        XCTAssertTrue(
            operations.removedExactRegistration
        )
        XCTAssertEqual(
            operations.currentUID,
            "USBMic_UID",
            "Deferred cleanup must preserve the newer user selection."
        )
    }

    func testExternalChoiceDuringRestoreTerminalizesWithoutOverwrite() {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(operations)
        XCTAssertTrue(lease.acquire(generation: 1))
        var injected = false
        operations.onBeforeDefaultInputCompareAndWrite = {
            [weak operations] deviceID, _ in
            guard deviceID == 1, !injected else {
                return
            }
            injected = true
            operations?.externalSelect(deviceID: 3)
        }

        XCTAssertEqual(
            lease.release(generation: 1),
            .externallySuperseded
        )
        XCTAssertEqual(operations.currentUID, "USBMic_UID")
        XCTAssertEqual(
            operations.writtenDeviceIDs,
            [2],
            "Restoration must not overwrite the newer external input."
        )
        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .terminalFailure
        )
    }

    private func makeLease(
        _ operations: DefaultInputLeaseOperationsFake,
        proofTimeout: TimeInterval = 0.1,
        deferredCleanupRetainer:
            any BlackHoleDefaultInputLeaseDeferredCleanupRetaining =
                BlackHoleDefaultInputLeaseDeferredCleanupRetainer()
    ) -> BlackHoleDefaultInputLease {
        BlackHoleDefaultInputLease(
            operations: operations,
            operationQueue: DispatchQueue(
                label: "test.BlackHoleDefaultInputLease.operations"
            ),
            listenerQueue: DispatchQueue(
                label: "test.BlackHoleDefaultInputLease.listener"
            ),
            proofTimeout: proofTimeout,
            deferredCleanupRetainer:
                deferredCleanupRetainer
        )
    }
}

private final class DefaultInputLeaseOperationsFake:
    BlackHoleDefaultInputLeaseOperations,
    @unchecked Sendable
{
    private struct Listener:
        @unchecked Sendable
    {
        var address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let registration:
            CoreAudioPropertyListenerRegistration
    }

    private let lock = NSLock()
    private var uids: [AudioDeviceID: String] = [
        1: "BuiltInMic_UID",
        2: "BlackHole2ch_UID",
        3: "USBMic_UID",
    ]
    private var currentDeviceID: AudioDeviceID = 1
    private var listener: Listener?
    private var eventStorage: [String] = []
    private var writes: [AudioDeviceID] = []
    private var exactInputAddress = false
    private var exactRemoval = false
    private var registrationCountStorage = 0
    private var removalListenerIdentifiersStorage:
        [ObjectIdentifier] = []
    private var removalQueueIdentifiersStorage:
        [ObjectIdentifier] = []
    private var onListenerQueueBeforeCallbackStorage:
        (@Sendable () -> Void)?
    let listenerRemovalCompleted =
        DispatchSemaphore(value: 0)
    var emitsNotifications = true
    var deliversNotificationsAsynchronously = false
    var listenerRegistrationFailuresRemaining = 0
    var listenerRemovalFailuresRemaining = 0
    var currentReadFailuresRemaining = 0
    var targetResolutionFailuresRemaining = 0
    var restoreResolutionFailuresRemaining = 0
    var defaultInputWriteFailuresRemaining = 0
    var writeFailuresByDeviceID: [AudioDeviceID: Int] = [:]
    var onListenerRegistered: (() -> Void)?
    var onResolveDeviceID: ((String) -> Void)?
    var onBeforeDefaultInputCompareAndWrite:
        ((AudioDeviceID, String) -> Void)?
    var onDefaultInputWritten: ((AudioDeviceID) -> Void)?

    var onListenerQueueBeforeCallback:
        (@Sendable () -> Void)? {
        get {
            lock.withLock {
                onListenerQueueBeforeCallbackStorage
            }
        }
        set {
            lock.withLock {
                onListenerQueueBeforeCallbackStorage =
                    newValue
            }
        }
    }

    var currentUID: String {
        lock.withLock { uids[currentDeviceID]! }
    }

    var events: [String] {
        lock.withLock { eventStorage }
    }

    var writtenDeviceIDs: [AudioDeviceID] {
        lock.withLock { writes }
    }

    var registeredExactInputAddress: Bool {
        lock.withLock { exactInputAddress }
    }

    var removedExactRegistration: Bool {
        lock.withLock { exactRemoval }
    }

    var listenerRegistrationCount: Int {
        lock.withLock { registrationCountStorage }
    }

    var removalListenerIdentifiers:
        [ObjectIdentifier] {
        lock.withLock {
            removalListenerIdentifiersStorage
        }
    }

    var removalQueueIdentifiers:
        [ObjectIdentifier] {
        lock.withLock {
            removalQueueIdentifiersStorage
        }
    }

    func addDefaultInputListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener registration:
            CoreAudioPropertyListenerRegistration
    ) -> OSStatus {
        let status: OSStatus = lock.withLock {
            if listenerRegistrationFailuresRemaining > 0 {
                listenerRegistrationFailuresRemaining -= 1
                eventStorage.append("register-failed")
                return OSStatus(-1)
            }
            eventStorage.append("register")
            registrationCountStorage += 1
            exactInputAddress =
                address.mSelector
                    == kAudioHardwarePropertyDefaultInputDevice
                && address.mScope
                    == kAudioObjectPropertyScopeGlobal
                && address.mElement
                    == kAudioObjectPropertyElementMain
            listener = Listener(
                address: address,
                queue: queue,
                registration: registration
            )
            return noErr
        }
        if status == noErr {
            onListenerRegistered?()
        }
        return status
    }

    func removeDefaultInputListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener registration:
            CoreAudioPropertyListenerRegistration
    ) -> OSStatus {
        let result: (OSStatus, Bool) =
            lock.withLock {
                removalListenerIdentifiersStorage
                    .append(
                        ObjectIdentifier(registration)
                    )
                removalQueueIdentifiersStorage
                    .append(
                        ObjectIdentifier(queue)
                    )

                if listenerRemovalFailuresRemaining
                        > 0 {
                    listenerRemovalFailuresRemaining -= 1
                    eventStorage.append("remove-failed")
                    return (OSStatus(-1), false)
                }

                eventStorage.append("remove")
                guard let listener else {
                    return (noErr, false)
                }
                exactRemoval =
                    listener.address.mSelector
                        == address.mSelector
                    && listener.address.mScope
                        == address.mScope
                    && listener.address.mElement
                        == address.mElement
                    && listener.queue === queue
                    && listener.registration
                        === registration
                self.listener = nil
                return (noErr, exactRemoval)
            }

        if result.1 {
            listenerRemovalCompleted.signal()
        }
        return result.0
    }

    func currentDefaultInputUID() throws -> String {
        try lock.withLock {
            eventStorage.append("read")
            if currentReadFailuresRemaining > 0 {
                currentReadFailuresRemaining -= 1
                throw BlackHoleDefaultInputFakeError
                    .injectedReadFailure
            }
            return uids[currentDeviceID]!
        }
    }

    func resolveDeviceID(uid: String) throws -> AudioDeviceID {
        let deviceID = try lock.withLock {
            eventStorage.append("resolve:\(uid)")
            if uid
                    == BlackHoleDefaultInputLease
                        .canonicalDeviceUID,
               targetResolutionFailuresRemaining > 0 {
                targetResolutionFailuresRemaining -= 1
                throw BlackHoleDefaultInputFakeError
                    .injectedResolutionFailure
            }
            if uid == "BuiltInMic_UID",
               restoreResolutionFailuresRemaining > 0 {
                restoreResolutionFailuresRemaining -= 1
                throw BlackHoleDefaultInputFakeError
                    .injectedResolutionFailure
            }
            guard let entry = uids.first(where: {
                $0.value == uid
            }) else {
                throw BlackHoleDefaultInputFakeError.missingUID
            }
            return entry.key
        }
        onResolveDeviceID?(uid)
        return deviceID
    }

    func compareAndSetDefaultInputDevice(
        _ deviceID: AudioDeviceID,
        expectedCurrentUID: String
    ) -> BlackHoleDefaultInputMutationResult {
        onBeforeDefaultInputCompareAndWrite?(
            deviceID,
            expectedCurrentUID
        )
        let result: (
            mutation: BlackHoleDefaultInputMutationResult,
            callback: Listener?
        ) = lock.withLock {
            eventStorage.append("write:\(deviceID)")
            guard uids[currentDeviceID]
                    == expectedCurrentUID else {
                return (.currentInputMismatch, nil)
            }
            if defaultInputWriteFailuresRemaining > 0 {
                defaultInputWriteFailuresRemaining -= 1
                return (.written(OSStatus(-1)), nil)
            }
            if let remaining =
                    writeFailuresByDeviceID[deviceID],
               remaining > 0 {
                writeFailuresByDeviceID[deviceID] =
                    remaining - 1
                return (.written(OSStatus(-1)), nil)
            }
            guard uids[deviceID] != nil else {
                return (.written(OSStatus(-1)), nil)
            }
            currentDeviceID = deviceID
            writes.append(deviceID)
            return (
                .written(noErr),
                emitsNotifications ? listener : nil
            )
        }
        guard result.mutation == .written(noErr) else {
            return result.mutation
        }
        emit(result.callback)
        onDefaultInputWritten?(deviceID)
        return result.mutation
    }

    func externalSelect(deviceID: AudioDeviceID) {
        let callback: Listener? = lock.withLock {
            guard uids[deviceID] != nil else {
                return nil
            }
            currentDeviceID = deviceID
            return listener
        }
        emit(callback)
    }

    func removeDevice(deviceID: AudioDeviceID) {
        _ = lock.withLock {
            uids.removeValue(forKey: deviceID)
        }
    }

    func installDevice(
        deviceID: AudioDeviceID,
        uid: String
    ) {
        lock.withLock {
            uids[deviceID] = uid
        }
    }

    private func emit(_ listener: Listener?) {
        guard let listener else { return }
        let beforeCallback = lock.withLock {
            onListenerQueueBeforeCallbackStorage
        }
        let callback: @Sendable () -> Void = {
            beforeCallback?()
            var address = listener.address
            withUnsafePointer(to: &address) {
                listener.registration.block(1, $0)
            }
        }
        if deliversNotificationsAsynchronously {
            listener.queue.async(execute: callback)
        } else {
            listener.queue.sync(execute: callback)
        }
    }

}

private enum BlackHoleDefaultInputFakeError: Error {
    case missingUID
    case injectedReadFailure
    case injectedResolutionFailure
}

private final class BlackHoleMonitorOperationsFake:
    BlackHoleDeviceAvailabilityMonitoringOperations,
    @unchecked Sendable
{
    enum LookupResult {
        case uid(String)
        case unavailable
        case configurationFailure
        case failure
    }

    private struct ListenerRecord {
        var address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let registration:
            CoreAudioPropertyListenerRegistration
    }

    private let lock = NSLock()
    private var lookupResults: [LookupResult]
    private var eventsStorage: [String] = []
    private var activeListener: ListenerRecord?
    private var activeListeners: [ObjectIdentifier: ListenerRecord] = [:]
    private var activeListenerOrder: [ObjectIdentifier] = []
    private var registeredListeners: [ListenerRecord] = []
    private var retiredListeners: [ListenerRecord] = []
    private var registeredExactAddress = false
    private var removedExact = false
    private var registrationCountStorage = 0
    private var removalListenerIdentifiersStorage:
        [ObjectIdentifier] = []
    private var removalQueueIdentifiersStorage:
        [ObjectIdentifier] = []
    var listenerRemovalFailuresRemaining = 0

    init(lookupResults: [LookupResult]) {
        self.lookupResults = lookupResults
    }

    var events: [String] {
        lock.withLock { eventsStorage }
    }

    var registeredExactDevicesAddress: Bool {
        lock.withLock { registeredExactAddress }
    }

    var removedExactRegistration: Bool {
        lock.withLock { removedExact }
    }

    var listenerRegistrationCount: Int {
        lock.withLock { registrationCountStorage }
    }

    var removalListenerIdentifiers:
        [ObjectIdentifier] {
        lock.withLock {
            removalListenerIdentifiersStorage
        }
    }

    var removalQueueIdentifiers:
        [ObjectIdentifier] {
        lock.withLock {
            removalQueueIdentifiersStorage
        }
    }

    var defaultDeviceWriteCount: Int {
        0
    }

    func addDevicesListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener registration:
            CoreAudioPropertyListenerRegistration
    ) -> OSStatus {
        lock.withLock {
            eventsStorage.append("register")
            registrationCountStorage += 1
            registeredExactAddress =
                address.mSelector == kAudioHardwarePropertyDevices
                && address.mScope
                    == kAudioObjectPropertyScopeGlobal
                && address.mElement
                    == kAudioObjectPropertyElementMain
            let record = ListenerRecord(
                address: address,
                queue: queue,
                registration: registration
            )
            let id = ObjectIdentifier(registration)
            activeListeners[id] = record
            activeListenerOrder.append(id)
            registeredListeners.append(record)
            activeListener = record
        }
        return noErr
    }

    func removeDevicesListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener registration:
            CoreAudioPropertyListenerRegistration
    ) -> OSStatus {
        lock.withLock {
            removalListenerIdentifiersStorage.append(
                ObjectIdentifier(registration)
            )
            removalQueueIdentifiersStorage.append(
                ObjectIdentifier(queue)
            )

            if listenerRemovalFailuresRemaining > 0 {
                listenerRemovalFailuresRemaining -= 1
                eventsStorage.append("remove-failed")
                return OSStatus(-1)
            }

            eventsStorage.append("remove")
            let id = ObjectIdentifier(registration)
            guard let exact = activeListeners[id] else {
                return noErr
            }
            removedExact =
                Self.addressesEqual(
                    address,
                    exact.address
                )
                && queue === exact.queue
                && exact.registration === registration
            activeListeners.removeValue(forKey: id)
            activeListenerOrder.removeAll { $0 == id }
            retiredListeners.append(exact)
            if let current = activeListener,
               current.registration === registration {
                activeListener = activeListenerOrder.reversed()
                    .compactMap { activeListeners[$0] }
                    .first
            }
            return noErr
        }
    }

    func resolveBlackHole2ChannelDeviceUID() throws -> String {
        try lock.withLock {
            eventsStorage.append("inventory")
            guard !lookupResults.isEmpty else {
                throw BlackHoleMonitorLookupError.injected
            }
            switch lookupResults.removeFirst() {
            case .uid(let uid):
                return uid
            case .unavailable:
                throw CaptureError.audioDeviceNotFound(
                    "injected factual absence"
                )
            case .configurationFailure:
                throw CaptureError.audioDeviceConfiguration(
                    "injected strict inventory property read",
                    OSStatus(-66_301)
                )
            case .failure:
                throw BlackHoleMonitorLookupError.injected
            }
        }
    }

    func emitCurrentListener() {
        let listener = lock.withLock { activeListener }
        emit(listener)
    }

    func emitRegisteredListener(at index: Int) {
        let listener: ListenerRecord? = lock.withLock {
            guard registeredListeners.indices.contains(index) else {
                return nil
            }
            return registeredListeners[index]
        }
        emit(listener)
    }

    func emitRetiredListener(at index: Int) {
        let listener: ListenerRecord? = lock.withLock {
            guard retiredListeners.indices.contains(index) else {
                return nil
            }
            return retiredListeners[index]
        }
        emit(listener)
    }

    private func emit(_ listener: ListenerRecord?) {
        guard let listener else { return }
        listener.queue.sync {
            var address = listener.address
            withUnsafePointer(to: &address) {
                listener.registration.block(1, $0)
            }
        }
    }

    private static func addressesEqual(
        _ lhs: AudioObjectPropertyAddress,
        _ rhs: AudioObjectPropertyAddress
    ) -> Bool {
        lhs.mSelector == rhs.mSelector
            && lhs.mScope == rhs.mScope
            && lhs.mElement == rhs.mElement
    }
}

private enum BlackHoleMonitorLookupError: Error {
    case injected
}

private final class BlackHoleSnapshotLedger:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage:
        [BlackHoleDeviceAvailabilitySnapshot] = []

    func append(
        _ snapshot: BlackHoleDeviceAvailabilitySnapshot
    ) {
        lock.withLock {
            storage.append(snapshot)
        }
    }

    var snapshots: [BlackHoleDeviceAvailabilitySnapshot] {
        lock.withLock { storage }
    }
}

private final class BlackHoleAvailabilityMonitorStrongBox:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: BlackHoleDeviceAvailabilityMonitor?

    func store(_ monitor: BlackHoleDeviceAvailabilityMonitor) {
        lock.withLock {
            storage = monitor
        }
    }

    func clear() {
        lock.withLock {
            storage = nil
        }
    }
}

private final class LockedEpochSource: @unchecked Sendable {
    private let lock = NSLock()
    private var epochs: [UUID]

    init(_ epochs: [UUID]) {
        self.epochs = epochs
    }

    func next() -> UUID {
        lock.withLock {
            guard !epochs.isEmpty else {
                return UUID()
            }
            return epochs.removeFirst()
        }
    }
}

private final class BlackHoleDeferredCleanupRetrySchedulerFake:
    BlackHoleDeferredCleanupRetryScheduling,
    @unchecked Sendable
{
    private struct ScheduledWork {
        let delay: TimeInterval
        let work: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var actions: [ScheduledWork] = []
    private var allDelays: [TimeInterval] = []

    func schedule(
        after delay: TimeInterval,
        work: @escaping @Sendable () -> Void
    ) {
        lock.withLock {
            allDelays.append(delay)
            actions.append(
                ScheduledWork(
                    delay: delay,
                    work: work
                )
            )
        }
    }

    var scheduledCount: Int {
        lock.withLock {
            actions.count
        }
    }

    var scheduledDelays: [TimeInterval] {
        lock.withLock {
            allDelays
        }
    }

    func runNext() {
        let action: ScheduledWork? =
            lock.withLock {
                guard !actions.isEmpty else {
                    return nil
                }
                return actions.removeFirst()
            }
        action?.work()
    }
}

private final class BlockingCleanupAttemptProbe:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    let entered = DispatchSemaphore(value: 0)
    private var attempts = 0
    private var concurrentAttempts = 0
    private var maximumConcurrentAttempts = 0

    func attempt() -> Bool {
        lock.withLock {
            attempts += 1
            concurrentAttempts += 1
            maximumConcurrentAttempts = max(
                maximumConcurrentAttempts,
                concurrentAttempts
            )
        }
        entered.signal()
        releaseGate.wait()
        lock.withLock {
            concurrentAttempts -= 1
        }
        return false
    }

    func release() {
        releaseGate.signal()
    }

    var attemptCount: Int {
        lock.withLock {
            attempts
        }
    }

    var maximumConcurrentAttemptCount: Int {
        lock.withLock {
            maximumConcurrentAttempts
        }
    }
}

private final class BlackHoleInventoryRetryScheduler:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var actions:
        [@Sendable () -> Void] = []

    func schedule(
        _ action: @escaping @Sendable () -> Void
    ) {
        lock.withLock {
            actions.append(action)
        }
    }

    var scheduledCount: Int {
        lock.withLock {
            actions.count
        }
    }

    func runNext() {
        let action: (@Sendable () -> Void)? =
            lock.withLock {
                guard !actions.isEmpty else {
                    return nil
                }
                return actions.removeFirst()
            }
        action?()
    }
}

private final class BlackHoleLeaseStrongBox:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: BlackHoleDefaultInputLease?

    func store(
        _ lease: BlackHoleDefaultInputLease
    ) {
        lock.withLock {
            storage = lease
        }
    }

    func clear() {
        lock.withLock {
            storage = nil
        }
    }
}

private final class BlackHoleWeakLeaseBox:
    @unchecked Sendable
{
    private let lock = NSLock()
    private weak var storage:
        BlackHoleDefaultInputLease?

    var lease: BlackHoleDefaultInputLease? {
        get {
            lock.withLock {
                storage
            }
        }
        set {
            lock.withLock {
                storage = newValue
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
#endif
