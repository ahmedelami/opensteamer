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
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
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
                    defaultInputEndpoint:
                        BlackHoleDeviceEndpointIdentity(
                            deviceID: 79,
                            deviceUID: "com.elamin.opensteamer.virtual-microphone.input"
                        ),
                    hiddenMirrorSinkEndpoint:
                        BlackHoleDeviceEndpointIdentity(
                            deviceID: 89,
                            deviceUID: "com.elamin.opensteamer.virtual-microphone.writer"
                        )
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
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
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
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
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
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
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
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
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
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
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
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
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

    func testRawUncertaintyPrecedesHeldRefreshAndSameIDsRequireFreshProof()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
            ]
        )
        let snapshots = BlackHoleSnapshotLedger()
        let uncertainties = BlackHoleUncertaintyLedger()
        let callbackQueue = DispatchQueue(
            label:
                "test.BlackHoleDeviceAvailabilityMonitor.held-refresh.callback"
        )
        let listenerQueue = DispatchQueue(
            label:
                "test.BlackHoleDeviceAvailabilityMonitor.held-refresh.listener"
        )
        let epoch = UUID()
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: callbackQueue,
            makeEpoch: { epoch },
            listenerQueue: listenerQueue
        )

        try monitor.start(
            onUncertain: { observedEpoch, eventSequence in
                uncertainties.append(
                    epoch: observedEpoch,
                    eventSequence: eventSequence
                )
            },
            observer: { snapshots.append($0) }
        )
        XCTAssertEqual(
            snapshots.snapshots.map(\.acceptedInventoryChangeSequence),
            [0]
        )

        let callbackQueueHeld = DispatchSemaphore(value: 0)
        let releaseCallbackQueue = DispatchSemaphore(value: 0)
        callbackQueue.async {
            callbackQueueHeld.signal()
            releaseCallbackQueue.wait()
        }
        XCTAssertEqual(
            callbackQueueHeld.wait(timeout: .now() + .seconds(1)),
            .success
        )

        operations.emitCurrentListener()
        XCTAssertEqual(
            uncertainties.events,
            [
                BlackHoleUncertaintyLedger.Event(
                    epoch: epoch,
                    eventSequence: 1
                ),
            ],
            "Raw uncertainty must be observable before refresh can run on the held callback queue."
        )
        XCTAssertEqual(
            snapshots.snapshots.map(\.deviceGeneration),
            [1],
            "The raw callback must not publish a recycled identity before a complete revalidation."
        )

        releaseCallbackQueue.signal()
        callbackQueue.sync {}
        XCTAssertEqual(
            snapshots.snapshots.map(\.deviceGeneration),
            [1, 2]
        )
        XCTAssertEqual(
            snapshots.snapshots.map(\.acceptedInventoryChangeSequence),
            [0, 1]
        )
        XCTAssertEqual(
            snapshots.snapshots.map {
                $0.defaultInputEndpoint?.deviceID
            },
            [79, 79],
            "An identical opaque AudioDeviceID after a device-list event is a new incarnation, not reusable proof."
        )

        operations.emitCurrentListener()
        callbackQueue.sync {}
        XCTAssertEqual(
            uncertainties.events.map(\.eventSequence),
            [1, 2]
        )
        XCTAssertEqual(
            snapshots.snapshots.map(\.deviceGeneration),
            [1, 2, 3]
        )
        XCTAssertEqual(
            snapshots.snapshots.map(\.acceptedInventoryChangeSequence),
            [0, 1, 2]
        )
        monitor.stop()
    }

    func testRetiredListenerCannotPublishUncertaintyIntoReplacementEpoch()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
            ]
        )
        let uncertainties = BlackHoleUncertaintyLedger()
        let epochs = [UUID(), UUID()]
        let epochSource = LockedEpochSource(epochs)
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label:
                    "test.BlackHoleDeviceAvailabilityMonitor.retired-uncertainty"
            ),
            makeEpoch: { epochSource.next() }
        )

        _ = try monitor.start(
            onUncertain: { epoch, sequence in
                uncertainties.append(
                    epoch: epoch,
                    eventSequence: sequence
                )
            },
            observer: { _ in }
        )
        monitor.stop()
        _ = try monitor.start(
            onUncertain: { epoch, sequence in
                uncertainties.append(
                    epoch: epoch,
                    eventSequence: sequence
                )
            },
            observer: { _ in }
        )

        operations.emitRetiredListener(at: 0)
        XCTAssertEqual(
            uncertainties.events,
            [],
            "A physically retained callback from a deactivated epoch must not close a replacement session's writer gate."
        )
        operations.emitCurrentListener()
        XCTAssertEqual(
            uncertainties.events,
            [
                BlackHoleUncertaintyLedger.Event(
                    epoch: epochs[1],
                    eventSequence: 1
                ),
            ]
        )
        monitor.stop()
    }

    func testLookupFailureAndDeviceReinstallPublishMonotonicGenerations()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
                .unavailable,
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
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
                "com.elamin.opensteamer.virtual-microphone.input",
                nil,
                "com.elamin.opensteamer.virtual-microphone.input",
            ]
        )
        XCTAssertEqual(
            ledger.snapshots.map {
                $0.defaultInputEndpoint?.deviceID
            },
            [79, nil, 79]
        )
        XCTAssertEqual(
            ledger.snapshots.map {
                $0.hiddenMirrorSinkEndpoint?.deviceID
            },
            [89, nil, 89]
        )
        XCTAssertEqual(operations.defaultDeviceWriteCount, 0)
        monitor.stop()
    }

    func testTransientInventoryConfigurationFailurePreservesLastFactualSnapshotAndClearsRetryAfterFactualRead()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
                .configurationFailure,
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
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
            [1, 2],
            "A device-list signal is incarnation evidence even when a retry resolves the same IDs and UIDs."
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
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
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
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
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
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
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

    func testDeviceListSignalAdvancesGenerationForIdenticalEndpointIdentity()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
            ]
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
        operations.emitCurrentListener()

        XCTAssertEqual(ledger.snapshots.count, 2)
        XCTAssertEqual(
            ledger.snapshots.map(\.deviceGeneration),
            [1, 2],
            "A replacement can reuse both its stable UID and opaque numeric AudioDeviceID; the observed inventory event must still mint a new generation."
        )
        XCTAssertEqual(
            operations.events.filter { $0 == "inventory" }.count,
            2
        )
        XCTAssertEqual(operations.defaultDeviceWriteCount, 0)
        monitor.stop()
    }

    func testEitherEndpointIdentityChangeAdvancesGeneration()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .endpointPair(
                    BlackHoleMonitorOperationsFake.endpointPair(
                        defaultInputDeviceID: 79,
                        hiddenMirrorSinkDeviceID: 89
                    )
                ),
                .endpointPair(
                    BlackHoleMonitorOperationsFake.endpointPair(
                        defaultInputDeviceID: 80,
                        hiddenMirrorSinkDeviceID: 89
                    )
                ),
                .endpointPair(
                    BlackHoleMonitorOperationsFake.endpointPair(
                        defaultInputDeviceID: 80,
                        hiddenMirrorSinkDeviceID: 90
                    )
                ),
                .endpointPair(
                    BlackHoleMonitorOperationsFake.endpointPair(
                        defaultInputDeviceID: 80,
                        defaultInputDeviceUID:
                            "com.elamin.opensteamer.virtual-microphone.input-replacement",
                        hiddenMirrorSinkDeviceID: 90
                    )
                ),
                .endpointPair(
                    BlackHoleMonitorOperationsFake.endpointPair(
                        defaultInputDeviceID: 80,
                        defaultInputDeviceUID:
                            "com.elamin.opensteamer.virtual-microphone.input-replacement",
                        hiddenMirrorSinkDeviceID: 90,
                        hiddenMirrorSinkDeviceUID:
                            "com.elamin.opensteamer.virtual-microphone.writer-replacement"
                    )
                ),
            ]
        )
        let ledger = BlackHoleSnapshotLedger()
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label:
                    "test.BlackHoleDeviceAvailabilityMonitor.pair-identity"
            ),
            makeEpoch: { UUID() }
        )

        try monitor.start {
            ledger.append($0)
        }
        for _ in 0..<4 {
            operations.emitCurrentListener()
        }

        XCTAssertEqual(
            ledger.snapshots.map(\.deviceGeneration),
            [1, 2, 3, 4, 5]
        )
        XCTAssertEqual(
            ledger.snapshots.map {
                $0.defaultInputEndpoint?.deviceID
            },
            [79, 80, 80, 80, 80]
        )
        XCTAssertEqual(
            ledger.snapshots.map {
                $0.hiddenMirrorSinkEndpoint?.deviceID
            },
            [89, 89, 90, 90, 90]
        )
        XCTAssertEqual(
            ledger.snapshots.last?
                .defaultInputEndpoint?.deviceUID,
            "com.elamin.opensteamer.virtual-microphone.input-replacement"
        )
        XCTAssertEqual(
            ledger.snapshots.last?
                .hiddenMirrorSinkEndpoint?.deviceUID,
            "com.elamin.opensteamer.virtual-microphone.writer-replacement"
        )
        monitor.stop()
    }

    func testListenerSequenceRejectsInventoryReadOverlappedByDeviceChange()
        throws {
        let initialPair =
            BlackHoleMonitorOperationsFake.endpointPair(
                defaultInputDeviceID: 79,
                hiddenMirrorSinkDeviceID: 89
            )
        let overlappedPair =
            BlackHoleMonitorOperationsFake.endpointPair(
                defaultInputDeviceID: 80,
                hiddenMirrorSinkDeviceID: 90
            )
        let stableReplacementPair =
            BlackHoleMonitorOperationsFake.endpointPair(
                defaultInputDeviceID: 81,
                hiddenMirrorSinkDeviceID: 91
            )
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .endpointPair(initialPair),
                .endpointPair(overlappedPair),
                .endpointPair(stableReplacementPair),
            ]
        )
        let retryScheduler = BlackHoleInventoryRetryScheduler()
        let ledger = BlackHoleSnapshotLedger()
        let callbackQueue = DispatchQueue(
            label:
                "test.BlackHoleDeviceAvailabilityMonitor.listener-fence.callback"
        )
        let listenerQueue = DispatchQueue(
            label:
                "test.BlackHoleDeviceAvailabilityMonitor.listener-fence.listener"
        )
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: callbackQueue,
            makeEpoch: { UUID() },
            scheduleInventoryRetry: { work in
                retryScheduler.schedule(work)
            },
            listenerQueue: listenerQueue
        )

        try monitor.start {
            ledger.append($0)
        }
        operations
            .emitCurrentListenerDuringNextInventoryResolution()

        XCTAssertEqual(
            monitor.revalidateCurrentSnapshot(),
            .validationFailed,
            "An observed device-list change during inventory must fail the synchronous validation closed."
        )

        let current = monitor.currentSnapshot()
        XCTAssertEqual(
            ledger.snapshots.map {
                $0.defaultInputEndpoint?.deviceID
            },
            [79, 81],
            "The overlapped pair must never be published as a factual generation."
        )
        XCTAssertEqual(
            ledger.snapshots.map {
                $0.hiddenMirrorSinkEndpoint?.deviceID
            },
            [89, 91]
        )
        XCTAssertEqual(current, ledger.snapshots.last)
        XCTAssertEqual(
            operations.events.filter { $0 == "inventory" }.count,
            3
        )

        retryScheduler.runNext()
        _ = monitor.currentSnapshot()
        XCTAssertEqual(
            operations.events.filter { $0 == "inventory" }.count,
            3,
            "The callback refresh must invalidate the retry token created by the overlapped read."
        )
        monitor.stop()
    }

    func testSynchronousRevalidationDetectsHiddenLivenessFailureWithoutDeviceNotification()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .endpointProperties(
                    defaultInput:
                        makeDefaultInputEndpointProperties(),
                    hiddenMirrorSink:
                        makeHiddenMirrorSinkEndpointProperties()
                ),
                .endpointProperties(
                    defaultInput:
                        makeDefaultInputEndpointProperties(),
                    hiddenMirrorSink:
                        makeHiddenMirrorSinkEndpointProperties(
                            isAlive: false
                        )
                ),
            ]
        )
        let ledger = BlackHoleSnapshotLedger()
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label:
                    "test.BlackHoleDeviceAvailabilityMonitor.revalidate-hidden-liveness"
            ),
            makeEpoch: { UUID() }
        )

        try monitor.start {
            ledger.append($0)
        }
        let revalidated = monitor.revalidateCurrentSnapshot()
        guard case .validated(let revalidatedSnapshot) = revalidated else {
            XCTFail("Expected a factual unavailable revalidation snapshot.")
            monitor.stop()
            return
        }

        XCTAssertEqual(
            ledger.snapshots.map(\.deviceGeneration),
            [1, 2]
        )
        XCTAssertFalse(revalidatedSnapshot.isAvailable)
        XCTAssertNil(revalidatedSnapshot.defaultInputEndpoint)
        XCTAssertNil(revalidatedSnapshot.hiddenMirrorSinkEndpoint)
        XCTAssertEqual(revalidatedSnapshot, ledger.snapshots.last)
        XCTAssertEqual(
            operations.events.filter { $0 == "inventory" }.count,
            2,
            "The second inventory read is explicit revalidation, not a listener callback."
        )
        monitor.stop()
    }

    func testSynchronousRevalidationDetectsHiddenTopologyFailureWithoutDeviceNotification()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .endpointProperties(
                    defaultInput:
                        makeDefaultInputEndpointProperties(),
                    hiddenMirrorSink:
                        makeHiddenMirrorSinkEndpointProperties()
                ),
                .endpointProperties(
                    defaultInput:
                        makeDefaultInputEndpointProperties(),
                    hiddenMirrorSink:
                        makeHiddenMirrorSinkEndpointProperties(
                            nominalSampleRate: 44_100
                        )
                ),
            ]
        )
        let ledger = BlackHoleSnapshotLedger()
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label:
                    "test.BlackHoleDeviceAvailabilityMonitor.revalidate-hidden-topology"
            ),
            makeEpoch: { UUID() }
        )

        try monitor.start {
            ledger.append($0)
        }
        let revalidated = monitor.revalidateCurrentSnapshot()
        guard case .validated(let revalidatedSnapshot) = revalidated else {
            XCTFail("Expected a factual unavailable revalidation snapshot.")
            monitor.stop()
            return
        }

        XCTAssertEqual(
            ledger.snapshots.map(\.deviceGeneration),
            [1, 2]
        )
        XCTAssertFalse(revalidatedSnapshot.isAvailable)
        XCTAssertNil(revalidatedSnapshot.deviceUID)
        XCTAssertEqual(revalidatedSnapshot, ledger.snapshots.last)
        XCTAssertEqual(
            operations.events.filter { $0 == "inventory" }.count,
            2
        )
        monitor.stop()
    }

    func testSynchronousRevalidationDetectsHiddenIdentityReplacementWithoutDeviceNotification()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .endpointProperties(
                    defaultInput:
                        makeDefaultInputEndpointProperties(),
                    hiddenMirrorSink:
                        makeHiddenMirrorSinkEndpointProperties(
                            deviceID: 89
                        )
                ),
                .endpointProperties(
                    defaultInput:
                        makeDefaultInputEndpointProperties(),
                    hiddenMirrorSink:
                        makeHiddenMirrorSinkEndpointProperties(
                            deviceID: 90
                        )
                ),
            ]
        )
        let ledger = BlackHoleSnapshotLedger()
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label:
                    "test.BlackHoleDeviceAvailabilityMonitor.revalidate-hidden-identity"
            ),
            makeEpoch: { UUID() }
        )

        try monitor.start {
            ledger.append($0)
        }
        let revalidated = monitor.revalidateCurrentSnapshot()
        guard case .validated(let revalidatedSnapshot) = revalidated else {
            XCTFail("Expected a factual endpoint replacement snapshot.")
            monitor.stop()
            return
        }

        XCTAssertEqual(
            ledger.snapshots.map(\.deviceGeneration),
            [1, 2]
        )
        XCTAssertTrue(revalidatedSnapshot.isAvailable)
        XCTAssertEqual(
            revalidatedSnapshot.defaultInputEndpoint?.deviceID,
            79
        )
        XCTAssertEqual(
            revalidatedSnapshot.hiddenMirrorSinkEndpoint?.deviceID,
            90
        )
        XCTAssertEqual(revalidatedSnapshot, ledger.snapshots.last)
        XCTAssertEqual(
            operations.events.filter { $0 == "inventory" }.count,
            2
        )
        monitor.stop()
    }

    func testSynchronousRevalidationReportsTransientFailureInsteadOfReturningStaleAvailability()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .endpointProperties(
                    defaultInput:
                        makeDefaultInputEndpointProperties(),
                    hiddenMirrorSink:
                        makeHiddenMirrorSinkEndpointProperties()
                ),
                .configurationFailure,
            ]
        )
        let retryScheduler = BlackHoleInventoryRetryScheduler()
        let ledger = BlackHoleSnapshotLedger()
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label:
                    "test.BlackHoleDeviceAvailabilityMonitor.revalidate-transient-failure"
            ),
            makeEpoch: { UUID() },
            scheduleInventoryRetry: { work in
                retryScheduler.schedule(work)
            }
        )

        try monitor.start {
            ledger.append($0)
        }

        XCTAssertEqual(
            monitor.revalidateCurrentSnapshot(),
            .validationFailed
        )
        XCTAssertEqual(ledger.snapshots.count, 1)
        XCTAssertTrue(monitor.currentSnapshot()?.isAvailable == true)
        XCTAssertEqual(retryScheduler.scheduledCount, 1)
        monitor.stop()
    }

    func testCompatibilitySnapshotCannotAssertPairAvailability() {
        let epoch = UUID()
        let snapshot = BlackHoleDeviceAvailabilitySnapshot(
            monitorEpoch: epoch,
            deviceGeneration: 7,
            isAvailable: true,
            deviceUID:
                WorldwideVirtualMicrophoneEndpointContract
                    .visibleDefaultInputDeviceUID
        )

        XCTAssertFalse(snapshot.isAvailable)
        XCTAssertEqual(
            snapshot.deviceUID,
            WorldwideVirtualMicrophoneEndpointContract
                .visibleDefaultInputDeviceUID
        )
        XCTAssertEqual(
            snapshot.defaultInputEndpoint,
            BlackHoleDeviceEndpointIdentity(
                deviceID: AudioDeviceID(kAudioObjectUnknown),
                deviceUID:
                    WorldwideVirtualMicrophoneEndpointContract
                        .visibleDefaultInputDeviceUID
            )
        )
        XCTAssertNil(snapshot.hiddenMirrorSinkEndpoint)
    }

    func testEndpointPairResolverAcceptsExactTopology()
        throws {
        let defaultInput = makeDefaultInputEndpointProperties()
        let hiddenMirrorSink =
            makeHiddenMirrorSinkEndpointProperties()
        let resolver = BlackHoleDeviceEndpointPairResolver(
            propertyReader:
                BlackHoleEndpointPropertyReaderFake(
                    defaultInput: defaultInput,
                    hiddenMirrorSink: hiddenMirrorSink
                )
        )

        XCTAssertEqual(
            try resolver.resolveValidatedPair(),
            BlackHoleDeviceEndpointPair(
                defaultInputEndpoint: defaultInput.identity,
                hiddenMirrorSinkEndpoint:
                    hiddenMirrorSink.identity
            )
        )
    }

    func testEndpointPairResolverRejectsTornPairUntilTwoConsecutivePassesMatch()
        throws {
        let firstVisible =
            makeDefaultInputEndpointProperties(
                deviceID: 79
            )
        let replacementVisible =
            makeDefaultInputEndpointProperties(
                deviceID: 80
            )
        let replacementHidden =
            makeHiddenMirrorSinkEndpointProperties(
                deviceID: 90
            )
        let reader =
            SequencedBlackHoleEndpointPropertyReaderFake(
                defaultInputs: [
                    firstVisible,
                    replacementVisible,
                    replacementVisible,
                    replacementVisible,
                ],
                hiddenMirrorSinks: Array(
                    repeating: replacementHidden,
                    count: 4
                )
            )
        let resolver = BlackHoleDeviceEndpointPairResolver(
            propertyReader: reader
        )

        XCTAssertThrowsError(
            try resolver.resolveValidatedPair()
        ) { error in
            guard let captureError = error as? CaptureError,
                  case .audioRouteUnhealthy = captureError else {
                return XCTFail(
                    "A torn consecutive pair produced \(error)"
                )
            }
        }
        XCTAssertEqual(
            try resolver.resolveValidatedPair(),
            BlackHoleDeviceEndpointPair(
                defaultInputEndpoint:
                    replacementVisible.identity,
                hiddenMirrorSinkEndpoint:
                    replacementHidden.identity
            ),
            "Only two consecutive identical full-pair reads may be admitted."
        )
        XCTAssertEqual(reader.defaultInputReadCount, 4)
        XCTAssertEqual(reader.hiddenMirrorSinkReadCount, 4)
    }

    func testEndpointPairResolverRejectsRoleStreamFormatChangeAcrossObservations()
        throws {
        let firstVisible = makeDefaultInputEndpointProperties()
        let changedVisible = makeDefaultInputEndpointProperties(
            roleStreams: [
                makeCanonicalRoleStream(
                    streamID: 179,
                    physicalFormat: makeCanonicalStreamFormat(
                        sampleRate: 48_000.5
                    )
                ),
            ]
        )
        let hidden = makeHiddenMirrorSinkEndpointProperties()
        let reader = SequencedBlackHoleEndpointPropertyReaderFake(
            defaultInputs: [firstVisible, changedVisible],
            hiddenMirrorSinks: [hidden, hidden]
        )
        let resolver = BlackHoleDeviceEndpointPairResolver(
            propertyReader: reader
        )

        XCTAssertThrowsError(
            try resolver.resolveValidatedPair()
        ) { error in
            guard let captureError = error as? CaptureError,
                  case .audioRouteUnhealthy = captureError else {
                return XCTFail(
                    "A torn role-stream format produced \(error)"
                )
            }
        }
        XCTAssertEqual(reader.defaultInputReadCount, 2)
        XCTAssertEqual(reader.hiddenMirrorSinkReadCount, 2)
    }

    func testEndpointPairResolverRejectsDistinctInvalidObservationsWithSameGenericReason()
        throws {
        let validVisible =
            makeDefaultInputEndpointProperties()
        let validHidden =
            makeHiddenMirrorSinkEndpointProperties()
        let reader =
            SequencedBlackHoleEndpointPropertyReaderFake(
                defaultInputs: [
                    makeDefaultInputEndpointProperties(
                        isAlive: false
                    ),
                    validVisible,
                    validVisible,
                    validVisible,
                ],
                hiddenMirrorSinks: [
                    validHidden,
                    makeHiddenMirrorSinkEndpointProperties(
                        outputChannelCount: 2
                    ),
                    validHidden,
                    validHidden,
                ]
            )
        let resolver = BlackHoleDeviceEndpointPairResolver(
            propertyReader: reader
        )

        XCTAssertThrowsError(
            try resolver.resolveValidatedPair()
        ) { error in
            guard let captureError = error as? CaptureError,
                  case .audioRouteUnhealthy = captureError else {
                return XCTFail(
                    "Distinct invalid observations produced \(error)"
                )
            }
        }
        XCTAssertEqual(
            try resolver.resolveValidatedPair(),
            BlackHoleDeviceEndpointPair(
                defaultInputEndpoint: validVisible.identity,
                hiddenMirrorSinkEndpoint: validHidden.identity
            ),
            "Only identical full raw observations may proceed to topology validation."
        )
        XCTAssertEqual(reader.defaultInputReadCount, 4)
        XCTAssertEqual(reader.hiddenMirrorSinkReadCount, 4)
    }

    func testEndpointPairResolverRejectsEveryInvalidTopology()
        throws {
        struct Scenario {
            let name: String
            let defaultInput:
                BlackHoleDeviceEndpointProperties?
            let hiddenMirrorSink:
                BlackHoleDeviceEndpointProperties?
        }

        let scenarios = [
            Scenario(
                name: "missing visible endpoint",
                defaultInput: nil,
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "missing hidden mirror",
                defaultInput:
                    makeDefaultInputEndpointProperties(),
                hiddenMirrorSink: nil
            ),
            Scenario(
                name: "same device identity",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        deviceID: 79
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties(
                        deviceID: 79
                    )
            ),
            Scenario(
                name: "wrong visible UID",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        deviceUID: "wrong-visible"
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "wrong hidden UID",
                defaultInput:
                    makeDefaultInputEndpointProperties(),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties(
                        deviceUID: "wrong-hidden"
                    )
            ),
            Scenario(
                name: "wrong visible model",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        modelUID: "wrong-model"
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "wrong hidden model",
                defaultInput:
                    makeDefaultInputEndpointProperties(),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties(
                        modelUID: "wrong-model"
                    )
            ),
            Scenario(
                name: "visible endpoint dead",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        isAlive: false
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "hidden endpoint dead",
                defaultInput:
                    makeDefaultInputEndpointProperties(),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties(
                        isAlive: false
                    )
            ),
            Scenario(
                name: "visible endpoint hidden",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        isHidden: true
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "mirror endpoint visible",
                defaultInput:
                    makeDefaultInputEndpointProperties(),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties(
                        isHidden: false
                    )
            ),
            Scenario(
                name: "visible input channels",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        inputChannelCount: 2
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "visible output channels",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        outputChannelCount: 1
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "mirror input channels",
                defaultInput:
                    makeDefaultInputEndpointProperties(),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties(
                        inputChannelCount: 1
                    )
            ),
            Scenario(
                name: "mirror output channels",
                defaultInput:
                    makeDefaultInputEndpointProperties(),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties(
                        outputChannelCount: 2
                    )
            ),
            Scenario(
                name: "visible sample rate",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        nominalSampleRate: 44_100
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "mirror sample rate",
                defaultInput:
                    makeDefaultInputEndpointProperties(),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties(
                        nominalSampleRate: 44_100
                    )
            ),
            Scenario(
                name: "visible zero clock domain",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        clockDomain: 0
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "hidden zero clock domain",
                defaultInput:
                    makeDefaultInputEndpointProperties(),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties(
                        clockDomain: 0
                    )
            ),
            Scenario(
                name: "visible wrong clock domain",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        clockDomain: 0x1234
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "hidden wrong clock domain",
                defaultInput:
                    makeDefaultInputEndpointProperties(),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties(
                        clockDomain: 0x1234
                    )
            ),
            Scenario(
                name: "role stream format ID",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        roleStreams: [
                            makeCanonicalRoleStream(
                                streamID: 179,
                                virtualFormat:
                                    makeCanonicalStreamFormat(
                                        formatID: 0
                                    )
                            ),
                        ]
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "role stream missing packed flag",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        roleStreams: [
                            makeCanonicalRoleStream(
                                streamID: 179,
                                virtualFormat:
                                    makeCanonicalStreamFormat(
                                        formatFlags:
                                            kAudioFormatFlagIsFloat
                                    )
                            ),
                        ]
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "role stream noninterleaved flag",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        roleStreams: [
                            makeCanonicalRoleStream(
                                streamID: 179,
                                virtualFormat:
                                    makeCanonicalStreamFormat(
                                        formatFlags:
                                            kAudioFormatFlagsNativeFloatPacked
                                            | kAudioFormatFlagIsNonInterleaved
                                    )
                            ),
                        ]
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "role stream fractional sample rate",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        roleStreams: [
                            makeCanonicalRoleStream(
                                streamID: 179,
                                virtualFormat:
                                    makeCanonicalStreamFormat(
                                        sampleRate: 48_000.5
                                    )
                            ),
                        ]
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "role stream channel count",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        roleStreams: [
                            makeCanonicalRoleStream(
                                streamID: 179,
                                virtualFormat:
                                    makeCanonicalStreamFormat(
                                        channelsPerFrame: 2
                                    )
                            ),
                        ]
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "role stream bytes per frame",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        roleStreams: [
                            makeCanonicalRoleStream(
                                streamID: 179,
                                virtualFormat:
                                    makeCanonicalStreamFormat(
                                        bytesPerFrame: 8
                                    )
                            ),
                        ]
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "role stream bytes per packet",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        roleStreams: [
                            makeCanonicalRoleStream(
                                streamID: 179,
                                virtualFormat:
                                    makeCanonicalStreamFormat(
                                        bytesPerPacket: 8
                                    )
                            ),
                        ]
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "role stream frames per packet",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        roleStreams: [
                            makeCanonicalRoleStream(
                                streamID: 179,
                                virtualFormat:
                                    makeCanonicalStreamFormat(
                                        framesPerPacket: 2
                                    )
                            ),
                        ]
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "role stream bits per channel",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        roleStreams: [
                            makeCanonicalRoleStream(
                                streamID: 179,
                                virtualFormat:
                                    makeCanonicalStreamFormat(
                                        bitsPerChannel: 24
                                    )
                            ),
                        ]
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "role stream reserved field",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        roleStreams: [
                            makeCanonicalRoleStream(
                                streamID: 179,
                                virtualFormat:
                                    makeCanonicalStreamFormat(
                                        reserved: 1
                                    )
                            ),
                        ]
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "role stream virtual physical mismatch",
                defaultInput:
                    makeDefaultInputEndpointProperties(),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties(
                        roleStreams: [
                            makeCanonicalRoleStream(
                                streamID: 189,
                                physicalFormat:
                                    makeCanonicalStreamFormat(
                                        sampleRate: 44_100
                                    )
                            ),
                        ]
                    )
            ),
            Scenario(
                name: "extra visible role stream",
                defaultInput:
                    makeDefaultInputEndpointProperties(
                        roleStreams: [
                            makeCanonicalRoleStream(streamID: 179),
                            makeCanonicalRoleStream(streamID: 180),
                        ]
                    ),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties()
            ),
            Scenario(
                name: "missing hidden role stream",
                defaultInput:
                    makeDefaultInputEndpointProperties(),
                hiddenMirrorSink:
                    makeHiddenMirrorSinkEndpointProperties(
                        roleStreams: []
                    )
            ),
        ]

        for scenario in scenarios {
            let resolver = BlackHoleDeviceEndpointPairResolver(
                propertyReader:
                    BlackHoleEndpointPropertyReaderFake(
                        defaultInput: scenario.defaultInput,
                        hiddenMirrorSink:
                            scenario.hiddenMirrorSink
                    )
            )
            XCTAssertThrowsError(
                try resolver.resolveValidatedPair(),
                scenario.name
            ) { error in
                guard let captureError = error as? CaptureError,
                      case .audioDeviceNotFound = captureError else {
                    return XCTFail(
                        "\(scenario.name) produced \(error)"
                    )
                }
            }
        }
    }

    func testNonIncreasingGenerationAndForeignEpochAreRejected()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("com.elamin.opensteamer.virtual-microphone.input"),
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
                defaultInputEndpoint:
                    BlackHoleDeviceEndpointIdentity(
                        deviceID: 79,
                        deviceUID: "com.elamin.opensteamer.virtual-microphone.input"
                    ),
                hiddenMirrorSinkEndpoint:
                    BlackHoleDeviceEndpointIdentity(
                        deviceID: 89,
                        deviceUID: "com.elamin.opensteamer.virtual-microphone.writer"
                    )
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
    func testExactEndpointRejectsSameUIDReplacementBeforeMutation() {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(operations)
        let monitoredEndpoint =
            BlackHoleDeviceEndpointIdentity(
                deviceID: 2,
                deviceUID:
                    BlackHoleDefaultInputLease
                        .canonicalDeviceUID
            )
        operations.replaceDevicePreservingUID(
            oldDeviceID: 2,
            newDeviceID: 22
        )

        XCTAssertEqual(
            lease.acquisitionResult(
                generation: 1,
                targetEndpoint: monitoredEndpoint
            ),
            .terminalFailure
        )
        XCTAssertEqual(
            operations.currentUID,
            "BuiltInMic_UID"
        )
        XCTAssertTrue(
            operations.writtenDeviceIDs.isEmpty
        )
        XCTAssertTrue(
            operations.removedExactRegistration
        )
    }

    func testAlreadySelectedEndpointRejectsSameUIDReplacementAfterFreshTranslation() {
        let operations = DefaultInputLeaseOperationsFake()
        operations.externalSelect(deviceID: 2)
        operations.onResolveDeviceID = {
            [weak operations] uid in
            guard uid
                    == BlackHoleDefaultInputLease
                        .canonicalDeviceUID else {
                return
            }
            operations?.replaceDevicePreservingUID(
                oldDeviceID: 2,
                newDeviceID: 22
            )
        }
        let lease = makeLease(operations)

        XCTAssertEqual(
            lease.acquisitionResult(
                generation: 1,
                targetEndpoint:
                    BlackHoleDeviceEndpointIdentity(
                        deviceID: 2,
                        deviceUID:
                            BlackHoleDefaultInputLease
                                .canonicalDeviceUID
                    )
            ),
            .terminalFailure
        )
        XCTAssertEqual(operations.selectedDeviceID, 22)
        XCTAssertTrue(
            operations.writtenDeviceIDs.isEmpty
        )
    }

    func testOwnedWriteReadbackRejectsSameUIDReplacement() {
        let operations = DefaultInputLeaseOperationsFake()
        operations.onDefaultInputWritten = {
            [weak operations] deviceID in
            guard deviceID == 2 else { return }
            operations?.replaceDevicePreservingUID(
                oldDeviceID: 2,
                newDeviceID: 22
            )
        }
        let lease = makeLease(operations)

        XCTAssertEqual(
            lease.acquisitionResult(
                generation: 1,
                targetEndpoint:
                    BlackHoleDeviceEndpointIdentity(
                        deviceID: 2,
                        deviceUID:
                            BlackHoleDefaultInputLease
                                .canonicalDeviceUID
                    )
            ),
            .terminalFailure
        )
        XCTAssertEqual(operations.selectedDeviceID, 22)
        XCTAssertEqual(operations.writtenDeviceIDs, [2])
    }

    func testHiddenMirrorCanNeverBeSelectedByDefaultInputLease() {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(operations)

        XCTAssertEqual(
            lease.acquisitionResult(
                generation: 1,
                targetUID: "com.elamin.opensteamer.virtual-microphone.writer"
            ),
            .terminalFailure
        )
        XCTAssertEqual(operations.events, [])
        XCTAssertEqual(operations.currentUID, "BuiltInMic_UID")
    }

    func testPreexistingHiddenMirrorDefaultInputFailsClosedWithoutRestorationLease() {
        let operations = DefaultInputLeaseOperationsFake()
        operations.externalSelect(deviceID: 4)
        let lease = makeLease(operations)

        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .terminalFailure
        )
        XCTAssertEqual(operations.currentUID, "com.elamin.opensteamer.virtual-microphone.writer")
        XCTAssertEqual(operations.writtenDeviceIDs, [])
        XCTAssertFalse(operations.events.contains("register"))
        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .terminalFailure
        )
    }

    func testPreexistingRetiredHiddenMirrorDefaultInputFailsClosedWithoutRestorationLease() {
        let operations = DefaultInputLeaseOperationsFake()
        operations.externalSelect(deviceID: 5)
        let lease = makeLease(operations)

        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .terminalFailure
        )
        XCTAssertEqual(
            operations.currentUID,
            WorldwideVirtualMicrophoneEndpointContract
                .retiredLegacyHiddenWriterDeviceUID
        )
        XCTAssertEqual(operations.writtenDeviceIDs, [])
        XCTAssertFalse(operations.events.contains("register"))
        XCTAssertEqual(
            lease.acquisitionResult(generation: 1),
            .terminalFailure
        )
    }

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

    func testExactOwnedWriteSettlesTwoHALNotificationsBeforeReturningAuthorization()
    {
        let operations = DefaultInputLeaseOperationsFake()
        operations.deliversNotificationsAsynchronously = true
        operations.notificationDelaysByWrittenDeviceID[2] = [
            0,
            0.005,
        ]
        operations.notificationDelaysByWrittenDeviceID[1] = [
            0,
            0.005,
        ]
        let recorder = DefaultInputUncertaintyRecorder()
        let lease = makeLease(
            operations,
            proofTimeout: 0.02
        )
        lease.setUncertaintyHandler { event in
            recorder.record(event)
        }
        let endpoint = BlackHoleDeviceEndpointIdentity(
            deviceID: 2,
            deviceUID:
                BlackHoleDefaultInputLease.canonicalDeviceUID
        )

        XCTAssertEqual(
            lease.acquisitionResult(
                generation: 1,
                targetEndpoint: endpoint
            ),
            .acquired
        )
        guard let authorization = lease.authorizationProof(
            generation: 1,
            targetEndpoint: endpoint
        ) else {
            return XCTFail(
                "Expected the settled exact listener authorization"
            )
        }

        XCTAssertEqual(
            authorization.acceptedListenerSequence,
            2
        )
        XCTAssertEqual(recorder.events.count, 2)
        XCTAssertTrue(
            recorder.events.allSatisfy(
                authorization.incorporates
            ),
            "The authorization returned after acquisition must incorporate both raw callbacks so neither can later revoke the reopened writer gate."
        )
        XCTAssertEqual(operations.writtenDeviceIDs, [2])

        XCTAssertEqual(
            lease.release(generation: 1),
            .released
        )
        XCTAssertEqual(operations.currentUID, "BuiltInMic_UID")
        XCTAssertEqual(operations.writtenDeviceIDs, [2, 1])
    }

    func testExactOwnedWriteThirdHALNotificationFailsClosed() {
        let operations = DefaultInputLeaseOperationsFake()
        operations.deliversNotificationsAsynchronously = true
        operations.notificationDelaysByWrittenDeviceID[2] = [
            0,
            0.004,
            0.008,
        ]
        let lease = makeLease(
            operations,
            proofTimeout: 0.02
        )
        let endpoint = BlackHoleDeviceEndpointIdentity(
            deviceID: 2,
            deviceUID:
                BlackHoleDefaultInputLease.canonicalDeviceUID
        )

        XCTAssertEqual(
            lease.acquisitionResult(
                generation: 1,
                targetEndpoint: endpoint
            ),
            .terminalFailure
        )
        XCTAssertNil(
            lease.authorizationProof(
                generation: 1,
                targetEndpoint: endpoint
            )
        )
        XCTAssertEqual(operations.writtenDeviceIDs, [2])
        XCTAssertEqual(
            lease.release(generation: 1),
            .externallySuperseded
        )
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

    func testPostAdmissionExternalHiddenInputSynchronouslyClosesGateAndInvalidatesProof() {
        let operations = DefaultInputLeaseOperationsFake()
        let recorder = DefaultInputUncertaintyRecorder()
        let lease = makeLease(operations)
        lease.setUncertaintyHandler { event in
            recorder.record(event)
        }
        let endpoint = BlackHoleDeviceEndpointIdentity(
            deviceID: 2,
            deviceUID:
                BlackHoleDefaultInputLease.canonicalDeviceUID
        )

        XCTAssertEqual(
            lease.acquisitionResult(
                generation: 1,
                targetEndpoint: endpoint
            ),
            .acquired
        )
        guard let authorization = lease.authorizationProof(
            generation: 1,
            targetEndpoint: endpoint
        ) else {
            return XCTFail("Expected an exact post-acquisition listener proof")
        }
        XCTAssertTrue(
            recorder.events.contains(where: authorization.incorporates),
            "The owned-write callback must be incorporated before admission."
        )

        recorder.reopenGate()
        operations.externalSelect(deviceID: 4)

        XCTAssertFalse(
            recorder.gateIsOpen,
            "The raw external selector callback must synchronously close the writer gate."
        )
        let externalEvent = try? XCTUnwrap(recorder.events.last)
        XCTAssertNotNil(externalEvent)
        if let externalEvent {
            XCTAssertFalse(authorization.incorporates(externalEvent))
        }
        XCTAssertNil(
            lease.authorizationProof(
                generation: 1,
                targetEndpoint: endpoint
            ),
            "A newer exact listener sequence must make the admitted proof unusable."
        )
        XCTAssertEqual(
            lease.release(generation: 1),
            .externallySuperseded
        )
        XCTAssertEqual(operations.currentUID, "com.elamin.opensteamer.virtual-microphone.writer")
        XCTAssertEqual(
            operations.writtenDeviceIDs,
            [2],
            "Release must not restore over the external hidden-endpoint choice."
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
        let operationQueue = DispatchQueue(
            label: "test.BlackHoleDefaultInputLease.callback-deinit.operations"
        )
        let listenerQueue = DispatchQueue(
            label: "test.BlackHoleDefaultInputLease.callback-deinit.listener"
        )
        let callbackReturned =
            DispatchSemaphore(value: 0)

        do {
            let lease = makeLease(
                operations,
                deferredCleanupRetainer: cleanupRetainer,
                operationQueue: operationQueue,
                listenerQueue: listenerQueue
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
        operationQueue.sync {}
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
                BlackHoleDefaultInputLeaseDeferredCleanupRetainer(),
        operationQueue: DispatchQueue = DispatchQueue(
            label: "test.BlackHoleDefaultInputLease.operations"
        ),
        listenerQueue: DispatchQueue = DispatchQueue(
            label: "test.BlackHoleDefaultInputLease.listener"
        )
    ) -> BlackHoleDefaultInputLease {
        BlackHoleDefaultInputLease(
            operations: operations,
            operationQueue: operationQueue,
            listenerQueue: listenerQueue,
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
        2: "com.elamin.opensteamer.virtual-microphone.input",
        3: "USBMic_UID",
        4: "com.elamin.opensteamer.virtual-microphone.writer",
        5: WorldwideVirtualMicrophoneEndpointContract
            .retiredLegacyHiddenWriterDeviceUID,
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
    var notificationDelaysByWrittenDeviceID:
        [AudioDeviceID: [TimeInterval]] = [:]
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

    var selectedDeviceID: AudioDeviceID {
        lock.withLock { currentDeviceID }
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

    func currentDefaultInputDeviceID() throws
        -> AudioDeviceID {
        try lock.withLock {
            eventStorage.append("read-id")
            if currentReadFailuresRemaining > 0 {
                currentReadFailuresRemaining -= 1
                throw BlackHoleDefaultInputFakeError
                    .injectedReadFailure
            }
            guard uids[currentDeviceID] != nil else {
                throw BlackHoleDefaultInputFakeError
                    .missingUID
            }
            return currentDeviceID
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
        if emitsNotifications {
            if let delays =
                    notificationDelaysByWrittenDeviceID[
                        deviceID
                    ] {
                for delay in delays {
                    emit(
                        result.callback,
                        after: delay
                    )
                }
            } else {
                emit(result.callback)
            }
        }
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

    /// Models Core Audio replacing an endpoint while preserving its stable UID.
    /// No default-input notification is emitted because this is an inventory
    /// transition, which is exactly why the lease must also fence on device ID.
    func replaceDevicePreservingUID(
        oldDeviceID: AudioDeviceID,
        newDeviceID: AudioDeviceID
    ) {
        lock.withLock {
            guard let uid = uids.removeValue(
                forKey: oldDeviceID
            ) else {
                return
            }
            uids[newDeviceID] = uid
            if currentDeviceID == oldDeviceID {
                currentDeviceID = newDeviceID
            }
        }
    }

    private func emit(
        _ listener: Listener?,
        after delay: TimeInterval = 0
    ) {
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
        if delay > 0 {
            listener.queue.asyncAfter(
                deadline: .now() + delay,
                execute: callback
            )
        } else if deliversNotificationsAsynchronously {
            listener.queue.async(execute: callback)
        } else {
            listener.queue.sync(execute: callback)
        }
    }

}

private final class DefaultInputUncertaintyRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var gateOpenStorage = false
    private var eventStorage:
        [BlackHoleDefaultInputLeaseUncertaintyEvent] = []

    func record(
        _ event: BlackHoleDefaultInputLeaseUncertaintyEvent
    ) {
        lock.withLock {
            gateOpenStorage = false
            eventStorage.append(event)
        }
    }

    func reopenGate() {
        lock.withLock {
            gateOpenStorage = true
        }
    }

    var gateIsOpen: Bool {
        lock.withLock { gateOpenStorage }
    }

    var events: [BlackHoleDefaultInputLeaseUncertaintyEvent] {
        lock.withLock { eventStorage }
    }
}

private enum BlackHoleDefaultInputFakeError: Error {
    case missingUID
    case injectedReadFailure
    case injectedResolutionFailure
}

private final class BlackHoleEndpointPropertyReaderFake:
    BlackHoleDeviceEndpointPropertyReading,
    @unchecked Sendable
{
    private let defaultInput:
        BlackHoleDeviceEndpointProperties?
    private let hiddenMirrorSink:
        BlackHoleDeviceEndpointProperties?

    init(
        defaultInput: BlackHoleDeviceEndpointProperties?,
        hiddenMirrorSink: BlackHoleDeviceEndpointProperties?
    ) {
        self.defaultInput = defaultInput
        self.hiddenMirrorSink = hiddenMirrorSink
    }

    func endpointProperties(
        exactUID: String
    ) throws -> BlackHoleDeviceEndpointProperties? {
        switch exactUID {
        case WorldwideBlackHoleMicrophoneEndpointContract
            .visibleDefaultInputDeviceUID:
            return defaultInput
        case WorldwideBlackHoleMicrophoneEndpointContract
            .hiddenMirrorSinkDeviceUID:
            return hiddenMirrorSink
        default:
            return nil
        }
    }
}

private final class SequencedBlackHoleEndpointPropertyReaderFake:
    BlackHoleDeviceEndpointPropertyReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var defaultInputs:
        [BlackHoleDeviceEndpointProperties]
    private var hiddenMirrorSinks:
        [BlackHoleDeviceEndpointProperties]
    private var defaultInputReads = 0
    private var hiddenMirrorSinkReads = 0

    init(
        defaultInputs: [BlackHoleDeviceEndpointProperties],
        hiddenMirrorSinks: [BlackHoleDeviceEndpointProperties]
    ) {
        self.defaultInputs = defaultInputs
        self.hiddenMirrorSinks = hiddenMirrorSinks
    }

    func endpointProperties(
        exactUID: String
    ) throws -> BlackHoleDeviceEndpointProperties? {
        try lock.withLock {
            switch exactUID {
            case WorldwideBlackHoleMicrophoneEndpointContract
                .visibleDefaultInputDeviceUID:
                guard !defaultInputs.isEmpty else {
                    throw BlackHoleMonitorLookupError.injected
                }
                defaultInputReads += 1
                return defaultInputs.removeFirst()
            case WorldwideBlackHoleMicrophoneEndpointContract
                .hiddenMirrorSinkDeviceUID:
                guard !hiddenMirrorSinks.isEmpty else {
                    throw BlackHoleMonitorLookupError.injected
                }
                hiddenMirrorSinkReads += 1
                return hiddenMirrorSinks.removeFirst()
            default:
                return nil
            }
        }
    }

    var defaultInputReadCount: Int {
        lock.withLock { defaultInputReads }
    }

    var hiddenMirrorSinkReadCount: Int {
        lock.withLock { hiddenMirrorSinkReads }
    }
}

private func makeDefaultInputEndpointProperties(
    deviceID: AudioDeviceID = 79,
    deviceUID: String =
        WorldwideVirtualMicrophoneEndpointContract
            .visibleDefaultInputDeviceUID,
    modelUID: String =
        WorldwideVirtualMicrophoneEndpointContract.modelUID,
    isAlive: Bool = true,
    isHidden: Bool = false,
    inputChannelCount: UInt32 = 1,
    outputChannelCount: UInt32 = 0,
    nominalSampleRate: Double = 48_000,
    clockDomain: UInt32 =
        WorldwideVirtualMicrophoneEndpointContract.clockDomain,
    roleStreams: [BlackHoleDeviceRoleStreamProperties] = [
        makeCanonicalRoleStream(streamID: 179),
    ]
) -> BlackHoleDeviceEndpointProperties {
    BlackHoleDeviceEndpointProperties(
        identity: BlackHoleDeviceEndpointIdentity(
            deviceID: deviceID,
            deviceUID: deviceUID
        ),
        modelUID: modelUID,
        isAlive: isAlive,
        isHidden: isHidden,
        inputChannelCount: inputChannelCount,
        outputChannelCount: outputChannelCount,
        nominalSampleRate: nominalSampleRate,
        clockDomain: clockDomain,
        roleStreams: roleStreams
    )
}

private func makeHiddenMirrorSinkEndpointProperties(
    deviceID: AudioDeviceID = 89,
    deviceUID: String =
        WorldwideVirtualMicrophoneEndpointContract
            .hiddenMirrorSinkDeviceUID,
    modelUID: String =
        WorldwideVirtualMicrophoneEndpointContract.modelUID,
    isAlive: Bool = true,
    isHidden: Bool = true,
    inputChannelCount: UInt32 = 0,
    outputChannelCount: UInt32 = 1,
    nominalSampleRate: Double = 48_000,
    clockDomain: UInt32 =
        WorldwideVirtualMicrophoneEndpointContract.clockDomain,
    roleStreams: [BlackHoleDeviceRoleStreamProperties] = [
        makeCanonicalRoleStream(streamID: 189),
    ]
) -> BlackHoleDeviceEndpointProperties {
    BlackHoleDeviceEndpointProperties(
        identity: BlackHoleDeviceEndpointIdentity(
            deviceID: deviceID,
            deviceUID: deviceUID
        ),
        modelUID: modelUID,
        isAlive: isAlive,
        isHidden: isHidden,
        inputChannelCount: inputChannelCount,
        outputChannelCount: outputChannelCount,
        nominalSampleRate: nominalSampleRate,
        clockDomain: clockDomain,
        roleStreams: roleStreams
    )
}

private func makeCanonicalRoleStream(
    streamID: AudioStreamID,
    virtualFormat: BlackHoleDeviceStreamFormat =
        makeCanonicalStreamFormat(),
    physicalFormat: BlackHoleDeviceStreamFormat? = nil
) -> BlackHoleDeviceRoleStreamProperties {
    BlackHoleDeviceRoleStreamProperties(
        streamID: streamID,
        virtualFormat: virtualFormat,
        physicalFormat: physicalFormat ?? virtualFormat
    )
}

private func makeCanonicalStreamFormat(
    sampleRate: Double = 48_000,
    formatID: AudioFormatID = kAudioFormatLinearPCM,
    formatFlags: AudioFormatFlags =
        kAudioFormatFlagsNativeFloatPacked,
    bytesPerPacket: UInt32 = 4,
    framesPerPacket: UInt32 = 1,
    bytesPerFrame: UInt32 = 4,
    channelsPerFrame: UInt32 = 1,
    bitsPerChannel: UInt32 = 32,
    reserved: UInt32 = 0
) -> BlackHoleDeviceStreamFormat {
    BlackHoleDeviceStreamFormat(
        sampleRate: sampleRate,
        formatID: formatID,
        formatFlags: formatFlags,
        bytesPerPacket: bytesPerPacket,
        framesPerPacket: framesPerPacket,
        bytesPerFrame: bytesPerFrame,
        channelsPerFrame: channelsPerFrame,
        bitsPerChannel: bitsPerChannel,
        reserved: reserved
    )
}

private final class BlackHoleMonitorOperationsFake:
    BlackHoleDeviceAvailabilityMonitoringOperations,
    @unchecked Sendable
{
    enum LookupResult {
        case uid(String)
        case endpointPair(BlackHoleDeviceEndpointPair)
        case endpointProperties(
            defaultInput: BlackHoleDeviceEndpointProperties?,
            hiddenMirrorSink: BlackHoleDeviceEndpointProperties?
        )
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
    private var emitListenerDuringNextInventoryResolution = false
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

    func resolveBlackHole2ChannelEndpointPair() throws
        -> BlackHoleDeviceEndpointPair {
        let (lookupResult, listenerToEmit):
            (LookupResult, ListenerRecord?) = try lock.withLock {
                eventsStorage.append("inventory")
                guard !lookupResults.isEmpty else {
                    throw BlackHoleMonitorLookupError.injected
                }
                let lookupResult = lookupResults.removeFirst()
                let listenerToEmit =
                    emitListenerDuringNextInventoryResolution
                        ? activeListener
                        : nil
                emitListenerDuringNextInventoryResolution = false
                return (lookupResult, listenerToEmit)
            }

        emit(listenerToEmit)
        switch lookupResult {
        case .uid(let uid):
            return Self.endpointPair(
                defaultInputDeviceID: 79,
                defaultInputDeviceUID: uid,
                hiddenMirrorSinkDeviceID: 89
            )
        case .endpointPair(let endpointPair):
            return endpointPair
        case .endpointProperties(
            let defaultInput,
            let hiddenMirrorSink
        ):
            return try BlackHoleDeviceEndpointPairResolver(
                propertyReader:
                    BlackHoleEndpointPropertyReaderFake(
                        defaultInput: defaultInput,
                        hiddenMirrorSink: hiddenMirrorSink
                    )
            ).resolveValidatedPair()
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

    func emitCurrentListenerDuringNextInventoryResolution() {
        lock.withLock {
            emitListenerDuringNextInventoryResolution = true
        }
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

    static func endpointPair(
        defaultInputDeviceID: AudioDeviceID,
        defaultInputDeviceUID: String = "com.elamin.opensteamer.virtual-microphone.input",
        hiddenMirrorSinkDeviceID: AudioDeviceID,
        hiddenMirrorSinkDeviceUID: String = "com.elamin.opensteamer.virtual-microphone.writer"
    ) -> BlackHoleDeviceEndpointPair {
        BlackHoleDeviceEndpointPair(
            defaultInputEndpoint:
                BlackHoleDeviceEndpointIdentity(
                    deviceID: defaultInputDeviceID,
                    deviceUID: defaultInputDeviceUID
                ),
            hiddenMirrorSinkEndpoint:
                BlackHoleDeviceEndpointIdentity(
                    deviceID: hiddenMirrorSinkDeviceID,
                    deviceUID: hiddenMirrorSinkDeviceUID
                )
        )
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

private final class BlackHoleUncertaintyLedger:
    @unchecked Sendable
{
    struct Event: Equatable {
        let epoch: UUID
        let eventSequence: UInt64
    }

    private let lock = NSLock()
    private var storage: [Event] = []

    func append(
        epoch: UUID,
        eventSequence: UInt64
    ) {
        lock.withLock {
            storage.append(
                Event(
                    epoch: epoch,
                    eventSequence: eventSequence
                )
            )
        }
    }

    var events: [Event] {
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
