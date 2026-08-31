import Foundation
@testable import CaptureServer
import WebRTCTransport
import XCTest

final class WorldwideScreenMediaSuspensionCoordinatorTests: XCTestCase {
    func testUnnegotiatedViewerKeepsTheActiveNonzeroFloor() {
        var coordinator = WorldwideScreenMediaSuspensionCoordinator()
        let binding = makeBinding()

        XCTAssertTrue(coordinator.activate(screenRequestID: 42, binding: binding))
        XCTAssertNil(
            coordinator.beginSuspensionIfNegotiated(
                negotiated: false,
                binding: binding
            )
        )
        XCTAssertEqual(coordinator.activeScreenRequestID, 42)
        XCTAssertTrue(coordinator.owns(binding))
        XCTAssertFalse(coordinator.suspensionIsInFlight)
        XCTAssertFalse(coordinator.isAutomaticallySuspended)
    }

    func testCoverAndInactiveMustBothFinishBeforeResumeAndHideRebindsEpoch() throws {
        let originalBinding = makeBinding(visibilityCommandEpoch: 7)
        let hiddenBinding = makeBinding(visibilityCommandEpoch: 8)

        for coverFirst in [true, false] {
            var coordinator = WorldwideScreenMediaSuspensionCoordinator()
            XCTAssertTrue(
                coordinator.activate(screenRequestID: 42, binding: originalBinding)
            )
            let notice = try XCTUnwrap(
                coordinator.beginSuspensionIfNegotiated(
                    negotiated: true,
                    binding: originalBinding
                )
            )
            let covered = WebRTCScreenMediaCoveredAcknowledgement(
                suspension: notice
            )

            if coverFirst {
                XCTAssertTrue(
                    coordinator.confirmCover(covered, binding: originalBinding)
                )
                XCTAssertFalse(coordinator.isAutomaticallySuspended)
                XCTAssertFalse(
                    coordinator.beginResumeAttempt(
                        attemptID: makeAttemptID(),
                        binding: originalBinding
                    )
                )
                XCTAssertTrue(
                    coordinator.confirmInactive(
                        for: notice,
                        binding: hiddenBinding
                    )
                )
            } else {
                XCTAssertTrue(
                    coordinator.confirmInactive(
                        for: notice,
                        binding: hiddenBinding
                    )
                )
                XCTAssertFalse(coordinator.isAutomaticallySuspended)
                XCTAssertTrue(
                    coordinator.confirmCover(covered, binding: hiddenBinding)
                )
            }

            XCTAssertTrue(coordinator.isAutomaticallySuspended)
            XCTAssertFalse(coordinator.owns(originalBinding))
            XCTAssertTrue(coordinator.owns(hiddenBinding))
            XCTAssertTrue(
                coordinator.beginResumeAttempt(
                    attemptID: makeAttemptID(),
                    binding: hiddenBinding
                )
            )
        }
    }

    func testExactResumeTranscriptCommitsOnlyTheCurrentBinding() throws {
        let binding = makeBinding(visibilityCommandEpoch: 8)
        var coordinator = try makeSuspendedCoordinator(binding: binding)
        let notice = try XCTUnwrap(coordinator.currentSuspensionNotice)
        let values = try makeLifecycle(notice: notice)

        XCTAssertTrue(
            coordinator.beginResumeAttempt(
                attemptID: values.markerReady.attemptID,
                binding: binding
            )
        )
        XCTAssertTrue(coordinator.acceptMarkerReady(values.markerReady, binding: binding))
        XCTAssertFalse(coordinator.acceptMarkerReady(values.markerReady, binding: binding))
        XCTAssertTrue(
            coordinator.acceptMarkerPresentation(
                values.markerPresentation,
                binding: binding
            )
        )
        XCTAssertTrue(coordinator.acceptResumeReady(values.resumeReady, binding: binding))
        XCTAssertTrue(coordinator.acceptResumeRequest(values.request, binding: binding))
        XCTAssertTrue(coordinator.authorizesFinalization(of: values.request, binding: binding))

        let staleBinding = makeBinding(visibilityCommandEpoch: 9)
        XCTAssertFalse(
            coordinator.commitFinalization(of: values.request, binding: staleBinding)
        )
        XCTAssertTrue(coordinator.commitFinalization(of: values.request, binding: binding))
        XCTAssertFalse(coordinator.isAutomaticallySuspended)
        XCTAssertFalse(coordinator.isResumeProbeInFlight)
        XCTAssertEqual(coordinator.activeScreenRequestID, 42)
        XCTAssertEqual(
            coordinator.diagnosticSnapshot.suspensionGeneration,
            values.markerReady.suspensionGeneration
        )
        XCTAssertTrue(
            coordinator.diagnosticSnapshot
                .requiresFreshMediaSessionAfterInvalidation
        )
        XCTAssertEqual(coordinator.currentSuspensionNotice, notice)
    }

    /// Models the ordered-lane race where a viewer cancellation crosses the final resumed ACK.
    /// WebRTCPeer emits the invalidation only after the service task has committed `.active` and
    /// cleared its in-flight context, so the finalized transcript itself must retain recovery
    /// ownership and force a fresh ordered Show instead of leaving acknowledged video disabled.
    func testFinalizedResumeRetainsRecoveryOwnershipForCrossedCancellation() throws {
        let binding = makeBinding(visibilityCommandEpoch: 8)
        var coordinator = try makeSuspendedCoordinator(binding: binding)
        let notice = try XCTUnwrap(coordinator.currentSuspensionNotice)
        let values = try makeLifecycle(notice: notice)

        XCTAssertTrue(
            coordinator.beginResumeAttempt(
                attemptID: values.markerReady.attemptID,
                binding: binding
            )
        )
        XCTAssertTrue(coordinator.acceptMarkerReady(values.markerReady, binding: binding))
        XCTAssertTrue(
            coordinator.acceptMarkerPresentation(
                values.markerPresentation,
                binding: binding
            )
        )
        XCTAssertTrue(coordinator.acceptResumeReady(values.resumeReady, binding: binding))
        XCTAssertTrue(coordinator.acceptResumeRequest(values.request, binding: binding))
        XCTAssertTrue(coordinator.commitFinalization(of: values.request, binding: binding))

        let afterFinalAcknowledgement = coordinator.diagnosticSnapshot
        XCTAssertEqual(afterFinalAcknowledgement.phase, .active)
        XCTAssertEqual(afterFinalAcknowledgement.screenRequestID, notice.screenRequestID)
        XCTAssertEqual(
            afterFinalAcknowledgement.suspensionGeneration,
            notice.suspensionGeneration
        )
        XCTAssertEqual(afterFinalAcknowledgement.binding, binding)
        XCTAssertTrue(
            afterFinalAcknowledgement.requiresFreshMediaSessionAfterInvalidation
        )
        XCTAssertEqual(coordinator.currentSuspensionNotice, notice)

        let replacementBinding = makeBinding(visibilityCommandEpoch: 9)
        XCTAssertTrue(
            coordinator.activate(
                screenRequestID: 84,
                binding: replacementBinding
            )
        )
        XCTAssertFalse(
            coordinator.diagnosticSnapshot
                .requiresFreshMediaSessionAfterInvalidation
        )
        XCTAssertNil(coordinator.currentSuspensionNotice)
    }

    func testAbortedNewSuspensionPreservesPriorCompletedTranscript() throws {
        let binding = makeBinding(visibilityCommandEpoch: 8)
        var coordinator = try makeSuspendedCoordinator(binding: binding)
        let priorNotice = try XCTUnwrap(coordinator.currentSuspensionNotice)
        let values = try makeLifecycle(notice: priorNotice)

        XCTAssertTrue(
            coordinator.beginResumeAttempt(
                attemptID: values.markerReady.attemptID,
                binding: binding
            )
        )
        XCTAssertTrue(coordinator.acceptMarkerReady(values.markerReady, binding: binding))
        XCTAssertTrue(
            coordinator.acceptMarkerPresentation(
                values.markerPresentation,
                binding: binding
            )
        )
        XCTAssertTrue(coordinator.acceptResumeReady(values.resumeReady, binding: binding))
        XCTAssertTrue(coordinator.acceptResumeRequest(values.request, binding: binding))
        XCTAssertTrue(coordinator.commitFinalization(of: values.request, binding: binding))

        let nextNotice = try XCTUnwrap(
            coordinator.beginSuspensionIfNegotiated(
                negotiated: true,
                binding: binding
            )
        )
        XCTAssertGreaterThan(
            nextNotice.suspensionGeneration,
            priorNotice.suspensionGeneration
        )
        XCTAssertTrue(coordinator.abortSuspensionBeforeInactive(binding: binding))
        XCTAssertEqual(coordinator.diagnosticSnapshot.phase, .active)
        XCTAssertEqual(
            coordinator.diagnosticSnapshot.suspensionGeneration,
            priorNotice.suspensionGeneration
        )
        XCTAssertTrue(
            coordinator.diagnosticSnapshot
                .requiresFreshMediaSessionAfterInvalidation
        )
        XCTAssertEqual(coordinator.currentSuspensionNotice, priorNotice)
    }

    func testEverySuspensionOwnedInvalidationPhaseRequiresAFreshMediaSession() throws {
        let activeBinding = makeBinding(visibilityCommandEpoch: 7)
        let hiddenBinding = makeBinding(visibilityCommandEpoch: 8)
        var coordinator = WorldwideScreenMediaSuspensionCoordinator()

        XCTAssertTrue(coordinator.activate(screenRequestID: 42, binding: activeBinding))
        XCTAssertEqual(coordinator.diagnosticSnapshot.phase, .active)
        XCTAssertFalse(
            coordinator.diagnosticSnapshot
                .requiresFreshMediaSessionAfterInvalidation
        )

        let notice = try XCTUnwrap(
            coordinator.beginSuspensionIfNegotiated(
                negotiated: true,
                binding: activeBinding
            )
        )
        assertFreshSessionRecovery(
            coordinator,
            phase: .suspending,
            notice: notice,
            binding: activeBinding
        )
        XCTAssertTrue(
            coordinator.confirmCover(
                WebRTCScreenMediaCoveredAcknowledgement(suspension: notice),
                binding: activeBinding
            )
        )
        XCTAssertTrue(
            coordinator.confirmInactive(for: notice, binding: hiddenBinding)
        )
        assertFreshSessionRecovery(
            coordinator,
            phase: .suspended,
            notice: notice,
            binding: hiddenBinding
        )

        let values = try makeLifecycle(notice: notice)
        XCTAssertTrue(
            coordinator.beginResumeAttempt(
                attemptID: values.markerReady.attemptID,
                binding: hiddenBinding
            )
        )
        assertFreshSessionRecovery(
            coordinator,
            phase: .awaitingMarker,
            notice: notice,
            binding: hiddenBinding
        )
        XCTAssertTrue(coordinator.acceptMarkerReady(values.markerReady, binding: hiddenBinding))
        assertFreshSessionRecovery(
            coordinator,
            phase: .awaitingMarkerPresentation,
            notice: notice,
            binding: hiddenBinding
        )
        XCTAssertTrue(
            coordinator.acceptMarkerPresentation(
                values.markerPresentation,
                binding: hiddenBinding
            )
        )
        assertFreshSessionRecovery(
            coordinator,
            phase: .awaitingRealFrame,
            notice: notice,
            binding: hiddenBinding
        )
        XCTAssertTrue(
            coordinator.acceptResumeReady(values.resumeReady, binding: hiddenBinding)
        )
        assertFreshSessionRecovery(
            coordinator,
            phase: .awaitingRealPresentation,
            notice: notice,
            binding: hiddenBinding
        )
        XCTAssertTrue(
            coordinator.acceptResumeRequest(values.request, binding: hiddenBinding)
        )
        assertFreshSessionRecovery(
            coordinator,
            phase: .awaitingFinalization,
            notice: notice,
            binding: hiddenBinding
        )
    }

    func testResumeCancellationRetriesOnlyForTheExactLogicalScreen() throws {
        let binding = makeBinding(visibilityCommandEpoch: 8)
        var coordinator = try makeSuspendedCoordinator(binding: binding)
        let notice = try XCTUnwrap(coordinator.currentSuspensionNotice)
        let attemptID = makeAttemptID()
        XCTAssertTrue(
            coordinator.beginResumeAttempt(
                attemptID: attemptID,
                binding: binding
            )
        )

        coordinator.cancelResume(
            binding: binding,
            logicalScreenIsStillRequested: true
        )
        XCTAssertTrue(coordinator.isAutomaticallySuspended)
        XCTAssertEqual(coordinator.diagnosticSnapshot.phase, .suspended)
        XCTAssertTrue(
            coordinator.diagnosticSnapshot
                .requiresFreshMediaSessionAfterInvalidation
        )
        XCTAssertFalse(coordinator.isResumeProbeInFlight)
        XCTAssertEqual(coordinator.currentSuspensionNotice, notice)
        XCTAssertTrue(
            coordinator.beginResumeAttempt(
                attemptID: UUID(),
                binding: binding
            )
        )

        coordinator.cancelResume(
            binding: makeBinding(visibilityCommandEpoch: 9),
            logicalScreenIsStillRequested: true
        )
        XCTAssertTrue(coordinator.isAutomaticallySuspended)
        XCTAssertTrue(coordinator.isResumeProbeInFlight)
        XCTAssertEqual(coordinator.activeScreenRequestID, 42)
        XCTAssertTrue(coordinator.owns(binding))
    }

    func testFailedProvisionalFinalizationRollsBackOnlyItsExactBinding() throws {
        let binding = makeBinding(visibilityCommandEpoch: 8)
        var coordinator = try makeSuspendedCoordinator(binding: binding)
        let notice = try XCTUnwrap(coordinator.currentSuspensionNotice)
        let values = try makeLifecycle(notice: notice)
        XCTAssertTrue(
            coordinator.beginResumeAttempt(
                attemptID: values.markerReady.attemptID,
                binding: binding
            )
        )
        XCTAssertTrue(coordinator.acceptMarkerReady(values.markerReady, binding: binding))
        XCTAssertTrue(
            coordinator.acceptMarkerPresentation(
                values.markerPresentation,
                binding: binding
            )
        )
        XCTAssertTrue(coordinator.acceptResumeReady(values.resumeReady, binding: binding))
        XCTAssertTrue(coordinator.acceptResumeRequest(values.request, binding: binding))
        XCTAssertTrue(coordinator.commitFinalization(of: values.request, binding: binding))

        XCTAssertFalse(
            coordinator.rollbackFinalizationBeforeAcknowledgement(
                notice: notice,
                binding: makeBinding(visibilityCommandEpoch: 9)
            )
        )
        XCTAssertTrue(coordinator.owns(binding))
        XCTAssertTrue(
            coordinator.rollbackFinalizationBeforeAcknowledgement(
                notice: notice,
                binding: binding
            )
        )
        XCTAssertTrue(coordinator.isAutomaticallySuspended)
        XCTAssertFalse(coordinator.isResumeProbeInFlight)
        XCTAssertEqual(coordinator.currentSuspensionNotice, notice)
    }

    func testStaleResumeCleanupCannotRetireANewerActiveBinding() throws {
        let staleBinding = makeBinding(visibilityCommandEpoch: 8)
        let currentBinding = makeBinding(visibilityCommandEpoch: 9)
        var coordinator = try makeSuspendedCoordinator(binding: staleBinding)
        XCTAssertTrue(
            coordinator.beginResumeAttempt(
                attemptID: makeAttemptID(),
                binding: staleBinding
            )
        )

        XCTAssertTrue(
            coordinator.activate(screenRequestID: 84, binding: currentBinding)
        )
        coordinator.cancelResume(
            binding: staleBinding,
            logicalScreenIsStillRequested: false
        )

        XCTAssertFalse(coordinator.isAutomaticallySuspended)
        XCTAssertFalse(coordinator.isResumeProbeInFlight)
        XCTAssertEqual(coordinator.activeScreenRequestID, 84)
        XCTAssertTrue(coordinator.owns(currentBinding))
    }

    private func makeSuspendedCoordinator(
        binding: WorldwideScreenMediaSuspensionCoordinator.Binding
    ) throws -> WorldwideScreenMediaSuspensionCoordinator {
        let activeBinding = makeBinding(
            peerGeneration: binding.peerGeneration,
            visibilityCommandEpoch: binding.visibilityCommandEpoch - 1,
            recoveryEpoch: binding.recoveryEpoch
        )
        var coordinator = WorldwideScreenMediaSuspensionCoordinator()
        XCTAssertTrue(coordinator.activate(screenRequestID: 42, binding: activeBinding))
        let notice = try XCTUnwrap(
            coordinator.beginSuspensionIfNegotiated(
                negotiated: true,
                binding: activeBinding
            )
        )
        XCTAssertTrue(
            coordinator.confirmCover(
                WebRTCScreenMediaCoveredAcknowledgement(suspension: notice),
                binding: activeBinding
            )
        )
        XCTAssertTrue(coordinator.confirmInactive(for: notice, binding: binding))
        return coordinator
    }

    private func assertFreshSessionRecovery(
        _ coordinator: WorldwideScreenMediaSuspensionCoordinator,
        phase: WorldwideScreenMediaSuspensionCoordinator.DiagnosticPhase,
        notice: WebRTCScreenMediaSuspensionNotice,
        binding: WorldwideScreenMediaSuspensionCoordinator.Binding,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let diagnostic = coordinator.diagnosticSnapshot
        XCTAssertEqual(diagnostic.phase, phase, file: file, line: line)
        XCTAssertEqual(
            diagnostic.screenRequestID,
            notice.screenRequestID,
            file: file,
            line: line
        )
        XCTAssertEqual(
            diagnostic.suspensionGeneration,
            notice.suspensionGeneration,
            file: file,
            line: line
        )
        XCTAssertEqual(diagnostic.binding, binding, file: file, line: line)
        XCTAssertTrue(
            diagnostic.requiresFreshMediaSessionAfterInvalidation,
            file: file,
            line: line
        )
    }

    private func makeLifecycle(
        notice: WebRTCScreenMediaSuspensionNotice
    ) throws -> LifecycleValues {
        let geometry = WebRTCScreenMediaGeometry(
            geometryRevision: 23,
            captureWidth: 3_024,
            captureHeight: 1_964
        )
        let markerReady = WebRTCScreenMediaMarkerReady(
            attemptID: makeAttemptID(),
            screenRequestID: notice.screenRequestID,
            suspensionGeneration: notice.suspensionGeneration,
            encoderGeneration: 19,
            encoderMarkerRTPTimestamp: .max - 2,
            boundaryRevision: geometry.geometryRevision,
            geometry: geometry
        )
        let markerPresentation = WebRTCScreenMediaMarkerPresentation(
            markerReady: markerReady,
            receiverMarkerRTPTimestamp: 1_000,
            receiverID: "receiver-1",
            sourceID: 77,
            presentedWidth: 1_280,
            presentedHeight: 832
        )
        let resumeReady = WebRTCScreenMediaResumeReady(
            markerPresentation: markerPresentation,
            encoderMarkerRTPTimestamp: markerReady.encoderMarkerRTPTimestamp,
            encoderRealFrameRTPTimestamp: 5,
            receiverMarkerRTPTimestamp:
                markerPresentation.receiverMarkerRTPTimestamp,
            receiverRealFrameFloorRTPTimestamp: 1_008,
            geometry: geometry
        )
        let presentation = WebRTCScreenMediaPresentation(
            resumeReady: resumeReady,
            presentedRTPTimestamp:
                resumeReady.receiverRealFrameFloorRTPTimestamp,
            receiverID: markerPresentation.receiverID,
            sourceID: markerPresentation.sourceID,
            presentedWidth: markerPresentation.presentedWidth,
            presentedHeight: markerPresentation.presentedHeight
        )
        return LifecycleValues(
            markerReady: markerReady,
            markerPresentation: markerPresentation,
            resumeReady: resumeReady,
            request: WebRTCScreenMediaResumeRequest(
                id: 55,
                presentation: presentation
            )
        )
    }

    private func makeBinding(
        peerGeneration: UInt64 = 3,
        visibilityCommandEpoch: UInt64 = 7,
        recoveryEpoch: UInt64 = 11
    ) -> WorldwideScreenMediaSuspensionCoordinator.Binding {
        WorldwideScreenMediaSuspensionCoordinator.Binding(
            peerGeneration: peerGeneration,
            visibilityCommandEpoch: visibilityCommandEpoch,
            recoveryEpoch: recoveryEpoch
        )
    }

    private func makeAttemptID() -> UUID {
        UUID(uuidString: "A1B2C3D4-E5F6-4718-89AB-CDEF01234567")!
    }
}

private struct LifecycleValues {
    let markerReady: WebRTCScreenMediaMarkerReady
    let markerPresentation: WebRTCScreenMediaMarkerPresentation
    let resumeReady: WebRTCScreenMediaResumeReady
    let request: WebRTCScreenMediaResumeRequest
}
