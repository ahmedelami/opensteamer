import CoreAudio
import CaptureCore
import Foundation
import XCTest
@testable import CaptureServer

@MainActor
final class WorldwideSharedClockEpochRecoveryTests: XCTestCase {
    func testOnlySigned32HeadroomFailureCanStartRecovery() {
        var policy = WorldwideSharedClockEpochRecoveryPolicy()
        let key = forwardingKey(transportAuthorizationEpoch: 7)

        XCTAssertEqual(
            policy.registerFailure(
                key: key,
                rejection: signed32HeadroomRejection()
            ),
            .recover(attempt: 1, maximumAttemptCount: 1)
        )
        XCTAssertEqual(
            policy.registerFailure(
                key: forwardingKey(
                    transportAuthorizationEpoch: 8
                ),
                rejection: .deviceClockRateMismatch(
                    actualFrameDelta: 1,
                    expectedFrameDelta: 2,
                    toleranceFrames: 0.1,
                    elapsedHostNanoseconds: 1
                )
            ),
            .failClosed
        )
    }

    func testRecoveryIsBoundedAcrossFreshTransportAuthorizationKeys() {
        var policy = WorldwideSharedClockEpochRecoveryPolicy()

        XCTAssertEqual(
            policy.registerFailure(
                key: forwardingKey(
                    transportAuthorizationEpoch: 1
                ),
                rejection: signed32HeadroomRejection()
            ),
            .recover(attempt: 1, maximumAttemptCount: 1)
        )
        XCTAssertEqual(
            policy.registerFailure(
                key: forwardingKey(
                    transportAuthorizationEpoch: 2
                ),
                rejection: signed32HeadroomRejection()
            ),
            .failClosed
        )
    }

    func testOnlyNewPeerOrPairGetsASeparateRecoveryBudget() {
        var policy = WorldwideSharedClockEpochRecoveryPolicy()
        let rejection = signed32HeadroomRejection()

        XCTAssertEqual(
            policy.registerFailure(
                key: forwardingKey(peerGeneration: 1),
                rejection: rejection
            ),
            .recover(attempt: 1, maximumAttemptCount: 1)
        )
        XCTAssertEqual(
            policy.registerFailure(
                key: forwardingKey(peerGeneration: 2),
                rejection: rejection
            ),
            .recover(attempt: 1, maximumAttemptCount: 1)
        )
        XCTAssertEqual(
            policy.registerFailure(
                key: forwardingKey(
                    peerGeneration: 2,
                    trackGeneration: 2
                ),
                rejection: rejection
            ),
            .failClosed,
            "Track churn must not reset a peer/pair compatibility budget."
        )

        XCTAssertEqual(
            policy.registerFailure(
                key: forwardingKey(
                    deviceGeneration: 2,
                    peerGeneration: 2,
                    trackGeneration: 2
                ),
                rejection: rejection
            ),
            .recover(attempt: 1, maximumAttemptCount: 1)
        )
        XCTAssertEqual(
            policy.registerFailure(
                key: forwardingKey(
                    monitorEpoch: UUID(
                        uuidString:
                            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                    )!,
                    deviceGeneration: 2,
                    peerGeneration: 2,
                    trackGeneration: 2
                ),
                rejection: rejection
            ),
            .recover(attempt: 1, maximumAttemptCount: 1)
        )
    }

    func testSuccessfulRetryDoesNotRestoreThePeerPairBudget() {
        var policy = WorldwideSharedClockEpochRecoveryPolicy()
        let key = forwardingKey()
        let rejection = signed32HeadroomRejection()

        XCTAssertEqual(
            policy.registerFailure(
                key: key,
                rejection: rejection
            ),
            .recover(attempt: 1, maximumAttemptCount: 1)
        )
        XCTAssertEqual(
            policy.registerFailure(
                key: forwardingKey(
                    transportAuthorizationEpoch: 2
                ),
                rejection: rejection
            ),
            .failClosed
        )
    }

    func testAdmissionRequiresExactNextAuthorizationAndOriginalTrack() {
        let rejected = forwardingKey(
            transportAuthorizationEpoch: 7,
            trackGeneration: 11
        )
        let expected = WorldwideSharedClockEpochRecoveryAdmissionPolicy
            .expectedReplacementKey(after: rejected)

        XCTAssertTrue(
            WorldwideSharedClockEpochRecoveryAdmissionPolicy.accepts(
                currentKey: expected,
                transportAuthorized: true,
                queueRunning: true,
                exactTrackAdmitted: true,
                after: rejected
            )
        )
        XCTAssertFalse(
            WorldwideSharedClockEpochRecoveryAdmissionPolicy.accepts(
                currentKey: forwardingKey(
                    transportAuthorizationEpoch: 8,
                    trackGeneration: 12
                ),
                transportAuthorized: true,
                queueRunning: true,
                exactTrackAdmitted: true,
                after: rejected
            ),
            "Track churn during readmission must fail closed."
        )
        XCTAssertFalse(
            WorldwideSharedClockEpochRecoveryAdmissionPolicy.accepts(
                currentKey: forwardingKey(
                    transportAuthorizationEpoch: 9,
                    trackGeneration: 11
                ),
                transportAuthorized: true,
                queueRunning: true,
                exactTrackAdmitted: true,
                after: rejected
            ),
            "A second authorization epoch must not impersonate the one recovery attempt."
        )
        XCTAssertFalse(
            WorldwideSharedClockEpochRecoveryAdmissionPolicy.accepts(
                currentKey: expected,
                transportAuthorized: true,
                queueRunning: false,
                exactTrackAdmitted: true,
                after: rejected
            )
        )
    }

    func testParkingRouteAllowsLegacyVisibleButRejectsVirtualEndpoints() {
        XCTAssertNotNil(
            WorldwideSharedClockEpochRecoveryParkingRoute(
                defaultInputUID:
                    WorldwideVirtualMicrophoneEndpointContract
                        .retiredLegacyVisibleDeviceUID
            )
        )
        XCTAssertNotNil(
            WorldwideSharedClockEpochRecoveryParkingRoute(
                defaultInputUID: "BuiltInMicrophoneDevice"
            )
        )
        XCTAssertNil(
            WorldwideSharedClockEpochRecoveryParkingRoute(
                defaultInputUID:
                    WorldwideVirtualMicrophoneEndpointContract
                        .visibleDefaultInputDeviceUID
            )
        )
        XCTAssertNil(
            WorldwideSharedClockEpochRecoveryParkingRoute(
                defaultInputUID:
                    WorldwideVirtualMicrophoneEndpointContract
                        .hiddenMirrorSinkDeviceUID
            )
        )
    }

    func testReadmissionDiagnosticReportsEveryAdmissionPredicateAndPhase() {
        let snapshot = WorldwideIPhoneMicrophoneForwardingHostSnapshot
            .inactive(policy: .enabled)

        XCTAssertEqual(
            WorldwideSharedClockEpochRecoveryAdmissionPolicy
                .diagnosticDescription(
                    snapshot: snapshot,
                    after: forwardingKey()
                ),
            "expectedOwnership=false transportAuthorized=false "
                + "queueRunning=false exactTrackAdmitted=false "
                + "phase=waitingForPeer lastFailure=none"
        )
    }

    func testProductionPropertyBoundaryRequiresSystemWideEndpointIdle() throws {
        let visibleID = AudioDeviceID(31)
        let hiddenID = AudioDeviceID(32)
        let parkingRoute = try XCTUnwrap(
            WorldwideSharedClockEpochRecoveryParkingRoute(
                defaultInputUID: "BuiltInMicrophoneDevice"
            )
        )

        let activeDeviceSets: [Set<AudioDeviceID>] = [
            [], [visibleID], [hiddenID], [visibleID, hiddenID],
        ]
        for activeDevices in activeDeviceSets {
            let properties = LockedEpochPropertyReads(
                activeDevices: activeDevices
            )
            let reader = try propertyReader(properties)
            let observation = try reader.observe(
                visibleInputDeviceID: visibleID,
                hiddenWriterDeviceID: hiddenID
            ).get()

            XCTAssertEqual(
                observation.provesGlobalIdleCandidate(parkedOn: parkingRoute),
                activeDevices.isEmpty,
                "Process-local idle must not hide a client in another process."
            )
            XCTAssertEqual(
                properties.reads.map(\.deviceID),
                [visibleID, hiddenID, hiddenID, visibleID]
            )
            for read in properties.reads {
                XCTAssertEqual(
                    read.selector,
                    kAudioDevicePropertyDeviceIsRunningSomewhere
                )
                XCTAssertEqual(read.scope, kAudioObjectPropertyScopeGlobal)
                XCTAssertEqual(read.element, kAudioObjectPropertyElementMain)
                XCTAssertEqual(read.requestedSize, UInt32(MemoryLayout<UInt32>.size))
            }
        }
    }

    func testSystemWidePropertyFailureDoesNotFallBackToProcessLocalIdle() throws {
        let failure = kAudioHardwareUnknownPropertyError
        let properties = LockedEpochPropertyReads(status: failure)

        XCTAssertEqual(
            try propertyReader(properties).observe(
                visibleInputDeviceID: 31,
                hiddenWriterDeviceID: 32
            ),
            .failure(.coreAudioStatus(failure))
        )
        XCTAssertEqual(properties.reads.count, 1)
        XCTAssertEqual(
            properties.reads.first?.selector,
            kAudioDevicePropertyDeviceIsRunningSomewhere
        )
    }

    func testSystemWidePropertyRejectsMalformedSizes() throws {
        let malformedSizes: [UInt32] = [0, 3, 8]
        for size in malformedSizes {
            let properties = LockedEpochPropertyReads(returnedSize: size)
            XCTAssertEqual(
                try propertyReader(properties).observe(
                    visibleInputDeviceID: 31,
                    hiddenWriterDeviceID: 32
                ),
                .failure(.unexpectedPropertySize(size))
            )
            XCTAssertEqual(properties.reads.count, 1)
        }
    }

    func testInvalidEndpointDoesNotReadSystemWideProperty() throws {
        let properties = LockedEpochPropertyReads()
        XCTAssertEqual(
            try propertyReader(properties).observe(
                visibleInputDeviceID: kAudioObjectUnknown,
                hiddenWriterDeviceID: 32
            ),
            .failure(.invalidDevice)
        )
        XCTAssertTrue(properties.reads.isEmpty)
    }

    func testPublicIdleCannotOverrideAnActiveOrChangedDriverEpoch() throws {
        let route = try XCTUnwrap(
            WorldwideSharedClockEpochRecoveryParkingRoute(defaultInputUID: "BuiltInMicrophoneDevice")
        )
        for changedMode in ["active", "new-instance", "new-lifecycle", "new-session", "new-seed"] {
            let diagnostics = try driverDiagnostics(["idle", "idle", changedMode, "idle"])
            let reader = WorldwideVirtualMicrophoneEpochStateReader(
                readDeviceRunning: { _ in .success(false) },
                readDefaultInputUID: { .success("BuiltInMicrophoneDevice") },
                readDriverDiagnostic: { diagnostics.read($0) }
            )
            let observation = try reader.observe(
                visibleInputDeviceID: 31,
                hiddenWriterDeviceID: 32
            ).get()
            XCTAssertFalse(observation.provesGlobalIdleCandidate(parkedOn: route))
            XCTAssertEqual(diagnostics.readOrder, [31, 32, 32, 31])
        }
    }

    func testDriverDiagnosticReadFailureKeepsPublicIdleUnproved() {
        let failure = WorldwideVirtualMicrophoneDriverDiagnosticError.property(kAudioHardwareUnknownPropertyError)
        let reader = WorldwideVirtualMicrophoneEpochStateReader(
            readDeviceRunning: { _ in .success(false) },
            readDefaultInputUID: { .success("BuiltInMicrophoneDevice") },
            readDriverDiagnostic: { _ in .failure(failure) }
        )
        XCTAssertEqual(
            reader.observe(visibleInputDeviceID: 31, hiddenWriterDeviceID: 32),
            .failure(.driverDiagnostics(failure))
        )
    }

    func testReaderRequiresTwoPassIdleAcrossBothEndpoints() throws {
        let visibleID = AudioDeviceID(41)
        let hiddenID = AudioDeviceID(42)
        let reads = LockedRunningReads([
            visibleID: [false, false],
            hiddenID: [false, false],
        ])
        let reader = WorldwideVirtualMicrophoneEpochStateReader(
            readDeviceRunning: { deviceID in
                reads.read(deviceID)
            },
            readDefaultInputUID: {
                .success(
                    WorldwideVirtualMicrophoneEndpointContract
                        .retiredLegacyVisibleDeviceUID
                )
            },
            readDriverDiagnostic: try idleDriverDiagnostics()
        )

        let observation = try reader.observe(
            visibleInputDeviceID: visibleID,
            hiddenWriterDeviceID: hiddenID
        ).get()

        let parkingRoute = try XCTUnwrap(
            WorldwideSharedClockEpochRecoveryParkingRoute(
                defaultInputUID:
                    WorldwideVirtualMicrophoneEndpointContract
                        .retiredLegacyVisibleDeviceUID
            )
        )
        XCTAssertTrue(
            observation.provesGlobalIdleCandidate(
                parkedOn: parkingRoute
            )
        )
        XCTAssertEqual(reads.readOrder, [visibleID, hiddenID, hiddenID, visibleID])
    }

    func testReaderRejectsAnEndpointThatStartsBetweenPasses() throws {
        let visibleID = AudioDeviceID(51)
        let hiddenID = AudioDeviceID(52)
        let reads = LockedRunningReads([
            visibleID: [false, true],
            hiddenID: [false, false],
        ])
        let reader = WorldwideVirtualMicrophoneEpochStateReader(
            readDeviceRunning: { deviceID in
                reads.read(deviceID)
            },
            readDefaultInputUID: {
                .success(
                    WorldwideVirtualMicrophoneEndpointContract
                        .retiredLegacyVisibleDeviceUID
                )
            },
            readDriverDiagnostic: try idleDriverDiagnostics()
        )

        let observation = try reader.observe(
            visibleInputDeviceID: visibleID,
            hiddenWriterDeviceID: hiddenID
        ).get()

        let parkingRoute = try XCTUnwrap(
            WorldwideSharedClockEpochRecoveryParkingRoute(
                defaultInputUID:
                    WorldwideVirtualMicrophoneEndpointContract
                        .retiredLegacyVisibleDeviceUID
            )
        )
        XCTAssertFalse(
            observation.provesGlobalIdleCandidate(
                parkedOn: parkingRoute
            )
        )
    }

    func testReaderRejectsParkingRouteChangeAcrossIdlePasses() throws {
        let visibleID = AudioDeviceID(61)
        let hiddenID = AudioDeviceID(62)
        let reads = LockedRunningReads([
            visibleID: [false, false],
            hiddenID: [false, false],
        ])
        let defaultInputs = LockedDefaultInputUIDReads([
            WorldwideVirtualMicrophoneEndpointContract
                .retiredLegacyVisibleDeviceUID,
            "ExternalMicrophoneDevice",
        ])
        let reader = WorldwideVirtualMicrophoneEpochStateReader(
            readDeviceRunning: { deviceID in
                reads.read(deviceID)
            },
            readDefaultInputUID: {
                defaultInputs.read()
            },
            readDriverDiagnostic: try idleDriverDiagnostics()
        )
        let parkingRoute = try XCTUnwrap(
            WorldwideSharedClockEpochRecoveryParkingRoute(
                defaultInputUID:
                    WorldwideVirtualMicrophoneEndpointContract
                        .retiredLegacyVisibleDeviceUID
            )
        )
        let observation = try reader.observe(
            visibleInputDeviceID: visibleID,
            hiddenWriterDeviceID: hiddenID
        ).get()

        XCTAssertFalse(
            observation.provesGlobalIdleCandidate(
                parkedOn: parkingRoute
            )
        )
    }

    func testQuiescenceRequiresConsecutiveIdleObservations() {
        var proof = WorldwideVirtualMicrophoneEpochQuiescenceProof(
            requiredConsecutiveIdleObservations: 2
        )

        XCTAssertFalse(proof.consume(.idle))
        XCTAssertFalse(proof.consume(.active))
        XCTAssertFalse(proof.consume(.idle))
        XCTAssertFalse(proof.consume(.unreadable))
        XCTAssertFalse(proof.consume(.idle))
        XCTAssertTrue(proof.consume(.idle))
    }

    func testPollerRequiresTwoIdleSamplesAcrossActiveAndUnreadableReads()
        async {
        let samples = LockedEpochSamples([
            .idle,
            .active,
            .idle,
            .unreadable,
            .idle,
            .idle,
        ])
        let poller = WorldwideSharedClockEpochRecoveryPoller(
            maximumPollCount: 6,
            requiredConsecutiveIdleObservations: 2
        )

        let outcome = await poller.wait(
            sleep: {},
            isCurrent: { true },
            sample: { samples.read() }
        )

        XCTAssertEqual(outcome, .idleProven)
        XCTAssertEqual(samples.readCount, 6)
    }

    func testPollerFailsClosedForTimeoutStaleOwnerAndCancellation()
        async {
        let timeoutPoller = WorldwideSharedClockEpochRecoveryPoller(
            maximumPollCount: 2,
            requiredConsecutiveIdleObservations: 2
        )
        let timedOut = await timeoutPoller.wait(
            sleep: {},
            isCurrent: { true },
            sample: { .unreadable }
        )
        XCTAssertEqual(timedOut, .timedOut)

        var currentChecks = 0
        let staleOwner = await timeoutPoller.wait(
            sleep: {},
            isCurrent: {
                currentChecks += 1
                return currentChecks == 1
            },
            sample: { .idle }
        )
        XCTAssertEqual(staleOwner, .staleOwner)

        let cancelled = await timeoutPoller.wait(
            sleep: { throw CancellationError() },
            isCurrent: { true },
            sample: { .idle }
        )
        XCTAssertEqual(cancelled, .cancelled)
    }

    private func forwardingKey(
        monitorEpoch: UUID = UUID(
            uuidString: "11111111-2222-3333-4444-555555555555"
        )!,
        deviceGeneration: UInt64 = 1,
        peerGeneration: UInt64 = 1,
        transportAuthorizationEpoch: UInt64 = 1,
        trackGeneration: UInt64 = 1
    ) -> WorldwideIPhoneMicrophoneForwardingKey {
        WorldwideIPhoneMicrophoneForwardingKey(
            monitorEpoch: monitorEpoch,
            deviceGeneration: deviceGeneration,
            peerGeneration: peerGeneration,
            transportAuthorizationEpoch:
                transportAuthorizationEpoch,
            trackGeneration: trackGeneration
        )
    }

    private func propertyReader(
        _ properties: LockedEpochPropertyReads
    ) throws -> WorldwideVirtualMicrophoneEpochStateReader {
        WorldwideVirtualMicrophoneEpochStateReader(
            readUInt32Property: { deviceID, address, size, value in
                properties.read(deviceID, address, &size, &value)
            },
            readDefaultInputUID: {
                .success("BuiltInMicrophoneDevice")
            },
            readDriverDiagnostic: try idleDriverDiagnostics()
        )
    }

    private func idleDriverDiagnostics() throws
        -> WorldwideVirtualMicrophoneEpochStateReader.DriverDiagnosticRead {
        let reads = try driverDiagnostics(["idle", "idle", "idle", "idle"])
        return { deviceID in reads.read(deviceID) }
    }

    private func driverDiagnostics(_ modes: [String]) throws -> LockedDriverDiagnosticReads {
        let snapshots = try modes.enumerated().map { index, mode in
            try WorldwideVirtualMicrophoneDriverDiagnosticSnapshot.decode(
                VirtualMicrophoneDiagnosticFixture.data(
                    mode, sequence: UInt64(index + 1), capturedHostTicks: UInt64(index + 101)
                )
            ).get()
        }
        return LockedDriverDiagnosticReads(snapshots.map { .success($0) })
    }

    private func signed32HeadroomRejection()
        -> BlackHoleFaceTimeClockRejection {
        .insufficientSigned32Headroom(
            observation: BlackHoleFaceTimeClockObservation(
                deviceSampleTime: 17_880_000_000,
                deviceHostTime: 1,
                deviceSampleRate: 48_000,
                projectedFaceTimeSampleTime: 8_940_000_000
            ),
            maximumProjectedSampleTime:
                BlackHoleFaceTimeClockPolicy
                    .maximumProjectedSampleTime
        )
    }
}

private final class LockedDriverDiagnosticReads: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<WorldwideVirtualMicrophoneDriverDiagnosticSnapshot,
                                WorldwideVirtualMicrophoneDriverDiagnosticError>]
    private var order: [AudioDeviceID] = []

    init(_ values: [Result<WorldwideVirtualMicrophoneDriverDiagnosticSnapshot,
                          WorldwideVirtualMicrophoneDriverDiagnosticError>]) {
        self.values = values
    }

    func read(_ deviceID: AudioDeviceID) -> Result<
        WorldwideVirtualMicrophoneDriverDiagnosticSnapshot,
        WorldwideVirtualMicrophoneDriverDiagnosticError
    > {
        lock.withLock {
            order.append(deviceID)
            return values.isEmpty ? .failure(.staleObservation) : values.removeFirst()
        }
    }

    var readOrder: [AudioDeviceID] { lock.withLock { order } }
}

private final class LockedEpochPropertyReads: @unchecked Sendable {
    struct Read: Sendable {
        let deviceID: AudioDeviceID
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
        let element: AudioObjectPropertyElement
        let requestedSize: UInt32
    }

    private let lock = NSLock()
    private let activeDevices: Set<AudioDeviceID>
    private let status: OSStatus
    private let returnedSize: UInt32
    private var recordedReads: [Read] = []

    init(
        activeDevices: Set<AudioDeviceID> = [],
        status: OSStatus = noErr,
        returnedSize: UInt32 = UInt32(MemoryLayout<UInt32>.size)
    ) {
        self.activeDevices = activeDevices
        self.status = status
        self.returnedSize = returnedSize
    }

    func read(
        _ deviceID: AudioDeviceID,
        _ address: AudioObjectPropertyAddress,
        _ size: inout UInt32,
        _ value: inout UInt32
    ) -> OSStatus {
        lock.withLock {
            recordedReads.append(
                Read(
                    deviceID: deviceID,
                    selector: address.mSelector,
                    scope: address.mScope,
                    element: address.mElement,
                    requestedSize: size
                )
            )
        }
        size = returnedSize
        // The old process-local selector always sees the idle host. Only the
        // system-wide selector exposes this other process's active client.
        value = address.mSelector == kAudioDevicePropertyDeviceIsRunningSomewhere
            && activeDevices.contains(deviceID) ? 1 : 0
        return status
    }

    var reads: [Read] {
        lock.withLock { recordedReads }
    }
}

private final class LockedRunningReads: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AudioDeviceID: [Bool]]
    private var order: [AudioDeviceID] = []

    init(_ values: [AudioDeviceID: [Bool]]) {
        self.values = values
    }

    func read(
        _ deviceID: AudioDeviceID
    ) -> Result<Bool, WorldwideVirtualMicrophoneEpochStateReadError> {
        lock.lock()
        defer { lock.unlock() }
        order.append(deviceID)
        guard var deviceValues = values[deviceID],
              !deviceValues.isEmpty else {
            return .failure(.invalidDevice)
        }
        let value = deviceValues.removeFirst()
        values[deviceID] = deviceValues
        return .success(value)
    }

    var readOrder: [AudioDeviceID] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }
}

private final class LockedDefaultInputUIDReads: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func read()
        -> Result<
            String,
            WorldwideVirtualMicrophoneEpochStateReadError
        > {
        lock.withLock {
            guard !values.isEmpty else {
                return .failure(.invalidDefaultInputUID)
            }
            return .success(values.removeFirst())
        }
    }
}

private final class LockedEpochSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples:
        [WorldwideVirtualMicrophoneEpochQuiescenceSample]
    private var count = 0

    init(
        _ samples:
            [WorldwideVirtualMicrophoneEpochQuiescenceSample]
    ) {
        self.samples = samples
    }

    func read()
        -> WorldwideVirtualMicrophoneEpochQuiescenceSample {
        lock.withLock {
            count += 1
            guard !samples.isEmpty else {
                return .unreadable
            }
            return samples.removeFirst()
        }
    }

    var readCount: Int {
        lock.withLock { count }
    }
}
