#if os(macOS) && DEBUG
import AudioToolbox
import CaptureCore
import Foundation
import XCTest
@testable import CaptureServer

final class WorldwideIPhoneMicrophoneForwardingDriverTests:
    XCTestCase
{
    func testVisibleEndpointWithoutHiddenSinkFailsClosed()
        async {
        let factory = DriverTestOutputFactory(
            outputs: [
                DriverTestOutput(
                    progressSnapshots: readyProgressSnapshots()
                ),
            ]
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
            BlackHoleDeviceAvailabilitySnapshot(
                monitorEpoch: epoch,
                deviceGeneration: 1,
                isAvailable: true,
                deviceUID: "BlackHole2ch_UID"
            )
        )

        let result = await harness.snapshot()
        XCTAssertEqual(factory.requestCount, 0)
        XCTAssertFalse(track.isEnabled)
        XCTAssertEqual(result.phase, .waitingForDevice)
        XCTAssertEqual(result.deviceUID, "BlackHole2ch_UID")
        XCTAssertNil(result.sinkDeviceUID)
        XCTAssertFalse(result.hiddenWriterSelectionProven)
    }

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
                "BlackHole2ch_2_UID",
                "BlackHole2ch_2_UID",
            ]
        )
        XCTAssertEqual(factory.requestedDeviceIDs, [89, 89])
        XCTAssertEqual(ready.startCount, 1)
        XCTAssertTrue(track.isEnabled)
        XCTAssertEqual(final.phase, .forwardingHealthy)
        XCTAssertTrue(final.exactTrackAdmitted)
        XCTAssertTrue(final.queueRunning)
        XCTAssertTrue(final.hiddenWriterSelectionProven)
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
        XCTAssertEqual(final.sinkDeviceUID, "BlackHole2ch_2_UID")
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
            ["BlackHole2ch_2_UID", "BlackHole2ch_2_UID"]
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
                "BlackHole2ch_2_UID",
                "BlackHole2ch_2_UID",
                "BlackHole2ch_2_UID",
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
                defaultInputEndpoint: .init(
                    deviceID: 79,
                    deviceUID: "BlackHole2ch_UID"
                ),
                hiddenMirrorSinkEndpoint: .init(
                    deviceID: 89,
                    deviceUID: "BlackHole2ch_2_UID"
                )
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

    func testFrozenRTPWithSuccessfulZeroFilledPullsRetiresOnlyExactAttempt()
        async {
        var frozenSourceProgress:
            [BlackHoleMicrophoneOutputProgressSnapshot] = []
        for index in 1...12 {
            let count = UInt64(index)
            let frames = count * 480
            frozenSourceProgress.append(
                progress(
                    callbacks: count,
                    requestedFrames: frames,
                    successfulPulls: count,
                    successfulFrames: frames,
                    silenceFallbacks: 0,
                    silenceFrames: 0
                )
            )
        }
        let first = DriverTestOutput(
            progressSnapshots: frozenSourceProgress
        )
        let replacement = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(
            outputs: [first, replacement]
        )
        let harness = DriverTestHarness(
            factory: factory,
            maximumAttemptCountPerKey: 2,
            maximumStaleInboundMediaSamples: 3,
            automaticallyAdvanceInboundMedia: false
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
        let firstAttemptID = await harness.snapshot().currentAttemptID
        XCTAssertNotNil(firstAttemptID)

        await harness.publishInboundMedia(
            packets: 38_626,
            bytes: 2_634_060,
            jitterBufferEmittedCount: 20_000,
            totalSamplesReceived: 36_698_880
        )
        await harness.publishInboundMedia(
            packets: 38_627,
            bytes: 2_634_128,
            jitterBufferEmittedCount: 20_001,
            totalSamplesReceived: 36_699_360
        )
        let initiallyHealthy = await harness.snapshot()
        XCTAssertEqual(initiallyHealthy.phase, .forwardingHealthy)

        for _ in 0..<3 {
            await harness.publishInboundMedia(
                packets: 38_627,
                bytes: 2_634_128,
                jitterBufferEmittedCount: 20_001,
                totalSamplesReceived: 36_699_360
            )
        }

        let retried = await harness.snapshot()
        XCTAssertEqual(factory.requestCount, 2)
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(replacement.stopCount, 0)
        XCTAssertNotEqual(retried.currentAttemptID, firstAttemptID)
        XCTAssertEqual(retried.lastFailureCategory, .sourceMediaStalled)
        XCTAssertEqual(retried.phase, .awaitingFrames)
        XCTAssertEqual(retried.inboundMediaAdvancementCount, 0)
        XCTAssertTrue(track.isEnabled)
    }

    func testQuietButAdvancingRTPIsHealthyWithoutAmplitudeOrEnergyEvidence()
        async {
        let output = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(outputs: [output])
        let harness = DriverTestHarness(
            factory: factory,
            automaticallyAdvanceInboundMedia: false
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
        await harness.publishInboundMedia(
            packets: 100,
            bytes: 8_000,
            jitterBufferEmittedCount: 50,
            totalSamplesReceived: 48_000
        )
        await harness.publishInboundMedia(
            packets: 101,
            bytes: 8_080
        )

        let healthy = await harness.snapshot()
        XCTAssertEqual(healthy.phase, .forwardingHealthy)
        XCTAssertTrue(healthy.inboundMediaFresh)
        XCTAssertEqual(healthy.inboundMediaAdvancementCount, 1)
        XCTAssertEqual(healthy.consecutiveStaleInboundMediaSamples, 0)
        XCTAssertTrue(track.isEnabled)
        XCTAssertEqual(output.stopCount, 0)
    }

    func testHealthyMediaExpiresWhenStatisticsStopCompletely()
        async {
        let watchdog = DriverTestMediaFreshnessWatchdog(now: 10)
        let output = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(outputs: [output])
        let harness = DriverTestHarness(
            factory: factory,
            maximumAttemptCountPerKey: 1,
            mediaFreshnessTimeoutNanoseconds: 100,
            mediaFreshnessWatchdog: watchdog,
            automaticallyAdvanceInboundMedia: false
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
        await harness.publishInboundMedia(
            packets: 700,
            bytes: 56_000
        )
        await harness.publishInboundMedia(
            packets: 701,
            bytes: 56_080
        )

        let healthy = await harness.snapshot()
        XCTAssertEqual(healthy.phase, .forwardingHealthy)
        let deadlineWasScheduled = await eventually {
            watchdog.scheduleCount == 1
        }
        XCTAssertTrue(deadlineWasScheduled)

        // No further statistics sample is delivered. Freshness must expire
        // synchronously from monotonic time even before the scheduled wake-up
        // is delivered, and that wake-up must then retire the exact attempt.
        watchdog.setNowWithoutDelivering(to: 110)
        let pastDeadline = await harness.snapshot()
        XCTAssertEqual(pastDeadline.phase, .awaitingFrames)
        XCTAssertFalse(pastDeadline.inboundMediaFresh)
        XCTAssertNotNil(pastDeadline.currentAttemptID)
        watchdog.deliverDueDeadlines()
        let didExpire = await eventually {
            await harness.snapshot().phase == .sourceMediaStalled
        }
        XCTAssertTrue(didExpire)
        let expired = await harness.snapshot()
        XCTAssertNil(expired.currentAttemptID)
        XCTAssertFalse(expired.inboundMediaFresh)
        XCTAssertEqual(factory.requestCount, 1)
        XCTAssertEqual(output.stopCount, 1)
        XCTAssertFalse(track.isEnabled)
    }

    func testRecoveryDeadlinesExhaustBudgetWhenStatisticsStayStopped()
        async {
        let watchdog = DriverTestMediaFreshnessWatchdog()
        let outputs = (0..<3).map { _ in
            DriverTestOutput(
                progressSnapshots: readyProgressSnapshots()
            )
        }
        let factory = DriverTestOutputFactory(outputs: outputs)
        let harness = DriverTestHarness(
            factory: factory,
            maximumAttemptCountPerKey: 3,
            mediaFreshnessTimeoutNanoseconds: 100,
            mediaFreshnessWatchdog: watchdog,
            automaticallyAdvanceInboundMedia: false
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
        await harness.publishInboundMedia(packets: 750, bytes: 60_000)
        await harness.publishInboundMedia(packets: 751, bytes: 60_080)

        let firstDeadlineReady = await eventually {
            watchdog.scheduleCount >= 1
        }
        XCTAssertTrue(firstDeadlineReady)

        for (deadline, expectedAttemptCount) in [
            (UInt64(100), 2),
            (UInt64(200), 3),
        ] {
            watchdog.advance(to: deadline)
            let replacementReady = await eventually {
                factory.requestCount == expectedAttemptCount
                    && watchdog.scheduleCount >= expectedAttemptCount
            }
            XCTAssertTrue(replacementReady)
        }

        watchdog.advance(to: 300)
        let exhausted = await eventually {
            let snapshot = await harness.snapshot()
            return snapshot.phase == .sourceMediaStalled
                && snapshot.currentAttemptID == nil
        }
        XCTAssertTrue(exhausted)
        XCTAssertEqual(factory.requestCount, 3)
        XCTAssertEqual(outputs.map(\.stopCount), [1, 1, 1])
        XCTAssertFalse(track.isEnabled)
    }

    func testFrozenRTPWithAdvancingConcealmentCountersExhaustsRetryBudget()
        async {
        let watchdog = DriverTestMediaFreshnessWatchdog()
        let outputs = (0..<3).map { _ in
            DriverTestOutput(
                progressSnapshots: readyProgressSnapshots()
            )
        }
        let factory = DriverTestOutputFactory(outputs: outputs)
        let harness = DriverTestHarness(
            factory: factory,
            maximumAttemptCountPerKey: 3,
            maximumStaleInboundMediaSamples: 1,
            mediaFreshnessTimeoutNanoseconds: 1_000,
            mediaFreshnessWatchdog: watchdog,
            automaticallyAdvanceInboundMedia: false
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
        await harness.publishInboundMedia(
            packets: 800,
            bytes: 64_000,
            jitterBufferEmittedCount: 400,
            totalSamplesReceived: 384_000
        )
        await harness.publishInboundMedia(
            packets: 801,
            bytes: 64_080,
            jitterBufferEmittedCount: 401,
            totalSamplesReceived: 384_480
        )
        let healthy = await harness.snapshot()
        XCTAssertEqual(healthy.phase, .forwardingHealthy)

        for increment in UInt64(1)...UInt64(3) {
            await harness.publishInboundMedia(
                packets: 801,
                bytes: 64_080,
                jitterBufferEmittedCount: 401 + increment,
                totalSamplesReceived: 384_480 + increment * 480
            )
        }

        let exhausted = await harness.snapshot()
        XCTAssertEqual(factory.requestCount, 3)
        XCTAssertNil(exhausted.currentAttemptID)
        XCTAssertEqual(exhausted.phase, .sourceMediaStalled)
        XCTAssertEqual(
            exhausted.lastFailureCategory,
            .sourceMediaStalled
        )
        XCTAssertFalse(exhausted.inboundMediaFresh)
        XCTAssertFalse(track.isEnabled)
        XCTAssertEqual(outputs.map(\.stopCount), [1, 1, 1])
        watchdog.advance(to: UInt64.max)
    }

    func testCancelledAttemptDeadlineCannotRetireHealthyReplacement()
        async {
        let watchdog = DriverTestMediaFreshnessWatchdog()
        let first = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let replacement = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(
            outputs: [first, replacement]
        )
        let harness = DriverTestHarness(
            factory: factory,
            maximumAttemptCountPerKey: 2,
            mediaFreshnessTimeoutNanoseconds: 100,
            mediaFreshnessWatchdog: watchdog,
            automaticallyAdvanceInboundMedia: false
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
        await harness.publishInboundMedia(packets: 900, bytes: 72_000)
        await harness.publishInboundMedia(packets: 901, bytes: 72_080)
        let firstAttemptID = await harness.snapshot().currentAttemptID
        XCTAssertNotNil(firstAttemptID)

        let failureWasHandled =
            await harness.handleRuntimeFailure(first)
        XCTAssertTrue(failureWasHandled)
        watchdog.advance(to: 50)
        await harness.publishInboundMedia(packets: 902, bytes: 72_160)
        let healthyReplacement = await harness.snapshot()
        XCTAssertNotEqual(
            healthyReplacement.currentAttemptID,
            firstAttemptID
        )
        XCTAssertEqual(healthyReplacement.phase, .forwardingHealthy)

        // This releases the old attempt's deadline but not the replacement's
        // refreshed deadline at 150. Exact attempt and watchdog-generation
        // fences must make the old wake-up inert.
        watchdog.advance(to: 100)
        try? await Task.sleep(for: .milliseconds(10))
        let afterStaleWake = await harness.snapshot()
        XCTAssertEqual(
            afterStaleWake.currentAttemptID,
            healthyReplacement.currentAttemptID
        )
        XCTAssertEqual(afterStaleWake.phase, .forwardingHealthy)
        XCTAssertTrue(track.isEnabled)
        XCTAssertEqual(replacement.stopCount, 0)
        watchdog.advance(to: UInt64.max)
    }

    func testStaleSamplesBeforeFirstInboundAdvanceDoNotConsumeRetryBudget()
        async {
        let output = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(outputs: [output])
        let harness = DriverTestHarness(
            factory: factory,
            maximumAttemptCountPerKey: 2,
            maximumStaleInboundMediaSamples: 2,
            automaticallyAdvanceInboundMedia: false
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
        let attemptID = await harness.snapshot().currentAttemptID

        for _ in 0..<8 {
            await harness.publishInboundMedia(
                packets: 400,
                bytes: 32_000
            )
        }

        let waiting = await harness.snapshot()
        XCTAssertEqual(factory.requestCount, 1)
        XCTAssertEqual(waiting.currentAttemptID, attemptID)
        XCTAssertEqual(waiting.phase, .awaitingFrames)
        XCTAssertEqual(waiting.inboundMediaAdvancementCount, 0)
        XCTAssertEqual(waiting.consecutiveStaleInboundMediaSamples, 0)
        XCTAssertFalse(waiting.inboundMediaFresh)
        XCTAssertNil(waiting.lastFailureCategory)
        XCTAssertTrue(track.isEnabled)
        XCTAssertEqual(output.stopCount, 0)
    }

    func testAdvancingSilentQueueAwaitsDelayedFirstPCMWithoutRetiringAttempt()
        async {
        let silentOne = progress(
            callbacks: 1,
            requestedFrames: 480,
            successfulPulls: 0,
            successfulFrames: 0,
            silenceFallbacks: 1,
            silenceFrames: 480
        )
        let silentTwo = progress(
            callbacks: 2,
            requestedFrames: 960,
            successfulPulls: 0,
            successfulFrames: 0,
            silenceFallbacks: 2,
            silenceFrames: 960
        )
        let firstReady = progress(
            callbacks: 3,
            requestedFrames: 1_440,
            successfulPulls: 1,
            successfulFrames: 480,
            silenceFallbacks: 2,
            silenceFrames: 960
        )
        let continuingReady = progress(
            callbacks: 4,
            requestedFrames: 1_920,
            successfulPulls: 2,
            successfulFrames: 960,
            silenceFallbacks: 2,
            silenceFrames: 960
        )
        let output = DriverTestOutput(
            progressSnapshots: [
                silentOne,
                silentTwo,
                firstReady,
                firstReady,
                firstReady,
                continuingReady,
            ]
        )
        let factory = DriverTestOutputFactory(outputs: [output])
        let harness = DriverTestHarness(
            factory: factory,
            automaticallyAdvanceInboundMedia: false
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
        XCTAssertEqual(output.stopCount, 0)
        XCTAssertTrue(track.isEnabled)

        await harness.publishInboundMedia(packets: 700, bytes: 56_000)
        await harness.publishInboundMedia(packets: 701, bytes: 56_080)

        let oneSinkWatermark = await harness.snapshot()
        XCTAssertEqual(oneSinkWatermark.phase, .forwardingReady)
        XCTAssertEqual(oneSinkWatermark.inboundMediaAdvancementCount, 1)
        XCTAssertFalse(oneSinkWatermark.inboundMediaFresh)
        XCTAssertEqual(factory.requestCount, 1)
        XCTAssertEqual(output.stopCount, 0)

        let endToEndHealthy = await harness.snapshot()
        XCTAssertEqual(endToEndHealthy.phase, .forwardingHealthy)
        XCTAssertTrue(endToEndHealthy.inboundMediaFresh)
        XCTAssertTrue(track.isEnabled)
    }

    func testStaleFreshnessCannotCrossAttemptOrPeerRollover()
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
            automaticallyAdvanceInboundMedia: false
        )
        let firstPeer = DriverTestPeer()
        let firstTrack = DriverTestTrack()
        let epoch = UUID()

        await prepare(
            harness: harness,
            epoch: epoch,
            peer: firstPeer,
            track: firstTrack
        )
        await harness.authorize(peer: firstPeer, generation: 1)
        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 1,
                available: true
            )
        )
        await harness.publishInboundMedia(packets: 10, bytes: 800)
        await harness.publishInboundMedia(packets: 11, bytes: 880)
        let firstAttemptHealthy = await harness.snapshot()
        XCTAssertEqual(firstAttemptHealthy.phase, .forwardingHealthy)

        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 2,
                available: true
            )
        )
        let deviceRollover = await harness.snapshot()
        XCTAssertEqual(deviceRollover.phase, .awaitingFrames)
        XCTAssertEqual(deviceRollover.inboundMediaAdvancementCount, 0)
        await harness.publishInboundMedia(packets: 11, bytes: 880)
        let unchangedWatermark = await harness.snapshot()
        XCTAssertEqual(unchangedWatermark.phase, .awaitingFrames)
        await harness.publishInboundMedia(packets: 12, bytes: 960)
        let advancedWatermark = await harness.snapshot()
        XCTAssertEqual(advancedWatermark.phase, .forwardingHealthy)

        let secondPeer = DriverTestPeer()
        let secondTrack = DriverTestTrack()
        await harness.replacePeer(secondPeer, generation: 2)
        await harness.installTrack(secondTrack)
        await harness.authorize(peer: secondPeer, generation: 2)

        await harness.publishInboundMedia(
            packets: 13,
            bytes: 1_040,
            peer: firstPeer,
            generation: 1
        )
        let rejectedOldPeer = await harness.snapshot()
        XCTAssertEqual(rejectedOldPeer.phase, .awaitingFrames)
        XCTAssertEqual(rejectedOldPeer.inboundMediaAdvancementCount, 0)

        await harness.publishInboundMedia(
            packets: 500,
            bytes: 40_000,
            peer: secondPeer,
            generation: 2
        )
        let secondPeerBaseline = await harness.snapshot()
        XCTAssertEqual(secondPeerBaseline.phase, .awaitingFrames)
        await harness.publishInboundMedia(
            packets: 501,
            bytes: 40_080,
            peer: secondPeer,
            generation: 2
        )
        let healthySecondPeer = await harness.snapshot()
        XCTAssertEqual(healthySecondPeer.phase, .forwardingHealthy)
        XCTAssertTrue(healthySecondPeer.inboundMediaFresh)
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(second.stopCount, 1)
        XCTAssertEqual(third.stopCount, 0)
    }

    func testTransientReadinessFailureRetriesSameGeneration()
        async {
        let notReady = DriverTestOutput(
            progressSnapshots: [.zero, .zero]
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
        guard available else {
            return BlackHoleDeviceAvailabilitySnapshot(
                monitorEpoch: epoch,
                deviceGeneration: generation,
                isAvailable: false,
                deviceUID: nil
            )
        }
        return BlackHoleDeviceAvailabilitySnapshot(
            monitorEpoch: epoch,
            deviceGeneration: generation,
            defaultInputEndpoint: .init(
                deviceID: 79,
                deviceUID: "BlackHole2ch_UID"
            ),
            hiddenMirrorSinkEndpoint: .init(
                deviceID: 89,
                deviceUID: "BlackHole2ch_2_UID"
            )
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
    func testHiddenSinkIdentityChangeRebindsAtomicPairLease() {
        let lease = DefaultInputCoordinatorLeaseFake()
        let coordinator = WorldwideBlackHoleDefaultInputCoordinator(
            policy: .enabled,
            lease: lease
        )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        _ = coordinator.transportDidBecomeHealthy(peerGeneration: 1)
        guard case .selected(let first) = coordinator.updateDeviceSnapshot(
            snapshot(epoch: epoch, generation: 1)
        ) else {
            return XCTFail("Expected the validated pair to acquire the visible input lease")
        }

        let replacement = BlackHoleDeviceAvailabilitySnapshot(
            monitorEpoch: epoch,
            deviceGeneration: 2,
            defaultInputEndpoint: .init(
                deviceID: 79,
                deviceUID: "BlackHole2ch_UID"
            ),
            hiddenMirrorSinkEndpoint: .init(
                deviceID: 90,
                deviceUID: "BlackHole2ch_2_UID"
            )
        )
        guard case .selected(let second) = coordinator
            .updateDeviceSnapshot(replacement) else {
            return XCTFail("Expected hidden-sink replacement to rebind the atomic pair")
        }

        XCTAssertNotEqual(first.leaseGeneration, second.leaseGeneration)
        XCTAssertEqual(lease.releases, [first.leaseGeneration])
        XCTAssertEqual(
            lease.acquisitions.map(\.targetUID),
            ["BlackHole2ch_UID", "BlackHole2ch_UID"]
        )
        XCTAssertEqual(
            lease.acquisitions.map(\.targetDeviceID),
            [79, 79]
        )
    }

    func testTransientPairRevalidationFailureReleasesAndSameGenerationCanRecover() {
        let lease = DefaultInputCoordinatorLeaseFake()
        let coordinator = WorldwideBlackHoleDefaultInputCoordinator(
            policy: .enabled,
            lease: lease
        )
        let epoch = UUID()
        let current = snapshot(epoch: epoch, generation: 1)

        _ = coordinator.beginMonitoring(epoch: epoch)
        _ = coordinator.transportDidBecomeHealthy(peerGeneration: 1)
        guard case .selected(let first) = coordinator
            .updateDeviceSnapshot(current) else {
            return XCTFail("Expected the initial pair to acquire the lease")
        }

        XCTAssertEqual(
            coordinator.deviceRevalidationDidFail(),
            .degraded
        )
        XCTAssertEqual(lease.releases, [first.leaseGeneration])

        guard case .selected(let recovered) = coordinator
            .updateDeviceSnapshot(current) else {
            return XCTFail("Expected the same factual generation to recover after fresh validation")
        }
        XCTAssertNotEqual(first.leaseGeneration, recovered.leaseGeneration)
    }

    func testVisibleSameUIDReplacementPassesNewExactIdentityToLease() {
        let lease = DefaultInputCoordinatorLeaseFake()
        let coordinator = WorldwideBlackHoleDefaultInputCoordinator(
            policy: .enabled,
            lease: lease
        )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        _ = coordinator.transportDidBecomeHealthy(peerGeneration: 1)
        guard case .selected(let first) = coordinator
            .updateDeviceSnapshot(
                snapshot(epoch: epoch, generation: 1)
            ) else {
            return XCTFail("Expected initial exact visible endpoint selection")
        }

        let replacement = BlackHoleDeviceAvailabilitySnapshot(
            monitorEpoch: epoch,
            deviceGeneration: 2,
            defaultInputEndpoint: .init(
                deviceID: 80,
                deviceUID: "BlackHole2ch_UID"
            ),
            hiddenMirrorSinkEndpoint: .init(
                deviceID: 89,
                deviceUID: "BlackHole2ch_2_UID"
            )
        )
        guard case .selected(let second) = coordinator
            .updateDeviceSnapshot(replacement) else {
            return XCTFail("Expected replacement exact visible endpoint selection")
        }

        XCTAssertEqual(first.deviceEndpoint.deviceID, 79)
        XCTAssertEqual(second.deviceEndpoint.deviceID, 80)
        XCTAssertEqual(
            lease.acquisitions.map(\.targetDeviceID),
            [79, 80]
        )
        XCTAssertEqual(
            lease.acquisitions.map(\.targetUID),
            ["BlackHole2ch_UID", "BlackHole2ch_UID"]
        )
        XCTAssertEqual(lease.releases, [first.leaseGeneration])
    }

    func testHigherPairGenerationRebindsWhenCoreAudioReusesEndpointIDs() {
        let lease = DefaultInputCoordinatorLeaseFake()
        let coordinator = WorldwideBlackHoleDefaultInputCoordinator(
            policy: .enabled,
            lease: lease
        )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        _ = coordinator.transportDidBecomeHealthy(peerGeneration: 1)
        guard case .selected(let first) = coordinator
            .updateDeviceSnapshot(
                snapshot(epoch: epoch, generation: 1)
            ) else {
            return XCTFail("Expected the initial pair generation to acquire")
        }

        guard case .selected(let second) = coordinator
            .updateDeviceSnapshot(
                snapshot(epoch: epoch, generation: 2)
            ) else {
            return XCTFail(
                "A listener-proven endpoint reincarnation must rebind even when Core Audio reused both IDs"
            )
        }

        XCTAssertNotEqual(first.leaseGeneration, second.leaseGeneration)
        XCTAssertEqual(first.deviceEndpoint, second.deviceEndpoint)
        XCTAssertEqual(lease.releases, [first.leaseGeneration])
        XCTAssertEqual(
            lease.acquisitions.map(\.targetDeviceID),
            [79, 79]
        )
    }

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
        XCTAssertEqual(key.deviceEndpoint.deviceID, 79)
        XCTAssertEqual(key.deviceEndpoint.deviceUID, "BlackHole2ch_UID")
        XCTAssertEqual(lease.acquisitions.count, 1)
        XCTAssertEqual(lease.acquisitions[0].targetDeviceID, 79)
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
                snapshot(epoch: epoch, generation: 1)
            ),
            .noChange,
            "A duplicate snapshot from the same generation must remain idempotent."
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
            .degraded
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

        for _ in 0..<512 {
            XCTAssertEqual(
                coordinator.updateDeviceSnapshot(
                    snapshot(
                        epoch: epoch,
                        generation: 1
                    )
                ),
                .noChange
            )
        }

        XCTAssertEqual(lease.acquisitions.count, 1)
        XCTAssertTrue(lease.releases.isEmpty)
    }

    func testPostAdmissionExternalDefaultInputEventRevokesAndCannotReassertSameConnection() {
        let lease = DefaultInputCoordinatorLeaseFake(
            releaseResults: [.externallySuperseded]
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
        guard case .selected(let admitted) =
                coordinator.transportDidBecomeHealthy(
                    peerGeneration: 1
                ) else {
            return XCTFail("Expected exact default-input admission")
        }

        guard case .selected(let refreshed) =
                coordinator.transportDidBecomeHealthy(
                    peerGeneration: 1
                ) else {
            return XCTFail(
                "The same-key path must return a freshly verified proof"
            )
        }
        XCTAssertEqual(
            admitted.leaseGeneration,
            refreshed.leaseGeneration
        )
        XCTAssertGreaterThanOrEqual(
            lease.authorizationProofCallCount,
            2
        )

        let incorporatedEvent =
            BlackHoleDefaultInputLeaseUncertaintyEvent(
                leaseGeneration: refreshed.leaseGeneration,
                listenerRegistrationID:
                    refreshed.inputAuthorization
                        .listenerRegistrationID,
                listenerSequence:
                    refreshed.inputAuthorization
                        .acceptedListenerSequence
            )
        XCTAssertEqual(
            coordinator.defaultInputDidBecomeUncertain(
                incorporatedEvent
            ),
            .noChange
        )
        XCTAssertTrue(lease.releases.isEmpty)

        let externalEvent =
            BlackHoleDefaultInputLeaseUncertaintyEvent(
                leaseGeneration: refreshed.leaseGeneration,
                listenerRegistrationID:
                    refreshed.inputAuthorization
                        .listenerRegistrationID,
                listenerSequence:
                    refreshed.inputAuthorization
                        .acceptedListenerSequence + 1
            )
        XCTAssertEqual(
            coordinator.defaultInputDidBecomeUncertain(externalEvent),
            .degraded
        )
        XCTAssertEqual(lease.releases, [refreshed.leaseGeneration])
        XCTAssertEqual(
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 1
            ),
            .degraded,
            "The same connection must not overwrite the external choice."
        )
        XCTAssertEqual(lease.acquisitions.count, 1)
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
            lease.acquisitions.count,
            2
        )
        guard case .selected(let refreshed) =
                coordinator.transportDidBecomeHealthy(
                    peerGeneration: 2
                ) else {
            return XCTFail(
                "The replacement must return a fresh same-key proof."
            )
        }
        XCTAssertEqual(refreshed.leaseGeneration, key.leaseGeneration)
        XCTAssertEqual(lease.acquisitions.count, 2)
    }

    private func snapshot(
        epoch: UUID,
        generation: UInt64
    ) -> BlackHoleDeviceAvailabilitySnapshot {
        BlackHoleDeviceAvailabilitySnapshot(
            monitorEpoch: epoch,
            deviceGeneration: generation,
            defaultInputEndpoint: .init(
                deviceID: 79,
                deviceUID: "BlackHole2ch_UID"
            ),
            hiddenMirrorSinkEndpoint: .init(
                deviceID: 89,
                deviceUID: "BlackHole2ch_2_UID"
            )
        )
    }
}

private final class DefaultInputCoordinatorLeaseFake:
    WorldwideBlackHoleDefaultInputLeasing,
    @unchecked Sendable
{
    struct Acquisition {
        let generation: UInt64
        let targetEndpoint: BlackHoleDeviceEndpointIdentity

        var targetUID: String {
            targetEndpoint.deviceUID
        }

        var targetDeviceID: AudioDeviceID {
            targetEndpoint.deviceID
        }
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
    private var listenerRegistrationIDs: [UInt64: UUID] = [:]
    private(set) var authorizationProofCallCount = 0

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
        targetEndpoint: BlackHoleDeviceEndpointIdentity
    ) -> BlackHoleDefaultInputLeaseAcquisitionResult {
        events.append(.acquisition(generation))
        acquisitions.append(
            Acquisition(
                generation: generation,
                targetEndpoint: targetEndpoint
            )
        )
        guard !acquisitionResults.isEmpty else {
            return .acquired
        }
        return acquisitionResults.removeFirst()
    }

    func authorizationProof(
        generation: UInt64,
        targetEndpoint: BlackHoleDeviceEndpointIdentity
    ) -> BlackHoleDefaultInputLeaseAuthorization? {
        authorizationProofCallCount += 1
        let registrationID: UUID
        if let existing = listenerRegistrationIDs[generation] {
            registrationID = existing
        } else {
            registrationID = UUID()
            listenerRegistrationIDs[generation] = registrationID
        }
        return BlackHoleDefaultInputLeaseAuthorization(
            leaseGeneration: generation,
            listenerRegistrationID: registrationID,
            acceptedListenerSequence: 1,
            targetEndpoint: targetEndpoint
        )
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
    private let automaticallyAdvanceInboundMedia: Bool
    private var currentPeer: DriverTestPeer?
    private var currentPeerGeneration: UInt64 = 0
    private var nextInboundCounter: UInt64 = 100

    init(
        policy:
            WorldwideIPhoneMicrophoneForwardingPolicy = .enabled,
        factory: DriverTestOutputFactory,
        readinessGate: DriverSuspensionGate? = nil,
        readinessSampleLimit: Int = 2,
        retryGate: DriverSuspensionGate? = nil,
        maximumAttemptCountPerKey: Int = 3,
        maximumStaleInboundMediaSamples: Int = 3,
        mediaFreshnessTimeoutNanoseconds: UInt64 = 3_000_000_000,
        mediaFreshnessWatchdog:
            DriverTestMediaFreshnessWatchdog? = nil,
        automaticallyAdvanceInboundMedia: Bool = true
    ) {
        self.automaticallyAdvanceInboundMedia =
            automaticallyAdvanceInboundMedia
        driver = WorldwideIPhoneMicrophoneForwardingDriver(
            policy: policy,
            makeOutput: { _, endpoint in
                factory.makeOutput(endpoint: endpoint)
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
            maximumStaleInboundMediaSamples:
                maximumStaleInboundMediaSamples,
            mediaFreshnessTimeoutNanoseconds:
                mediaFreshnessTimeoutNanoseconds,
            mediaFreshnessNow: {
                mediaFreshnessWatchdog?.now
                    ?? DispatchTime.now().uptimeNanoseconds
            },
            mediaFreshnessDeadlineSleep: { deadline in
                if let mediaFreshnessWatchdog {
                    try await mediaFreshnessWatchdog.sleep(
                        until: deadline
                    )
                } else {
                    while true {
                        let now =
                            DispatchTime.now().uptimeNanoseconds
                        guard now < deadline else { return }
                        try await Task.sleep(
                            nanoseconds: deadline - now
                        )
                    }
                }
            },
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
        currentPeer = peer
        currentPeerGeneration = generation
        driver.replacePeer(
            peer: peer,
            peerGeneration: generation
        )
    }

    func installTrack(_ track: DriverTestTrack) async {
        await driver.installTrack(track)
        await automaticallyPublishAdvancingInboundMediaIfNeeded()
    }

    func authorize(
        peer: DriverTestPeer,
        generation: UInt64
    ) async {
        await driver.authorizeTransport(
            peer: peer,
            peerGeneration: generation
        )
        await automaticallyPublishAdvancingInboundMediaIfNeeded()
    }

    func invalidateTransport() {
        driver.invalidateTransport()
    }

    func updateDevice(
        _ snapshot: BlackHoleDeviceAvailabilitySnapshot
    ) async {
        await driver.updateDeviceSnapshot(snapshot)
        await automaticallyPublishAdvancingInboundMediaIfNeeded()
    }

    func handleRuntimeFailure(
        _ output: DriverTestOutput,
        category:
            WorldwideIPhoneMicrophoneForwardingFailureCategory =
                .runtimeEnqueueFailed
    ) async -> Bool {
        let handled = await driver.handleRuntimeFailure(
            from: output,
            category: category
        )
        await automaticallyPublishAdvancingInboundMediaIfNeeded()
        return handled
    }

    func publishInboundMedia(
        packets: UInt64?,
        bytes: UInt64?,
        jitterBufferEmittedCount: UInt64? = nil,
        totalSamplesReceived: UInt64? = nil,
        peer: DriverTestPeer? = nil,
        generation: UInt64? = nil
    ) async {
        guard let sourcePeer = peer ?? currentPeer else { return }
        await driver.updateInboundMediaFreshness(
            peer: sourcePeer,
            peerGeneration: generation ?? currentPeerGeneration,
            watermark:
                WorldwideIPhoneMicrophoneInboundMediaWatermark(
                    packetsReceived: packets,
                    bytesReceived: bytes,
                    jitterBufferEmittedCount:
                        jitterBufferEmittedCount,
                    totalSamplesReceived: totalSamplesReceived
                )
        )
    }

    private func automaticallyPublishAdvancingInboundMediaIfNeeded()
        async {
        guard automaticallyAdvanceInboundMedia,
              driver.snapshot().exactTrackAdmitted,
              let currentPeer else {
            return
        }
        nextInboundCounter &+= 1
        await publishInboundMedia(
            packets: nextInboundCounter,
            bytes: nextInboundCounter * 80,
            peer: currentPeer,
            generation: currentPeerGeneration
        )
        nextInboundCounter &+= 1
        await publishInboundMedia(
            packets: nextInboundCounter,
            bytes: nextInboundCounter * 80,
            peer: currentPeer,
            generation: currentPeerGeneration
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
    private var endpoints: [BlackHoleDeviceEndpointIdentity] = []

    init(outputs: [DriverTestOutput]) {
        self.outputs = outputs
    }

    func makeOutput(
        endpoint: BlackHoleDeviceEndpointIdentity
    ) -> (any WorldwideIPhoneMicrophoneOutput)? {
        lock.withLock {
            requests += 1
            endpoints.append(endpoint)
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
        lock.withLock { endpoints.map(\.deviceUID) }
    }

    var requestedDeviceIDs: [AudioDeviceID] {
        lock.withLock { endpoints.map(\.deviceID) }
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
    private var currentPeer: DriverTestPeer?
    private var currentPeerGeneration: UInt64 = 0
    private var nextInboundCounter: UInt64 = 1_000

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
        currentPeer = peer
        currentPeerGeneration = generation
        driver.replacePeer(
            peer: peer,
            peerGeneration: generation
        )
    }

    func installTrack(
        _ track: DriverTestTrack
    ) async {
        await driver.installTrack(track)
        await publishAdvancingInboundMediaIfNeeded()
    }

    func authorize(
        peer: DriverTestPeer,
        generation: UInt64
    ) async {
        await driver.authorizeTransport(
            peer: peer,
            peerGeneration: generation
        )
        await publishAdvancingInboundMediaIfNeeded()
    }

    func updateDevice(
        _ snapshot:
            BlackHoleDeviceAvailabilitySnapshot
    ) async {
        await driver.updateDeviceSnapshot(snapshot)
        await publishAdvancingInboundMediaIfNeeded()
    }

    func handleRuntimeFailure(
        _ output: BlackHoleMicrophoneOutput
    ) async -> Bool {
        let handled = await driver.handleRuntimeFailure(
            from: output,
            category:
                .runtimeProgressStalled
        )
        await publishAdvancingInboundMediaIfNeeded()
        return handled
    }

    private func publishAdvancingInboundMediaIfNeeded() async {
        guard driver.snapshot().exactTrackAdmitted,
              let currentPeer else {
            return
        }
        nextInboundCounter &+= 1
        await driver.updateInboundMediaFreshness(
            peer: currentPeer,
            peerGeneration: currentPeerGeneration,
            watermark:
                WorldwideIPhoneMicrophoneInboundMediaWatermark(
                    packetsReceived: nextInboundCounter,
                    bytesReceived: nextInboundCounter * 80,
                    jitterBufferEmittedCount: nil,
                    totalSamplesReceived: nil
                )
        )
        nextInboundCounter &+= 1
        await driver.updateInboundMediaFreshness(
            peer: currentPeer,
            peerGeneration: currentPeerGeneration,
            watermark:
                WorldwideIPhoneMicrophoneInboundMediaWatermark(
                    packetsReceived: nextInboundCounter,
                    bytesReceived: nextInboundCounter * 80,
                    jitterBufferEmittedCount: nil,
                    totalSamplesReceived: nil
                )
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
    private var selectedDeviceUIDs: [UInt: String] = [:]
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

    func translateDeviceID(
        exactUID: String
    ) -> (status: OSStatus, deviceID: AudioDeviceID?) {
        guard exactUID
                == WorldwideBlackHoleMicrophoneEndpointContract
                    .hiddenMirrorSinkDeviceUID else {
            return (kAudio_ParamError, nil)
        }
        return (noErr, 89)
    }

    func setCurrentDevice(
        _ uid: String,
        on queue: AudioQueueRef
    ) -> OSStatus {
        lock.withLock {
            selectedDeviceUIDs[Self.identity(queue)] = uid
            return noErr
        }
    }

    func currentDeviceUID(
        on queue: AudioQueueRef
    ) -> (status: OSStatus, uid: String?) {
        lock.withLock {
            (noErr, selectedDeviceUIDs[Self.identity(queue)])
        }
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

private final class DriverTestMediaFreshnessWatchdog:
    @unchecked Sendable
{
    private struct Waiter {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var currentNanoseconds: UInt64
    private var waiters: [Waiter] = []
    private var scheduledDeadlineCount = 0

    init(now: UInt64 = 0) {
        currentNanoseconds = now
    }

    var now: UInt64 {
        lock.withLock { currentNanoseconds }
    }

    func sleep(until deadline: UInt64) async throws {
        if Task.isCancelled {
            throw CancellationError()
        }
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                scheduledDeadlineCount += 1
                guard currentNanoseconds < deadline else {
                    return true
                }
                waiters.append(
                    Waiter(
                        deadline: deadline,
                        continuation: continuation
                    )
                )
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
        if Task.isCancelled {
            throw CancellationError()
        }
    }

    func advance(to nanoseconds: UInt64) {
        setNowWithoutDelivering(to: nanoseconds)
        deliverDueDeadlines()
    }

    func setNowWithoutDelivering(to nanoseconds: UInt64) {
        lock.withLock {
            currentNanoseconds = max(
                currentNanoseconds,
                nanoseconds
            )
        }
    }

    func deliverDueDeadlines() {
        let ready = lock.withLock { () -> [Waiter] in
            let ready = waiters.filter {
                $0.deadline <= currentNanoseconds
            }
            waiters.removeAll {
                $0.deadline <= currentNanoseconds
            }
            return ready
        }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    var scheduleCount: Int {
        lock.withLock { scheduledDeadlineCount }
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
