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
            ledger.snapshots.map {
                $0.defaultInputEndpoint?.deviceUID
            },
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
        XCTAssertNil(
            revalidatedSnapshot.defaultInputEndpoint?.deviceUID
        )
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

    func testPartialSnapshotCannotAssertPairAvailability() {
        let epoch = UUID()
        let snapshot = BlackHoleDeviceAvailabilitySnapshot(
            monitorEpoch: epoch,
            deviceGeneration: 7,
            defaultInputEndpoint: BlackHoleDeviceEndpointIdentity(
                deviceID: AudioDeviceID(kAudioObjectUnknown),
                deviceUID:
                    WorldwideVirtualMicrophoneEndpointContract
                        .visibleDefaultInputDeviceUID
            ),
            hiddenMirrorSinkEndpoint: nil
        )

        XCTAssertFalse(snapshot.isAvailable)
        XCTAssertEqual(
            snapshot.defaultInputEndpoint?.deviceUID,
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
                defaultInputEndpoint: nil,
                hiddenMirrorSinkEndpoint: nil
            )
        )
        monitor.publishForTesting(
            BlackHoleDeviceAvailabilitySnapshot(
                monitorEpoch: UUID(),
                deviceGeneration: 4,
                defaultInputEndpoint: nil,
                hiddenMirrorSinkEndpoint: nil
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
        case WorldwideVirtualMicrophoneEndpointContract
            .visibleDefaultInputDeviceUID:
            return defaultInput
        case WorldwideVirtualMicrophoneEndpointContract
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
            case WorldwideVirtualMicrophoneEndpointContract
                .visibleDefaultInputDeviceUID:
                guard !defaultInputs.isEmpty else {
                    throw BlackHoleMonitorLookupError.injected
                }
                defaultInputReads += 1
                return defaultInputs.removeFirst()
            case WorldwideVirtualMicrophoneEndpointContract
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

#endif
