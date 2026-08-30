import CoreAudio
import Foundation
import XCTest
@testable import CaptureCore
@testable import CaptureServer

/// Defines the ordering and failure boundary for acknowledging that remote screen video is hidden.
///
/// The host may report `.inactive` only after native capture has stopped. A native-stop failure
/// closes the session because continued capture would contradict the acknowledgement; an ACK
/// transport failure is reported but does not retroactively invalidate the completed local stop.
@MainActor
final class WorldwideScreenInactiveTransitionTests: XCTestCase {
    func testSuccessfulTransitionStopsNativeCaptureBeforeInactiveAcknowledgement() async {
        let probe = InactiveTransitionProbe()

        let failure = await WorldwideScreenInactiveTransition.perform(
            stopNativeCapture: {
                probe.events.append("native-stop")
            },
            acknowledgeInactive: {
                probe.events.append("inactive-ack")
                probe.inactiveAcknowledgementCount += 1
            },
            failClosed: { error in
                probe.events.append("close-session")
                probe.closeSessionCount += 1
                probe.closeError = error
            }
        )

        XCTAssertNil(failure)
        XCTAssertEqual(probe.events, ["native-stop", "inactive-ack"])
        XCTAssertEqual(probe.inactiveAcknowledgementCount, 1)
        XCTAssertEqual(probe.closeSessionCount, 0)
        XCTAssertNil(probe.closeError)
    }

    func testThrowingNativeStopRejectsInactiveAcknowledgementAndClosesSession() async {
        let source = ThrowingScreenStopSource()
        let probe = InactiveTransitionProbe()

        let failure = await WorldwideScreenInactiveTransition.perform(
            stopNativeCapture: {
                probe.events.append("native-stop")
                try await source.stop()
            },
            acknowledgeInactive: {
                probe.events.append("inactive-ack")
                probe.inactiveAcknowledgementCount += 1
            },
            failClosed: { error in
                probe.events.append("close-session")
                probe.closeSessionCount += 1
                probe.closeError = error
            }
        )

        XCTAssertEqual(source.stopAttemptCount, 1)
        XCTAssertEqual(probe.inactiveAcknowledgementCount, 0)
        XCTAssertEqual(probe.closeSessionCount, 1)
        XCTAssertEqual(probe.events, ["native-stop", "close-session"])
        XCTAssertEqual(probe.closeError as? ThrowingScreenStopSource.StopError, .injected)

        guard case .nativeStop(let error) = failure else {
            return XCTFail("A throwing native stop must remain a visible native-stop failure.")
        }
        XCTAssertEqual(error as? ThrowingScreenStopSource.StopError, .injected)
    }

    func testAcknowledgementFailureOccursAfterNativeStopWithoutClosingSession() async {
        let probe = InactiveTransitionProbe()

        let failure = await WorldwideScreenInactiveTransition.perform(
            stopNativeCapture: {
                probe.events.append("native-stop")
            },
            acknowledgeInactive: {
                probe.events.append("inactive-ack")
                probe.inactiveAcknowledgementCount += 1
                throw InactiveAcknowledgementError.injected
            },
            failClosed: { error in
                probe.events.append("close-session")
                probe.closeSessionCount += 1
                probe.closeError = error
            }
        )

        XCTAssertEqual(probe.events, ["native-stop", "inactive-ack"])
        XCTAssertEqual(probe.inactiveAcknowledgementCount, 1)
        XCTAssertEqual(probe.closeSessionCount, 0)
        XCTAssertNil(probe.closeError)
        guard case .acknowledgement(let error) = failure else {
            return XCTFail("A throwing acknowledgement must remain a visible ACK failure.")
        }
        XCTAssertEqual(error as? InactiveAcknowledgementError, .injected)
    }

    func testHideCommandUsesVerifiedNativeStopBoundaryBeforeInactiveAcknowledgement() throws {
        // Behavioral tests cover the transition helper. This source-level integration oracle makes
        // sure the production Hide branch still calls that helper instead of acknowledging the peer
        // directly. The mutation check below proves the oracle detects the bypass it guards against.
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceSourceURL = repositoryRoot.appendingPathComponent(
            "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
        )
        let serviceSource = try String(contentsOf: serviceSourceURL, encoding: .utf8)
        let handler = try sourceSlice(
            in: serviceSource,
            after: "    private func handleControlRequest(_ request: WebRTCControlRequest) async {",
            before: "    @discardableResult\n    private func acknowledgeInactiveAfterVerifiedScreenStop("
        )
        let hideBranch = try sourceSlice(
            in: handler,
            after: "        case .hideScreen:",
            before: "        case .requestKeyFrame:"
        )

        XCTAssertEqual(hideContractViolations(in: hideBranch), [])

        let directAcknowledgementMutant = hideBranch.replacingOccurrences(
            of: "acknowledgeInactiveAfterVerifiedScreenStop(",
            with: "peer.acknowledgeControlRequest("
        )
        XCTAssertNotEqual(directAcknowledgementMutant, hideBranch)
        XCTAssertEqual(
            Set(hideContractViolations(in: directAcknowledgementMutant)),
            Set([
                "verified-boundary-call-count",
                "direct-peer-acknowledgement",
            ]),
            "The source oracle itself must reject a regression that bypasses the boundary."
        )

        let verifiedBoundary = try sourceSlice(
            in: serviceSource,
            after: "    private func acknowledgeInactiveAfterVerifiedScreenStop(",
            before: "    @discardableResult\n    private func stopScreenCaptureOrCloseSession("
        )
        XCTAssertTrue(
            verifiedBoundary.contains("WorldwideScreenInactiveTransition.perform("),
            "The production helper must use the behavior-tested transition boundary."
        )
        let nativeStop = try XCTUnwrap(
            verifiedBoundary.range(of: "try await self.stopScreenCapture()")
        )
        let inactiveAcknowledgement = try XCTUnwrap(
            verifiedBoundary.range(
                of: "try await peer.acknowledgeControlRequest(\n                    id: requestID,\n                    state: .inactive"
            )
        )
        XCTAssertLessThan(
            nativeStop.lowerBound,
            inactiveAcknowledgement.lowerBound,
            "The production boundary must attempt native stop before sending Inactive."
        )
    }

    func testIPhoneMicrophoneInstallationDelegatesClassifiedTrackToGenerationDriver() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceSourceURL = repositoryRoot.appendingPathComponent(
            "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
        )
        let serviceSource = try String(
            contentsOf: serviceSourceURL,
            encoding: .utf8
        )

        let installation = try sourceSlice(
            in: serviceSource,
            after: "    private func installIPhoneMicrophoneTrack(",
            before: "    /// Converts unexplained audio-start failure on a healthy route into ICE recovery."
        )
        let laneCheck = try XCTUnwrap(
            installation.range(
                of: "track.logicalLane == .iPhoneMicrophone"
            )
        )
        let driverInstallation = try XCTUnwrap(
            installation.range(
                of: "await iPhoneMicrophoneForwarding.installTrack(track)"
            )
        )
        XCTAssertLessThan(
            laneCheck.lowerBound,
            driverInstallation.lowerBound
        )
        XCTAssertFalse(installation.contains(".trackID"))
        XCTAssertFalse(
            installation.contains(
                "WebRTCAudioTrackIdentifiers.iPhoneMicrophone"
            )
        )

        let driverSourceURL = repositoryRoot.appendingPathComponent(
            "macOS/Sources/CaptureServer/" +
                "WorldwideIPhoneMicrophoneForwardingDriver.swift"
        )
        let driverSource = try String(
            contentsOf: driverSourceURL,
            encoding: .utf8
        )
        XCTAssertTrue(
            driverSource.contains(
                "candidate.peer === attempt.peer"
            )
        )
        XCTAssertTrue(
            driverSource.contains(
                "candidate.track === attempt.track"
            )
        )
        XCTAssertTrue(
            driverSource.contains(
                "candidate.key == attempt.key"
            ),
            "Every post-await continuation must retain the complete generation key."
        )
        XCTAssertTrue(
            serviceSource.contains(
                "peer.enableRemoteIPhoneMicrophonePlaybackIfTransportHealthy("
            ),
            "The service must delegate final current-object and health admission to the peer."
        )
    }

    func testIPhoneMicrophoneRuntimeFailureMappingAndLogAreSemantic()
        throws {
        XCTAssertEqual(
            WorldwideScreenService
                .iPhoneMicrophoneRuntimeFailureCategory(
                    for: .operation("enqueue", -1)
                ),
            .runtimeEnqueueFailed
        )
        XCTAssertEqual(
            WorldwideScreenService
                .iPhoneMicrophoneRuntimeFailureCategory(
                    for: .progressStalled
                ),
            .runtimeProgressStalled
        )
        let capturedClockRejection =
            BlackHoleFaceTimeClockRejection
                .insufficientSigned32Headroom(
                    observation: BlackHoleFaceTimeClockObservation(
                        deviceSampleTime: 6_687_779_444,
                        deviceHostTime: 1,
                        deviceSampleRate: 48_000,
                        projectedFaceTimeSampleTime: 3_343_889_722
                    ),
                    maximumProjectedSampleTime:
                        BlackHoleFaceTimeClockPolicy
                            .maximumProjectedSampleTime
                )
        XCTAssertEqual(
            WorldwideScreenService
                .iPhoneMicrophoneRuntimeFailureCategory(
                    for: .sharedClockUnsafe(
                        capturedClockRejection
                    )
                ),
            .sharedClockUnsafe
        )
        let formatRejection =
            BlackHoleMicrophoneOutputFormatRejection
                .unexpectedDeviceChannelCount(actual: 4)
        XCTAssertEqual(
            WorldwideScreenService
                .iPhoneMicrophoneRuntimeFailureCategory(
                    for: .formatUnsafe(formatRejection)
                ),
            .formatUnsafe
        )

        let message = WorldwideScreenService
            .iPhoneMicrophoneRuntimeFailureLogMessage(
                error: .progressStalled
            )
        XCTAssertTrue(message.contains("output runtime failure"))
        XCTAssertFalse(message.contains("AudioQueue"))
        let clockMessage = WorldwideScreenService
            .iPhoneMicrophoneRuntimeFailureLogMessage(
                error: .sharedClockUnsafe(
                    capturedClockRejection
                )
            )
        XCTAssertTrue(
            clockMessage.contains(
                "projected 24 kHz sample time 3343889722"
            )
        )
        XCTAssertTrue(
            clockMessage.contains("bounded idle proof")
        )
        let nonrecoverableClockMessage = WorldwideScreenService
            .iPhoneMicrophoneRuntimeFailureLogMessage(
                error: .sharedClockUnsafe(
                    .startupClockContinuityTimedOut
                )
            )
        XCTAssertTrue(
            nonrecoverableClockMessage.contains(
                "automatic restart is blocked"
            )
        )
        XCTAssertFalse(clockMessage.contains("BlackHole2ch_UID"))
        XCTAssertFalse(clockMessage.contains("BlackHole2ch_2_UID"))
        XCTAssertFalse(
            clockMessage.contains(
                WorldwideVirtualMicrophoneEndpointContract
                    .visibleDefaultInputDeviceUID
            )
        )
        XCTAssertFalse(
            clockMessage.contains(
                WorldwideVirtualMicrophoneEndpointContract
                    .hiddenMirrorSinkDeviceUID
            )
        )
        let formatMessage = WorldwideScreenService
            .iPhoneMicrophoneRuntimeFailureLogMessage(
                error: .formatUnsafe(formatRejection)
            )
        XCTAssertTrue(
            formatMessage.contains(formatRejection.description),
            "The exact typed readback rejection must reach telemetry."
        )
        XCTAssertTrue(
            formatMessage.contains("automatic restart is blocked")
        )
        XCTAssertFalse(formatMessage.contains("BlackHole2ch_UID"))
        XCTAssertFalse(formatMessage.contains("BlackHole2ch_2_UID"))
        XCTAssertFalse(
            formatMessage.contains(
                WorldwideVirtualMicrophoneEndpointContract
                    .visibleDefaultInputDeviceUID
            )
        )
        XCTAssertFalse(
            formatMessage.contains(
                WorldwideVirtualMicrophoneEndpointContract
                    .hiddenMirrorSinkDeviceUID
            )
        )
        XCTAssertFalse(formatMessage.contains("raw PCM"))

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
            ),
            encoding: .utf8
        )
        let handler = try sourceSlice(
            in: serviceSource,
            after: "    private func iPhoneMicrophoneOutputDidFail(",
            before: "    private func installIPhoneMicrophoneTrack("
        )
        XCTAssertTrue(
            handler.contains(
                "iPhoneMicrophoneRuntimeFailureCategory("
            )
        )
        XCTAssertTrue(
            handler.contains(
                "iPhoneMicrophoneRuntimeFailureLogMessage("
            )
        )
        XCTAssertFalse(handler.contains("AudioQueue failure"))

        let failedKeyCapture = try XCTUnwrap(
            handler.range(
                of: "iPhoneMicrophoneForwarding.snapshot().currentKey"
            )
        )
        let formatFailureBranch = try sourceSlice(
            in: handler,
            after:
                "        if case .formatUnsafe(let rejection) = error {",
            before:
                "        if case .sharedClockUnsafe(let rejection) = error {"
        )
        let formatRuntimeTeardown = try XCTUnwrap(
            formatFailureBranch.range(
                of: "iPhoneMicrophoneForwarding.handleRuntimeFailure("
            )
        )
        let formatRevocation = try XCTUnwrap(
            formatFailureBranch.range(
                of: "iPhoneMicrophoneFormatDidFail("
            )
        )
        XCTAssertLessThan(
            formatRuntimeTeardown.lowerBound,
            formatRevocation.lowerBound,
            "The driver must own the exact failed key before the service blocks its pair."
        )
        XCTAssertFalse(
            formatFailureBranch.contains(
                "consumeCurrentBlackHoleDeviceSnapshot()"
            ),
            "A deterministic format failure must not readmit the rejected pair."
        )
        let clockFailureBranch = try sourceSlice(
            in: handler,
            after:
                "        if case .sharedClockUnsafe(let rejection) = error {",
            before:
                "        // A listener may already have closed the realtime gate while its actor"
        )
        let clockRuntimeTeardown = try XCTUnwrap(
            clockFailureBranch.range(
                of: "iPhoneMicrophoneForwarding.handleRuntimeFailure("
            )
        )
        let clockRevocation = try XCTUnwrap(
            clockFailureBranch.range(
                of: "iPhoneMicrophoneSharedClockDidFail("
            )
        )
        XCTAssertLessThan(
            clockRuntimeTeardown.lowerBound,
            clockRevocation.lowerBound,
            "The non-retryable driver teardown must own the captured exact key before the service blocks and revokes it."
        )
        XCTAssertFalse(
            clockFailureBranch.contains(
                "consumeCurrentBlackHoleDeviceSnapshot()"
            ),
            "A deterministic shared-clock failure must not readmit the rejected pair."
        )

        let clockBranchStart = try XCTUnwrap(
            handler.range(
                of: "if case .sharedClockUnsafe(let rejection) = error"
            )
        )
        let formatBranchStart = try XCTUnwrap(
            handler.range(
                of: "if case .formatUnsafe(let rejection) = error"
            )
        )
        XCTAssertLessThan(
            failedKeyCapture.lowerBound,
            formatBranchStart.lowerBound,
            "The exact failed key must be captured before format-failure handling can clear it."
        )
        XCTAssertLessThan(
            failedKeyCapture.lowerBound,
            clockBranchStart.lowerBound,
            "The exact failed key must be captured before handling can clear it."
        )

        let genericFailureBranch = try sourceSlice(
            in: handler,
            after:
                "        // A listener may already have closed the realtime gate while its actor",
            before: "        logger.error("
        )
        let genericRevalidation = try XCTUnwrap(
            genericFailureBranch.range(
                of: "await consumeCurrentBlackHoleDeviceSnapshot()"
            )
        )
        let genericRuntimeTeardown = try XCTUnwrap(
            genericFailureBranch.range(
                of: "iPhoneMicrophoneForwarding.handleRuntimeFailure("
            )
        )
        XCTAssertLessThan(
            genericRevalidation.lowerBound,
            genericRuntimeTeardown.lowerBound,
            "Fresh endpoint-pair and safe-output proof must precede any retryable driver teardown/redrive."
        )

        let clockFailureHandler = try sourceSlice(
            in: serviceSource,
            after:
                "    private func iPhoneMicrophoneSharedClockDidFail(",
            before:
                "    private func startIPhoneMicrophoneDeviceMonitoringIfNeeded()"
        )
        let blockPublication = try XCTUnwrap(
            clockFailureHandler.range(
                of: "sharedClockBlockedPeerPair ="
            )
        )
        let listenerBoundParking = try XCTUnwrap(
            clockFailureHandler.range(
                of: "parkWorldwideMicrophoneForSharedClockRecovery()"
            )
        )
        XCTAssertTrue(
            clockFailureHandler.contains(
                "preservingSharedClockUnsafeFailure: true"
            )
        )
        XCTAssertLessThan(
            blockPublication.lowerBound,
            listenerBoundParking.lowerBound,
            "The exact peer/pair generation must be blocked before its listener-bound parking transition."
        )
        let provedParking = try XCTUnwrap(
            clockFailureHandler.range(
                of: "guard case .parked(let parkingProof) = parkingOutcome"
            )
        )
        let failedParkingCleanup = try sourceSlice(
            in: clockFailureHandler,
            after:
                "guard case .parked(let parkingProof) = parkingOutcome",
            before: "            guard scheduleSharedClockEpochRecovery("
        )
        XCTAssertTrue(
            failedParkingCleanup.contains(
                "revokeWorldwideMicrophoneForSharedClockFailure("
            ),
            "A retryable parking or restore failure must arm exact cleanup redrive."
        )
        XCTAssertTrue(
            serviceSource.contains(
                "if redriveSharedClockEpochCleanupIfNeeded()"
            ),
            "Pending same-pair cleanup must be retried on later statistics ticks."
        )
        let cleanupStatePublication = try sourceSlice(
            in: serviceSource,
            after:
                "    private func revokeWorldwideMicrophoneForSharedClockFailure(",
            before:
                "    private func redriveSharedClockEpochCleanupIfNeeded()"
        )
        XCTAssertTrue(
            cleanupStatePublication.contains(
                "case .degraded:\n            sharedClockEpochCleanupPendingPair = blockedPair"
            ),
            "A retryable exact release must retain the blocked pair for redrive."
        )
        let cleanupRedrive = try sourceSlice(
            in: serviceSource,
            after:
                "    private func redriveSharedClockEpochCleanupIfNeeded()",
            before:
                "    private func cancelSharedClockEpochRecovery("
        )
        XCTAssertTrue(
            cleanupRedrive.contains(
                "sharedClockBlockedPeerPair == blockedPair"
            )
        )
        XCTAssertTrue(
            cleanupRedrive.contains(
                "blockedPair.peerGeneration == peerGeneration"
            )
        )
        XCTAssertTrue(
            cleanupRedrive.contains("blockedPair.matches(")
        )
        XCTAssertTrue(
            cleanupRedrive.contains(
                "revokeWorldwideMicrophoneForSharedClockFailure("
            )
        )
        let invariantMaintenance = try sourceSlice(
            in: serviceSource,
            after:
                "    private func maintainWorldwideSafeOutputInvariant() async {",
            before:
                "    private func safeOutputInvariantDidBecomeUncertain("
        )
        let cleanupBeforeCaptureGuard = try XCTUnwrap(
            invariantMaintenance.range(
                of: "redriveSharedClockEpochCleanupIfNeeded()"
            )
        )
        let captureGuard = try XCTUnwrap(
            invariantMaintenance.range(
                of: "guard transportAllowsCapture else"
            )
        )
        XCTAssertLessThan(
            cleanupBeforeCaptureGuard.lowerBound,
            captureGuard.lowerBound,
            "Exact cleanup must continue even after capture transport closes."
        )
        let recoverySchedule = try XCTUnwrap(
            clockFailureHandler.range(
                of: "scheduleSharedClockEpochRecovery("
            )
        )
        let parkingRouteProof = try XCTUnwrap(
            clockFailureHandler.range(
                of: "parkingProof.parkingEndpoint.deviceUID"
            )
        )
        XCTAssertLessThan(
            listenerBoundParking.lowerBound,
            provedParking.lowerBound
        )
        XCTAssertLessThan(
            provedParking.lowerBound,
            parkingRouteProof.lowerBound
        )
        XCTAssertLessThan(
            parkingRouteProof.lowerBound,
            recoverySchedule.lowerBound,
            "A degraded or unproved listener-bound parking transition must never start clock recovery."
        )
        let idleRead = try XCTUnwrap(
            clockFailureHandler.range(
                of: "virtualMicrophoneEpochStateReader.observe("
            )
        )
        let compatibilityBlockClear = try XCTUnwrap(
            clockFailureHandler.range(
                of: "sharedClockBlockedPeerPair = nil"
            )
        )
        let safeReadmission = try XCTUnwrap(
            clockFailureHandler.range(
                of: "await resumeWorldwideMicrophoneAfterSafeOutputInvariant("
            )
        )
        XCTAssertLessThan(recoverySchedule.lowerBound, idleRead.lowerBound)
        XCTAssertLessThan(idleRead.lowerBound, compatibilityBlockClear.lowerBound)
        XCTAssertLessThan(
            compatibilityBlockClear.lowerBound,
            safeReadmission.lowerBound,
            "Only the idle-qualified owner may clear its block before the full safe-output readmission transaction."
        )
        let exactAdmissionProof = try XCTUnwrap(
            clockFailureHandler.range(
                of: "WorldwideSharedClockEpochRecoveryAdmissionPolicy"
            )
        )
        XCTAssertLessThan(
            safeReadmission.lowerBound,
            exactAdmissionProof.lowerBound,
            "Readmission success must be checked only after the awaited driver transition returns."
        )
        XCTAssertTrue(
            clockFailureHandler.contains(
                "forwarding.transportAuthorizationEpoch"
            )
        )
        XCTAssertTrue(
            clockFailureHandler.contains(
                "forwarding.trackGeneration == key.trackGeneration"
            )
        )
        XCTAssertTrue(
            clockFailureHandler.contains(
                ".accepts(snapshot: forwarding, after: key)"
            ),
            "Same-pair identity is insufficient; recovery must prove the exact next authorization and unchanged track."
        )
        XCTAssertTrue(
            clockFailureHandler.contains(
                "sharedClockParkingProofIsCurrent("
            ),
            "Polling must retain and re-prove the exact lease listener across the parking interval."
        )
        XCTAssertEqual(
            WorldwideSharedClockEpochRecoveryPolicy
                .maximumAttemptCount,
            1
        )

        let formatFailureHandler = try sourceSlice(
            in: serviceSource,
            after:
                "    private func iPhoneMicrophoneFormatDidFail(",
            before:
                "    private func startIPhoneMicrophoneDeviceMonitoringIfNeeded()"
        )
        let formatBlockPublication = try XCTUnwrap(
            formatFailureHandler.range(
                of: "formatUnsafeBlockedPeerPair ="
            )
        )
        let formatRouteRevocation = try XCTUnwrap(
            formatFailureHandler.range(
                of: "revokeWorldwideMicrophoneForUnsafeOutputInvariant("
            )
        )
        XCTAssertTrue(
            formatFailureHandler.contains(
                "preservingFormatUnsafeFailure: true"
            )
        )
        XCTAssertTrue(
            formatFailureHandler.contains(
                "error: .formatUnsafe(rejection)"
            )
        )
        XCTAssertLessThan(
            formatBlockPublication.lowerBound,
            formatRouteRevocation.lowerBound,
            "The exact peer/pair format block must publish before route revocation."
        )

        let routeRevocationHandler = try sourceSlice(
            in: serviceSource,
            after:
                "    private func revokeWorldwideMicrophoneForUnsafeOutputInvariant()",
            before:
                "    private func resumeWorldwideMicrophoneAfterSafeOutputInvariant("
        )
        let writerClose = try XCTUnwrap(
            routeRevocationHandler.range(
                of: "blackHoleMicrophoneOutputAuthorizationGate?.close()"
            )
        )
        let forwardingRevocation = try XCTUnwrap(
            routeRevocationHandler.range(
                of: "iPhoneMicrophoneForwarding.invalidateTransport("
            )
        )
        let conditionalInputRelease = try XCTUnwrap(
            routeRevocationHandler.range(
                of: "blackHoleDefaultInput.transportDidBecomeUnhealthy("
            )
        )
        XCTAssertLessThan(
            writerClose.lowerBound,
            forwardingRevocation.lowerBound
        )
        XCTAssertLessThan(
            forwardingRevocation.lowerBound,
            conditionalInputRelease.lowerBound,
            "The writer and track route must close before the coordinator conditionally releases its exact default-input lease."
        )

        let admission = try sourceSlice(
            in: serviceSource,
            after:
                "    private func admitBlackHoleInputWithinSafeOutputFence(",
            before:
                "    /// Continuously verifies the output invariant."
        )
        let clockFence = try XCTUnwrap(
            admission.range(
                of: "if sharedClockBlocksCurrentPeerAndPair()"
            )
        )
        let formatFence = try XCTUnwrap(
            admission.range(
                of: "if formatUnsafeBlocksCurrentPeerAndPair()"
            )
        )
        let mutationTransaction = try XCTUnwrap(
            admission.range(
                of: "enforceDuringAdmission("
            )
        )
        XCTAssertLessThan(
            clockFence.lowerBound,
            mutationTransaction.lowerBound,
            "A statistics tick must reject the blocked peer/pair before reopening or mutating Core Audio routing."
        )
        XCTAssertLessThan(
            formatFence.lowerBound,
            mutationTransaction.lowerBound,
            "A format-rejected peer/pair must remain fenced before Core Audio routing mutation."
        )
    }

    func testCompatibilityBlocksSurviveDriverKeyChurnAndClearForNewPeerOrPair()
    {
        let epoch = UUID()
        let originalKey = WorldwideIPhoneMicrophoneForwardingKey(
            monitorEpoch: epoch,
            deviceGeneration: 7,
            peerGeneration: 11,
            transportAuthorizationEpoch: 13,
            trackGeneration: 17
        )
        let churnedDriverKey =
            WorldwideIPhoneMicrophoneForwardingKey(
                monitorEpoch: epoch,
                deviceGeneration: 7,
                peerGeneration: 11,
                transportAuthorizationEpoch: 19,
                trackGeneration: 23
            )
        let originalBlock =
            WorldwideScreenService.SharedClockBlockedPeerPair(
                forwardingKey: originalKey
            )
        XCTAssertEqual(
            originalBlock,
            WorldwideScreenService.SharedClockBlockedPeerPair(
                forwardingKey: churnedDriverKey
            ),
            "Track and transport-authorization churn must not escape an exact peer/pair clock block."
        )
        let originalFormatBlock =
            WorldwideScreenService.FormatUnsafeBlockedPeerPair(
                forwardingKey: originalKey
            )
        XCTAssertEqual(
            originalFormatBlock,
            WorldwideScreenService.FormatUnsafeBlockedPeerPair(
                forwardingKey: churnedDriverKey
            ),
            "Track and transport churn must not escape an exact peer/pair format block."
        )

        func pairSnapshot(
            epoch: UUID,
            generation: UInt64
        ) -> BlackHoleDeviceAvailabilitySnapshot {
            BlackHoleDeviceAvailabilitySnapshot(
                monitorEpoch: epoch,
                deviceGeneration: generation,
                defaultInputEndpoint: .init(
                    deviceID: 79,
                    deviceUID: WorldwideVirtualMicrophoneEndpointContract
                        .visibleDefaultInputDeviceUID
                ),
                hiddenMirrorSinkEndpoint: .init(
                    deviceID: 89,
                    deviceUID: WorldwideVirtualMicrophoneEndpointContract
                        .hiddenMirrorSinkDeviceUID
                )
            )
        }

        let originalSnapshot = pairSnapshot(
            epoch: epoch,
            generation: 7
        )
        var samePairBlock:
            WorldwideScreenService.SharedClockBlockedPeerPair? =
                originalBlock
        XCTAssertTrue(
            WorldwideScreenService.sharedClockBlockRemainsActive(
                &samePairBlock,
                peerGeneration: 11,
                snapshot: originalSnapshot
            )
        )
        XCTAssertEqual(samePairBlock, originalBlock)
        var samePairFormatBlock:
            WorldwideScreenService.FormatUnsafeBlockedPeerPair? =
                originalFormatBlock
        XCTAssertTrue(
            WorldwideScreenService.formatUnsafeBlockRemainsActive(
                &samePairFormatBlock,
                peerGeneration: 11,
                snapshot: originalSnapshot
            )
        )
        XCTAssertEqual(samePairFormatBlock, originalFormatBlock)

        var newPeerBlock:
            WorldwideScreenService.SharedClockBlockedPeerPair? =
                originalBlock
        XCTAssertFalse(
            WorldwideScreenService.sharedClockBlockRemainsActive(
                &newPeerBlock,
                peerGeneration: 12,
                snapshot: originalSnapshot
            )
        )
        XCTAssertNil(newPeerBlock)
        var newPeerFormatBlock:
            WorldwideScreenService.FormatUnsafeBlockedPeerPair? =
                originalFormatBlock
        XCTAssertFalse(
            WorldwideScreenService.formatUnsafeBlockRemainsActive(
                &newPeerFormatBlock,
                peerGeneration: 12,
                snapshot: originalSnapshot
            )
        )
        XCTAssertNil(newPeerFormatBlock)

        for replacementSnapshot in [
            pairSnapshot(epoch: epoch, generation: 8),
            pairSnapshot(epoch: UUID(), generation: 7),
        ] {
            var changedPairBlock:
                WorldwideScreenService.SharedClockBlockedPeerPair? =
                    originalBlock
            XCTAssertFalse(
                WorldwideScreenService.sharedClockBlockRemainsActive(
                    &changedPairBlock,
                    peerGeneration: 11,
                    snapshot: replacementSnapshot
                )
            )
            XCTAssertNil(
                changedPairBlock,
                "A new monitor or device generation must clear the block so a fresh proof can be attempted."
            )
            var changedFormatBlock:
                WorldwideScreenService.FormatUnsafeBlockedPeerPair? =
                    originalFormatBlock
            XCTAssertFalse(
                WorldwideScreenService
                    .formatUnsafeBlockRemainsActive(
                        &changedFormatBlock,
                        peerGeneration: 11,
                        snapshot: replacementSnapshot
                    )
            )
            XCTAssertNil(
                changedFormatBlock,
                "A new monitor or device generation must clear the format block for a fresh proof."
            )
        }
    }

    func testDefaultInputSelectionPrecedesSystemAudioAndHasNoTrackDependency()
        throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
            ),
            encoding: .utf8
        )

        for (startMarker, endMarker) in [
            (
                "    private func completePendingRecoveryProofIfPossible(",
                "    /// Marks an initially healthy route usable and ensures system audio is live."
            ),
            (
                "    private func markRecoveryHealthyIfPossible() async -> Bool {",
                "    // MARK: - iPhone microphone to BlackHole"
            ),
        ] {
            let function = try sourceSlice(
                in: serviceSource,
                after: startMarker,
                before: endMarker
            )
            let routingAdmission = try XCTUnwrap(
                function.range(
                    of: "admitBlackHoleInputWithinSafeOutputFence()"
                )
            )
            let systemAudio = try XCTUnwrap(
                function.range(
                    of: "guard await startSystemAudioOrStopSession()"
                )
            )
            XCTAssertLessThan(
                routingAdmission.lowerBound,
                systemAudio.lowerBound,
                "The listener-fenced default-input admission must complete before the first system-audio await."
            )
            XCTAssertFalse(
                function.contains(
                    "await consumeCurrentBlackHoleDeviceSnapshot()"
                ),
                "Default-input selection must not await forwarding startup, readiness sampling, retries, or PCM."
            )
        }

        let admission = try sourceSlice(
            in: serviceSource,
            after:
                "    private func admitBlackHoleInputWithinSafeOutputFence(",
            before:
                "    /// Continuously verifies the output invariant."
        )
        let safeOutputFence = try XCTUnwrap(
            admission.range(of: ".enforceDuringAdmission(")
        )
        let preMutationHook = try XCTUnwrap(
            admission.range(of: "beforeFirstMutation: {")
        )
        let inputAdmission = try XCTUnwrap(
            admission.range(of: "admission: { ()")
        )
        let transportGate = try XCTUnwrap(
            admission.range(of: "guard transportAllowsCapture else")
        )
        let retryGate = try XCTUnwrap(
            admission.range(of: ".shouldAttemptOnCurrentTick()")
        )
        let initialAdmissionSnapshotConsumption = try XCTUnwrap(
            admission.range(
                of: "revalidateCurrentBlackHoleDeviceSnapshotForDefaultInput()"
            )
        )
        let initialSelection = try XCTUnwrap(
            admission.range(of: ".transportDidBecomeHealthy(")
        )
        XCTAssertLessThan(
            transportGate.lowerBound,
            retryGate.lowerBound
        )
        XCTAssertLessThan(
            retryGate.lowerBound,
            safeOutputFence.lowerBound
        )
        XCTAssertLessThan(
            safeOutputFence.lowerBound,
            preMutationHook.lowerBound
        )
        XCTAssertLessThan(
            preMutationHook.lowerBound,
            inputAdmission.lowerBound
        )
        XCTAssertLessThan(
            inputAdmission.lowerBound,
            initialAdmissionSnapshotConsumption.lowerBound
        )
        let prepareGate = try XCTUnwrap(
            admission.range(of: "authorizationGate.prepareToOpen()")
        )
        XCTAssertLessThan(
            inputAdmission.lowerBound,
            initialAdmissionSnapshotConsumption.lowerBound
        )
        XCTAssertLessThan(
            initialAdmissionSnapshotConsumption.lowerBound,
            initialSelection.lowerBound
        )
        XCTAssertLessThan(initialSelection.lowerBound, prepareGate.lowerBound)
        let finalSnapshotConsumption = try XCTUnwrap(
            admission.range(
                of: "revalidateCurrentBlackHoleDeviceSnapshotForDefaultInput()",
                range: prepareGate.upperBound..<admission.endIndex
            )
        )
        let finalSelection = try XCTUnwrap(
            admission.range(
                of: ".transportDidBecomeHealthy(",
                range:
                    finalSnapshotConsumption.upperBound..<admission.endIndex
            )
        )
        XCTAssertLessThan(
            prepareGate.lowerBound,
            finalSnapshotConsumption.lowerBound,
            "The gate preparation must span final pair revalidation."
        )
        XCTAssertLessThan(
            finalSnapshotConsumption.lowerBound,
            finalSelection.lowerBound
        )

        let preMutation = try sourceSlice(
            in: admission,
            after: "                    beforeFirstMutation: {",
            before: "                    admission: { ()"
        )
        let gateClose = try XCTUnwrap(
            preMutation.range(of: "authorizationGate.close()")
        )
        let forwardingRevoke = try XCTUnwrap(
            preMutation.range(
                of: "iPhoneMicrophoneForwarding\n                            .invalidateTransport()"
            )
        )
        let inputRelease = try XCTUnwrap(
            preMutation.range(
                of: "blackHoleDefaultInput\n                                .transportDidBecomeUnhealthy("
            )
        )
        XCTAssertLessThan(gateClose.lowerBound, forwardingRevoke.lowerBound)
        XCTAssertLessThan(forwardingRevoke.lowerBound, inputRelease.lowerBound)
        XCTAssertTrue(
            preMutation.contains(
                "iPhoneMicrophoneForwarding\n                            .invalidateTransport()"
            )
        )

        let commit = try sourceSlice(
            in: admission,
            after: "                    commit: { admittedSnapshot, authorization in",
            before: "                )\n            safeOutputInvariantNeedsRedrive = false"
        )
        XCTAssertTrue(
            admission.contains("monitoringEpoch: monitoringEpoch")
        )
        let openGate = try XCTUnwrap(
            commit.range(of: "authorizationGate.open(")
        )
        let publishAuthorization = try XCTUnwrap(
            commit.range(
                of: "self.safeOutputInvariantAuthorization ="
            )
        )
        XCTAssertLessThan(openGate.lowerBound, publishAuthorization.lowerBound)
        XCTAssertFalse(
            commit.contains("authorizationGate.prepareToOpen()"),
            "Preparing only at commit would let a device event after pair validation reopen stale proof."
        )
        let publishPairAuthorization = try XCTUnwrap(
            commit.range(
                of: "self.blackHoleEndpointPairAuthorization ="
            )
        )
        XCTAssertLessThan(
            publishAuthorization.lowerBound,
            publishPairAuthorization.lowerBound
        )
        let publishInputAuthorization = try XCTUnwrap(
            commit.range(
                of: "self.blackHoleDefaultInputAuthorization ="
            )
        )
        XCTAssertLessThan(
            openGate.lowerBound,
            publishInputAuthorization.lowerBound
        )
        XCTAssertTrue(
            commit.contains("acceptedInventoryChangeSequence")
        )
        XCTAssertTrue(
            preMutation.contains(
                "blackHoleDefaultInput\n                                .transportDidBecomeUnhealthy("
            )
        )
        XCTAssertTrue(
            preMutation.contains("if outcome == .degraded")
        )
        XCTAssertTrue(
            preMutation.contains(".microphoneInputReleaseUnproved")
        )

        XCTAssertTrue(
            serviceSource.contains(
                "blackHoleDeviceAvailabilityMonitor\n            .revalidateCurrentSnapshot()"
            ),
            "The healthy boundary must synchronously revalidate and consume the exact endpoint-pair generation."
        )

        let monitorStartup = try sourceSlice(
            in: serviceSource,
            after: "    private func startIPhoneMicrophoneDeviceMonitoringIfNeeded()",
            before: "    private func consumeCurrentBlackHoleDeviceSnapshot()"
        )
        let forwardingMonitorStart = try XCTUnwrap(
            monitorStartup.range(
                of: "iPhoneMicrophoneForwarding.beginMonitoring("
            )
        )
        let safeOutputMonitorStart = try XCTUnwrap(
            monitorStartup.range(of: ".beginSessionMonitoring {")
        )
        let defaultInputUncertaintyStart = try XCTUnwrap(
            monitorStartup.range(
                of: "blackHoleDefaultInputLease.setUncertaintyHandler"
            )
        )
        let deviceMonitorStart = try XCTUnwrap(
            monitorStartup.range(
                of: "blackHoleDeviceAvailabilityMonitor.start"
            )
        )
        let synchronousGateClose = try XCTUnwrap(
            monitorStartup.range(of: "authorizationGate.close()")
        )
        let deferredActorTask = try XCTUnwrap(
            monitorStartup.range(of: "Task { [weak self] in")
        )
        XCTAssertLessThan(
            defaultInputUncertaintyStart.lowerBound,
            safeOutputMonitorStart.lowerBound
        )
        let defaultInputUncertainty = try sourceSlice(
            in: monitorStartup,
            after: "        blackHoleDefaultInputLease.setUncertaintyHandler {",
            before: "        do {\n            safeOutputInvariantMonitoringEpoch ="
        )
        let inputGateClose = try XCTUnwrap(
            defaultInputUncertainty.range(
                of: "authorizationGate.close()"
            )
        )
        let inputActorTask = try XCTUnwrap(
            defaultInputUncertainty.range(
                of: "Task { [weak self] in"
            )
        )
        XCTAssertLessThan(
            inputGateClose.lowerBound,
            inputActorTask.lowerBound
        )
        XCTAssertTrue(
            defaultInputUncertainty.contains(
                ".blackHoleDefaultInputDidBecomeUncertain(event)"
            )
        )
        XCTAssertLessThan(
            safeOutputMonitorStart.lowerBound,
            deviceMonitorStart.lowerBound
        )
        XCTAssertLessThan(
            synchronousGateClose.lowerBound,
            deferredActorTask.lowerBound
        )
        let deviceUncertainty = try sourceSlice(
            in: monitorStartup,
            after: "                onUncertain: {",
            before: "                observer: {"
        )
        let deviceGateClose = try XCTUnwrap(
            deviceUncertainty.range(of: "authorizationGate.close()")
        )
        let deviceActorTask = try XCTUnwrap(
            deviceUncertainty.range(of: "Task { [weak self] in")
        )
        XCTAssertLessThan(deviceGateClose.lowerBound, deviceActorTask.lowerBound)
        XCTAssertTrue(
            deviceUncertainty.contains(
                ".blackHoleDeviceInventoryDidBecomeUncertain("
            )
        )
        let initialSnapshotConsumption = try XCTUnwrap(
            monitorStartup.range(
                of: "await consumeCurrentBlackHoleDeviceSnapshot()"
            )
        )
        XCTAssertLessThan(
            forwardingMonitorStart.lowerBound,
            initialSnapshotConsumption.lowerBound,
            "The forwarding driver must accept the monitor epoch before the initial snapshot is consumed."
        )

        let initialSnapshotConsumer = try sourceSlice(
            in: serviceSource,
            after: "    private func consumeCurrentBlackHoleDeviceSnapshot()",
            before: "    private func blackHoleDeviceAvailabilityDidChange("
        )
        XCTAssertTrue(
            initialSnapshotConsumer.contains(
                "await iPhoneMicrophoneForwarding.updateDeviceSnapshot("
            ),
            "The initial monitor snapshot must be delivered to forwarding independently of later callbacks."
        )
        XCTAssertTrue(
            initialSnapshotConsumer.contains(
                "await authorizeIPhoneMicrophoneForwardingIfPossible()"
            ),
            "A successful healthy revalidation must restore transport authorization after fail-closed revocation."
        )

        let deviceChange = try sourceSlice(
            in: serviceSource,
            after: "    private func blackHoleDeviceAvailabilityDidChange(",
            before: "    func iPhoneMicrophoneForwardingSnapshot()"
        )
        XCTAssertFalse(
            deviceChange.contains("await blackHoleDefaultInput"),
            "Forwarding must not await default-input retry coordination."
        )
        XCTAssertTrue(
            deviceChange.contains(
                "await consumeCurrentBlackHoleDeviceSnapshot()"
            ),
            "A queued observer callback must obtain fresh exact-pair proof before it can restore routing."
        )
        XCTAssertFalse(
            deviceChange.contains(".updateDeviceSnapshot(snapshot)"),
            "A delayed pre-failure callback must never directly re-admit its captured generation."
        )

        let uncertaintyHandler = try sourceSlice(
            in: serviceSource,
            after:
                "    private func blackHoleDeviceInventoryDidBecomeUncertain(",
            before:
                "    func iPhoneMicrophoneForwardingSnapshot()"
        )
        let acceptedEventFence = try XCTUnwrap(
            uncertaintyHandler.range(
                of: "eventSequence\n                <= authorization.acceptedInventoryChangeSequence"
            )
        )
        let revokePairProof = try XCTUnwrap(
            uncertaintyHandler.range(
                of: "blackHoleEndpointPairAuthorization = nil"
            )
        )
        let revokeRouting = try XCTUnwrap(
            uncertaintyHandler.range(
                of: "revokeWorldwideMicrophoneForUnsafeOutputInvariant()"
            )
        )
        XCTAssertLessThan(acceptedEventFence.lowerBound, revokePairProof.lowerBound)
        XCTAssertLessThan(revokePairProof.lowerBound, revokeRouting.lowerBound)

        let coordinatorSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/" +
                    "WorldwideIPhoneMicrophoneForwardingDriver.swift"
            ),
            encoding: .utf8
        )
        let coordinator = try sourceSlice(
            in: coordinatorSource,
            after: "final class WorldwideBlackHoleDefaultInputCoordinator {",
            before: "\n}"
        )
        XCTAssertFalse(coordinator.contains("Track"))
        XCTAssertFalse(coordinator.contains("successfulPull"))
        XCTAssertFalse(coordinator.contains("successfulFrame"))
        XCTAssertFalse(coordinator.contains("forwardingProgress"))
        XCTAssertFalse(coordinator.contains("installTrack"))
        XCTAssertFalse(
            coordinator.contains("isDriving"),
            "Default-input retries must complete synchronously; callers cannot observe an in-progress noChange."
        )
        XCTAssertFalse(
            coordinator.contains("retrySleep"),
            "Default-input retries must not suspend and let a concurrent drive escape early."
        )
        XCTAssertTrue(
            coordinator.contains(
                "nextLeaseGeneration = Self.nextNonzero("
            ),
            "Every ownership attempt must receive a fresh lease generation."
        )
        XCTAssertFalse(
            coordinator.contains(
                "leaseGeneration:\n" +
                    "                    identity.connectionGeneration"
            ),
            "Connection generations must not be reused as ownership-attempt generations."
        )

        let releaseFunction = try sourceSlice(
            in: coordinatorSource,
            after: "    private func releaseActive()",
            before: "    private func releaseActiveBounded()"
        )
        let releaseCall = try XCTUnwrap(
            releaseFunction.range(
                of: "lease.release("
            )
        )
        let keyClear = try XCTUnwrap(
            releaseFunction.range(
                of: "self.activeKey = nil"
            )
        )
        XCTAssertLessThan(
            releaseCall.lowerBound,
            keyClear.lowerBound,
            "The coordinator must retain the lease generation until restoration reports completion."
        )
    }

    func testDeviceInventoryCloseSupersedesPrevalidationGatePreparation()
        throws {
        let gate = try XCTUnwrap(
            BlackHoleMicrophoneOutputAuthorizationGate()
        )
        let admitted = gate.prepareToOpen()
        XCTAssertTrue(gate.openForTesting(preparation: admitted))
        XCTAssertTrue(gate.isOpen)

        let prevalidationPreparation = gate.prepareToOpen()
        gate.close()

        XCTAssertFalse(
            gate.isOpen,
            "The raw device-list callback must close the realtime writer immediately."
        )
        XCTAssertFalse(
            gate.openForTesting(
                preparation: prevalidationPreparation
            ),
            "A pair proof prepared before the callback must not reopen after revalidation."
        )

        let freshPreparation = gate.prepareToOpen()
        XCTAssertTrue(
            gate.openForTesting(preparation: freshPreparation),
            "Only a preparation captured after the uncertainty event may reopen the writer."
        )
    }

    func testHealthyStatisticsContinuouslyVerifyAndRevokeBeforeRepair()
        throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
            ),
            encoding: .utf8
        )
        let statisticsCase = try sourceSlice(
            in: serviceSource,
            after: "        case .statistics(let snapshot):",
            before: "        case .iceCandidateError(let error):"
        )
        XCTAssertTrue(
            statisticsCase.contains(
                "await maintainWorldwideSafeOutputInvariant()"
            )
        )
        let originFence = try XCTUnwrap(
            statisticsCase.range(
                of: "peerGeneration == sourcePeerGeneration"
            )
        )
        let pairAdmission = try XCTUnwrap(
            statisticsCase.range(
                of: "admitBlackHoleInputWithinSafeOutputFence()"
            )
        )
        let forwardingSnapshot = try XCTUnwrap(
            statisticsCase.range(
                of: "iPhoneMicrophoneForwarding.snapshot()"
            )
        )
        let forwardingAuthorization = try XCTUnwrap(
            statisticsCase.range(
                of: "await authorizeIPhoneMicrophoneForwardingIfPossible()"
            )
        )
        let hiddenWriterMarker = try XCTUnwrap(
            statisticsCase.range(
                of: "Self.hiddenWriterSelectionLogMessage("
            )
        )
        let safeOutputMaintenance = try XCTUnwrap(
            statisticsCase.range(
                of: "await maintainWorldwideSafeOutputInvariant()"
            )
        )
        XCTAssertLessThan(originFence.lowerBound, pairAdmission.lowerBound)
        XCTAssertLessThan(pairAdmission.lowerBound, forwardingAuthorization.lowerBound)
        XCTAssertLessThan(forwardingAuthorization.lowerBound, forwardingSnapshot.lowerBound)
        XCTAssertLessThan(forwardingSnapshot.lowerBound, hiddenWriterMarker.lowerBound)
        XCTAssertLessThan(hiddenWriterMarker.lowerBound, safeOutputMaintenance.lowerBound)

        let maintenance = try sourceSlice(
            in: serviceSource,
            after:
                "    private func maintainWorldwideSafeOutputInvariant() async {",
            before:
                "    private func revokeWorldwideMicrophoneForUnsafeOutputInvariant()"
        )
        XCTAssertTrue(
            maintenance.contains(
                "worldwideSafeOutputInvariant.verify(\n                monitoringEpoch: monitoringEpoch"
            )
        )
        XCTAssertTrue(maintenance.contains("if verification.isSatisfied"))
        let verificationFailureStart = try XCTUnwrap(
            maintenance.range(of: "        } catch {")
        )
        let verificationRecoveryStart = try XCTUnwrap(
            maintenance.range(
                of: "        if safeOutputInvariantVerificationWasFailing {"
            )
        )
        let verificationFailureRange = verificationFailureStart.lowerBound..<verificationRecoveryStart.lowerBound
        let verificationFailurePath = String(
            maintenance[verificationFailureRange]
        )
        XCTAssertTrue(
            verificationFailurePath.contains(
                "safeOutputInvariantVerificationWasFailing = true"
            )
        )
        XCTAssertTrue(
            verificationFailurePath.contains(
                "revokeWorldwideMicrophoneForUnsafeOutputInvariant()"
            )
        )
        XCTAssertFalse(
            verificationFailurePath.contains(
                "safeOutputInvariantRetryPolicy.recordFailure()"
            ),
            "Read-only verifier outages must not consume mutation attempts."
        )
        let verificationRecoveryRange = verificationRecoveryStart.lowerBound..<maintenance.endIndex
        let recoveredReset = try XCTUnwrap(
            maintenance.range(
                of: "safeOutputInvariantRetryPolicy.reset()",
                range: verificationRecoveryRange
            )
        )
        let satisfiedBranch = try XCTUnwrap(
            maintenance.range(of: "if verification.isSatisfied")
        )
        XCTAssertLessThan(
            recoveredReset.lowerBound,
            satisfiedBranch.lowerBound,
            "A recovered verifier must reset a prior cap before handling the same snapshot."
        )
        let unsafeStart = try XCTUnwrap(
            maintenance.range(
                of: "if verification.changedSincePreviousObservation"
            )
        )
        let unsafePath = String(
            maintenance[unsafeStart.lowerBound...]
        )
        let revocation = try XCTUnwrap(
            unsafePath.range(
                of: "revokeWorldwideMicrophoneForUnsafeOutputInvariant()"
            )
        )
        let resume = try XCTUnwrap(
            unsafePath.range(
                of: "await resumeWorldwideMicrophoneAfterSafeOutputInvariant()"
            )
        )
        XCTAssertLessThan(revocation.lowerBound, resume.lowerBound)
        XCTAssertFalse(
            unsafePath.contains("enforceWorldwideSafeOutputInvariant()")
        )

        let deviceChange = try sourceSlice(
            in: serviceSource,
            after:
                "    private func blackHoleDeviceAvailabilityDidChange(",
            before:
                "    func iPhoneMicrophoneForwardingSnapshot()"
        )
        XCTAssertTrue(
            deviceChange.contains("safeOutputInvariantRetryPolicy.reset()")
        )
        XCTAssertFalse(
            deviceChange.contains(
                "await maintainWorldwideSafeOutputInvariant()"
            )
        )
    }

    func testActualStartupGateBlocksPersistentDeferredLeaseCleanupUntilExactOwnerCompletes()
    {
        let operations =
            WorldwideScreenDefaultInputLeaseOperationsFake()
        let deferredRetainer =
            BlackHoleDefaultInputLeaseDeferredCleanupRetainer()
        var lease: BlackHoleDefaultInputLease? =
            BlackHoleDefaultInputLease(
                operations: operations,
                operationQueue: DispatchQueue(
                    label:
                        "test.WorldwideScreen.default-input-cleanup.operations"
                ),
                listenerQueue: DispatchQueue(
                    label:
                        "test.WorldwideScreen.default-input-cleanup.listener"
                ),
                proofTimeout: 0.01,
                deferredCleanupRetainer:
                    deferredRetainer
            )

        XCTAssertTrue(lease!.acquire(generation: 1))
        operations.restoreFailuresRemaining = 9
        XCTAssertEqual(
            lease!.shutdown(),
            .retryableFailure
        )
        lease = nil

        for _ in 0..<6 {
            XCTAssertEqual(
                operations.restoreWriteAttempted.wait(
                    timeout: .now() + .seconds(1)
                ),
                .success,
                "The explicit shutdown and asynchronous deinit redrive must each consume one bounded three-attempt episode."
            )
        }

        XCTAssertEqual(
            deferredRetainer.retainedJobCount,
            1
        )
        XCTAssertEqual(
            operations.currentUID,
            BlackHoleDefaultInputLease.canonicalDeviceUID
        )
        XCTAssertFalse(
            operations.removedExactRegistration
        )

        let serviceRetainer =
            WorldwideBlackHoleAudioRoutingCleanupRetainer()
        let replacement =
            WorldwideScreenRoutingOwnershipInstallationProbe()
        let deferredCleanup:
            @Sendable (Int) -> Bool = {
                maximumAttemptCount in
                BlackHoleDefaultInputLease
                    .redriveDeferredCleanup(
                        using: deferredRetainer,
                        maximumAttemptCount:
                            maximumAttemptCount
                    )
            }

        XCTAssertFalse(
            replacement.start(
                using: serviceRetainer,
                deferredDefaultInputCleanup:
                    deferredCleanup
            ),
            "The actual production startup gate must block while the old exact default-input listener/route cleanup still fails."
        )
        XCTAssertEqual(
            replacement.installationCount,
            0
        )
        XCTAssertEqual(
            deferredRetainer.retainedJobCount,
            1
        )
        XCTAssertEqual(
            operations.currentUID,
            BlackHoleDefaultInputLease.canonicalDeviceUID
        )
        XCTAssertFalse(
            operations.removedExactRegistration
        )

        XCTAssertTrue(
            replacement.start(
                using: serviceRetainer,
                deferredDefaultInputCleanup:
                    deferredCleanup
            ),
            "Replacement ownership is permitted only after the same retained exact route restoration and listener removal complete."
        )
        XCTAssertEqual(
            replacement.installationCount,
            1
        )
        XCTAssertEqual(
            deferredRetainer.retainedJobCount,
            0
        )
        XCTAssertEqual(
            operations.currentUID,
            "BuiltInMic_UID"
        )
        XCTAssertTrue(
            operations.removedExactRegistration
        )
        XCTAssertEqual(
            operations.listenerRemovalCompleted.wait(
                timeout: .now() + .seconds(1)
            ),
            .success
        )
    }

    func testRetainedAudioRoutingCleanupBlocksReplacementOwnershipUntilLaterLifecycleCompletes()
        throws {
        let retainer =
            WorldwideBlackHoleAudioRoutingCleanupRetainer()
        let cleanup =
            WorldwideScreenRoutingCleanupAttemptProbe(
                results: [false, true]
            )
        let stoppedService =
            WorldwideScreenStoppedRoutingLifecycleProbe(
                retainer: retainer,
                cleanup: cleanup
            )
        stoppedService.stopWithDegradedCleanup()

        XCTAssertEqual(retainer.retainedJobCount, 1)

        let replacement =
            WorldwideScreenRoutingOwnershipInstallationProbe()
        XCTAssertFalse(
            replacement.start(
                using: retainer,
                deferredDefaultInputCleanup: {
                    _ in true
                }
            ),
            "One bounded failed lifecycle redrive must block creation of any replacement monitor or lease ownership."
        )
        XCTAssertEqual(cleanup.attemptCount, 1)
        XCTAssertEqual(
            replacement.installationCount,
            0
        )
        XCTAssertEqual(retainer.retainedJobCount, 1)

        XCTAssertTrue(
            replacement.start(
                using: retainer,
                deferredDefaultInputCleanup: {
                    _ in true
                }
            ),
            "A later lifecycle may install replacement ownership only after the retained exact cleanup succeeds."
        )
        XCTAssertEqual(cleanup.attemptCount, 2)
        XCTAssertEqual(
            replacement.installationCount,
            1
        )
        XCTAssertEqual(retainer.retainedJobCount, 0)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
            ),
            encoding: .utf8
        )

        let monitorStartup = try sourceSlice(
            in: serviceSource,
            after: "    private func startIPhoneMicrophoneDeviceMonitoringIfNeeded()",
            before: "    private func consumeCurrentBlackHoleDeviceSnapshot()"
        )
        let startupGate = try XCTUnwrap(
            monitorStartup.range(
                of: "redriveAndPermitNewOwnership("
            )
        )
        let monitorInstallation = try XCTUnwrap(
            monitorStartup.range(
                of: "blackHoleDeviceAvailabilityMonitor.start"
            )
        )
        XCTAssertLessThan(
            startupGate.lowerBound,
            monitorInstallation.lowerBound,
            "The behavior-tested retained-cleanup gate must run before production installs a replacement monitor."
        )

        let driverSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/" +
                    "WorldwideIPhoneMicrophoneForwardingDriver.swift"
            ),
            encoding: .utf8
        )
        let productionGate = try sourceSlice(
            in: driverSource,
            after:
                "enum WorldwideBlackHoleAudioRoutingStartupGate {",
            before:
                "/// Retains exact degraded Core Audio cleanup ownership after its originating"
        )
        XCTAssertTrue(
            productionGate.contains(
                "BlackHoleDefaultInputLease\n" +
                    "                    .redriveRetainedDeferredCleanup("
            ),
            "Production replacement startup must redrive the lease-local deferred exact-cleanup domain."
        )
        XCTAssertTrue(
            productionGate.contains(
                "retainer.redriveRetained("
            ),
            "Production replacement startup must also redrive the service-level retained cleanup domain."
        )

        let shutdown = try sourceSlice(
            in: serviceSource,
            after: "    private func shutdownBlackHoleAudioRouting() {",
            before: "    private func recordBlackHoleDefaultInputOutcome("
        )
        XCTAssertTrue(
            shutdown.contains(
                "WorldwideBlackHoleAudioRoutingCleanupRetainer\n" +
                    "                .shared\n" +
                    "                .retain("
            )
        )
        XCTAssertFalse(
            shutdown.contains("during object deinitialization"),
            "Persistent degradation must be transferred to retained exact ownership rather than relying on discarded deinit state."
        )
    }

    private func sourceSlice(
        in source: String,
        after startMarker: String,
        before endMarker: String
    ) throws -> String {
        // Markers intentionally name neighboring declarations/cases so extraction fails loudly if
        // production control-flow structure changes and the integration contract needs review.
        let start = try XCTUnwrap(source.range(of: startMarker)?.upperBound)
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound
        )
        return String(source[start..<end])
    }

    private func hideContractViolations(in hideBranch: String) -> [String] {
        // Return all violations to keep mutant failures diagnostic rather than stopping at the
        // first missing argument or forbidden direct acknowledgement.
        var violations: [String] = []
        let verifiedCallCount = hideBranch.components(
            separatedBy: "acknowledgeInactiveAfterVerifiedScreenStop("
        ).count - 1
        // Ordinary Hide and the negotiated weak-network suspension Hide are distinct branches;
        // both must cross the same behavior-tested native-stop boundary before Inactive.
        if verifiedCallCount != 2 {
            violations.append("verified-boundary-call-count")
        }
        if !hideBranch.contains("peer: peer,") {
            violations.append("peer-argument")
        }
        if !hideBranch.contains("requestID: request.id,") {
            violations.append("request-id-argument")
        }
        if !hideBranch.contains("context: \"screen Hide\"") {
            violations.append("hide-context")
        }
        if hideBranch.contains("peer.acknowledgeControlRequest(") {
            violations.append("direct-peer-acknowledgement")
        }
        return violations
    }
}

private final class WorldwideScreenRoutingCleanupAttemptProbe:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var results: [Bool]
    private var attempts = 0

    init(results: [Bool]) {
        self.results = results
    }

    func attempt() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        attempts += 1
        guard !results.isEmpty else {
            return false
        }
        return results.removeFirst()
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }
}

private final class WorldwideScreenStoppedRoutingLifecycleProbe:
    @unchecked Sendable
{
    private let id = UUID()
    private let retainer:
        any WorldwideBlackHoleAudioRoutingCleanupRetaining
    private let cleanup:
        WorldwideScreenRoutingCleanupAttemptProbe
    private let lock = NSLock()
    private var didStop = false

    init(
        retainer:
            any WorldwideBlackHoleAudioRoutingCleanupRetaining,
        cleanup:
            WorldwideScreenRoutingCleanupAttemptProbe
    ) {
        self.retainer = retainer
        self.cleanup = cleanup
    }

    func stopWithDegradedCleanup() {
        lock.lock()
        guard !didStop else {
            lock.unlock()
            return
        }
        didStop = true
        lock.unlock()

        let cleanup = cleanup
        retainer.retain(id: id) {
            cleanup.attempt()
        }
    }
}

private final class WorldwideScreenRoutingOwnershipInstallationProbe:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var installationCountStorage = 0

    var installationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return installationCountStorage
    }

    func start(
        using retainer:
            any WorldwideBlackHoleAudioRoutingCleanupRetaining,
        deferredDefaultInputCleanup:
            @Sendable (Int) -> Bool = {
                maximumAttemptCount in
                BlackHoleDefaultInputLease
                    .redriveRetainedDeferredCleanup(
                        maximumAttemptCount:
                            maximumAttemptCount
                    )
            }
    ) -> Bool {
        guard WorldwideBlackHoleAudioRoutingStartupGate
                .redriveAndPermitNewOwnership(
                    retainer: retainer,
                    maximumAttemptCount: 1,
                    deferredDefaultInputCleanup:
                        deferredDefaultInputCleanup
                ) else {
            return false
        }
        lock.lock()
        installationCountStorage += 1
        lock.unlock()
        return true
    }
}

private final class
    WorldwideScreenDefaultInputLeaseOperationsFake:
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
    private let devices: [AudioDeviceID: String] = [
        1: "BuiltInMic_UID",
        2: WorldwideVirtualMicrophoneEndpointContract
            .visibleDefaultInputDeviceUID,
    ]
    private var currentDeviceID: AudioDeviceID = 1
    private var listener: Listener?
    private var restoreFailuresRemainingStorage = 0
    private var removedExactRegistrationStorage = false

    let restoreWriteAttempted =
        DispatchSemaphore(value: 0)
    let listenerRemovalCompleted =
        DispatchSemaphore(value: 0)

    var restoreFailuresRemaining: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return restoreFailuresRemainingStorage
        }
        set {
            lock.lock()
            restoreFailuresRemainingStorage =
                max(0, newValue)
            lock.unlock()
        }
    }

    var currentUID: String {
        lock.lock()
        defer { lock.unlock() }
        return devices[currentDeviceID]!
    }

    var removedExactRegistration: Bool {
        lock.lock()
        defer { lock.unlock() }
        return removedExactRegistrationStorage
    }

    func addDefaultInputListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener registration:
            CoreAudioPropertyListenerRegistration
    ) -> OSStatus {
        lock.lock()
        listener = Listener(
            address: address,
            queue: queue,
            registration: registration
        )
        lock.unlock()
        return noErr
    }

    func removeDefaultInputListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener registration:
            CoreAudioPropertyListenerRegistration
    ) -> OSStatus {
        let removed: Bool
        lock.lock()
        if let listener {
            removed =
                listener.address.mSelector
                    == address.mSelector
                && listener.address.mScope
                    == address.mScope
                && listener.address.mElement
                    == address.mElement
                && listener.queue === queue
                && listener.registration
                    === registration
            if removed {
                self.listener = nil
                removedExactRegistrationStorage =
                    true
            }
        } else {
            removed = true
        }
        lock.unlock()

        if removed {
            listenerRemovalCompleted.signal()
            return noErr
        }
        return OSStatus(-66_501)
    }

    func currentDefaultInputUID() throws
        -> String {
        currentUID
    }

    func currentDefaultInputDeviceID() throws
        -> AudioDeviceID {
        lock.lock()
        defer { lock.unlock() }
        return currentDeviceID
    }

    func resolveDeviceID(
        uid: String
    ) throws -> AudioDeviceID {
        lock.lock()
        defer { lock.unlock() }
        guard let device = devices.first(
            where: { $0.value == uid }
        )?.key else {
            throw CaptureError.audioDeviceNotFound(
                "injected missing UID"
            )
        }
        return device
    }

    func compareAndSetDefaultInputDevice(
        _ deviceID: AudioDeviceID,
        expectedCurrentUID: String
    ) -> BlackHoleDefaultInputMutationResult {
        if deviceID == 1 {
            restoreWriteAttempted.signal()
        }

        let result: (
            BlackHoleDefaultInputMutationResult,
            Listener?
        )
        lock.lock()
        guard devices[currentDeviceID]
                == expectedCurrentUID else {
            lock.unlock()
            return .currentInputMismatch
        }
        if deviceID == 1,
           restoreFailuresRemainingStorage > 0 {
            restoreFailuresRemainingStorage -= 1
            lock.unlock()
            return .written(OSStatus(-66_502))
        }
        guard devices[deviceID] != nil else {
            lock.unlock()
            return .written(OSStatus(-66_503))
        }
        currentDeviceID = deviceID
        result = (.written(noErr), listener)
        lock.unlock()

        if let listener = result.1 {
            listener.queue.sync {
                var address = listener.address
                withUnsafePointer(to: &address) {
                    listener.registration.block(1, $0)
                }
            }
        }
        return result.0
    }
}

private enum InactiveAcknowledgementError: Error, Equatable {
    case injected
}

/// Failure-injection source that records whether native-stop was attempted exactly once.
@MainActor
private final class ThrowingScreenStopSource {
    enum StopError: Error, Equatable {
        case injected
    }

    private(set) var stopAttemptCount = 0

    func stop() async throws {
        stopAttemptCount += 1
        throw StopError.injected
    }
}

/// Main-actor event ledger used to assert externally observable ordering across async closures.
@MainActor
private final class InactiveTransitionProbe {
    var events: [String] = []
    var inactiveAcknowledgementCount = 0
    var closeSessionCount = 0
    var closeError: (any Error)?
}
