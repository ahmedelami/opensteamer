#if os(macOS) && DEBUG
import AudioToolbox
import CaptureCore
import Foundation
import XCTest
@testable import CaptureServer

final class WorldwideIPhoneMicrophoneForwardingDriverTests:
    XCTestCase
{
    func testTransientOutputConstructionFailureRetriesSameGenerationAndBecomesHealthy()
        async {
        let retryGate = DriverSuspensionGate()
        let ready = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(outputs: [])
        let harness = DriverTestHarness(
            factory: factory,
            retryGate: retryGate
        )
        let peer = DriverTestPeer()
        let track = DriverTestTrack()
        let epoch = UUID()

        await prepare(
            harness: harness,
            epoch: epoch,
            peer: peer,
            track: track
        )
        await harness.authorize(
            peer: peer,
            generation: 1
        )

        let availableSnapshot = snapshot(
            epoch: epoch,
            generation: 1,
            available: true
        )
        let drive = Task {
            await harness.updateDevice(availableSnapshot)
        }

        let retryWasScheduled = await eventually {
            guard factory.requestCount == 1 else {
                return false
            }
            return await retryGate.hasEntered()
        }
        XCTAssertTrue(retryWasScheduled)
        XCTAssertEqual(factory.requestCount, 1)
        XCTAssertFalse(track.isEnabled)
        let unavailable = await harness.snapshot()
        XCTAssertEqual(
            unavailable.phase,
            .outputUnavailable
        )
        XCTAssertEqual(
            unavailable.lastFailureCategory,
            .outputUnavailable
        )

        factory.append(ready)
        await retryGate.open()
        await drive.value

        let final = await harness.snapshot()
        XCTAssertEqual(factory.requestCount, 2)
        XCTAssertEqual(
            factory.requestedUIDs,
            [
                "BlackHole2ch_UID",
                "BlackHole2ch_UID",
            ]
        )
        XCTAssertEqual(ready.startCount, 1)
        XCTAssertTrue(track.isEnabled)
        XCTAssertEqual(final.phase, .forwardingHealthy)
        XCTAssertTrue(final.exactTrackAdmitted)
        XCTAssertTrue(final.queueRunning)
        XCTAssertEqual(
            final.currentKey?.deviceGeneration,
            1
        )
    }

    func testTransientStartFailureRetriesSameGenerationAndBecomesHealthy()
        async {
        let retryGate = DriverSuspensionGate()
        let failing = DriverTestOutput(
            startError: DriverTestError.start
        )
        let ready = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(
            outputs: [failing, ready]
        )
        let harness = DriverTestHarness(
            factory: factory,
            retryGate: retryGate
        )
        let peer = DriverTestPeer()
        let track = DriverTestTrack()
        let epoch = UUID()

        await prepare(
            harness: harness,
            epoch: epoch,
            peer: peer,
            track: track
        )
        await harness.authorize(peer: peer, generation: 1)

        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 1,
                available: false
            )
        )
        XCTAssertEqual(factory.requestCount, 0)
        XCTAssertFalse(track.isEnabled)
        let waitingForDevicePhase = await harness.snapshot().phase
        XCTAssertEqual(
            waitingForDevicePhase,
            .waitingForDevice
        )

        let availableSnapshot = snapshot(
            epoch: epoch,
            generation: 2,
            available: true
        )
        let drive = Task {
            await harness.updateDevice(availableSnapshot)
        }
        let retryWasScheduled = await eventually {
            guard failing.startCount == 1 else {
                return false
            }
            return await retryGate.hasEntered()
        }
        XCTAssertTrue(retryWasScheduled)
        XCTAssertEqual(factory.requestCount, 1)
        XCTAssertEqual(failing.stopCount, 1)
        XCTAssertFalse(track.isEnabled)
        let startFailedPhase = await harness.snapshot().phase
        XCTAssertEqual(
            startFailedPhase,
            .startFailed
        )

        await retryGate.open()
        await drive.value
        let final = await harness.snapshot()
        XCTAssertEqual(factory.requestCount, 2)
        XCTAssertEqual(ready.startCount, 1)
        XCTAssertTrue(track.isEnabled)
        XCTAssertEqual(final.phase, .forwardingHealthy)
        XCTAssertTrue(final.exactTrackAdmitted)
        XCTAssertEqual(final.monitorEpoch, epoch)
        XCTAssertEqual(final.deviceGeneration, 2)
        XCTAssertEqual(final.deviceUID, "BlackHole2ch_UID")
        XCTAssertEqual(
            final.currentKey?.deviceGeneration,
            2
        )
        XCTAssertEqual(
            final.currentKey?.transportAuthorizationEpoch,
            1
        )
        XCTAssertEqual(
            factory.requestedUIDs,
            ["BlackHole2ch_UID", "BlackHole2ch_UID"]
        )

        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 2,
                available: true
            )
        )
        XCTAssertEqual(
            factory.requestCount,
            2,
            "A duplicate monitor snapshot must not create another attempt."
        )
    }

    func testStartFailureRetryBudgetIsBoundedPerGeneration()
        async {
        let failures = (0..<3).map { _ in
            DriverTestOutput(startError: DriverTestError.start)
        }
        let ready = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(
            outputs: failures + [ready]
        )
        let harness = DriverTestHarness(factory: factory)
        let peer = DriverTestPeer()
        let track = DriverTestTrack()
        let epoch = UUID()

        await prepare(
            harness: harness,
            epoch: epoch,
            peer: peer,
            track: track
        )
        await harness.authorize(peer: peer, generation: 1)
        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 1,
                available: true
            )
        )
        XCTAssertEqual(factory.requestCount, 3)
        XCTAssertFalse(track.isEnabled)
        let exhaustedPhase = await harness.snapshot().phase
        XCTAssertEqual(
            exhaustedPhase,
            .startFailed
        )

        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 1,
                available: true
            )
        )
        XCTAssertEqual(factory.requestCount, 3)

        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 2,
                available: true
            )
        )
        XCTAssertEqual(factory.requestCount, 4)
        XCTAssertTrue(track.isEnabled)
        let recoveredPhase = await harness.snapshot().phase
        XCTAssertEqual(
            recoveredPhase,
            .forwardingHealthy
        )
    }

    func testDeviceGenerationChangeDuringRetryDelayUsesOnlyLatestKey()
        async {
        let retryGate = DriverSuspensionGate()
        let failing = DriverTestOutput(
            startError: DriverTestError.start
        )
        let replacement = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(
            outputs: [failing, replacement]
        )
        let harness = DriverTestHarness(
            factory: factory,
            retryGate: retryGate
        )
        let peer = DriverTestPeer()
        let track = DriverTestTrack()
        let epoch = UUID()

        await prepare(
            harness: harness,
            epoch: epoch,
            peer: peer,
            track: track
        )
        await harness.authorize(peer: peer, generation: 1)
        let firstSnapshot = snapshot(
            epoch: epoch,
            generation: 1,
            available: true
        )
        let firstDrive = Task {
            await harness.updateDevice(firstSnapshot)
        }
        let retryWasSuspended = await eventually {
            await retryGate.hasEntered()
        }
        XCTAssertTrue(retryWasSuspended)

        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 2,
                available: true
            )
        )
        await retryGate.open()
        await firstDrive.value

        XCTAssertEqual(factory.requestCount, 2)
        XCTAssertEqual(failing.stopCount, 1)
        XCTAssertEqual(replacement.stopCount, 0)
        XCTAssertTrue(track.isEnabled)
        let result = await harness.snapshot()
        XCTAssertEqual(
            result.currentKey?.deviceGeneration,
            2
        )
        XCTAssertEqual(result.phase, .forwardingHealthy)
    }

    func testOutputUnavailableExhaustsBoundedRetriesUntilNewDeviceGeneration()
        async {
        let factory = DriverTestOutputFactory(outputs: [])
        let harness = DriverTestHarness(factory: factory)
        let peer = DriverTestPeer()
        let track = DriverTestTrack()
        let epoch = UUID()

        await prepare(
            harness: harness,
            epoch: epoch,
            peer: peer,
            track: track
        )
        await harness.authorize(peer: peer, generation: 1)
        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 1,
                available: true
            )
        )

        XCTAssertEqual(factory.requestCount, 3)
        XCTAssertEqual(
            factory.requestedUIDs,
            [
                "BlackHole2ch_UID",
                "BlackHole2ch_UID",
                "BlackHole2ch_UID",
            ]
        )
        let outputUnavailablePhase = await harness.snapshot().phase
        XCTAssertEqual(
            outputUnavailablePhase,
            .outputUnavailable
        )
        XCTAssertFalse(track.isEnabled)

        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 1,
                available: true
            )
        )
        XCTAssertEqual(factory.requestCount, 3)

        let ready = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        factory.append(ready)
        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 2,
                available: true
            )
        )

        XCTAssertEqual(factory.requestCount, 4)
        let forwardingHealthyPhase = await harness.snapshot().phase
        XCTAssertEqual(
            forwardingHealthyPhase,
            .forwardingHealthy
        )
        XCTAssertTrue(track.isEnabled)
    }

    func testInitialMonitorSnapshotBeforePeerAndTrackIsRetained()
        async {
        let output = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(outputs: [output])
        let harness = DriverTestHarness(factory: factory)
        let peer = DriverTestPeer()
        let track = DriverTestTrack()
        let epoch = UUID()

        await harness.beginMonitoring(epoch)
        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 1,
                available: true
            )
        )
        XCTAssertEqual(factory.requestCount, 0)

        await harness.replacePeer(peer, generation: 1)
        await harness.installTrack(track)
        await harness.authorize(peer: peer, generation: 1)

        XCTAssertEqual(factory.requestCount, 1)
        XCTAssertTrue(track.isEnabled)
        let result = await harness.snapshot()
        XCTAssertEqual(result.deviceGeneration, 1)
        XCTAssertEqual(result.phase, .forwardingHealthy)
    }

    func testNewDeviceGenerationDuringSuspendedStartRedrivesOnlyLatest()
        async {
        let startGate = DriverSuspensionGate()
        let stale = DriverTestOutput(
            startGate: startGate,
            progressSnapshots: readyProgressSnapshots()
        )
        let replacement = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(
            outputs: [stale, replacement]
        )
        let harness = DriverTestHarness(factory: factory)
        let peer = DriverTestPeer()
        let track = DriverTestTrack()
        let epoch = UUID()

        await prepare(
            harness: harness,
            epoch: epoch,
            peer: peer,
            track: track
        )
        await harness.authorize(peer: peer, generation: 1)

        let firstSnapshot = snapshot(
            epoch: epoch,
            generation: 1,
            available: true
        )
        let firstDrive = Task {
            await harness.updateDevice(firstSnapshot)
        }
        let startWasEntered = await eventually {
            stale.startWasEntered
        }
        XCTAssertTrue(startWasEntered)
        let suspended = await harness.snapshot()
        XCTAssertEqual(
            suspended.lastAttemptedKey?.deviceGeneration,
            1
        )
        XCTAssertNotNil(suspended.currentAttemptID)

        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 2,
                available: true
            )
        )
        await startGate.open()
        await firstDrive.value

        XCTAssertEqual(factory.requestCount, 2)
        XCTAssertGreaterThanOrEqual(stale.stopCount, 1)
        XCTAssertEqual(replacement.startCount, 1)
        XCTAssertTrue(track.isEnabled)
        let currentDeviceGeneration = await harness.snapshot().currentKey?.deviceGeneration
        XCTAssertEqual(
            currentDeviceGeneration,
            2
        )
    }

    func testNewDeviceGenerationDuringSuspendedAdmissionRedrivesLatest()
        async {
        let admissionGate = DriverSuspensionGate()
        let peer = DriverTestPeer(
            admissionGate: admissionGate
        )
        let stale = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let replacement = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(
            outputs: [stale, replacement]
        )
        let harness = DriverTestHarness(factory: factory)
        let track = DriverTestTrack()
        let epoch = UUID()

        await prepare(
            harness: harness,
            epoch: epoch,
            peer: peer,
            track: track
        )
        await harness.authorize(peer: peer, generation: 1)

        let firstSnapshot = snapshot(
            epoch: epoch,
            generation: 1,
            available: true
        )
        let firstDrive = Task {
            await harness.updateDevice(firstSnapshot)
        }
        let admissionWasSuspended = await eventually {
            let gateHasEntered = await admissionGate.hasEntered()
            return peer.admissionCount == 1 && gateHasEntered
        }
        XCTAssertTrue(admissionWasSuspended)

        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 2,
                available: true
            )
        )
        await admissionGate.open()
        await firstDrive.value

        XCTAssertEqual(factory.requestCount, 2)
        XCTAssertGreaterThanOrEqual(stale.stopCount, 1)
        XCTAssertEqual(replacement.stopCount, 0)
        XCTAssertEqual(peer.admissionCount, 2)
        XCTAssertTrue(track.isEnabled)
        let forwardingHealthyPhase = await harness.snapshot().phase
        XCTAssertEqual(
            forwardingHealthyPhase,
            .forwardingHealthy
        )
    }

    func testNewDeviceGenerationDuringSuspendedReadinessRedrivesLatest()
        async {
        let readinessGate = DriverSuspensionGate()
        let stale = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let replacement = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(
            outputs: [stale, replacement]
        )
        let harness = DriverTestHarness(
            factory: factory,
            readinessGate: readinessGate
        )
        let peer = DriverTestPeer()
        let track = DriverTestTrack()
        let epoch = UUID()

        await prepare(
            harness: harness,
            epoch: epoch,
            peer: peer,
            track: track
        )
        await harness.authorize(peer: peer, generation: 1)

        let firstSnapshot = snapshot(
            epoch: epoch,
            generation: 1,
            available: true
        )
        let firstDrive = Task {
            await harness.updateDevice(firstSnapshot)
        }
        let readinessWasSuspended = await eventually {
            await readinessGate.hasEntered()
        }
        XCTAssertTrue(readinessWasSuspended)

        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 2,
                available: true
            )
        )
        await readinessGate.open()
        await firstDrive.value

        XCTAssertEqual(factory.requestCount, 2)
        XCTAssertGreaterThanOrEqual(stale.stopCount, 1)
        XCTAssertEqual(replacement.stopCount, 0)
        XCTAssertTrue(track.isEnabled)
        let currentDeviceGeneration = await harness.snapshot().currentKey?.deviceGeneration
        XCTAssertEqual(
            currentDeviceGeneration,
            2
        )
    }

    func testLatestDeviceWhileTransportUnhealthyIsConsumedByOneFreshAuthorization()
        async {
        let first = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let second = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(
            outputs: [first, second]
        )
        let harness = DriverTestHarness(factory: factory)
        let peer = DriverTestPeer()
        let track = DriverTestTrack()
        let epoch = UUID()

        await prepare(
            harness: harness,
            epoch: epoch,
            peer: peer,
            track: track
        )
        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 1,
                available: true
            )
        )
        XCTAssertEqual(factory.requestCount, 0)
        let waitingForTransportPhase = await harness.snapshot().phase
        XCTAssertEqual(
            waitingForTransportPhase,
            .waitingForTransport
        )

        await harness.authorize(peer: peer, generation: 1)
        XCTAssertEqual(factory.requestCount, 1)
        let firstAuthorizationEpoch = await harness.snapshot().transportAuthorizationEpoch
        XCTAssertEqual(
            firstAuthorizationEpoch,
            1
        )

        await harness.invalidateTransport()
        XCTAssertFalse(track.isEnabled)
        XCTAssertGreaterThanOrEqual(first.stopCount, 1)

        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 2,
                available: true
            )
        )
        XCTAssertEqual(factory.requestCount, 1)

        await harness.authorize(peer: peer, generation: 1)
        XCTAssertEqual(factory.requestCount, 2)
        let secondAuthorizationEpoch = await harness.snapshot().transportAuthorizationEpoch
        XCTAssertEqual(
            secondAuthorizationEpoch,
            2
        )
        XCTAssertTrue(track.isEnabled)

        await harness.authorize(peer: peer, generation: 1)
        XCTAssertEqual(factory.requestCount, 2)
        let duplicateAuthorizationEpoch = await harness.snapshot().transportAuthorizationEpoch
        XCTAssertEqual(
            duplicateAuthorizationEpoch,
            2,
            "Duplicate healthy callbacks must not mint another authorization epoch."
        )
    }

    func testRemovalReinstallAndStaleRuntimeFailureAffectOnlyExactOutput()
        async {
        let first = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let second = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let runtimeReplacement = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(
            outputs: [first, second, runtimeReplacement]
        )
        let harness = DriverTestHarness(factory: factory)
        let peer = DriverTestPeer()
        let track = DriverTestTrack()
        let epoch = UUID()

        await prepare(
            harness: harness,
            epoch: epoch,
            peer: peer,
            track: track
        )
        await harness.authorize(peer: peer, generation: 1)
        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 1,
                available: true
            )
        )
        let originalTrackGeneration =
            await harness.snapshot().trackGeneration
        XCTAssertTrue(track.isEnabled)

        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 2,
                available: false
            )
        )
        let removed = await harness.snapshot()
        XCTAssertFalse(track.isEnabled)
        XCTAssertNil(removed.currentKey)
        XCTAssertEqual(
            removed.trackGeneration,
            originalTrackGeneration,
            "Device disappearance preserves the current remote track generation."
        )
        XCTAssertGreaterThanOrEqual(first.stopCount, 1)

        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 3,
                available: true
            )
        )
        XCTAssertEqual(factory.requestCount, 2)
        XCTAssertTrue(track.isEnabled)
        XCTAssertEqual(second.stopCount, 0)

        let staleRuntimeFailureHandled = await harness.handleRuntimeFailure(
            first,
            category: .runtimeProgressStalled
        )
        XCTAssertFalse(
            staleRuntimeFailureHandled
        )
        XCTAssertTrue(track.isEnabled)
        XCTAssertEqual(second.stopCount, 0)
        let forwardingHealthyPhase = await harness.snapshot().phase
        XCTAssertEqual(
            forwardingHealthyPhase,
            .forwardingHealthy
        )

        let activeRuntimeFailureHandled = await harness.handleRuntimeFailure(second)
        XCTAssertTrue(
            activeRuntimeFailureHandled
        )
        XCTAssertEqual(second.stopCount, 1)
        XCTAssertEqual(factory.requestCount, 3)
        XCTAssertTrue(track.isEnabled)
        XCTAssertEqual(runtimeReplacement.stopCount, 0)
        let recoveredPhase = await harness.snapshot().phase
        XCTAssertEqual(
            recoveredPhase,
            .forwardingHealthy
        )
        let repeatedRuntimeFailureHandled = await harness.handleRuntimeFailure(second)
        XCTAssertFalse(
            repeatedRuntimeFailureHandled
        )
        XCTAssertEqual(second.stopCount, 1)
        XCTAssertTrue(track.isEnabled)
        XCTAssertEqual(runtimeReplacement.stopCount, 0)
    }

    func testProgressStallRuntimeFailureUsesBoundedRetryBudget()
        async {
        let first = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let second = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let third = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(
            outputs: [first, second, third]
        )
        let harness = DriverTestHarness(
            factory: factory,
            maximumAttemptCountPerKey: 3
        )
        let peer = DriverTestPeer()
        let track = DriverTestTrack()
        let epoch = UUID()

        await prepare(
            harness: harness,
            epoch: epoch,
            peer: peer,
            track: track
        )
        await harness.authorize(peer: peer, generation: 1)
        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 1,
                available: true
            )
        )

        XCTAssertEqual(factory.requestCount, 1)
        XCTAssertTrue(track.isEnabled)

        let firstHandled = await harness.handleRuntimeFailure(
            first,
            category: .runtimeProgressStalled
        )
        XCTAssertTrue(firstHandled)
        XCTAssertEqual(factory.requestCount, 2)
        XCTAssertTrue(track.isEnabled)

        let secondHandled = await harness.handleRuntimeFailure(
            second,
            category: .runtimeProgressStalled
        )
        XCTAssertTrue(secondHandled)
        XCTAssertEqual(factory.requestCount, 3)
        XCTAssertTrue(track.isEnabled)

        let thirdHandled = await harness.handleRuntimeFailure(
            third,
            category: .runtimeProgressStalled
        )
        XCTAssertTrue(thirdHandled)
        let terminal = await harness.snapshot()
        XCTAssertEqual(factory.requestCount, 3)
        XCTAssertFalse(track.isEnabled)
        XCTAssertEqual(terminal.phase, .runtimeFailed)
        XCTAssertEqual(
            terminal.lastFailureCategory,
            .runtimeProgressStalled
        )

        let repeated = await harness.handleRuntimeFailure(
            third,
            category: .runtimeProgressStalled
        )
        XCTAssertFalse(repeated)
        XCTAssertEqual(factory.requestCount, 3)
    }

    func testRuntimeFailureTreatsDisposeReturnAsTerminalBeforeReplacementQueueCreation()
        async throws {
        let disposalFailure = OSStatus(-66_701)
        let retainer =
            BlackHoleMicrophoneOutputQueueDisposalRetainer()
        let operations =
            DistinctRuntimeAudioQueueOperations(
                disposeStatuses: [
                    disposalFailure,
                    noErr,
                ]
            )
        let factory =
            RuntimeDisposalOutputFactory(
                operations: operations,
                retainer: retainer
            )
        let harness =
            RuntimeDisposalDriverHarness(
                factory: factory,
                operations: operations
            )
        let peer = DriverTestPeer()
        let track = DriverTestTrack()
        let epoch = UUID()

        await harness.beginMonitoring(epoch)
        await harness.replacePeer(
            peer,
            generation: 1
        )
        await harness.installTrack(track)
        await harness.authorize(
            peer: peer,
            generation: 1
        )
        await harness.updateDevice(
            BlackHoleDeviceAvailabilitySnapshot(
                monitorEpoch: epoch,
                deviceGeneration: 1,
                isAvailable: true,
                deviceUID: "BlackHole2ch_UID"
            )
        )

        let original = try XCTUnwrap(
            factory.output(at: 0)
        )
        XCTAssertEqual(
            operations.createdQueueIdentities.count,
            1
        )

        let runtimeFailureHandled =
            await harness.handleRuntimeFailure(
                original
            )
        XCTAssertTrue(runtimeFailureHandled)

        let queueIdentities =
            operations.createdQueueIdentities
        XCTAssertEqual(
            queueIdentities.count,
            2,
            "Only the original queue and one replacement queue may be created."
        )
        XCTAssertNotEqual(
            queueIdentities[0],
            queueIdentities[1],
            "The integration fake must expose distinct old/new AudioQueue identities."
        )
        XCTAssertEqual(
            retainer.retainedDisposalCount,
            0
        )

        let events = operations.events
        let oldDisposeReturned =
            try XCTUnwrap(
                events.firstIndex(
                    of:
                        "dispose:\(queueIdentities[0]):\(disposalFailure)"
                )
            )
        let replacementCreated =
            try XCTUnwrap(
                events.firstIndex(
                    of:
                        "create:\(queueIdentities[1])"
                )
            )
        XCTAssertLessThan(
            oldDisposeReturned,
            replacementCreated,
            "The old exact queue/context must finish its one terminal AudioQueueDispose call before replacement queue creation."
        )

        let snapshot = await harness.snapshot()
        XCTAssertEqual(
            snapshot.phase,
            .forwardingHealthy
        )
        XCTAssertTrue(track.isEnabled)

        await harness.shutdown()
        XCTAssertEqual(
            operations.activeAllocationCount,
            0
        )
    }

    func testAdmissionFailureDisablesExactTrackAndRetiresOutput()
        async {
        let peer = DriverTestPeer(healthy: false)
        let output = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(outputs: [output])
        let harness = DriverTestHarness(factory: factory)
        let track = DriverTestTrack()
        let epoch = UUID()

        await prepare(
            harness: harness,
            epoch: epoch,
            peer: peer,
            track: track
        )
        await harness.authorize(peer: peer, generation: 1)
        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 1,
                available: true
            )
        )

        XCTAssertFalse(track.isEnabled)
        XCTAssertEqual(output.stopCount, 1)
        let result = await harness.snapshot()
        XCTAssertEqual(result.phase, .admissionFailed)
        XCTAssertEqual(
            result.lastFailureCategory,
            .admissionFailed
        )
    }

    func testAdvancingSilentQueueAwaitsDelayedFirstPCMWithoutRetiringAttempt()
        async {
        let output = DriverTestOutput(
            progressSnapshots: [
                progress(
                    callbacks: 1,
                    requestedFrames: 480,
                    successfulPulls: 0,
                    successfulFrames: 0,
                    silenceFallbacks: 1,
                    silenceFrames: 480
                ),
                progress(
                    callbacks: 2,
                    requestedFrames: 960,
                    successfulPulls: 0,
                    successfulFrames: 0,
                    silenceFallbacks: 2,
                    silenceFrames: 960
                ),
                progress(
                    callbacks: 3,
                    requestedFrames: 1_440,
                    successfulPulls: 1,
                    successfulFrames: 480,
                    silenceFallbacks: 2,
                    silenceFrames: 960
                ),
                progress(
                    callbacks: 4,
                    requestedFrames: 1_920,
                    successfulPulls: 2,
                    successfulFrames: 960,
                    silenceFallbacks: 2,
                    silenceFrames: 960
                ),
            ]
        )
        let factory = DriverTestOutputFactory(outputs: [output])
        let harness = DriverTestHarness(
            factory: factory,
            readinessSampleLimit: 3
        )
        let peer = DriverTestPeer()
        let track = DriverTestTrack()
        let epoch = UUID()

        await prepare(
            harness: harness,
            epoch: epoch,
            peer: peer,
            track: track
        )
        await harness.authorize(peer: peer, generation: 1)
        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 1,
                available: true
            )
        )

        let firstPCM = await harness.snapshot()
        XCTAssertEqual(firstPCM.phase, .forwardingReady)
        XCTAssertNil(firstPCM.lastFailureCategory)
        XCTAssertTrue(track.isEnabled)
        XCTAssertEqual(output.stopCount, 0)
        XCTAssertEqual(factory.requestCount, 1)
        XCTAssertNotNil(firstPCM.currentAttemptID)
        XCTAssertEqual(firstPCM.progress.successfulFrameCount, 480)

        let continuingPCM = await harness.snapshot()
        XCTAssertEqual(
            continuingPCM.currentAttemptID,
            firstPCM.currentAttemptID
        )
        XCTAssertEqual(
            continuingPCM.phase,
            .forwardingHealthy
        )
        XCTAssertEqual(
            continuingPCM.progress.successfulFrameCount,
            960
        )
        XCTAssertEqual(output.stopCount, 0)
    }

    func testDeferredReadyProgressIsFencedToExactAttemptGeneration()
        async {
        let first = DriverTestOutput(
            progressSnapshots: [
                progress(
                    callbacks: 1,
                    requestedFrames: 480,
                    successfulPulls: 0,
                    successfulFrames: 0,
                    silenceFallbacks: 1,
                    silenceFrames: 480
                ),
                progress(
                    callbacks: 2,
                    requestedFrames: 960,
                    successfulPulls: 0,
                    successfulFrames: 0,
                    silenceFallbacks: 2,
                    silenceFrames: 960
                ),
                progress(
                    callbacks: 3,
                    requestedFrames: 1_440,
                    successfulPulls: 1,
                    successfulFrames: 480,
                    silenceFallbacks: 2,
                    silenceFrames: 960
                ),
            ]
        )
        let replacement = DriverTestOutput(
            progressSnapshots: [
                progress(
                    callbacks: 10,
                    requestedFrames: 4_800,
                    successfulPulls: 0,
                    successfulFrames: 0,
                    silenceFallbacks: 10,
                    silenceFrames: 4_800
                ),
                progress(
                    callbacks: 11,
                    requestedFrames: 5_280,
                    successfulPulls: 0,
                    successfulFrames: 0,
                    silenceFallbacks: 11,
                    silenceFrames: 5_280
                ),
                progress(
                    callbacks: 100,
                    requestedFrames: 48_000,
                    successfulPulls: 100,
                    successfulFrames: 48_000,
                    silenceFallbacks: 11,
                    silenceFrames: 5_280
                ),
                progress(
                    callbacks: 101,
                    requestedFrames: 48_480,
                    successfulPulls: 101,
                    successfulFrames: 48_480,
                    silenceFallbacks: 11,
                    silenceFrames: 5_280
                ),
            ]
        )
        let factory = DriverTestOutputFactory(
            outputs: [first, replacement]
        )
        let harness = DriverTestHarness(
            factory: factory,
            readinessSampleLimit: 3
        )
        let peer = DriverTestPeer()
        let track = DriverTestTrack()
        let epoch = UUID()

        await prepare(
            harness: harness,
            epoch: epoch,
            peer: peer,
            track: track
        )
        await harness.authorize(peer: peer, generation: 1)
        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 1,
                available: true
            )
        )

        let staleReady = await harness.snapshot()
        XCTAssertEqual(staleReady.phase, .forwardingReady)
        XCTAssertNotNil(staleReady.currentAttemptID)

        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 2,
                available: true
            )
        )

        let replacementReady = await harness.snapshot()
        XCTAssertEqual(
            replacementReady.phase,
            .forwardingReady,
            "A ready sample retained by the superseded attempt must not make its replacement look healthy."
        )
        XCTAssertNotEqual(
            replacementReady.currentAttemptID,
            staleReady.currentAttemptID
        )
        XCTAssertEqual(
            replacementReady.currentKey?.deviceGeneration,
            2
        )
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(replacement.stopCount, 0)

        let replacementHealthy = await harness.snapshot()
        XCTAssertEqual(
            replacementHealthy.phase,
            .forwardingHealthy
        )
        XCTAssertEqual(
            replacementHealthy.currentAttemptID,
            replacementReady.currentAttemptID
        )
    }

    func testTransientReadinessFailureRetriesSameGeneration()
        async {
        let notReady = DriverTestOutput(
            progressSnapshots: [
                progress(
                    callbacks: 0,
                    requestedFrames: 0,
                    successfulPulls: 0,
                    successfulFrames: 0,
                    silenceFallbacks: 0,
                    silenceFrames: 0
                ),
                progress(
                    callbacks: 0,
                    requestedFrames: 0,
                    successfulPulls: 0,
                    successfulFrames: 0,
                    silenceFallbacks: 0,
                    silenceFrames: 0
                ),
            ]
        )
        let ready = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(
            outputs: [notReady, ready]
        )
        let harness = DriverTestHarness(factory: factory)
        let peer = DriverTestPeer()
        let track = DriverTestTrack()
        let epoch = UUID()

        await prepare(
            harness: harness,
            epoch: epoch,
            peer: peer,
            track: track
        )
        await harness.authorize(peer: peer, generation: 1)
        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 1,
                available: true
            )
        )

        XCTAssertEqual(factory.requestCount, 2)
        XCTAssertEqual(notReady.stopCount, 1)
        XCTAssertEqual(ready.stopCount, 0)
        XCTAssertTrue(track.isEnabled)
        let recoveredPhase = await harness.snapshot().phase
        XCTAssertEqual(
            recoveredPhase,
            .forwardingHealthy
        )
    }

    func testLANCoexistencePolicySuppressesEveryHealthyInput()
        async {
        let output = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(outputs: [output])
        let harness = DriverTestHarness(
            policy: .suppressedForLANCoexistence,
            factory: factory
        )
        let peer = DriverTestPeer()
        let track = DriverTestTrack()
        let epoch = UUID()

        await harness.beginMonitoring(epoch)
        await harness.replacePeer(peer, generation: 1)
        await harness.installTrack(track)
        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 1,
                available: true
            )
        )
        await harness.authorize(peer: peer, generation: 1)

        XCTAssertEqual(factory.requestCount, 0)
        XCTAssertFalse(track.isEnabled)
        let result = await harness.snapshot()
        XCTAssertEqual(
            result.policy,
            .suppressedForLANCoexistence
        )
        XCTAssertEqual(
            result.phase,
            .suppressedForLANCoexistence
        )
        XCTAssertEqual(
            result.transportAuthorizationEpoch,
            0
        )
    }

    private func prepare(
        harness: DriverTestHarness,
        epoch: UUID,
        peer: DriverTestPeer,
        track: DriverTestTrack
    ) async {
        await harness.beginMonitoring(epoch)
        await harness.replacePeer(peer, generation: 1)
        await harness.installTrack(track)
    }

    private func snapshot(
        epoch: UUID,
        generation: UInt64,
        available: Bool
    ) -> BlackHoleDeviceAvailabilitySnapshot {
        BlackHoleDeviceAvailabilitySnapshot(
            monitorEpoch: epoch,
            deviceGeneration: generation,
            isAvailable: available,
            deviceUID: available ? "BlackHole2ch_UID" : nil
        )
    }

    private func readyProgressSnapshots()
        -> [BlackHoleMicrophoneOutputProgressSnapshot] {
        [
            progress(
                callbacks: 1,
                requestedFrames: 480,
                successfulPulls: 1,
                successfulFrames: 480,
                silenceFallbacks: 0,
                silenceFrames: 0
            ),
            progress(
                callbacks: 2,
                requestedFrames: 960,
                successfulPulls: 2,
                successfulFrames: 960,
                silenceFallbacks: 0,
                silenceFrames: 0
            ),
        ]
    }

    private func progress(
        callbacks: UInt64,
        requestedFrames: UInt64,
        successfulPulls: UInt64,
        successfulFrames: UInt64,
        silenceFallbacks: UInt64,
        silenceFrames: UInt64,
        enqueueFailures: UInt64 = 0,
        lastEnqueueStatus: OSStatus = noErr
    ) -> BlackHoleMicrophoneOutputProgressSnapshot {
        BlackHoleMicrophoneOutputProgressSnapshot(
            queueRunning: true,
            postStartCallbackCount: callbacks,
            requestedFrameCount: requestedFrames,
            successfulPullCount: successfulPulls,
            successfulFrameCount: successfulFrames,
            silenceFallbackCount: silenceFallbacks,
            silenceFrameCount: silenceFrames,
            enqueueFailureCount: enqueueFailures,
            lastEnqueueStatus: lastEnqueueStatus
        )
    }

    private func eventually(
        attempts: Int = 1_000,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }
}

final class WorldwideBlackHoleDefaultInputCoordinatorTests:
    XCTestCase
{
    func testAudioRoutingCleanupPolicyRedrivesBothOwnersAfterOneExhaustedEpisode()
    {
        var defaultInputOutcomes:
            [WorldwideBlackHoleDefaultInputOutcome] = [
                .degraded,
                .released,
            ]
        var monitorOutcomes:
            [BlackHoleDeviceAvailabilityMonitorStopResult] = [
                .retryableFailure,
                .stopped,
            ]
        var defaultInputCallCount = 0
        var monitorCallCount = 0

        let result =
            WorldwideBlackHoleAudioRoutingCleanupPolicy.run(
                maximumEpisodeCount: 3,
                shutdownDefaultInput: {
                    defaultInputCallCount += 1
                    return defaultInputOutcomes.removeFirst()
                },
                stopDeviceMonitor: {
                    monitorCallCount += 1
                    return monitorOutcomes.removeFirst()
                }
            )

        XCTAssertEqual(result, .cleaned)
        XCTAssertEqual(
            defaultInputCallCount,
            2,
            "The same production shutdown initiation must redrive default-input cleanup after one exhausted episode."
        )
        XCTAssertEqual(
            monitorCallCount,
            2,
            "The same production shutdown initiation must redrive exact device-list listener removal after one exhausted episode."
        )
    }

    func testAudioRoutingCleanupPolicyCallsCompletedHalfIdempotentlyWhileOtherHalfRecovers()
    {
        var defaultInputOutcomes:
            [WorldwideBlackHoleDefaultInputOutcome] = [
                .released,
                .noChange,
            ]
        var monitorOutcomes:
            [BlackHoleDeviceAvailabilityMonitorStopResult] = [
                .retryableFailure,
                .stopped,
            ]
        var defaultInputCallCount = 0
        var monitorCallCount = 0

        let result =
            WorldwideBlackHoleAudioRoutingCleanupPolicy.run(
                maximumEpisodeCount: 2,
                shutdownDefaultInput: {
                    defaultInputCallCount += 1
                    return defaultInputOutcomes.removeFirst()
                },
                stopDeviceMonitor: {
                    monitorCallCount += 1
                    return monitorOutcomes.removeFirst()
                }
            )

        XCTAssertEqual(result, .cleaned)
        XCTAssertEqual(defaultInputCallCount, 2)
        XCTAssertEqual(monitorCallCount, 2)
    }

    func testAudioRoutingCleanupPolicyIsBoundedAndReportsPersistentDegradation()
    {
        var defaultInputCallCount = 0
        var monitorCallCount = 0

        let result =
            WorldwideBlackHoleAudioRoutingCleanupPolicy.run(
                maximumEpisodeCount: 2,
                shutdownDefaultInput: {
                    defaultInputCallCount += 1
                    return .degraded
                },
                stopDeviceMonitor: {
                    monitorCallCount += 1
                    return .retryableFailure
                }
            )

        XCTAssertEqual(result, .degraded)
        XCTAssertEqual(defaultInputCallCount, 2)
        XCTAssertEqual(monitorCallCount, 2)
    }

    func testRetainedCleanupRedriveUsesOneGlobalRoundRobinBudget()
    {
        let retainer =
            WorldwideBlackHoleAudioRoutingCleanupRetainer()
        let first = CleanupAttemptProbe(
            results: [false, true]
        )
        let second = CleanupAttemptProbe(
            results: [false]
        )

        retainer.retain(id: UUID()) {
            first.attempt()
        }
        retainer.retain(id: UUID()) {
            second.attempt()
        }
        XCTAssertEqual(retainer.retainedJobCount, 2)

        XCTAssertEqual(
            retainer.redriveRetained(
                maximumAttemptCount: 1
            ),
            2
        )
        XCTAssertEqual(first.attemptCount, 1)
        XCTAssertEqual(second.attemptCount, 0)

        _ = retainer.redriveRetained(
            maximumAttemptCount: 1
        )
        XCTAssertEqual(first.attemptCount, 1)
        XCTAssertEqual(second.attemptCount, 1)

        XCTAssertEqual(
            retainer.redriveRetained(
                maximumAttemptCount: 1
            ),
            1,
            "A completed owner is removed while the independently degraded owner remains retained."
        )
        XCTAssertEqual(first.attemptCount, 2)
        XCTAssertEqual(second.attemptCount, 1)
    }

    func testDeviceBeforeConnectionSelectsAtHealthyBoundaryWithoutTrack() {
        let lease = DefaultInputCoordinatorLeaseFake()
        let coordinator =
            WorldwideBlackHoleDefaultInputCoordinator(
                policy: .enabled,
                lease: lease
            )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        let deviceResult =
            coordinator.updateDeviceSnapshot(
                snapshot(epoch: epoch, generation: 1)
            )
        XCTAssertEqual(
            deviceResult,
            .noChange
        )
        let result =
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 7
            )

        guard case .selected(let key) = result else {
            return XCTFail("Expected connection-level selection")
        }
        XCTAssertEqual(key.peerGeneration, 7)
        XCTAssertEqual(key.deviceGeneration, 1)
        XCTAssertEqual(lease.acquisitions.count, 1)
    }

    func testConnectionBeforeDeviceSelectsFirstCurrentAvailableGeneration() {
        let lease = DefaultInputCoordinatorLeaseFake()
        let coordinator =
            WorldwideBlackHoleDefaultInputCoordinator(
                policy: .enabled,
                lease: lease
            )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        let healthyWithoutDevice =
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 3
            )
        XCTAssertEqual(
            healthyWithoutDevice,
            .waitingForMonitor
        )
        XCTAssertEqual(lease.acquisitions.count, 0)

        let result = coordinator.updateDeviceSnapshot(
            snapshot(epoch: epoch, generation: 1)
        )
        guard case .selected = result else {
            return XCTFail("Expected selection on device appearance")
        }
        XCTAssertEqual(lease.acquisitions.count, 1)
    }

    func testRemovalRestoresAndReinstallUsesFreshLeaseGeneration() {
        let lease = DefaultInputCoordinatorLeaseFake()
        let coordinator =
            WorldwideBlackHoleDefaultInputCoordinator(
                policy: .enabled,
                lease: lease
            )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        _ = coordinator.transportDidBecomeHealthy(
            peerGeneration: 1
        )
        _ = coordinator.updateDeviceSnapshot(
            snapshot(epoch: epoch, generation: 1)
        )
        let firstGeneration =
            lease.acquisitions[0].generation

        _ = coordinator.updateDeviceSnapshot(
            BlackHoleDeviceAvailabilitySnapshot(
                monitorEpoch: epoch,
                deviceGeneration: 2,
                isAvailable: false,
                deviceUID: nil
            )
        )
        XCTAssertEqual(lease.releases, [firstGeneration])

        _ = coordinator.updateDeviceSnapshot(
            snapshot(epoch: epoch, generation: 3)
        )
        XCTAssertEqual(lease.acquisitions.count, 2)
        XCTAssertNotEqual(
            lease.acquisitions[1].generation,
            firstGeneration
        )
    }

    func testStalePeerCannotReleaseReplacementConnection() {
        let lease = DefaultInputCoordinatorLeaseFake()
        let coordinator =
            WorldwideBlackHoleDefaultInputCoordinator(
                policy: .enabled,
                lease: lease
            )
        let epoch = UUID()
        _ = coordinator.beginMonitoring(epoch: epoch)
        _ = coordinator.updateDeviceSnapshot(
            snapshot(epoch: epoch, generation: 1)
        )
        _ = coordinator.transportDidBecomeHealthy(
            peerGeneration: 1
        )
        _ = coordinator.invalidateCurrentConnection()
        _ = coordinator.transportDidBecomeHealthy(
            peerGeneration: 2
        )
        let replacementGeneration =
            lease.acquisitions.last!.generation
        let releaseCount = lease.releases.count

        _ = coordinator.transportDidBecomeUnhealthy(
            peerGeneration: 1
        )

        XCTAssertEqual(lease.releases.count, releaseCount)
        XCTAssertNotEqual(
            lease.releases.last,
            replacementGeneration
        )
    }

    func testStaleHealthyPeerCannotReplaceOrResurrectAfterNewerConnection() {
        let lease = DefaultInputCoordinatorLeaseFake()
        let coordinator =
            WorldwideBlackHoleDefaultInputCoordinator(
                policy: .enabled,
                lease: lease
            )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        _ = coordinator.updateDeviceSnapshot(
            snapshot(epoch: epoch, generation: 1)
        )
        _ = coordinator.transportDidBecomeHealthy(
            peerGeneration: 1
        )
        let firstGeneration =
            lease.acquisitions[0].generation

        let replacement =
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 2
            )
        guard case .selected(let replacementKey) =
                replacement else {
            return XCTFail(
                "Expected the newer peer generation to replace the first connection"
            )
        }
        XCTAssertEqual(replacementKey.peerGeneration, 2)
        XCTAssertEqual(lease.acquisitions.count, 2)
        let replacementGeneration =
            lease.acquisitions[1].generation
        XCTAssertEqual(
            lease.releases,
            [firstGeneration]
        )

        XCTAssertEqual(
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 1
            ),
            .noChange,
            "A stale healthy callback must not release or replace the newer connection."
        )
        XCTAssertEqual(lease.acquisitions.count, 2)
        XCTAssertEqual(
            lease.releases,
            [firstGeneration]
        )

        XCTAssertEqual(
            coordinator.transportDidBecomeUnhealthy(
                peerGeneration: 2
            ),
            .released
        )
        XCTAssertEqual(
            lease.releases,
            [firstGeneration, replacementGeneration]
        )

        XCTAssertEqual(
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 1
            ),
            .noChange,
            "A stale healthy callback must not resurrect an older peer after the replacement disconnects."
        )
        XCTAssertEqual(lease.acquisitions.count, 2)

        let samePeerRecovery =
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 2
            )
        guard case .selected(let recoveryKey) =
                samePeerRecovery else {
            return XCTFail(
                "The newest peer generation must remain eligible for a fresh connection boundary"
            )
        }
        XCTAssertEqual(recoveryKey.peerGeneration, 2)
        XCTAssertEqual(lease.acquisitions.count, 3)
        XCTAssertNotEqual(
            recoveryKey.leaseGeneration,
            replacementGeneration
        )
    }

    func testLANCoexistenceSuppressesDefaultInputLease() {
        let lease = DefaultInputCoordinatorLeaseFake()
        let coordinator =
            WorldwideBlackHoleDefaultInputCoordinator(
                policy: .suppressedForLANCoexistence,
                lease: lease
            )
        let epoch = UUID()

        XCTAssertEqual(
            coordinator.beginMonitoring(epoch: epoch),
            .suppressed
        )
        let healthyResult =
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 1
            )
        XCTAssertEqual(
            healthyResult,
            .suppressed
        )
        XCTAssertEqual(lease.acquisitions.count, 0)
    }

    func testSynchronousPreWriteRetryReusesExactLeaseGenerationAndBaseline() {
        let lease = DefaultInputCoordinatorLeaseFake(
            acquisitionResults: [
                .retryableFailure,
                .acquired,
            ]
        )
        let coordinator =
            WorldwideBlackHoleDefaultInputCoordinator(
                policy: .enabled,
                lease: lease,
                maximumAcquisitionAttemptCount: 3
            )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        _ = coordinator.updateDeviceSnapshot(
            snapshot(epoch: epoch, generation: 1)
        )
        let result =
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 4
            )

        guard case .selected(let key) = result else {
            return XCTFail("Expected retry to confirm default input")
        }
        XCTAssertEqual(lease.acquisitions.count, 2)
        XCTAssertEqual(
            lease.acquisitions[0].generation,
            lease.acquisitions[1].generation,
            "Retryable pre-write failure must reuse the exact lease generation and captured baseline."
        )
        XCTAssertTrue(
            lease.releases.isEmpty,
            "A retryable pre-write failure did not acquire ownership and must not release its generation between attempts."
        )
        XCTAssertEqual(
            key.leaseGeneration,
            lease.acquisitions[1].generation
        )
    }

    func testAcquireRetryBudgetIsBoundedForExactIdentity() {
        let lease = DefaultInputCoordinatorLeaseFake(
            acquisitionResults: [
                .retryableFailure,
                .retryableFailure,
                .retryableFailure,
                .retryableFailure,
                .retryableFailure,
                .acquired,
            ],
            releaseResults: [
                .retryableFailure,
                .released,
            ]
        )
        let coordinator =
            WorldwideBlackHoleDefaultInputCoordinator(
                policy: .enabled,
                lease: lease,
                maximumAcquisitionAttemptCount: 3,
                maximumReleaseAttemptCount: 1
            )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        _ = coordinator.updateDeviceSnapshot(
            snapshot(epoch: epoch, generation: 1)
        )
        let exhausted =
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 1
            )
        XCTAssertEqual(exhausted, .degraded)
        guard lease.acquisitions.count == 3 else {
            return XCTFail(
                "The first healthy callback must consume exactly the bounded three-attempt acquisition budget."
            )
        }

        let exhaustedGeneration =
            lease.acquisitions[0].generation
        XCTAssertEqual(
            lease.acquisitions.map(\.generation),
            [
                exhaustedGeneration,
                exhaustedGeneration,
                exhaustedGeneration,
            ],
            "All retryable acquisition attempts must reuse one exact lease generation."
        )
        XCTAssertEqual(
            lease.releases,
            [exhaustedGeneration],
            "Budget exhaustion must immediately perform exactly one bounded release attempt for the same generation."
        )
        XCTAssertEqual(
            lease.events,
            [
                .acquisition(exhaustedGeneration),
                .acquisition(exhaustedGeneration),
                .acquisition(exhaustedGeneration),
                .release(exhaustedGeneration),
            ],
            "The exact cleanup attempt must occur only after all three acquisitions, never between them."
        )

        let repeated =
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 1
            )
        XCTAssertEqual(repeated, .degraded)
        XCTAssertEqual(
            lease.releases,
            [
                exhaustedGeneration,
                exhaustedGeneration,
            ],
            "A duplicate healthy callback must redrive the pending exact release on the same generation."
        )
        XCTAssertEqual(
            lease.acquisitions.count,
            3,
            "Cleanup completion must not perform a fourth acquisition or bypass the exhausted identity budget."
        )
        XCTAssertEqual(
            lease.events,
            [
                .acquisition(exhaustedGeneration),
                .acquisition(exhaustedGeneration),
                .acquisition(exhaustedGeneration),
                .release(exhaustedGeneration),
                .release(exhaustedGeneration),
            ]
        )

        XCTAssertEqual(
            coordinator.updateDeviceSnapshot(
                snapshot(epoch: epoch, generation: 2)
            ),
            .noChange,
            "A synthetic generation bump with unchanged identity must remain idempotent."
        )
        XCTAssertEqual(lease.acquisitions.count, 3)

        XCTAssertEqual(
            coordinator.updateDeviceSnapshot(
                BlackHoleDeviceAvailabilitySnapshot(
                    monitorEpoch: epoch,
                    deviceGeneration: 3,
                    isAvailable: false,
                    deviceUID: nil
                )
            ),
            .waitingForDevice,
            "After exact cleanup completes, factual removal must report waitingForDevice."
        )

        let result = coordinator.updateDeviceSnapshot(
            snapshot(epoch: epoch, generation: 4)
        )
        guard case .selected(let replacementKey) = result else {
            return XCTFail(
                "Removal and reappearance must receive a fresh bounded acquisition budget."
            )
        }
        XCTAssertEqual(lease.acquisitions.count, 6)
        XCTAssertNotEqual(
            replacementKey.leaseGeneration,
            exhaustedGeneration,
            "Reappearance must mint a different exact lease generation."
        )
        XCTAssertEqual(
            lease.acquisitions.suffix(3).map(\.generation),
            [
                replacementKey.leaseGeneration,
                replacementKey.leaseGeneration,
                replacementKey.leaseGeneration,
            ],
            "The reappeared identity must receive a fresh three-attempt budget on its new generation."
        )
        XCTAssertEqual(
            lease.events,
            [
                .acquisition(exhaustedGeneration),
                .acquisition(exhaustedGeneration),
                .acquisition(exhaustedGeneration),
                .release(exhaustedGeneration),
                .release(exhaustedGeneration),
                .acquisition(
                    replacementKey.leaseGeneration
                ),
                .acquisition(
                    replacementKey.leaseGeneration
                ),
                .acquisition(
                    replacementKey.leaseGeneration
                ),
            ]
        )
    }

    func testTerminalAcquireFailureCannotRetryUntilNewConnection() {
        let lease = DefaultInputCoordinatorLeaseFake(
            acquisitionResults: [
                .terminalFailure,
                .acquired,
            ]
        )
        let coordinator =
            WorldwideBlackHoleDefaultInputCoordinator(
                policy: .enabled,
                lease: lease,
                maximumAcquisitionAttemptCount: 3
            )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        _ = coordinator.updateDeviceSnapshot(
            snapshot(epoch: epoch, generation: 1)
        )
        XCTAssertEqual(
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 1
            ),
            .degraded
        )
        XCTAssertEqual(lease.acquisitions.count, 1)

        XCTAssertEqual(
            coordinator.updateDeviceSnapshot(
                snapshot(epoch: epoch, generation: 2)
            ),
            .noChange
        )
        XCTAssertEqual(
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 1
            ),
            .degraded
        )
        XCTAssertEqual(
            lease.acquisitions.count,
            1,
            "A terminal lease generation must never reassert over an external choice."
        )

        _ = coordinator.invalidateCurrentConnection()
        let replacement =
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 2
            )
        guard case .selected(let key) = replacement else {
            return XCTFail("A new connection must receive a new lease generation")
        }
        XCTAssertEqual(lease.acquisitions.count, 2)
        XCTAssertNotEqual(
            lease.acquisitions[0].generation,
            key.leaseGeneration
        )
    }

    func testTerminalAcquireCleanupIsRedrivenByDuplicateHealthyCallback() {
        let lease = DefaultInputCoordinatorLeaseFake(
            acquisitionResults: [
                .terminalFailure,
            ],
            releaseResults: [
                .retryableFailure,
                .released,
            ]
        )
        let coordinator =
            WorldwideBlackHoleDefaultInputCoordinator(
                policy: .enabled,
                lease: lease,
                maximumAcquisitionAttemptCount: 3,
                maximumReleaseAttemptCount: 1
            )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        _ = coordinator.updateDeviceSnapshot(
            snapshot(epoch: epoch, generation: 1)
        )

        XCTAssertEqual(
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 1
            ),
            .degraded
        )
        XCTAssertEqual(lease.acquisitions.count, 1)
        let generation = lease.acquisitions[0].generation
        XCTAssertEqual(lease.releases, [generation])

        XCTAssertEqual(
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 1
            ),
            .degraded,
            "A terminal connection must still redrive retained cleanup ownership."
        )
        XCTAssertEqual(
            lease.releases,
            [generation, generation]
        )
        XCTAssertEqual(
            lease.acquisitions.count,
            1,
            "Cleanup completion must not reacquire on the terminal connection."
        )

        XCTAssertEqual(
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 1
            ),
            .degraded
        )
        XCTAssertEqual(
            lease.releases,
            [generation, generation]
        )
        XCTAssertEqual(lease.acquisitions.count, 1)
    }

    func testFailedRestoreIsRetainedAndRedrivenByDuplicateUnhealthyCallback() {
        let lease = DefaultInputCoordinatorLeaseFake(
            releaseResults: [
                .retryableFailure,
                .released,
            ]
        )
        let coordinator =
            WorldwideBlackHoleDefaultInputCoordinator(
                policy: .enabled,
                lease: lease,
                maximumReleaseAttemptCount: 1
            )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        _ = coordinator.updateDeviceSnapshot(
            snapshot(epoch: epoch, generation: 1)
        )
        _ = coordinator.transportDidBecomeHealthy(
            peerGeneration: 1
        )
        let generation = lease.acquisitions[0].generation

        XCTAssertEqual(
            coordinator.transportDidBecomeUnhealthy(
                peerGeneration: 1
            ),
            .degraded
        )
        XCTAssertEqual(lease.releases, [generation])

        XCTAssertEqual(
            coordinator.transportDidBecomeUnhealthy(
                peerGeneration: 1
            ),
            .released
        )
        XCTAssertEqual(
            lease.releases,
            [generation, generation]
        )
    }

    func testSingleShutdownRedrivesPendingReleaseWithoutSecondExternalCallback()
    {
        let lease = DefaultInputCoordinatorLeaseFake(
            releaseResults: [
                .retryableFailure,
                .released,
            ]
        )
        let coordinator =
            WorldwideBlackHoleDefaultInputCoordinator(
                policy: .enabled,
                lease: lease,
                maximumReleaseAttemptCount: 1,
                maximumShutdownAttemptCount: 2
            )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        _ = coordinator.updateDeviceSnapshot(
            snapshot(epoch: epoch, generation: 1)
        )
        _ = coordinator.transportDidBecomeHealthy(
            peerGeneration: 1
        )

        XCTAssertEqual(
            coordinator.shutdown(),
            .released
        )
        XCTAssertEqual(
            lease.releases.count,
            2,
            "One shutdown initiation must internally redrive retained route and listener cleanup."
        )
        XCTAssertEqual(lease.shutdownCallCount, 1)
    }

    func testSingleShutdownRetriesRetryableLeaseShutdownWithinSameBoundedPolicy()
    {
        let lease = DefaultInputCoordinatorLeaseFake(
            shutdownResults: [
                .retryableFailure,
                .released,
            ]
        )
        let coordinator =
            WorldwideBlackHoleDefaultInputCoordinator(
                policy: .enabled,
                lease: lease,
                maximumReleaseAttemptCount: 1,
                maximumShutdownAttemptCount: 2
            )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        _ = coordinator.updateDeviceSnapshot(
            snapshot(epoch: epoch, generation: 1)
        )
        _ = coordinator.transportDidBecomeHealthy(
            peerGeneration: 1
        )

        XCTAssertEqual(
            coordinator.shutdown(),
            .released
        )
        XCTAssertEqual(lease.releases.count, 1)
        XCTAssertEqual(
            lease.shutdownCallCount,
            2,
            "A retryable lease shutdown must be redriven without another production stop callback."
        )
    }

    func testShutdownPermanentExhaustionIsBoundedAndRetainedForLaterExplicitRetry()
    {
        let lease = DefaultInputCoordinatorLeaseFake(
            releaseResults: [
                .retryableFailure,
                .retryableFailure,
                .released,
            ]
        )
        let coordinator =
            WorldwideBlackHoleDefaultInputCoordinator(
                policy: .enabled,
                lease: lease,
                maximumReleaseAttemptCount: 1,
                maximumShutdownAttemptCount: 2
            )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        _ = coordinator.updateDeviceSnapshot(
            snapshot(epoch: epoch, generation: 1)
        )
        _ = coordinator.transportDidBecomeHealthy(
            peerGeneration: 1
        )

        XCTAssertEqual(
            coordinator.shutdown(),
            .degraded
        )
        XCTAssertEqual(
            lease.releases.count,
            2,
            "One shutdown invocation must stop at its configured bound."
        )
        XCTAssertEqual(lease.shutdownCallCount, 0)

        XCTAssertEqual(
            coordinator.shutdown(),
            .released,
            "A later explicit coordinator shutdown must retain and complete the same cleanup ownership."
        )
        XCTAssertEqual(lease.releases.count, 3)
        XCTAssertEqual(lease.shutdownCallCount, 1)
    }

    func testExternalChoiceDuringRemovalTerminalizesCurrentConnection() {
        let lease = DefaultInputCoordinatorLeaseFake(
            releaseResults: [
                .externallySuperseded,
            ]
        )
        let coordinator =
            WorldwideBlackHoleDefaultInputCoordinator(
                policy: .enabled,
                lease: lease
            )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        _ = coordinator.updateDeviceSnapshot(
            snapshot(epoch: epoch, generation: 1)
        )
        _ = coordinator.transportDidBecomeHealthy(
            peerGeneration: 1
        )

        XCTAssertEqual(
            coordinator.updateDeviceSnapshot(
                BlackHoleDeviceAvailabilitySnapshot(
                    monitorEpoch: epoch,
                    deviceGeneration: 2,
                    isAvailable: false,
                    deviceUID: nil
                )
            ),
            .released
        )
        XCTAssertEqual(
            coordinator.updateDeviceSnapshot(
                snapshot(epoch: epoch, generation: 3)
            ),
            .degraded
        )
        XCTAssertEqual(
            lease.acquisitions.count,
            1,
            "Device reappearance must not reassert over an external choice in the same connection."
        )
    }

    func testUnchangedIdentityChurnDoesNotReleaseOrReacquire() {
        let lease = DefaultInputCoordinatorLeaseFake()
        let coordinator =
            WorldwideBlackHoleDefaultInputCoordinator(
                policy: .enabled,
                lease: lease
            )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        _ = coordinator.updateDeviceSnapshot(
            snapshot(epoch: epoch, generation: 1)
        )
        _ = coordinator.transportDidBecomeHealthy(
            peerGeneration: 1
        )

        for generation in UInt64(2)...UInt64(512) {
            XCTAssertEqual(
                coordinator.updateDeviceSnapshot(
                    snapshot(
                        epoch: epoch,
                        generation: generation
                    )
                ),
                .noChange
            )
        }

        XCTAssertEqual(lease.acquisitions.count, 1)
        XCTAssertTrue(lease.releases.isEmpty)
    }

    func testStalePeerReleaseCannotClearPendingReplacementConnection() {
        let lease = DefaultInputCoordinatorLeaseFake(
            releaseResults: [
                .retryableFailure,
                .released,
            ]
        )
        let coordinator =
            WorldwideBlackHoleDefaultInputCoordinator(
                policy: .enabled,
                lease: lease,
                maximumReleaseAttemptCount: 1
            )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        _ = coordinator.updateDeviceSnapshot(
            snapshot(epoch: epoch, generation: 1)
        )
        _ = coordinator.transportDidBecomeHealthy(
            peerGeneration: 1
        )

        XCTAssertEqual(
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 2
            ),
            .degraded
        )

        let replacement =
            coordinator.transportDidBecomeUnhealthy(
                peerGeneration: 1
            )
        guard case .selected(let key) = replacement else {
            return XCTFail(
                "Successful stale cleanup must immediately drive the already-recorded healthy replacement."
            )
        }
        XCTAssertEqual(key.peerGeneration, 2)
        XCTAssertEqual(lease.acquisitions.count, 2)
        XCTAssertNotEqual(
            lease.acquisitions[0].generation,
            lease.acquisitions[1].generation
        )
        XCTAssertEqual(
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 2
            ),
            .noChange,
            "The replacement must not require or duplicate a second healthy callback."
        )
        XCTAssertEqual(lease.acquisitions.count, 2)
    }

    private func snapshot(
        epoch: UUID,
        generation: UInt64
    ) -> BlackHoleDeviceAvailabilitySnapshot {
        BlackHoleDeviceAvailabilitySnapshot(
            monitorEpoch: epoch,
            deviceGeneration: generation,
            isAvailable: true,
            deviceUID: "BlackHole2ch_UID"
        )
    }
}

private final class DefaultInputCoordinatorLeaseFake:
    WorldwideBlackHoleDefaultInputLeasing,
    @unchecked Sendable
{
    struct Acquisition {
        let generation: UInt64
        let targetUID: String
    }

    enum Event: Equatable {
        case acquisition(UInt64)
        case release(UInt64)
    }

    private(set) var events: [Event] = []
    private(set) var acquisitions: [Acquisition] = []
    private(set) var releases: [UInt64] = []
    private var acquisitionResults:
        [BlackHoleDefaultInputLeaseAcquisitionResult]
    private var releaseResults:
        [BlackHoleDefaultInputLeaseReleaseResult]
    private var shutdownResults:
        [BlackHoleDefaultInputLeaseReleaseResult]
    private(set) var shutdownCallCount = 0

    init(
        acquisitionResults:
            [BlackHoleDefaultInputLeaseAcquisitionResult] = [],
        releaseResults:
            [BlackHoleDefaultInputLeaseReleaseResult] = [],
        shutdownResults:
            [BlackHoleDefaultInputLeaseReleaseResult] = []
    ) {
        self.acquisitionResults = acquisitionResults
        self.releaseResults = releaseResults
        self.shutdownResults = shutdownResults
    }

    func acquisitionResult(
        generation: UInt64,
        targetUID: String
    ) -> BlackHoleDefaultInputLeaseAcquisitionResult {
        events.append(.acquisition(generation))
        acquisitions.append(
            Acquisition(
                generation: generation,
                targetUID: targetUID
            )
        )
        guard !acquisitionResults.isEmpty else {
            return .acquired
        }
        return acquisitionResults.removeFirst()
    }

    func release(
        generation: UInt64
    ) -> BlackHoleDefaultInputLeaseReleaseResult {
        events.append(.release(generation))
        releases.append(generation)
        guard !releaseResults.isEmpty else {
            return .released
        }
        return releaseResults.removeFirst()
    }

    func shutdown()
        -> BlackHoleDefaultInputLeaseReleaseResult {
        shutdownCallCount += 1
        guard !shutdownResults.isEmpty else {
            return .released
        }
        return shutdownResults.removeFirst()
    }
}

private actor DriverTestHarness {
    private let driver:
        WorldwideIPhoneMicrophoneForwardingDriver<
            DriverTestPeer,
            DriverTestTrack
        >

    init(
        policy:
            WorldwideIPhoneMicrophoneForwardingPolicy = .enabled,
        factory: DriverTestOutputFactory,
        readinessGate: DriverSuspensionGate? = nil,
        readinessSampleLimit: Int = 2,
        retryGate: DriverSuspensionGate? = nil,
        maximumAttemptCountPerKey: Int = 3
    ) {
        driver = WorldwideIPhoneMicrophoneForwardingDriver(
            policy: policy,
            makeOutput: { _, uid in
                factory.makeOutput(deviceUID: uid)
            },
            startOutput: { output in
                guard let output = output as? DriverTestOutput else {
                    throw DriverTestError.wrongOutputType
                }
                try await output.startAsynchronously()
            },
            admit: { peer, track in
                try await peer.admit(track)
            },
            disableTrack: { track in
                track.setEnabled(false)
            },
            readinessSleep: {
                if let readinessGate {
                    await readinessGate.wait()
                }
            },
            readinessSampleLimit: readinessSampleLimit,
            retrySleep: {
                if let retryGate {
                    await retryGate.wait()
                }
            },
            maximumAttemptCountPerKey:
                maximumAttemptCountPerKey
        )
    }

    func beginMonitoring(_ epoch: UUID) {
        driver.beginMonitoring(epoch: epoch)
    }

    func replacePeer(
        _ peer: DriverTestPeer,
        generation: UInt64
    ) {
        driver.replacePeer(
            peer: peer,
            peerGeneration: generation
        )
    }

    func installTrack(_ track: DriverTestTrack) async {
        await driver.installTrack(track)
    }

    func authorize(
        peer: DriverTestPeer,
        generation: UInt64
    ) async {
        await driver.authorizeTransport(
            peer: peer,
            peerGeneration: generation
        )
    }

    func invalidateTransport() {
        driver.invalidateTransport()
    }

    func updateDevice(
        _ snapshot: BlackHoleDeviceAvailabilitySnapshot
    ) async {
        await driver.updateDeviceSnapshot(snapshot)
    }

    func handleRuntimeFailure(
        _ output: DriverTestOutput,
        category:
            WorldwideIPhoneMicrophoneForwardingFailureCategory =
                .runtimeEnqueueFailed
    ) async -> Bool {
        await driver.handleRuntimeFailure(
            from: output,
            category: category
        )
    }

    func snapshot()
        -> WorldwideIPhoneMicrophoneForwardingHostSnapshot {
        driver.snapshot()
    }
}

private final class DriverTestOutput:
    WorldwideIPhoneMicrophoneOutput,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let startGate: DriverSuspensionGate?
    private let startError: DriverTestError?
    private var progressSnapshots:
        [BlackHoleMicrophoneOutputProgressSnapshot]
    private var starts = 0
    private var stops = 0
    private var startEntered = false

    init(
        startGate: DriverSuspensionGate? = nil,
        startError: DriverTestError? = nil,
        progressSnapshots:
            [BlackHoleMicrophoneOutputProgressSnapshot] = [.zero]
    ) {
        self.startGate = startGate
        self.startError = startError
        self.progressSnapshots = progressSnapshots
    }

    func startAsynchronously() async throws {
        lock.withLock {
            startEntered = true
        }
        if let startGate {
            await startGate.wait()
        }
        try start()
    }

    func start() throws {
        let error = lock.withLock { () -> DriverTestError? in
            starts += 1
            return startError
        }
        if let error {
            throw error
        }
    }

    func stop() {
        lock.withLock {
            stops += 1
        }
    }

    var forwardingProgressSnapshot:
        BlackHoleMicrophoneOutputProgressSnapshot {
        lock.withLock {
            guard !progressSnapshots.isEmpty else {
                return .zero
            }
            if progressSnapshots.count > 1 {
                return progressSnapshots.removeFirst()
            }
            return progressSnapshots[0]
        }
    }

    var startCount: Int {
        lock.withLock { starts }
    }

    var stopCount: Int {
        lock.withLock { stops }
    }

    var startWasEntered: Bool {
        lock.withLock { startEntered }
    }
}

private final class DriverTestOutputFactory:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var outputs: [DriverTestOutput]
    private var requests = 0
    private var uids: [String] = []

    init(outputs: [DriverTestOutput]) {
        self.outputs = outputs
    }

    func makeOutput(
        deviceUID: String
    ) -> (any WorldwideIPhoneMicrophoneOutput)? {
        lock.withLock {
            requests += 1
            uids.append(deviceUID)
            guard !outputs.isEmpty else {
                return nil
            }
            return outputs.removeFirst()
        }
    }

    func append(_ output: DriverTestOutput) {
        lock.withLock {
            outputs.append(output)
        }
    }

    var requestCount: Int {
        lock.withLock { requests }
    }

    var requestedUIDs: [String] {
        lock.withLock { uids }
    }
}

private final class DriverTestPeer: @unchecked Sendable {
    private let lock = NSLock()
    private let admissionGate: DriverSuspensionGate?
    private var healthy: Bool
    private var admissions = 0

    init(
        healthy: Bool = true,
        admissionGate: DriverSuspensionGate? = nil
    ) {
        self.healthy = healthy
        self.admissionGate = admissionGate
    }

    func admit(_ track: DriverTestTrack) async throws {
        lock.withLock {
            admissions += 1
        }
        if let admissionGate {
            await admissionGate.wait()
        }
        let isHealthy = lock.withLock { healthy }
        guard isHealthy else {
            track.setEnabled(false)
            throw DriverTestError.admission
        }
        track.setEnabled(true)
    }

    var admissionCount: Int {
        lock.withLock { admissions }
    }
}

private final class CleanupAttemptProbe:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var results: [Bool]
    private var attempts = 0

    init(results: [Bool]) {
        self.results = results
    }

    func attempt() -> Bool {
        lock.withLock {
            attempts += 1
            guard !results.isEmpty else {
                return false
            }
            return results.removeFirst()
        }
    }

    var attemptCount: Int {
        lock.withLock {
            attempts
        }
    }
}

private final class RuntimeDisposalOutputFactory:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let operations:
        DistinctRuntimeAudioQueueOperations
    private let retainer:
        BlackHoleMicrophoneOutputQueueDisposalRetainer
    private var outputs:
        [BlackHoleMicrophoneOutput] = []

    init(
        operations:
            DistinctRuntimeAudioQueueOperations,
        retainer:
            BlackHoleMicrophoneOutputQueueDisposalRetainer
    ) {
        self.operations = operations
        self.retainer = retainer
    }

    func makeOutput()
        -> (any WorldwideIPhoneMicrophoneOutput)? {
        guard let output =
                BlackHoleMicrophoneOutput(
                    testingAudioQueueOperations:
                        operations,
                    renderForTesting: {
                        samples,
                        frameCount in
                        for index in 0..<(frameCount * 2) {
                            samples[index] = 1
                        }
                        return true
                    },
                    queueDisposalRetainer:
                        retainer,
                    maximumQueueDisposalAttemptCountPerEpisode:
                        1,
                    runtimeFailureHandler: {
                        _, _ in
                    }
                ) else {
            return nil
        }
        lock.withLock {
            outputs.append(output)
        }
        return output
    }

    func output(
        at index: Int
    ) -> BlackHoleMicrophoneOutput? {
        lock.withLock {
            guard outputs.indices.contains(index)
            else {
                return nil
            }
            return outputs[index]
        }
    }

    func latestOutput()
        -> BlackHoleMicrophoneOutput? {
        lock.withLock {
            outputs.last
        }
    }
}

private actor RuntimeDisposalDriverHarness {
    private let driver:
        WorldwideIPhoneMicrophoneForwardingDriver<
            DriverTestPeer,
            DriverTestTrack
        >

    init(
        factory: RuntimeDisposalOutputFactory,
        operations:
            DistinctRuntimeAudioQueueOperations
    ) {
        driver =
            WorldwideIPhoneMicrophoneForwardingDriver(
                policy: .enabled,
                makeOutput: { _, _ in
                    factory.makeOutput()
                },
                startOutput: { output in
                    try output.start()
                    guard let output =
                            output as?
                                BlackHoleMicrophoneOutput,
                          let queue =
                            operations.latestQueue,
                          let buffer =
                            operations
                                .firstActiveBuffer
                    else {
                        return
                    }
                    output
                        .debugInvokeRealtimeCallbackForTesting(
                            queue: queue,
                            buffer: buffer
                        )
                },
                admit: { peer, track in
                    try await peer.admit(track)
                },
                disableTrack: { track in
                    track.setEnabled(false)
                },
                readinessSleep: {
                    guard let output =
                            factory.latestOutput(),
                          let queue =
                            operations.latestQueue,
                          let buffer =
                            operations
                                .firstActiveBuffer
                    else {
                        return
                    }
                    output
                        .debugInvokeRealtimeCallbackForTesting(
                            queue: queue,
                            buffer: buffer
                        )
                },
                readinessSampleLimit: 2,
                retrySleep: {},
                maximumAttemptCountPerKey: 3
            )
    }

    func beginMonitoring(_ epoch: UUID) {
        driver.beginMonitoring(epoch: epoch)
    }

    func replacePeer(
        _ peer: DriverTestPeer,
        generation: UInt64
    ) {
        driver.replacePeer(
            peer: peer,
            peerGeneration: generation
        )
    }

    func installTrack(
        _ track: DriverTestTrack
    ) async {
        await driver.installTrack(track)
    }

    func authorize(
        peer: DriverTestPeer,
        generation: UInt64
    ) async {
        await driver.authorizeTransport(
            peer: peer,
            peerGeneration: generation
        )
    }

    func updateDevice(
        _ snapshot:
            BlackHoleDeviceAvailabilitySnapshot
    ) async {
        await driver.updateDeviceSnapshot(snapshot)
    }

    func handleRuntimeFailure(
        _ output: BlackHoleMicrophoneOutput
    ) async -> Bool {
        await driver.handleRuntimeFailure(
            from: output,
            category:
                .runtimeProgressStalled
        )
    }

    func snapshot()
        -> WorldwideIPhoneMicrophoneForwardingHostSnapshot {
        driver.snapshot()
    }

    func shutdown() {
        driver.shutdown()
    }
}

private final class
    DistinctRuntimeAudioQueueOperations:
    BlackHoleMicrophoneOutputAudioQueueOperations,
    @unchecked Sendable
{
    private struct QueueState {
        var disposed = false
        var allocations:
            [RuntimeDisposalBufferAllocation] = []
    }

    private let lock = NSLock()
    private let disposeStatuses: [OSStatus]
    private var disposeIndex = 0
    private var nextQueueIdentity: UInt = 65_536
    private var queues: [UInt: QueueState] = [:]
    private var created:
        [UInt] = []
    private var eventStorage:
        [String] = []
    private var latestQueueStorage:
        AudioQueueRef?

    init(disposeStatuses: [OSStatus]) {
        self.disposeStatuses = disposeStatuses
    }

    deinit {
        let allocations = lock.withLock {
            queues.values.flatMap {
                $0.allocations
            }
        }
        for allocation in allocations {
            allocation.freeIfNeeded()
        }
    }

    var createdQueueIdentities: [UInt] {
        lock.withLock {
            created
        }
    }

    var events: [String] {
        lock.withLock {
            eventStorage
        }
    }

    var latestQueue: AudioQueueRef? {
        lock.withLock {
            latestQueueStorage
        }
    }

    var firstActiveBuffer:
        AudioQueueBufferRef? {
        lock.withLock {
            for queue in created.reversed() {
                guard let state = queues[queue],
                      !state.disposed,
                      let allocation =
                        state.allocations.first(
                            where: {
                                !$0.isFreed
                            }
                        ) else {
                    continue
                }
                return allocation.buffer
            }
            return nil
        }
    }

    var activeAllocationCount: Int {
        lock.withLock {
            queues.values.reduce(0) {
                partial,
                state in
                partial + state.allocations.filter {
                    !$0.isFreed
                }.count
            }
        }
    }

    func createOutputQueue() -> (
        status: OSStatus,
        queue: AudioQueueRef?
    ) {
        lock.withLock {
            let identity = nextQueueIdentity
            nextQueueIdentity += 1
            let queue =
                OpaquePointer(
                    bitPattern: identity
                )!
            queues[identity] = QueueState()
            created.append(identity)
            latestQueueStorage = queue
            eventStorage.append(
                "create:\(identity)"
            )
            return (noErr, queue)
        }
    }

    func setCurrentDevice(
        _ uid: String,
        on queue: AudioQueueRef
    ) -> OSStatus {
        noErr
    }

    func allocateBuffer(
        on queue: AudioQueueRef,
        byteCount: UInt32
    ) -> (
        status: OSStatus,
        buffer: AudioQueueBufferRef?
    ) {
        lock.withLock {
            let identity =
                Self.identity(queue)
            guard var state = queues[identity],
                  !state.disposed else {
                return (kAudio_ParamError, nil)
            }
            let allocation =
                RuntimeDisposalBufferAllocation(
                    capacity: byteCount
                )
            state.allocations.append(allocation)
            queues[identity] = state
            return (noErr, allocation.buffer)
        }
    }

    func enqueueBuffer(
        _ buffer: AudioQueueBufferRef,
        on queue: AudioQueueRef
    ) -> OSStatus {
        lock.withLock {
            let identity =
                Self.identity(queue)
            guard let state = queues[identity],
                  !state.disposed,
                  state.allocations.contains(
                    where: {
                        $0.buffer == buffer
                            && !$0.isFreed
                    }
                  ) else {
                return kAudio_ParamError
            }
            return noErr
        }
    }

    func startQueue(
        _ queue: AudioQueueRef
    ) -> OSStatus {
        noErr
    }

    func stopQueue(
        _ queue: AudioQueueRef,
        immediate: Bool
    ) -> OSStatus {
        noErr
    }

    func freeBuffer(
        _ buffer: AudioQueueBufferRef,
        from queue: AudioQueueRef
    ) -> OSStatus {
        lock.withLock {
            let identity =
                Self.identity(queue)
            guard let state = queues[identity],
                  let allocation =
                    state.allocations.first(
                        where: {
                            $0.buffer == buffer
                        }
                    ) else {
                return kAudio_ParamError
            }
            allocation.freeIfNeeded()
            return noErr
        }
    }

    func disposeQueue(
        _ queue: AudioQueueRef,
        immediate: Bool
    ) -> OSStatus {
        lock.withLock {
            let identity =
                Self.identity(queue)
            guard var state = queues[identity],
                  !state.disposed else {
                preconditionFailure(
                    "AudioQueueDispose was called twice for terminal queue \(identity)"
                )
            }
            let status =
                disposeIndex
                    < disposeStatuses.count
                ? disposeStatuses[disposeIndex]
                : noErr
            disposeIndex += 1
            eventStorage.append(
                "dispose:\(identity):\(status)"
            )
            state.disposed = true
            for allocation in state.allocations {
                allocation.freeIfNeeded()
            }
            queues[identity] = state
            return status
        }
    }

    private static func identity(
        _ queue: AudioQueueRef
    ) -> UInt {
        UInt(bitPattern: queue)
    }
}

private final class RuntimeDisposalBufferAllocation:
    @unchecked Sendable
{
    let buffer: AudioQueueBufferRef
    private let lock = NSLock()
    private var data:
        UnsafeMutableRawPointer?
    private var bufferStorage:
        UnsafeMutablePointer<AudioQueueBuffer>?

    init(capacity: UInt32) {
        let byteCount = max(1, Int(capacity))
        let data = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<Int16>.alignment
        )
        data.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: byteCount
        )
        let storage =
            UnsafeMutablePointer<AudioQueueBuffer>
                .allocate(capacity: 1)
        storage.initialize(
            to: AudioQueueBuffer(
                mAudioDataBytesCapacity: capacity,
                mAudioData: data,
                mAudioDataByteSize: 0,
                mUserData: nil,
                mPacketDescriptionCapacity: 0,
                mPacketDescriptions: nil,
                mPacketDescriptionCount: 0
            )
        )
        self.data = data
        bufferStorage = storage
        buffer = storage
    }

    deinit {
        freeIfNeeded()
    }

    var isFreed: Bool {
        lock.withLock {
            bufferStorage == nil
        }
    }

    func freeIfNeeded() {
        lock.lock()
        let data = self.data
        let storage = bufferStorage
        self.data = nil
        bufferStorage = nil
        lock.unlock()

        if let storage {
            storage.deinitialize(count: 1)
            storage.deallocate()
        }
        data?.deallocate()
    }
}

private final class DriverTestTrack: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    var isEnabled: Bool {
        lock.withLock { enabled }
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock {
            self.enabled = enabled
        }
    }
}

private actor DriverSuspensionGate {
    private var isOpen = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        entered = true
        await withCheckedContinuation {
            waiters.append($0)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }

    func hasEntered() -> Bool {
        entered
    }
}

private enum DriverTestError: Error {
    case start
    case admission
    case wrongOutputType
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
