import CaptureCore
import WebRTCTransport
import XCTest
@testable import CaptureServer

/// Exercises the pure state machine that separates bootstrap pairing, availability, and media.
///
/// Exchange identifiers are treated as generation tokens. Late departure events must not clear
/// a newer connection, and availability must not begin until the pairing record is durable. These
/// are regression-critical because process restarts and network reordering exercise both cases.
final class WorldwideHostLifecycleTests: XCTestCase {
    private static let routingEpoch =
        "0123456789abcdef0123456789abcdef"

    func testPeerStateLogBindsConnectedEventToExactHostProcess() {
        XCTAssertEqual(
            WorldwideScreenService.peerStateLogMessage(
                state: "connected",
                processIdentifier: 42_071
            ),
            "Worldwide WebRTC peer state: connected pid=42071"
        )
    }

    func testScreenClientDiagnosticsLogIsBoundedToAggregateProtocolEvidence() {
        let heartbeat = WebRTCScreenClientDiagnosticsHeartbeat(
            sequence: 9,
            screenRequestID: 42,
            liveness: .presentationStalled,
            trackAttached: true,
            coverVisible: false,
            coverReason: .none,
            inboundBytes: 8_192,
            inboundPackets: 64,
            framesDecoded: 32,
            framesPresented: 31,
            contentSamples: 12,
            contentChanges: 4,
            presentationAgeMilliseconds: 5_250,
            frameWidth: 1_280,
            frameHeight: 832,
            framesPerSecond: 12.5
        )

        let message = WorldwideScreenService.screenClientDiagnosticsLogMessage(
            heartbeat,
            hostPhase: .suspended,
            isCorrelated: false
        )

        XCTAssertEqual(
            message,
            "Worldwide screen client diagnostics seq=9 screenRequestID=42 "
                + "hostPhase=suspended correlation=mismatch "
                + "liveness=presentationStalled trackAttached=true "
                + "coverVisible=false coverReason=none inboundBytes=8192 "
                + "inboundPackets=64 decoded=32 presented=31 contentSamples=12 "
                + "contentChanges=4 presentationAgeMs=5250 dimensions=1280x832 "
                + "fps=12.5"
        )
        XCTAssertFalse(message.contains("trackID"))
        XCTAssertFalse(message.contains("receiverID"))
        XCTAssertFalse(message.contains("sourceID"))
        XCTAssertFalse(message.contains("SSRC"))
        XCTAssertFalse(message.contains("SDP"))
    }

    func testRemoteInputFormatDiagnosticReportsBoundedOriginAndGeometryState() {
        let portrait = WebRTCInputVideoSize(width: 1_080, height: 2_340)
        let captureGate = WorldwideRemoteInputInjectionOutcome(
            .rejected(.screenFormatChanging),
            formatOrigin: .captureGateUnavailable(
                .init(
                    phase: "active",
                    formatIsProven: false,
                    displayConfigurationInProgress: false,
                    frameMetadataState: .invalid,
                    frameSurfaceWidth: 1_206,
                    frameSurfaceHeight: 2_622,
                    retainedProvenGeometry: true
                )
            )
        )
        let controllerDiagnostic = MacRemoteInputScreenFormatDiagnostic(
            reason: .viewerAspectMismatch,
            viewerVideoSize: .init(width: 1_080, height: 2_340),
            frameSurfaceWidth: 2_340,
            frameSurfaceHeight: 1_080,
            stableGeometryAvailable: true,
            candidateGeometryAvailable: true,
            candidateAgeMilliseconds: 812,
            viewerAspectRelativeDifference: 0.7869822485
        )
        let controller = WorldwideRemoteInputInjectionOutcome(
            .rejected(.screenFormatChanging),
            formatOrigin: .controller(controllerDiagnostic)
        )

        XCTAssertEqual(
            WorldwideScreenService.remoteInputFormatDiagnostic(
                viewerVideoSize: portrait,
                outcome: captureGate
            ),
            "formatOrigin=captureGateUnavailable viewerVideoSize=1080x2340 " +
                "capturePhase=active formatProven=false " +
                "displayConfigurationInProgress=false frameMetadata=invalid " +
                "frameSurface=1206x2622 retainedProvenGeometry=true"
        )
        XCTAssertEqual(
            WorldwideScreenService.remoteInputFormatDiagnostic(
                viewerVideoSize: portrait,
                outcome: controller
            ),
            "formatOrigin=controller.viewerAspectMismatch " +
                "viewerVideoSize=1080x2340 frameSurface=2340x1080 " +
                "stableGeometry=true candidateGeometry=true " +
                "candidateAgeMs=812 viewerAspectDeltaPPM=786982"
        )
        XCTAssertNil(
            WorldwideScreenService.remoteInputFormatDiagnostic(
                viewerVideoSize: portrait,
                outcome: .init(.accepted(.none))
            )
        )
        XCTAssertNil(
            WorldwideScreenService.remoteInputFormatDiagnostic(
                viewerVideoSize: portrait,
                outcome: .init(.rejected(.invalidPoint))
            )
        )
    }

    func testDefaultInputLogBindsHealthyBoundaryToPeerAndHostProcess() {
        XCTAssertEqual(
            WorldwideScreenService.defaultInputSelectionLogMessage(
                routingEpoch: Self.routingEpoch,
                peerGeneration: 9,
                deviceGeneration: 4,
                processIdentifier: 42_071
            ),
            "Worldwide authenticated media route selected virtual " +
                "microphone default input routingEpoch=\(Self.routingEpoch) " +
                "peerGeneration=9 " +
                "deviceGeneration=4 pid=42071"
        )
    }

    func testRoutingEpochIsPrivacySafeLowercaseHex() {
        let epoch = WorldwideScreenService.makeBlackHoleRoutingEpoch()

        XCTAssertEqual(epoch.utf8.count, 32)
        XCTAssertTrue(
            epoch.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57)
                    || ($0 >= 97 && $0 <= 102)
            }
        )
    }

    func testHiddenWriterSelectionLogBindsPairToPeerAndHostProcess() {
        XCTAssertEqual(
            WorldwideScreenService.hiddenWriterSelectionLogMessage(
                routingEpoch: Self.routingEpoch,
                peerGeneration: 9,
                deviceGeneration: 4,
                selectionProven: true,
                processIdentifier: 42_071
            ),
            "Worldwide iPhone microphone hidden writer selected " +
                "routingEpoch=\(Self.routingEpoch) " +
                "peerGeneration=9 deviceGeneration=4 pid=42071"
        )
        XCTAssertNil(
            WorldwideScreenService.hiddenWriterSelectionLogMessage(
                routingEpoch: Self.routingEpoch,
                peerGeneration: 9,
                deviceGeneration: 4,
                selectionProven: false,
                processIdentifier: 42_071
            )
        )
    }

    func testMicrophoneForwardingTelemetryIsProgressOnlyAndPrivacySafe() {
        let message = WorldwideScreenService
            .iPhoneMicrophoneForwardingLogMessage(
                .inactive(policy: .enabled)
            )

        XCTAssertEqual(
            message,
            "Worldwide iPhone microphone forwarding " +
                "phase=waitingForPeer inputEndpointAvailable=false " +
                "hiddenSinkAvailable=false " +
                "hiddenWriterSelectionProven=false transport=false " +
                "trackAdmitted=false queueRunning=false callbacks=0 " +
                "pulls=0 frames=0 silenceFallbacks=0 " +
                "enqueueFailures=0 pcmLifecycleGeneration=0 " +
                "pcmWindowSequence=0 pcmCompletedFrames=0 " +
                "pcmSourceStartFrame=0 pcmSourceEndFrame=0 " +
                "pcmWindowFrames=0 pcmWindowBytes=0 " +
                "boundDecGeneration=0 " +
                "boundDecRenderFloor=0 " +
                "pcmRMS=0.000000 pcmRMSdBFS=-160.00 " +
                "pcmPeak=0.000000 pcmPeakdBFS=-160.00 " +
                "pcmDC=0.000000 pcmZeroFraction=0.000000 " +
                "pcmClippingFraction=0.000000 " +
                "decGeneration=0 decCalls=0 decRequestedFrames=0 " +
                "decRequestedBytes=0 decReturnedBytes=0 " +
                "decNativeSuccess=0 decNativeFailure=0 " +
                "decExactContracts=0 decAnalyzedCalls=0 " +
                "decAnalyzedFrames=0 decAnalyzedBytes=0 " +
                "decDropped=0 decContractMismatch=0 " +
                "decPendingFrames=0 decLatestCall=0 " +
                "decLatestStatus=0 decLatestRequestedFrames=0 " +
                "decLatestRequestedBytes=0 decLatestReturnedBytes=0 " +
                "decLatestExact=false " +
                "decHasWindow=false decWindowSequence=0 " +
                "decWindowGeneration=0 decSourceStartFrame=0 " +
                "decSourceEndFrame=0 decWindowFrames=0 " +
                "decWindowBytes=0 " +
                "decRMS=0.000000 decRMSdBFS=-160.00 " +
                "decPeak=0.000000 decPeakdBFS=-160.00 " +
                "decDC=0.000000 decZeroFraction=0.000000 " +
                "decClippingFraction=0.000000 " +
                "decAllZero=false " +
                "decFrozenBlocks=0 decLongestFrozenRun=0 " +
                "contentWindowsAlign=false " +
                "contentFingerprintsMatch=false " +
                "mediaSample=0 mediaAdvances=0 " +
                "mediaStale=0 mediaFresh=false failure=none"
        )
        XCTAssertFalse(message.contains("BlackHole2ch_UID"))
        XCTAssertFalse(message.contains("BlackHole2ch_2_UID"))
        XCTAssertFalse(
            message.contains(
                "com.elamin.opensteamer.virtual-microphone.input"
            )
        )
        XCTAssertFalse(
            message.contains(
                "com.elamin.opensteamer.virtual-microphone.writer"
            )
        )
        XCTAssertFalse(message.contains("trackID"))
        XCTAssertFalse(message.contains("attemptID"))
        XCTAssertFalse(message.contains("nonce"))
        XCTAssertFalse(message.contains("rawPCM"))
        XCTAssertFalse(message.contains("windowFingerprint"))
        XCTAssertFalse(message.contains("Correlation"))
        XCTAssertFalse(message.contains("LeftOnly"))
        XCTAssertFalse(message.contains("RightOnly"))
    }

    func testInboundAudioRTPTelemetryIsAggregateAndPrivacySafe() {
        let message = WorldwideScreenService.inboundAudioRTPLogMessage(
            packets: 127,
            bytes: 48_210,
            totalAudioEnergy: 0.125,
            audioLevel: 0.03125
        )

        XCTAssertEqual(
            message,
            "Worldwide inbound audio RTP packets=127 bytes=48210 "
                + "energy=0.125000 level=0.031250"
        )
        XCTAssertFalse(message.contains("BlackHole2ch_UID"))
        XCTAssertFalse(message.contains("BlackHole2ch_2_UID"))
        XCTAssertFalse(
            message.contains(
                "com.elamin.opensteamer.virtual-microphone.input"
            )
        )
        XCTAssertFalse(
            message.contains(
                "com.elamin.opensteamer.virtual-microphone.writer"
            )
        )
        XCTAssertFalse(message.contains("trackID"))
        XCTAssertFalse(message.contains("device"))
        XCTAssertFalse(message.contains("nonce"))
    }

    func testSafeOutputRetryPolicyBacksOffThenProbesAfterCappedCooldown() {
        var policy = WorldwideSafeOutputInvariantRetryPolicy(
            maximumFailedAttemptCount: 3,
            maximumBackoffTickCount: 4,
            cappedCooldownTickCount: 3
        )

        XCTAssertTrue(policy.shouldAttemptOnCurrentTick())
        policy.recordFailure()
        XCTAssertFalse(policy.shouldAttemptOnCurrentTick())
        XCTAssertTrue(policy.shouldAttemptOnCurrentTick())

        policy.recordFailure()
        XCTAssertFalse(policy.shouldAttemptOnCurrentTick())
        XCTAssertFalse(policy.shouldAttemptOnCurrentTick())
        XCTAssertTrue(policy.shouldAttemptOnCurrentTick())

        policy.recordFailure()
        for _ in 0..<3 {
            XCTAssertFalse(policy.shouldAttemptOnCurrentTick())
        }
        XCTAssertEqual(policy.failedAttemptCount, 3)
        XCTAssertTrue(policy.shouldAttemptOnCurrentTick())
        XCTAssertEqual(policy.failedAttemptCount, 0)

        policy.recordFailure()
        policy.reset()
        XCTAssertEqual(policy.failedAttemptCount, 0)
        XCTAssertTrue(policy.shouldAttemptOnCurrentTick())
    }

    func testAvailabilityBackoffDoesNotResetForUpgradeFollowedByServerError() {
        var policy = WorldwideAvailabilityRetryPolicy()

        XCTAssertEqual(policy.delayAfterFailure(), 1)
        XCTAssertEqual(policy.delayAfterFailure(), 2)
        XCTAssertEqual(policy.delayAfterFailure(), 4)
        XCTAssertEqual(policy.delayAfterFailure(), 8)
        XCTAssertEqual(policy.delayAfterFailure(), 16)
        XCTAssertEqual(policy.delayAfterFailure(), 30)
        XCTAssertEqual(policy.delayAfterFailure(), 30)
        XCTAssertFalse(policy.hasValidatedConnection)
    }

    func testValidAvailabilityStateResetsBackoffAndIsReportedOncePerConnection() {
        var policy = WorldwideAvailabilityRetryPolicy()
        XCTAssertEqual(policy.delayAfterFailure(), 1)
        XCTAssertEqual(policy.delayAfterFailure(), 2)

        XCTAssertTrue(policy.observedValidAvailabilityState())
        XCTAssertFalse(policy.observedValidAvailabilityState())
        XCTAssertTrue(policy.hasValidatedConnection)
        XCTAssertEqual(policy.delayAfterFailure(), 1)

        XCTAssertTrue(policy.observedValidAvailabilityState())
        XCTAssertEqual(policy.nextDelaySeconds, 1)
    }

    func testMediaDepartureReturnsPairedHostToAvailability() throws {
        var lifecycle = WorldwideHostLifecycle()
        try lifecycle.start(hasPairedViewer: true)
        try lifecycle.availabilityReady(exchangeID: "exchange-one")
        try lifecycle.mediaStarted(exchangeID: "exchange-one")

        lifecycle.availabilityPeerLeft(exchangeID: "exchange-one")
        // Signaling may leave while its already-established media peer is still shutting down.
        XCTAssertEqual(lifecycle.runState, .pairedAvailable)
        XCTAssertNil(lifecycle.activeExchangeID)
        XCTAssertEqual(lifecycle.mediaExchangeID, "exchange-one")

        lifecycle.mediaEnded(exchangeID: "exchange-one")
        XCTAssertEqual(lifecycle.runState, .pairedAvailable)
        XCTAssertNil(lifecycle.mediaExchangeID)

        try lifecycle.availabilityReady(exchangeID: "exchange-two")
        XCTAssertEqual(lifecycle.activeExchangeID, "exchange-two")
    }

    func testInvitationMustCommitBeforeAvailabilityCanAcceptViewer() throws {
        var lifecycle = WorldwideHostLifecycle()
        try lifecycle.start(hasPairedViewer: false)
        XCTAssertEqual(lifecycle.runState, .inviting)
        XCTAssertThrowsError(try lifecycle.availabilityReady(exchangeID: "too-early"))

        try lifecycle.durablePairingRecordAvailable()
        try lifecycle.availabilityReady(exchangeID: "after-commit")
        XCTAssertEqual(lifecycle.runState, .pairedAvailable)
    }

    func testBootstrapLossAfterDurableRecordMovesToAvailabilityRecovery() throws {
        var lifecycle = WorldwideHostLifecycle()
        try lifecycle.start(hasPairedViewer: false)

        try lifecycle.durablePairingRecordAvailable()

        XCTAssertEqual(lifecycle.runState, .pairedAvailable)
        try lifecycle.availabilityReady(exchangeID: "commit-recovery")
        XCTAssertEqual(lifecycle.activeExchangeID, "commit-recovery")
    }

    func testStaleDepartureCannotClearNewExchange() throws {
        var lifecycle = WorldwideHostLifecycle()
        try lifecycle.start(hasPairedViewer: true)
        try lifecycle.availabilityReady(exchangeID: "old")
        lifecycle.availabilityPeerLeft(exchangeID: "old")
        try lifecycle.availabilityReady(exchangeID: "new")

        lifecycle.availabilityPeerLeft(exchangeID: "old")
        lifecycle.mediaEnded(exchangeID: "old")
        XCTAssertEqual(lifecycle.activeExchangeID, "new")
    }
}
