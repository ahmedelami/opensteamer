#if os(macOS) && DEBUG
import CaptureCore
import Foundation
import XCTest
@testable import CaptureServer

final class WorldwideIPhoneMicrophoneForwardingDriverTests:
    XCTestCase
{
    func testMissingDeviceThenStartFailureRetriesOnlyOnNewDeviceGeneration()
        async {
        let failing = DriverTestOutput(
            startError: DriverTestError.start
        )
        let ready = DriverTestOutput(
            progressSnapshots: readyProgressSnapshots()
        )
        let factory = DriverTestOutputFactory(
            outputs: [failing, ready]
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

        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 2,
                available: true
            )
        )
        XCTAssertEqual(factory.requestCount, 1)
        XCTAssertEqual(failing.startCount, 1)
        XCTAssertFalse(track.isEnabled)
        let startFailedPhase = await harness.snapshot().phase
        XCTAssertEqual(
            startFailedPhase,
            .startFailed
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
            1,
            "The same device generation must never retry."
        )

        await harness.updateDevice(
            snapshot(
                epoch: epoch,
                generation: 3,
                available: true
            )
        )
        let final = await harness.snapshot()
        XCTAssertEqual(factory.requestCount, 2)
        XCTAssertEqual(ready.startCount, 1)
        XCTAssertTrue(track.isEnabled)
        XCTAssertEqual(final.phase, .forwardingHealthy)
        XCTAssertTrue(final.exactTrackAdmitted)
        XCTAssertEqual(final.monitorEpoch, epoch)
        XCTAssertEqual(final.deviceGeneration, 3)
        XCTAssertEqual(final.deviceUID, "BlackHole2ch_UID")
        XCTAssertEqual(
            final.currentKey?.deviceGeneration,
            3
        )
        XCTAssertEqual(
            final.currentKey?.transportAuthorizationEpoch,
            1
        )
        XCTAssertEqual(
            factory.requestedUIDs,
            ["BlackHole2ch_UID", "BlackHole2ch_UID"]
        )
    }

    func testOutputUnavailableDoesNotRetryUntilNewDeviceGeneration()
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

        XCTAssertEqual(factory.requestCount, 1)
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
        XCTAssertEqual(factory.requestCount, 1)

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

        XCTAssertEqual(factory.requestCount, 2)
        let forwardingHealthyPhase = await harness.snapshot().phase
        XCTAssertEqual(
            forwardingHealthyPhase,
            .forwardingHealthy
        )
        XCTAssertTrue(track.isEnabled)
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

        let staleRuntimeFailureHandled = await harness.handleRuntimeFailure(first)
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
        XCTAssertFalse(track.isEnabled)
        XCTAssertEqual(second.stopCount, 1)
        let runtimeFailedPhase = await harness.snapshot().phase
        XCTAssertEqual(
            runtimeFailedPhase,
            .runtimeFailed
        )
        let repeatedRuntimeFailureHandled = await harness.handleRuntimeFailure(second)
        XCTAssertFalse(
            repeatedRuntimeFailureHandled
        )
        XCTAssertEqual(second.stopCount, 1)
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

    func testCallbackAndSilenceProgressWithoutSuccessfulFramesIsNotReady()
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
            ]
        )
        let factory = DriverTestOutputFactory(outputs: [output])
        let harness = DriverTestHarness(
            factory: factory,
            readinessSampleLimit: 2
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

        let result = await harness.snapshot()
        XCTAssertEqual(result.phase, .readinessFailed)
        XCTAssertEqual(
            result.lastFailureCategory,
            .readinessFailed
        )
        XCTAssertFalse(track.isEnabled)
        XCTAssertEqual(output.stopCount, 1)
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
    func testDeviceBeforeConnectionSelectsAtHealthyBoundaryWithoutTrack() {
        let lease = DefaultInputCoordinatorLeaseFake()
        let coordinator =
            WorldwideBlackHoleDefaultInputCoordinator(
                policy: .enabled,
                lease: lease
            )
        let epoch = UUID()

        _ = coordinator.beginMonitoring(epoch: epoch)
        XCTAssertEqual(
            coordinator.updateDeviceSnapshot(
                snapshot(epoch: epoch, generation: 1)
            ),
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
        XCTAssertEqual(
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 3
            ),
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

    func testRemovalRestoresAndReinstallReusesConnectionLeaseGeneration() {
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
        XCTAssertEqual(
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
        XCTAssertEqual(
            coordinator.transportDidBecomeHealthy(
                peerGeneration: 1
            ),
            .suppressed
        )
        XCTAssertEqual(lease.acquisitions.count, 0)
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

    private(set) var acquisitions: [Acquisition] = []
    private(set) var releases: [UInt64] = []

    func acquire(
        generation: UInt64,
        targetUID: String
    ) -> Bool {
        acquisitions.append(
            Acquisition(
                generation: generation,
                targetUID: targetUID
            )
        )
        return true
    }

    func release(generation: UInt64) {
        releases.append(generation)
    }

    func shutdown() {}
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
        readinessSampleLimit: Int = 2
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
            readinessSampleLimit: readinessSampleLimit
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
        _ output: DriverTestOutput
    ) -> Bool {
        driver.handleRuntimeFailure(from: output)
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
