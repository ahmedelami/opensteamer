#if os(macOS)
import CoreAudio
import Foundation
import XCTest
@testable import CaptureCore

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
#endif
