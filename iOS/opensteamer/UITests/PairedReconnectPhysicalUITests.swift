import XCTest

/// Release gate for the exact physical failure reported from the distributed production build. The test deliberately
/// launches the isolated TestFlight bundle rather than the side-by-side `.dev` app. A shell
/// preflight must first prove the expected distributed build is
/// installed; missing pairing, accessibility identifiers, host availability, or any live route is
/// a failure, never a skip.
@MainActor
final class PairedReconnectPhysicalUITests: XCTestCase {
    /// Internal sentinel used when an accessibility oracle rejects otherwise reachable UI.
    private enum PhysicalValidationError: Error {
        case oracleRejected
    }

    /// Screen evidence retained across a stability interval for final cross-checks and attachments.
    private struct LiveScreenEvidence {
        let showAcknowledgement: PhysicalScreenAcknowledgementSnapshot
        let initialVideoSnapshot: PhysicalVideoRenderSnapshot
        let finalVideoSnapshot: PhysicalVideoRenderSnapshot
    }

    /// Exact iPhone production raw-sender evidence. This intentionally makes no claim about later
    /// Mac forwarding, BlackHole delivery, host application consumption, or acoustic audibility.
    private struct LiveRawMicrophoneEvidence {
        let initialSnapshot: PhysicalRawMicrophoneSnapshot
        let finalSnapshot: PhysicalRawMicrophoneSnapshot
        let elapsed: TimeInterval
        let advancementObservations: Int
        let continuityDurationNs: UInt64
        let applicationProcessIDAtStart: Int32
        let applicationProcessIDAtEnd: Int32
        let sampleLog: String
    }

    /// Route and final monotonic audio snapshot from one verified playback window.
    private struct LivePlaybackEvidence {
        let route: String
        let finalAudioSnapshot: PhysicalAudioPlayoutSnapshot
    }

    private struct LiveHostedCallEvidence {
        let route: String
        let initialSnapshot: PhysicalHostedCallPlayoutSnapshot
        let finalSnapshot: PhysicalHostedCallPlayoutSnapshot
        let elapsed: TimeInterval
        let sampleLog: String
    }

    private struct LivePostCallPlaybackEvidence {
        let route: String
        let excludedHostedAudioPolicyGenerations: Set<UUID>
        let ordinaryAudioPolicyGeneration: UUID
        let postCallBaseline: PhysicalAudioPlayoutSnapshot
        let finalAudioSnapshot: PhysicalAudioPlayoutSnapshot
        let elapsed: TimeInterval
        let sampleLog: String
    }

    // The validation shell exports the exact side-by-side TestFlight identity. The application
    // object itself is never constructed with caller-controlled input.
    private static let sideBySideAppBundleIdentifier = "com.elamin.opensteamer"
    private static let guardedPhysicalEvidenceRoot = "/Volumes/t7"
    private let app = XCUIApplication(bundleIdentifier: Self.sideBySideAppBundleIdentifier)
    // Audio diagnostics are published by the one-second WebRTC statistics task, so 1.5 seconds
    // permits one ordinary publication interval without allowing a late burst to launder a stall.
    private let maximumAudioOracleProgressGap: TimeInterval = 1.5
    private let maximumRawMicrophoneOracleProgressGap: TimeInterval = 1.5
    // At a 60 fps source, a 750 ms decoded-frame stall is already user-visible.
    private let maximumVideoOracleProgressGap: TimeInterval = 0.75
    private let backgroundEvidenceDuration: TimeInterval = 35
    // A separate physical driver proves the real connected iPhone call is already connected before
    // this production app cold-launches, then ends it later while the same process remains live.
    // Missing either boundary is an acceptance failure, never a skip.
    private let physicalCallTransitionTimeout: TimeInterval = 120

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        let requestedBundleIdentifier = ProcessInfo.processInfo.environment[
            "OPENSTEAMER_EXPECTED_APP_BUNDLE_IDENTIFIER"
        ]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? Self.sideBySideAppBundleIdentifier
        XCTAssertEqual(
            requestedBundleIdentifier,
            Self.sideBySideAppBundleIdentifier,
            "Physical TestFlight validation is restricted to the isolated side-by-side app."
        )
    }

    /// Pre-update evidence for the production build that originally exhibited the regression.
    /// This method must remain limited to accessibility identifiers already shipped in installed release;
    /// the candidate-only presentation and pair-fingerprint oracles are intentionally forbidden.
    func testLegacyInstalledReleaseProductionBaselineHasSavedPair() {
        app.terminate()
        app.launch()

        XCTAssertTrue(
            element("worldwidePairedMac").waitForExistence(timeout: 10),
            "Installed release did not restore its saved paired Mac"
        )
        XCTAssertTrue(
            element("worldwidePairingSaved").exists,
            "Installed release did not show its saved-pair confirmation"
        )
        let connect = app.buttons["connectPairedWorldwide"]
        XCTAssertTrue(connect.exists, "Installed release has no saved-pair connect action")
        XCTAssertEqual(connect.label, "Connect to Paired Mac")
        XCTAssertFalse(
            element("worldwideInvitationCode").exists,
            "A restored active pair must not fall back to the one-time invitation UI"
        )

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Installed release saved-pair baseline"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testProductionRawIPhoneMicrophoneOracleSustainsRollingContinuity() throws {
        let runtimeNonce = try XCTUnwrap(
            ProcessInfo.processInfo.environment[
                "OPENSTEAMER_RAW_CONTINUITY_PROOF_NONCE"
            ]?.trimmingCharacters(in: .whitespacesAndNewlines),
            "The raw overlap nonce was not propagated into XCTest."
        )
        guard runtimeNonce.range(
            of: #"^[A-Za-z0-9-]{16,128}$"#,
            options: .regularExpression
        ) != nil else {
            XCTFail("The raw overlap nonce was malformed.")
            return
        }

        hardLaunch()
        let expectedPairFingerprint = try currentPairFingerprint()
        assertSavedPairIsIdleWithoutHistoricalError(
            expectedPairFingerprint: expectedPairFingerprint
        )

        let playback = try connectAndRequireStablePlayback(
            phase: "raw iPhone microphone production oracle"
        )
        XCTAssertTrue(
            element("toggleWorldwideIPhoneMicrophone")
                .waitForExistence(timeout: 10),
            "The production session exposed no iPhone microphone control."
        )

        let evidence = try XCTUnwrap(
            waitForStableRawIPhoneMicrophone(
                timeout: 65,
                stableFor: 30,
                expectedSessionGeneration:
                    playback.finalAudioSnapshot.sessionGeneration
            ),
            "The production iPhone oracle did not sustain density-checked raw sender progress. Last observation: \(liveRawMicrophoneObservation)"
        )

        XCTAssertGreaterThanOrEqual(
            evidence.advancementObservations,
            2
        )
        XCTAssertEqual(
            evidence.initialSnapshot.sessionGeneration,
            evidence.finalSnapshot.sessionGeneration
        )
        XCTAssertEqual(
            evidence.initialSnapshot.windowGeneration,
            evidence.finalSnapshot.windowGeneration
        )
        XCTAssertGreaterThanOrEqual(
            evidence.continuityDurationNs,
            30_000_000_000
        )
        XCTAssertGreaterThan(
            evidence.applicationProcessIDAtStart,
            0
        )
        XCTAssertEqual(
            evidence.applicationProcessIDAtStart,
            evidence.applicationProcessIDAtEnd
        )


        let attachment = XCTAttachment(
            string:
                "schema=opensteamer.raw-ui-continuity.v1\n"
                    + "nonce=\(runtimeNonce)\n"
                    + "scope=iPhone production raw microphone sender oracle only; downstream Mac BlackHole consumption is not claimed\n"
                    + evidence.sampleLog
        )
        attachment.name =
            "Production raw iPhone microphone rolling continuity evidence"
        attachment.lifetime = .keepAlways
        add(attachment)

        let runtimeAttachment = XCTAttachment(
            string:
                "schema=opensteamer.raw-ui-runtime.v1\n"
                    + "nonce=\(runtimeNonce)\n"
                    + "continuityDurationNs=\(evidence.continuityDurationNs)\n"
                    + "appPIDAtStart=\(evidence.applicationProcessIDAtStart)\n"
                    + "appPIDAtEnd=\(evidence.applicationProcessIDAtEnd)\n"
        )
        runtimeAttachment.name =
            "Production raw iPhone microphone runtime overlap evidence"
        runtimeAttachment.lifetime = .keepAlways
        add(runtimeAttachment)

        publishRawUIContinuityBoundary(
            "OPENSTEAMER_RAW_UI_CONTINUITY_COMPLETE_V1",
            nonce: runtimeNonce
        )
        RunLoop.current.run(until: Date().addingTimeInterval(10))
        publishRawUIContinuityBoundary(
            "OPENSTEAMER_RAW_UI_TEARDOWN_BEGIN_V1",
            nonce: runtimeNonce
        )
        app.buttons["disconnectWorldwide"].tap()
        XCTAssertTrue(
            waitForHostFailureToReturnToSavedPair(timeout: 45)
        )
        assertSavedPairIsIdleWithoutHistoricalError(
            expectedPairFingerprint: expectedPairFingerprint
        )
        app.terminate()
    }

    func testRealConnectedCallRecoveryRotatesOrdinaryAudioPolicyAndRequiresFreshProof() throws {
        let postCallRuntimeNonce = try XCTUnwrap(
            ProcessInfo.processInfo.environment[
                "OPENSTEAMER_POST_CALL_RAW_CONTINUITY_PROOF_NONCE"
            ]?.trimmingCharacters(in: .whitespacesAndNewlines),
            "The post-call raw overlap nonce was not propagated into XCTest."
        )
        guard postCallRuntimeNonce.range(
            of: #"^[A-Za-z0-9-]{16,128}$"#,
            options: .regularExpression
        ) != nil else {
            XCTFail("The post-call raw overlap nonce was malformed.")
            return
        }
        let postCallRawContinuityText = try XCTUnwrap(
            ProcessInfo.processInfo.environment[
                "OPENSTEAMER_POST_CALL_RAW_CONTINUITY_SECONDS"
            ]?.trimmingCharacters(in: .whitespacesAndNewlines),
            "The required post-call raw continuity duration was not propagated into XCTest."
        )
        let postCallRawTimeoutText = try XCTUnwrap(
            ProcessInfo.processInfo.environment[
                "OPENSTEAMER_POST_CALL_RAW_UI_TIMEOUT_SECONDS"
            ]?.trimmingCharacters(in: .whitespacesAndNewlines),
            "The bounded post-call raw UI timeout was not propagated into XCTest."
        )
        let callAcousticRequestPath = try XCTUnwrap(
            ProcessInfo.processInfo.environment[
                "OPENSTEAMER_CALL_ACOUSTIC_REQUEST_PATH"
            ]?.trimmingCharacters(in: .whitespacesAndNewlines),
            "The acoustic acknowledgement request path was not propagated into XCTest."
        )
        let callAcousticStatusPath = try XCTUnwrap(
            ProcessInfo.processInfo.environment[
                "OPENSTEAMER_CALL_ACOUSTIC_STATUS_PATH"
            ]?.trimmingCharacters(in: .whitespacesAndNewlines),
            "The acoustic acknowledgement status path was not propagated into XCTest."
        )
        let callAcousticTimeoutText = try XCTUnwrap(
            ProcessInfo.processInfo.environment[
                "OPENSTEAMER_CALL_ACOUSTIC_TIMEOUT_SECONDS"
            ]?.trimmingCharacters(in: .whitespacesAndNewlines),
            "The acoustic acknowledgement timeout was not propagated into XCTest."
        )
        guard let postCallRawContinuitySeconds = UInt64(
                postCallRawContinuityText
              ),
              (30...600).contains(postCallRawContinuitySeconds),
              let postCallRawTimeoutSeconds = UInt64(
                postCallRawTimeoutText
              ),
              postCallRawTimeoutSeconds > postCallRawContinuitySeconds,
              postCallRawTimeoutSeconds <= 720,
              let callAcousticTimeoutSeconds = UInt64(
                callAcousticTimeoutText
              ),
              (1...300).contains(callAcousticTimeoutSeconds),
              Self.isGuardedT7EvidencePath(callAcousticRequestPath),
              Self.isGuardedT7EvidencePath(callAcousticStatusPath) else {
            XCTFail("The post-call raw timing contract was malformed or outside its reviewed bounds.")
            return
        }
        let postCallRawContinuityDuration = TimeInterval(
            postCallRawContinuitySeconds
        )
        let postCallRawTimeoutDuration = TimeInterval(
            postCallRawTimeoutSeconds
        )
        let requiredPostCallContinuityNs =
            postCallRawContinuitySeconds * 1_000_000_000
        let callAcousticTimeoutDuration = TimeInterval(
            callAcousticTimeoutSeconds
        )

        hardLaunch()
        let expectedPairFingerprint = try currentPairFingerprint()
        assertSavedPairIsIdleWithoutHistoricalError(
            expectedPairFingerprint: expectedPairFingerprint
        )

        let connect = app.buttons["connectPairedWorldwide"]
        XCTAssertTrue(
            connect.exists,
            "The production session exposed no saved-pair connect action during the driver-proven connected call."
        )
        XCTAssertEqual(connect.label, "Connect to Paired Mac")
        connect.tap()

        let startup = try XCTUnwrap(
            waitForStableHostedCallPlayout(
                timeout: physicalCallTransitionTimeout,
                stableFor: 2,
                expectedOrigin: .startupConnectedCall,
                expectedSessionGeneration: nil
            ),
            "The cold-launched production app did not establish a sustained startup-connected-call hosted playout window with advancing incoming Mac audio. Last observation: \(livePlaybackObservation)"
        )
        XCTAssertEqual(
            startup.initialSnapshot.origin,
            .startupConnectedCall
        )
        XCTAssertEqual(
            startup.finalSnapshot.origin,
            .startupConnectedCall
        )
        XCTAssertEqual(
            startup.initialSnapshot.sessionGeneration,
            startup.finalSnapshot.sessionGeneration
        )
        XCTAssertEqual(
            startup.initialSnapshot.policyID,
            startup.finalSnapshot.policyID
        )
        XCTAssertEqual(
            startup.initialSnapshot.audioPolicyGeneration,
            startup.finalSnapshot.audioPolicyGeneration
        )
        XCTAssertEqual(
            startup.initialSnapshot.authorizationGeneration,
            startup.finalSnapshot.authorizationGeneration
        )
        XCTAssertTrue(
            acceptedRouteValues.contains(startup.route),
            "Startup connected-call playout did not retain a Direct or TURN relay route."
        )
        assertActivePresentation(route: startup.route)
        XCTAssertEqual(
            element("worldwideMicrophoneState").value as? String,
            "Muted — iPhone call active",
            "Startup connected-call playout must keep the iPhone microphone unavailable."
        )
        XCTAssertFalse(
            element("worldwideRawMicrophoneOracle").exists,
            "Startup connected-call playout must not expose a raw iPhone microphone oracle."
        )

        let startupAttachment = XCTAttachment(
            string:
                "scope=startup-connected-call incoming Mac playout before the final iOS mixer/route/DAC/speaker\n"
                    + "route=\(startup.route)\n"
                    + startup.sampleLog
        )
        startupAttachment.name =
            "Startup connected-call incoming Mac playout continuity evidence"
        startupAttachment.lifetime = .keepAlways
        add(startupAttachment)

        let interruption = try XCTUnwrap(
            waitForStableHostedCallPlayout(
                timeout: physicalCallTransitionTimeout,
                stableFor: 2,
                expectedOrigin: .interruption,
                expectedSessionGeneration:
                    startup.finalSnapshot.sessionGeneration
            ),
            "The connected call did not produce a second sustained hosted playout window from a genuine AVAudioSession interruption. Last observation: \(livePlaybackObservation)"
        )
        XCTAssertEqual(
            interruption.initialSnapshot.origin,
            .interruption
        )
        XCTAssertEqual(
            interruption.finalSnapshot.origin,
            .interruption
        )
        XCTAssertEqual(
            interruption.initialSnapshot.sessionGeneration,
            interruption.finalSnapshot.sessionGeneration
        )
        XCTAssertEqual(
            interruption.finalSnapshot.sessionGeneration,
            startup.finalSnapshot.sessionGeneration
        )
        XCTAssertEqual(
            interruption.initialSnapshot.policyID,
            interruption.finalSnapshot.policyID
        )
        XCTAssertEqual(
            interruption.initialSnapshot.audioPolicyGeneration,
            interruption.finalSnapshot.audioPolicyGeneration
        )
        XCTAssertEqual(
            interruption.initialSnapshot.authorizationGeneration,
            interruption.finalSnapshot.authorizationGeneration
        )
        XCTAssertTrue(
            acceptedRouteValues.contains(interruption.route),
            "Interruption-origin hosted playout did not retain a Direct or TURN relay route."
        )
        assertActivePresentation(route: interruption.route)
        XCTAssertEqual(
            element("worldwideMicrophoneState").value as? String,
            "Muted — iPhone call active",
            "Interruption-origin hosted playout must keep the iPhone microphone unavailable."
        )
        XCTAssertFalse(
            element("worldwideRawMicrophoneOracle").exists,
            "Interruption-origin hosted playout must not expose a raw iPhone microphone oracle."
        )

        let interruptionAttachment = XCTAttachment(
            string:
                "scope=interruption-origin incoming Mac playout before the final iOS mixer/route/DAC/speaker\n"
                    + "route=\(interruption.route)\n"
                    + interruption.sampleLog
        )
        interruptionAttachment.name =
            "Interruption-origin incoming Mac playout continuity evidence"
        interruptionAttachment.lifetime = .keepAlways
        add(interruptionAttachment)

        XCTAssertNotEqual(
            startup.finalSnapshot.policyID,
            interruption.finalSnapshot.policyID,
            "A genuine interruption must replace the startup-connected-call hosted policy."
        )

        let excludedHostedAudioPolicyGenerations: Set<UUID> = [
            startup.finalSnapshot.audioPolicyGeneration,
            interruption.finalSnapshot.audioPolicyGeneration,
        ]
        XCTAssertEqual(
            excludedHostedAudioPolicyGenerations.count,
            2,
            "Startup and interruption hosted windows must use distinct audio-policy generations."
        )

        let hostedMarkerRawMicrophone =
            element("worldwideRawMicrophoneOracle")
        guard presentationValue == "active",
              !hasConnectionError,
              element("worldwideSessionState").value as? String
                == "Connected",
              element("worldwideAudioState").value as? String
                == "Playing — iPhone call may reduce quality",
              element("worldwideMicrophoneState").value as? String
                == "Muted — iPhone call active",
              !hostedMarkerRawMicrophone.exists,
              interruption.initialSnapshot.origin == .interruption,
              interruption.finalSnapshot.origin == .interruption,
              interruption.initialSnapshot.sessionGeneration
                == interruption.finalSnapshot.sessionGeneration,
              interruption.finalSnapshot.sessionGeneration
                == startup.finalSnapshot.sessionGeneration,
              acceptedRouteValues.contains(interruption.route),
              startup.finalSnapshot.policyID
                != interruption.finalSnapshot.policyID,
              excludedHostedAudioPolicyGenerations.count == 2 else {
            XCTFail(
                "Refusing to publish the hosted-call causal marker because the immediately observed UI and oracle state was not the proven connected-call state. Last observation: \(livePlaybackObservation)"
            )
            return
        }

        // Sequence 1 proves hosted-call state immediately before the driver may accept an
        // acoustic acknowledgement. XCTest then stays in this loop and fails closed on any
        // ordinary-playback transition until it consumes the exact accepted record and observes
        // fresh hosted-call advancement after that acceptance.
        publishHostedCallBoundary(
            nonce: postCallRuntimeNonce,
            sequence: 1,
            acousticToken: "-"
        )
        let acceptedAcousticToken = try XCTUnwrap(
            waitForAcceptedAcousticAcknowledgementWhileHosted(
                requestPath: callAcousticRequestPath,
                statusPath: callAcousticStatusPath,
                nonce: postCallRuntimeNonce,
                expectedRoute: interruption.route,
                baseline: interruption.finalSnapshot,
                timeout: callAcousticTimeoutDuration
            ),
            "The exact nonce-bound acoustic acknowledgement was not consumed while interruption-origin hosted playout remained live. Last observation: \(livePlaybackObservation)"
        )
        publishHostedCallBoundary(
            nonce: postCallRuntimeNonce,
            sequence: 2,
            acousticToken: acceptedAcousticToken
        )

        let recovered = try XCTUnwrap(
            waitForFreshPostCallOrdinaryPlayback(
                expectedSessionGeneration:
                    startup.finalSnapshot.sessionGeneration,
                excludedHostedAudioPolicyGenerations:
                    excludedHostedAudioPolicyGenerations,
                timeout: physicalCallTransitionTimeout,
                stableFor: 2
            ),
            "Final call recovery did not establish and advance fresh ordinary Playing evidence under the original media session. Last observation: \(livePlaybackObservation)"
        )

        XCTAssertEqual(
            recovered.postCallBaseline.sessionGeneration,
            startup.finalSnapshot.sessionGeneration
        )
        XCTAssertEqual(
            recovered.finalAudioSnapshot.sessionGeneration,
            startup.finalSnapshot.sessionGeneration
        )
        XCTAssertEqual(
            recovered.postCallBaseline.audioPolicyGeneration,
            recovered.ordinaryAudioPolicyGeneration
        )
        XCTAssertEqual(
            recovered.finalAudioSnapshot.audioPolicyGeneration,
            recovered.ordinaryAudioPolicyGeneration
        )
        XCTAssertEqual(
            recovered.excludedHostedAudioPolicyGenerations,
            excludedHostedAudioPolicyGenerations
        )
        XCTAssertFalse(
            excludedHostedAudioPolicyGenerations.contains(
                recovered.finalAudioSnapshot.audioPolicyGeneration
            ),
            "Ordinary recovery reused a hosted-call audio-policy generation."
        )
        XCTAssertEqual(
            element("worldwideAudioState").value as? String,
            "Playing",
            "Final recovery did not remain in ordinary Playing state."
        )
        XCTAssertFalse(
            element("worldwideHostedCallPlayoutOracle").exists,
            "Final ordinary recovery retained a hosted-call oracle after the call ended."
        )
        assertActivePresentation(route: recovered.route)

        let finalSessionGenerations: Set<UUID> = [
            startup.finalSnapshot.sessionGeneration,
            interruption.finalSnapshot.sessionGeneration,
            recovered.finalAudioSnapshot.sessionGeneration,
        ]
        XCTAssertEqual(
            finalSessionGenerations.count,
            1,
            "Startup, interruption, and ordinary recovery must remain in one media-session generation."
        )

        let finalAudioPolicyGenerations: Set<UUID> = [
            startup.finalSnapshot.audioPolicyGeneration,
            interruption.finalSnapshot.audioPolicyGeneration,
            recovered.finalAudioSnapshot.audioPolicyGeneration,
        ]
        XCTAssertEqual(
            finalAudioPolicyGenerations.count,
            3,
            "Startup, interruption, and ordinary recovery audio-policy generations must be pairwise distinct."
        )

        let excludedHostedPolicyText =
            recovered.excludedHostedAudioPolicyGenerations
                .map { $0.uuidString.lowercased() }
                .sorted()
                .joined(separator: ",")
        let recoveredAttachment = XCTAttachment(
            string:
                "startupOrigin=\(startup.finalSnapshot.origin.rawValue) startupSession=\(startup.finalSnapshot.sessionGeneration) startupPolicyID=\(startup.finalSnapshot.policyID) startupAudioPolicyGeneration=\(startup.finalSnapshot.audioPolicyGeneration) startupAuthorizationGeneration=\(startup.finalSnapshot.authorizationGeneration)\n"
                    + "interruptionOrigin=\(interruption.finalSnapshot.origin.rawValue) interruptionSession=\(interruption.finalSnapshot.sessionGeneration) interruptionPolicyID=\(interruption.finalSnapshot.policyID) interruptionAudioPolicyGeneration=\(interruption.finalSnapshot.audioPolicyGeneration) interruptionAuthorizationGeneration=\(interruption.finalSnapshot.authorizationGeneration)\n"
                    + "excludedHostedAudioPolicyGenerations=\(excludedHostedPolicyText)\n"
                    + "ordinaryOrigin=ordinary ordinarySession=\(recovered.finalAudioSnapshot.sessionGeneration) ordinaryPolicyID=none ordinaryAudioPolicyGeneration=\(recovered.ordinaryAudioPolicyGeneration) ordinaryAuthorizationGeneration=none route=\(recovered.route)\n"
                    + recovered.sampleLog
        )
        recoveredAttachment.name =
            "Fresh ordinary audio proof after final call recovery"
        recoveredAttachment.lifetime = .keepAlways
        add(recoveredAttachment)

        XCTAssertEqual(
            element("worldwideMicrophoneState").value as? String,
            "On",
            "The iPhone microphone did not automatically reopen after final call recovery."
        )
        let postCallRaw = try XCTUnwrap(
            waitForStableRawIPhoneMicrophone(
                timeout: postCallRawTimeoutDuration,
                stableFor: postCallRawContinuityDuration,
                expectedSessionGeneration:
                    recovered.finalAudioSnapshot.sessionGeneration
            ),
            "Post-call recovery did not establish a fresh density-checked raw microphone sender under the same media session. Last observation: \(liveRawMicrophoneObservation)"
        )
        let initialPostCallRaw = postCallRaw.initialSnapshot
        let finalPostCallRaw = postCallRaw.finalSnapshot
        let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        XCTAssertEqual(
            element("worldwideMicrophoneState").value as? String,
            "On",
            "The iPhone microphone did not remain On through the post-call raw proof."
        )
        XCTAssertEqual(
            initialPostCallRaw.audioPolicyGeneration,
            recovered.ordinaryAudioPolicyGeneration
        )
        XCTAssertEqual(
            finalPostCallRaw.audioPolicyGeneration,
            recovered.ordinaryAudioPolicyGeneration
        )
        XCTAssertNotEqual(
            initialPostCallRaw.transportAuthorizationGeneration,
            zeroUUID
        )
        XCTAssertNotEqual(initialPostCallRaw.windowGeneration, zeroUUID)
        XCTAssertGreaterThan(initialPostCallRaw.microphonePolicyGeneration, 0)
        XCTAssertGreaterThan(initialPostCallRaw.recordingGeneration, 0)
        XCTAssertEqual(
            initialPostCallRaw.recordingGeneration,
            initialPostCallRaw.approvedRecordingGeneration
        )
        XCTAssertEqual(
            initialPostCallRaw.transportAuthorizationGeneration,
            finalPostCallRaw.transportAuthorizationGeneration
        )
        XCTAssertEqual(
            initialPostCallRaw.recordingGeneration,
            finalPostCallRaw.recordingGeneration
        )
        XCTAssertGreaterThanOrEqual(
            postCallRaw.continuityDurationNs,
            requiredPostCallContinuityNs
        )

        let postCallRawAttachment = XCTAttachment(
            string:
                "schema=opensteamer.post-call-raw-ui-continuity.v1\n"
                    + "nonce=\(postCallRuntimeNonce)\n"
                    + "scope=same production media session after real-call ordinary recovery; downstream BlackHole overlap is proved by the physical driver\n"
                    + postCallRaw.sampleLog
        )
        postCallRawAttachment.name =
            "Post-call raw iPhone microphone rolling continuity evidence"
        postCallRawAttachment.lifetime = .keepAlways
        add(postCallRawAttachment)

        let postCallRuntimeAttachment = XCTAttachment(
            string:
                "schema=opensteamer.raw-ui-runtime.v1\n"
                    + "nonce=\(postCallRuntimeNonce)\n"
                    + "continuityDurationNs=\(postCallRaw.continuityDurationNs)\n"
                    + "appPIDAtStart=\(postCallRaw.applicationProcessIDAtStart)\n"
                    + "appPIDAtEnd=\(postCallRaw.applicationProcessIDAtEnd)\n"
        )
        postCallRuntimeAttachment.name =
            "Post-call raw iPhone microphone runtime overlap evidence"
        postCallRuntimeAttachment.lifetime = .keepAlways
        add(postCallRuntimeAttachment)

        let postCallGenerationAttachment = XCTAttachment(
            string:
                "schema=opensteamer.post-call-raw-generation.v1\n"
                    + "nonce=\(postCallRuntimeNonce)\n"
                    + "sessionGeneration=\(finalPostCallRaw.sessionGeneration.uuidString.lowercased())\n"
                    + "ordinaryAudioPolicyGeneration=\(recovered.ordinaryAudioPolicyGeneration.uuidString.lowercased())\n"
                    + "rawAudioPolicyGeneration=\(finalPostCallRaw.audioPolicyGeneration.uuidString.lowercased())\n"
                    + "transportAuthorizationGeneration=\(finalPostCallRaw.transportAuthorizationGeneration.uuidString.lowercased())\n"
                    + "windowGeneration=\(finalPostCallRaw.windowGeneration.uuidString.lowercased())\n"
                    + "microphonePolicyGeneration=\(finalPostCallRaw.microphonePolicyGeneration)\n"
                    + "recordingGeneration=\(finalPostCallRaw.recordingGeneration)\n"
                    + "approvedRecordingGeneration=\(finalPostCallRaw.approvedRecordingGeneration)\n"
                    + "appPIDAtStart=\(postCallRaw.applicationProcessIDAtStart)\n"
                    + "appPIDAtEnd=\(postCallRaw.applicationProcessIDAtEnd)\n"
                    + "continuityDurationNs=\(postCallRaw.continuityDurationNs)\n"
        )
        postCallGenerationAttachment.name =
            "Post-call raw microphone generation evidence"
        postCallGenerationAttachment.lifetime = .keepAlways
        add(postCallGenerationAttachment)

        publishRawUIContinuityBoundary(
            "OPENSTEAMER_RAW_UI_CONTINUITY_COMPLETE_V1",
            nonce: postCallRuntimeNonce
        )
        RunLoop.current.run(until: Date().addingTimeInterval(10))
        publishRawUIContinuityBoundary(
            "OPENSTEAMER_RAW_UI_TEARDOWN_BEGIN_V1",
            nonce: postCallRuntimeNonce
        )
        app.buttons["disconnectWorldwide"].tap()
        XCTAssertTrue(
            waitForHostFailureToReturnToSavedPair(timeout: 45)
        )
        assertSavedPairIsIdleWithoutHistoricalError(
            expectedPairFingerprint: expectedPairFingerprint
        )
        app.terminate()
    }

    /// The shell driver restarts the Mac host only after its log proves that each WebRTC peer is
    /// connected. Keeping this app process alive across all three host failures is important: a
    /// terminate/relaunch-only test discards the in-memory media error that caused the regression.
    func testThreeSameProcessHostRestartsThenColdRelaunchPreservePairing() throws {
        hardLaunch()
        let expectedPairFingerprint = try currentPairFingerprint()
        assertSavedPairIsIdleWithoutHistoricalError(
            expectedPairFingerprint: expectedPairFingerprint
        )

        for attempt in 1...3 {
            try XCTContext.runActivity(named: "Same-process host restart and reconnect \(attempt)") { activity in
                assertSavedPairIsIdleWithoutHistoricalError(
                    expectedPairFingerprint: expectedPairFingerprint
                )

                let playback = try connectAndRequireStablePlayback(
                    phase: "host restart reconnect \(attempt)"
                )
                addRouteEvidence(
                    playback.route,
                    phase: "host restart reconnect \(attempt)",
                    to: activity
                )

                let liveAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                liveAttachment.name =
                    "test iPhone \(playback.route) route before host restart \(attempt)"
                liveAttachment.lifetime = .keepAlways
                activity.add(liveAttachment)

                XCTAssertTrue(
                    waitForHostFailureToReturnToSavedPair(timeout: 45),
                    "Host restart \(attempt) did not return the same app process to its saved-pair reconnect UI without a stale error"
                )
                assertSavedPairIsIdleWithoutHistoricalError(
                    expectedPairFingerprint: expectedPairFingerprint
                )

                let recoveredAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                recoveredAttachment.name = "test iPhone recovered in same process \(attempt)"
                recoveredAttachment.lifetime = .keepAlways
                activity.add(recoveredAttachment)
            }
        }

        try XCTContext.runActivity(named: "Explicit disconnect and same-process reconnect") { activity in
            let firstPlayback = try connectAndRequireStablePlayback(
                phase: "explicit disconnect"
            )
            addRouteEvidence(
                firstPlayback.route,
                phase: "before explicit disconnect",
                to: activity
            )
            app.buttons["disconnectWorldwide"].tap()
            XCTAssertTrue(
                waitForHostFailureToReturnToSavedPair(timeout: 45),
                "Explicit disconnect did not return to the clean saved-pair UI"
            )
            assertSavedPairIsIdleWithoutHistoricalError(
                expectedPairFingerprint: expectedPairFingerprint
            )

            let reconnectedPlayback = try connectAndRequireStablePlayback(
                phase: "same-process reconnect after explicit disconnect"
            )
            addRouteEvidence(
                reconnectedPlayback.route,
                phase: "same-process reconnect after explicit disconnect",
                to: activity
            )
            app.buttons["disconnectWorldwide"].tap()
            XCTAssertTrue(
                waitForHostFailureToReturnToSavedPair(timeout: 45),
                "Second explicit disconnect did not return to the clean saved-pair UI"
            )
            assertSavedPairIsIdleWithoutHistoricalError(
                expectedPairFingerprint: expectedPairFingerprint
            )
        }

        // Only after exercising peer-left and explicit-disconnect transitions in one process do
        // one cold launch. Reconnecting after that launch proves that production Keychain state
        // is not merely displayable: its identity, pair record, and counters remain usable.
        hardLaunch()
        assertSavedPairIsIdleWithoutHistoricalError(
            expectedPairFingerprint: expectedPairFingerprint
        )
        try XCTContext.runActivity(named: "Cold-launch saved-pair reconnect") { activity in
            var playback = try connectAndRequireStablePlayback(
                phase: "cold-launch saved-pair reconnect"
            )
            addRouteEvidence(
                playback.route,
                phase: "cold-launch saved-pair reconnect",
                to: activity
            )

            playback = try XCTContext.runActivity(
                named: "Physical background audio continuity oracle"
            ) { backgroundActivity in
                try exerciseBackgroundAudioContinuity(
                    startingFrom: playback,
                    phase: "cold-launch saved-pair reconnect",
                    activity: backgroundActivity
                )
            }
            addRouteEvidence(
                playback.route,
                phase: "after background audio proof",
                to: activity
            )

            playback = try XCTContext.runActivity(
                named: "Physical screen Show-Hide and same-session audio oracle"
            ) { screenActivity in
                try exerciseLiveScreenAndRequirePlaybackContinuity(
                    startingFrom: playback,
                    phase: "cold-launch saved-pair reconnect",
                    activity: screenActivity
                )
            }
            addRouteEvidence(
                playback.route,
                phase: "after hiding the cold-launch Mac screen",
                to: activity
            )

            app.buttons["disconnectWorldwide"].tap()
            XCTAssertTrue(
                waitForHostFailureToReturnToSavedPair(timeout: 45),
                "Cold-launch reconnect did not disconnect back to the clean saved-pair UI"
            )
            assertSavedPairIsIdleWithoutHistoricalError(
                expectedPairFingerprint: expectedPairFingerprint
            )
        }
        app.terminate()
    }

    // MARK: - Production app lifecycle and connection assertions

    /// Terminates and relaunches the production bundle without replacing its Keychain container.
    private func hardLaunch() {
        app.terminate()
        app.launch()
        XCTAssertTrue(
            element("worldwidePairedMac").waitForExistence(timeout: 10),
            "The production app did not restore its saved paired Mac"
        )
    }

    private func assertSavedPairIsIdleWithoutHistoricalError(
        expectedPairFingerprint: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertPresentation("pairedIdle", file: file, line: line)
        let pairingOracle = element("worldwidePairingSaved")
        XCTAssertTrue(pairingOracle.exists, file: file, line: line)
        XCTAssertEqual(
            pairingOracle.value as? String,
            expectedPairFingerprint,
            "The saved pair identity changed during reconnect recovery",
            file: file,
            line: line
        )
        XCTAssertTrue(app.buttons["connectPairedWorldwide"].exists, file: file, line: line)
        XCTAssertEqual(
            app.buttons["connectPairedWorldwide"].label,
            "Connect to Paired Mac",
            file: file,
            line: line
        )
        XCTAssertFalse(element("worldwideInvitationCode").exists, file: file, line: line)
        assertNoConnectionError(file: file, line: line)
    }

    private func currentPairFingerprint(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let oracle = element("worldwidePairingSaved")
        XCTAssertTrue(
            oracle.waitForExistence(timeout: 10),
            "The saved-pair fingerprint oracle is missing",
            file: file,
            line: line
        )
        let fingerprint = try XCTUnwrap(
            oracle.value as? String,
            "The saved-pair fingerprint oracle has no value",
            file: file,
            line: line
        )
        XCTAssertTrue(
            fingerprint.range(of: #"^pair-[0-9a-f]{24}$"#, options: .regularExpression) != nil,
            "The saved-pair oracle must be a non-secret truncated digest",
            file: file,
            line: line
        )
        return fingerprint
    }

    private func assertNoConnectionError(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for identifier in connectionErrorIdentifiers {
            XCTAssertFalse(
                element(identifier).exists,
                "Unexpected connection error row: \(identifier)",
                file: file,
                line: line
            )
        }
        XCTAssertFalse(
            app.staticTexts[
                "The Mac disconnected. Reconnect to the saved paired Mac when it is available."
            ].exists,
            file: file,
            line: line
        )
    }

    private func connectAndRequireStablePlayback(phase: String) throws -> LivePlaybackEvidence {
        app.buttons["connectPairedWorldwide"].tap()
        return try XCTUnwrap(
            waitForStableLivePlaybackWithoutError(timeout: 45, stableFor: 2),
            "\(phase) did not sustain an active Connected session with native audio Playing and a Direct or TURN relay route. Last observation: \(livePlaybackObservation)"
        )
    }

    private func waitForStableLivePlaybackWithoutError(
        timeout: TimeInterval,
        stableFor stableDuration: TimeInterval,
        expectedSessionGeneration: UUID? = nil,
        expectedAudioPolicyGeneration: UUID? = nil
    ) -> LivePlaybackEvidence? {
        let deadline = Date().addingTimeInterval(timeout)
        var stableRoute: String?
        var tracker = PhysicalAudioContinuityTracker(
            requiredDuration: stableDuration,
            maximumProgressGap: maximumAudioOracleProgressGap,
            expectedSessionGeneration: expectedSessionGeneration,
            expectedAudioPolicyGeneration:
                expectedAudioPolicyGeneration
        )
        while Date() < deadline {
            if app.state != .runningForeground || hasConnectionError {
                return nil
            }

            let routeElement = element("worldwideSessionRoute")
            let sessionStateElement = element("worldwideSessionState")
            let audioStateElement = element("worldwideAudioState")
            let audioOracleElement = element("worldwideAudioPlayoutOracle")
            let route = routeElement.value as? String
            if presentationValue == "active",
               sessionStateElement.value as? String == "Connected",
               audioStateElement.value as? String == "Playing",
               routeElement.exists,
               let route,
               acceptedRouteValues.contains(route),
               audioOracleElement.exists,
               let encodedOracle = audioOracleElement.value as? String,
               let currentOracle = PhysicalAudioPlayoutSnapshot(
                   accessibilityValue: encodedOracle
               ),
               currentOracle.fullQualityInvariantsHold {
                let now = ProcessInfo.processInfo.systemUptime
                if route != stableRoute {
                    stableRoute = route
                    tracker = PhysicalAudioContinuityTracker(
                        requiredDuration: stableDuration,
                        maximumProgressGap: maximumAudioOracleProgressGap,
                        expectedSessionGeneration: expectedSessionGeneration,
                        expectedAudioPolicyGeneration:
                            expectedAudioPolicyGeneration
                    )
                }
                switch tracker.observe(currentOracle, at: now) {
                case .waiting:
                    break
                case .satisfied:
                    return LivePlaybackEvidence(
                        route: route,
                        finalAudioSnapshot: currentOracle
                    )
                case .rejected:
                    return nil
                }
            } else {
                stableRoute = nil
                tracker = PhysicalAudioContinuityTracker(
                    requiredDuration: stableDuration,
                    maximumProgressGap: maximumAudioOracleProgressGap,
                    expectedSessionGeneration: expectedSessionGeneration,
                    expectedAudioPolicyGeneration:
                        expectedAudioPolicyGeneration
                )
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    private func exerciseBackgroundAudioContinuity(
        startingFrom playback: LivePlaybackEvidence,
        phase: String,
        activity: XCTActivity
    ) throws -> LivePlaybackEvidence {
        let before = playback.finalAudioSnapshot
        let backgroundStartedAt = ProcessInfo.processInfo.systemUptime
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            waitForAppToLeaveForeground(timeout: 5),
            "\(phase) did not place opensteamer in the background"
        )

        let holdUntil = backgroundStartedAt + backgroundEvidenceDuration
        while ProcessInfo.processInfo.systemUptime < holdUntil {
            XCTAssertNotEqual(
                app.state,
                .notRunning,
                "\(phase) terminated while proving background audio"
            )
            let remaining = holdUntil - ProcessInfo.processInfo.systemUptime
            RunLoop.current.run(
                until: Date().addingTimeInterval(min(0.25, max(0, remaining)))
            )
        }

        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 8),
            "\(phase) did not return from the background audio interval"
        )

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            guard !hasConnectionError,
                  element("worldwideSessionState").value as? String == "Connected",
                  element("worldwideAudioState").value as? String == "Playing",
                  let route = element("worldwideSessionRoute").value as? String,
                  acceptedRouteValues.contains(route),
                  let encoded = element("worldwideAudioPlayoutOracle").value as? String,
                  let current = PhysicalAudioPlayoutSnapshot(
                      accessibilityValue: encoded
                  ) else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                continue
            }
            guard current.sessionGeneration == before.sessionGeneration,
                  current.audioPolicyGeneration
                    == before.audioPolicyGeneration,
                  current.failureCount == 0,
                  current.fullQualityInvariantsHold else {
                XCTFail("\(phase) replaced the media/audio-policy window or degraded playback while backgrounded")
                throw PhysicalValidationError.oracleRejected
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - backgroundStartedAt
            if PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
                previous: before,
                current: current,
                elapsed: elapsed,
                minimumRealtimeCoverage: 0.97
            ) {
                let attachment = XCTAttachment(
                    string: "backgroundSeconds=\(elapsed) session=\(current.sessionGeneration) nativeFrames=\(current.frameCount - before.frameCount) pcmSamples=\(current.pcmSampleCount - before.pcmSampleCount) inboundDuration=\(current.inboundSamplesDuration - before.inboundSamplesDuration) inboundEnergy=\(current.inboundAudioEnergy - before.inboundAudioEnergy) gapViolations=\(current.callbackGapViolationCount - before.callbackGapViolationCount) nearSilenceCallbacks=\(current.nearSilenceCallbackCount - before.nearSilenceCallbackCount) shapeAnomalies=\(current.pcmShapeAnomalyCallbackCount - before.pcmShapeAnomalyCallbackCount) boundaryDiscontinuities=\(current.pcmBoundaryDiscontinuityCallbackCount - before.pcmBoundaryDiscontinuityCallbackCount) rebuilds=\(current.recoveryRebuildCount - before.recoveryRebuildCount) leftCrossings=\(current.pcmLeftZeroCrossingCount - before.pcmLeftZeroCrossingCount) rightCrossings=\(current.pcmRightZeroCrossingCount - before.pcmRightZeroCrossingCount) envelopeTransitions=\(current.pcmEnvelopeTransitionCount - before.pcmEnvelopeTransitionCount)"
                )
                attachment.name = "Background native audio continuity evidence"
                attachment.lifetime = .keepAlways
                activity.add(attachment)
                return LivePlaybackEvidence(route: route, finalAudioSnapshot: current)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail(
            "\(phase) did not accumulate real-time inbound energy and rendered PCM beyond the background-task lease. Last observation: \(livePlaybackObservation)"
        )
        throw PhysicalValidationError.oracleRejected
    }

    private func waitForAppToLeaveForeground(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch app.state {
            case .runningBackground, .runningBackgroundSuspended:
                return true
            case .notRunning:
                return false
            default:
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        }
        return false
    }

    private func exerciseLiveScreenAndRequirePlaybackContinuity(
        startingFrom playback: LivePlaybackEvidence,
        phase: String,
        activity: XCTActivity
    ) throws -> LivePlaybackEvidence {
        let audioContinuityStartedAt = ProcessInfo.processInfo.systemUptime
        let playerTab = app.tabBars.buttons["Player"]
        XCTAssertTrue(
            playerTab.waitForExistence(timeout: 10),
            "\(phase) could not open Player to exercise the worldwide Mac screen"
        )
        playerTab.tap()

        let showScreen = app.buttons["viewWorldwideMacScreen"]
        XCTAssertTrue(
            showScreen.waitForExistence(timeout: 10),
            "\(phase) has no worldwide View Mac Screen action despite a live control channel"
        )
        XCTAssertTrue(
            waitForEnabled(showScreen, timeout: 10),
            "\(phase) left View Mac Screen disabled despite a live control channel"
        )
        showScreen.tap()

        let liveScreenEvidence = try XCTUnwrap(
            waitForStableLiveScreenWithRemoteInput(timeout: 45, stableFor: 2),
            "\(phase) did not sustain advancing decoded Mac frames with an authenticated Active acknowledgement and a current remote-input capability. Last observation: \(liveScreenObservation)"
        )

        let liveScreenAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        liveScreenAttachment.name =
            "test iPhone live Mac screen with authenticated input capability"
        liveScreenAttachment.lifetime = .keepAlways
        activity.add(liveScreenAttachment)

        let pixelFreshnessAttachment = XCTAttachment(
            string: "renderer=\(liveScreenEvidence.finalVideoSnapshot.rendererID) decodedFrames=\(liveScreenEvidence.finalVideoSnapshot.frameCount - liveScreenEvidence.initialVideoSnapshot.frameCount) contentSamples=\(liveScreenEvidence.finalVideoSnapshot.contentSampleCount - liveScreenEvidence.initialVideoSnapshot.contentSampleCount) distinctContentChanges=\(liveScreenEvidence.finalVideoSnapshot.contentChangeCount - liveScreenEvidence.initialVideoSnapshot.contentChangeCount) initialDigest=\(liveScreenEvidence.initialVideoSnapshot.contentDigest) finalDigest=\(liveScreenEvidence.finalVideoSnapshot.contentDigest)"
        )
        pixelFreshnessAttachment.name = "Decoded screen pixel freshness evidence"
        pixelFreshnessAttachment.lifetime = .keepAlways
        activity.add(pixelFreshnessAttachment)

        let hideScreen = app.buttons["hideWorldwideMacScreen"]
        XCTAssertTrue(
            hideScreen.exists,
            "\(phase) displayed a live Mac screen without its explicit Hide Screen action"
        )
        hideScreen.tap()

        let hideAcknowledgement = try XCTUnwrap(
            waitForHostAcknowledgedScreenHide(
                after: liveScreenEvidence.showAcknowledgement,
                timeout: 20
            ),
            "\(phase) did not receive a newer authenticated Inactive acknowledgement before dismissing every live-screen surface. Last observation: \(liveScreenObservation)"
        )
        let acknowledgementAttachment = XCTAttachment(
            string: "showRequest=\(liveScreenEvidence.showAcknowledgement.requestID) hideRequest=\(hideAcknowledgement.requestID) finalVideoFrames=\(liveScreenEvidence.finalVideoSnapshot.frameCount)"
        )
        acknowledgementAttachment.name = "Authenticated screen Show-Hide evidence"
        acknowledgementAttachment.lifetime = .keepAlways
        activity.add(acknowledgementAttachment)
        XCTAssertTrue(
            showScreen.waitForExistence(timeout: 10),
            "\(phase) did not return to Player after the host acknowledged Hide Screen"
        )

        let serversTab = app.tabBars.buttons["Servers"]
        XCTAssertTrue(
            serversTab.waitForExistence(timeout: 10),
            "\(phase) could not return to Servers to verify post-Hide media continuity"
        )
        serversTab.tap()

        let finalPlayback = try XCTUnwrap(
            waitForStableLivePlaybackWithoutError(
                timeout: 20,
                stableFor: 2,
                expectedSessionGeneration:
                    playback.finalAudioSnapshot.sessionGeneration,
                expectedAudioPolicyGeneration:
                    playback.finalAudioSnapshot.audioPolicyGeneration
            ),
            "\(phase) lost its Connected session, native audio playback, or live WebRTC route after Hide Screen. Last observation: \(livePlaybackObservation)"
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - audioContinuityStartedAt
        guard finalPlayback.finalAudioSnapshot.audioPolicyGeneration
                == playback.finalAudioSnapshot.audioPolicyGeneration else {
            XCTFail("\(phase) rotated ordinary audio policy across screen Show-Hide")
            throw PhysicalValidationError.oracleRejected
        }
        guard PhysicalAudioPlayoutEvaluator.coversElapsedInterval(
            previous: playback.finalAudioSnapshot,
            current: finalPlayback.finalAudioSnapshot,
            elapsed: elapsed,
            minimumRealtimeCoverage: 0.97
        ) else {
            XCTFail(
                "\(phase) did not preserve the deterministic audio stream continuously across screen Show-Hide"
            )
            throw PhysicalValidationError.oracleRejected
        }
        let audioAttachment = XCTAttachment(
            string: "screenSeconds=\(elapsed) session=\(finalPlayback.finalAudioSnapshot.sessionGeneration) nativeFrames=\(finalPlayback.finalAudioSnapshot.frameCount - playback.finalAudioSnapshot.frameCount) gapViolations=\(finalPlayback.finalAudioSnapshot.callbackGapViolationCount - playback.finalAudioSnapshot.callbackGapViolationCount) nearSilenceCallbacks=\(finalPlayback.finalAudioSnapshot.nearSilenceCallbackCount - playback.finalAudioSnapshot.nearSilenceCallbackCount) shapeAnomalies=\(finalPlayback.finalAudioSnapshot.pcmShapeAnomalyCallbackCount - playback.finalAudioSnapshot.pcmShapeAnomalyCallbackCount) boundaryDiscontinuities=\(finalPlayback.finalAudioSnapshot.pcmBoundaryDiscontinuityCallbackCount - playback.finalAudioSnapshot.pcmBoundaryDiscontinuityCallbackCount) rebuilds=\(finalPlayback.finalAudioSnapshot.recoveryRebuildCount - playback.finalAudioSnapshot.recoveryRebuildCount) envelopeTransitions=\(finalPlayback.finalAudioSnapshot.pcmEnvelopeTransitionCount - playback.finalAudioSnapshot.pcmEnvelopeTransitionCount)"
        )
        audioAttachment.name = "Same-session audio continuity across screen Show-Hide"
        audioAttachment.lifetime = .keepAlways
        activity.add(audioAttachment)
        return finalPlayback
    }

    private func waitForStableRawIPhoneMicrophone(
        timeout: TimeInterval,
        stableFor stableDuration: TimeInterval,
        expectedSessionGeneration: UUID
    ) -> LiveRawMicrophoneEvidence? {
        let deadline = Date().addingTimeInterval(timeout)
        var tracker: PhysicalRawMicrophoneContinuityTracker?
        var initialSnapshot: PhysicalRawMicrophoneSnapshot?
        var latestSnapshot: PhysicalRawMicrophoneSnapshot?
        var initialObservedAt: TimeInterval?
        var latestObservedAt: TimeInterval?
        var applicationProcessIDAtStart: Int32?
        var sampleLines: [String] = []

        while Date() < deadline {
            if app.state != .runningForeground || hasConnectionError {
                return nil
            }

            let now = ProcessInfo.processInfo.systemUptime
            let oracleElement = element("worldwideRawMicrophoneOracle")
            guard presentationValue == "active",
                  element("worldwideSessionState").value as? String
                    == "Connected",
                  element("worldwideMicrophoneState").value as? String
                    == "On",
                  oracleElement.exists,
                  let encoded = oracleElement.value as? String,
                  let current = PhysicalRawMicrophoneSnapshot(
                    accessibilityValue: encoded
                  ),
                  current.sessionGeneration
                    == expectedSessionGeneration else {
                if let latestObservedAt,
                   now - latestObservedAt
                    > maximumRawMicrophoneOracleProgressGap {
                    return nil
                }
                RunLoop.current.run(
                    until: Date().addingTimeInterval(0.1)
                )
                continue
            }

            if current == latestSnapshot {
                if let latestObservedAt,
                   now - latestObservedAt
                    > maximumRawMicrophoneOracleProgressGap {
                    return nil
                }
                RunLoop.current.run(
                    until: Date().addingTimeInterval(0.1)
                )
                continue
            }

            if tracker == nil {
                let processIdentifier = current.applicationProcessIdentifier
                guard processIdentifier > 0 else {
                    return nil
                }

                var newTracker =
                    PhysicalRawMicrophoneContinuityTracker(
                        requiredDuration: stableDuration,
                        maximumProgressGap:
                            maximumRawMicrophoneOracleProgressGap,
                        expectedSessionGeneration:
                            expectedSessionGeneration,
                        expectedWindowGeneration:
                            current.windowGeneration,
                        minimumAdvancementObservations: 2
                    )
                guard newTracker.observe(current, at: now)
                        == .waiting else {
                    return nil
                }
                tracker = newTracker
                initialSnapshot = current
                latestSnapshot = current
                initialObservedAt = now
                latestObservedAt = now
                applicationProcessIDAtStart = processIdentifier
                var baselineLine = "t=0 baseline"
                baselineLine += " session=\(current.sessionGeneration)"
                baselineLine += " window=\(current.windowGeneration)"
                baselineLine += " transport=\(current.transportAuthorizationGeneration)"
                baselineLine += " audioPolicy=\(current.audioPolicyGeneration)"
                baselineLine += " negotiation=\(current.negotiationEpoch)"
                baselineLine += " binding=\(current.bindingGeneration)"
                baselineLine += " track=\(current.trackGeneration)"
                baselineLine += " micPolicy=\(current.microphonePolicyGeneration)"
                baselineLine += " recording=\(current.recordingGeneration)"
                baselineLine += " admissions=\(current.realtimeAdmissionCount)"
                baselineLine += " callbacks=\(current.deliveryCallbackCount)"
                baselineLine += " frames=\(current.deliveredFrameCount)"
                baselineLine += " packets=\(current.packetsSent)"
                baselineLine += " bytes=\(current.bytesSent)"
                let duration: String
                if let totalSamplesDuration = current.totalSamplesDuration {
                    duration = String(totalSamplesDuration)
                } else {
                    duration = "missing"
                }
                baselineLine += " duration=\(duration)"
                sampleLines.append(baselineLine)
                continue
            }

            guard let previous = latestSnapshot,
                  let initialSnapshot,
                  let initialObservedAt,
                  let applicationProcessIDAtStart,
                  current.applicationProcessIdentifier
                    == applicationProcessIDAtStart,
                  current.windowGeneration
                    == initialSnapshot.windowGeneration,
                  var activeTracker = tracker else {
                return nil
            }

            let result = activeTracker.observe(current, at: now)
            tracker = activeTracker
            guard result != .rejected else { return nil }

            let elapsed: TimeInterval = now - initialObservedAt
            let gap: TimeInterval =
                now - (latestObservedAt ?? initialObservedAt)
            var progressLine = "t=\(elapsed)"
            progressLine += " gap=\(gap)"
            progressLine += " session=\(current.sessionGeneration)"
            progressLine += " window=\(current.windowGeneration)"
            progressLine += " transport=\(current.transportAuthorizationGeneration)"
            progressLine += " audioPolicy=\(current.audioPolicyGeneration)"
            progressLine += " negotiation=\(current.negotiationEpoch)"
            progressLine += " binding=\(current.bindingGeneration)"
            progressLine += " track=\(current.trackGeneration)"
            progressLine += " micPolicy=\(current.microphonePolicyGeneration)"
            progressLine += " recording=\(current.recordingGeneration)"
            progressLine += " admissionsDelta=\(current.realtimeAdmissionCount - previous.realtimeAdmissionCount)"
            progressLine += " callbacksDelta=\(current.deliveryCallbackCount - previous.deliveryCallbackCount)"
            progressLine += " framesDelta=\(current.deliveredFrameCount - previous.deliveredFrameCount)"
            progressLine += " packetsDelta=\(current.packetsSent - previous.packetsSent)"
            progressLine += " bytesDelta=\(current.bytesSent - previous.bytesSent)"
            let durationDelta: String
            if let currentDuration = current.totalSamplesDuration,
               let previousDuration = previous.totalSamplesDuration {
                durationDelta = String(currentDuration - previousDuration)
            } else {
                durationDelta = "missing"
            }
            progressLine += " durationDelta=\(durationDelta)"
            sampleLines.append(progressLine)
            latestSnapshot = current
            latestObservedAt = now

            if result == .satisfied {
                let applicationProcessIDAtEnd = current.applicationProcessIdentifier
                let validDuration = activeTracker.accumulatedValidDuration
                guard applicationProcessIDAtStart > 0,
                      applicationProcessIDAtEnd == applicationProcessIDAtStart,
                      validDuration.isFinite,
                      validDuration >= stableDuration,
                      validDuration <= Double(UInt64.max) / 1_000_000_000 else {
                    return nil
                }
                let continuityDurationNs = UInt64(
                    (validDuration * 1_000_000_000).rounded(.down)
                )
                return LiveRawMicrophoneEvidence(
                    initialSnapshot: initialSnapshot,
                    finalSnapshot: current,
                    elapsed: validDuration,
                    advancementObservations: activeTracker
                        .advancementObservationCount,
                    continuityDurationNs: continuityDurationNs,
                    applicationProcessIDAtStart: applicationProcessIDAtStart,
                    applicationProcessIDAtEnd: applicationProcessIDAtEnd,
                    sampleLog: sampleLines.joined(separator: "\n")
                )
            }

            RunLoop.current.run(
                until: Date().addingTimeInterval(0.1)
            )
        }

        return nil
    }

    private func publishRawUIContinuityBoundary(
        _ boundary: String,
        nonce: String
    ) {
        let line = "\(boundary) nonce=\(nonce)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    private func publishHostedCallBoundary(
        nonce: String,
        sequence: Int,
        acousticToken: String
    ) {
        precondition(sequence == 1 || sequence == 2)
        let line = "OPENSTEAMER_CALL_UI_HOSTED_ACTIVE_V2 nonce=\(nonce) sequence=\(sequence) acousticToken=\(acousticToken)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    /// Keeps the UI test inside the interruption-origin hosted state until it consumes the exact
    /// driver-published accepted record. A transition to ordinary playback before that point is a
    /// causal failure, not post-call success. After consuming the record, one fresh advancing
    /// hosted snapshot is required before sequence 2 can be published.
    private func waitForAcceptedAcousticAcknowledgementWhileHosted(
        requestPath: String,
        statusPath: String,
        nonce: String,
        expectedRoute: String,
        baseline: PhysicalHostedCallPlayoutSnapshot,
        timeout: TimeInterval
    ) -> String? {
        guard timeout.isFinite, timeout > 0,
              Self.isGuardedT7EvidencePath(requestPath),
              Self.isGuardedT7EvidencePath(statusPath) else {
            XCTFail("The acoustic acknowledgement evidence path or timeout was not guarded.")
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        var tracker = PhysicalHostedCallPlayoutContinuityTracker(
            requiredDuration: 0.25,
            maximumProgressGap: maximumAudioOracleProgressGap,
            expectedSessionGeneration: baseline.sessionGeneration,
            expectedPolicyID: baseline.policyID,
            expectedOrigin: .interruption,
            expectedAudioPolicyGeneration: baseline.audioPolicyGeneration,
            expectedAuthorizationGeneration: baseline.authorizationGeneration,
            minimumAdvancementObservations: 2
        )
        _ = tracker.observe(
            baseline,
            at: ProcessInfo.processInfo.systemUptime
        )
        var acceptedToken: String?
        var acceptedAtMonotonicNs: UInt64?
        var snapshotAtAcceptance: PhysicalHostedCallPlayoutSnapshot?
        var observedAdvancementAfterAcceptance = false

        while Date() < deadline {
            guard app.state == .runningForeground, !hasConnectionError else {
                XCTFail("The app or connection ended before the acoustic acknowledgement completed.")
                return nil
            }

            let audioState = element("worldwideAudioState").value as? String
            let microphoneState = element("worldwideMicrophoneState").value as? String
            let hostedElement = element("worldwideHostedCallPlayoutOracle")
            let rawMicrophone = element("worldwideRawMicrophoneOracle")
            let routeElement = element("worldwideSessionRoute")
            guard presentationValue == "active",
                  element("worldwideSessionState").value as? String == "Connected",
                  audioState == "Playing — iPhone call may reduce quality",
                  microphoneState == "Muted — iPhone call active",
                  !rawMicrophone.exists,
                  routeElement.exists,
                  routeElement.value as? String == expectedRoute,
                  hostedElement.exists,
                  let encoded = hostedElement.value as? String,
                  let current = PhysicalHostedCallPlayoutSnapshot(
                    accessibilityValue: encoded
                  ) else {
                XCTFail(
                    "Hosted-call state ended before the acoustic acknowledgement was causally bracketed; ordinary playback cannot satisfy the in-call acknowledgement."
                )
                return nil
            }

            let now = ProcessInfo.processInfo.systemUptime
            let continuity = tracker.observe(current, at: now)
            guard continuity != .rejected else {
                XCTFail("Hosted-call identity or progress changed while awaiting the acoustic acknowledgement.")
                return nil
            }

            if acceptedToken == nil,
               let request = Self.readExactSingleLine(path: requestPath),
               request.hasPrefix("heard-token=") {
                let token = String(request.dropFirst("heard-token=".count))
                guard Self.isEvidenceToken(token),
                      let status = Self.readExactKeyValueRecord(
                        path: statusPath,
                        keys: [
                            "schema", "nonce", "sequence", "token",
                            "state", "acceptedAtMonotonicNs",
                        ]
                      ),
                      status["schema"] == "opensteamer.call-acoustic-acknowledgement.v2",
                      status["nonce"] == nonce,
                      status["sequence"] == "1",
                      status["token"] == token,
                      status["state"] == "accepted",
                      let acceptedAt = status["acceptedAtMonotonicNs"].flatMap(UInt64.init),
                      acceptedAt > 0,
                      String(acceptedAt) == status["acceptedAtMonotonicNs"] else {
                    RunLoop.current.run(
                        until: Date().addingTimeInterval(0.05)
                    )
                    continue
                }
                acceptedToken = token
                acceptedAtMonotonicNs = acceptedAt
                snapshotAtAcceptance = current
            }

            if let acceptedToken, let acceptedAtMonotonicNs,
               let snapshotAtAcceptance {
                let nowNs = UInt64(max(1, now * 1_000_000_000))
                guard nowNs >= acceptedAtMonotonicNs else {
                    XCTFail("The acoustic acceptance timestamp was from the future.")
                    return nil
                }
                if current != snapshotAtAcceptance,
                   PhysicalHostedCallPlayoutEvaluator.evaluate(
                    previous: snapshotAtAcceptance,
                    current: current
                   ) == .advancing {
                    observedAdvancementAfterAcceptance = true
                }
                if observedAdvancementAfterAcceptance {
                    return acceptedToken
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        return nil
    }

    private static func isEvidenceToken(_ value: String) -> Bool {
        (16...128).contains(value.utf8.count)
            && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57)
                    || ($0 >= 65 && $0 <= 90)
                    || ($0 >= 97 && $0 <= 122)
                    || $0 == 45
            }
    }

    private static func isGuardedT7EvidencePath(_ path: String) -> Bool {
        guard path.hasPrefix(guardedPhysicalEvidenceRoot + "/"),
              !path.contains("\n"), !path.contains("\r"),
              !path.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0 == "." || $0 == ".." }) else {
            return false
        }
        let url = URL(fileURLWithPath: path)
        return url.standardizedFileURL.path == path
            && url.resolvingSymlinksInPath().path == path
    }

    private static func readExactSingleLine(path: String) -> String? {
        guard isGuardedT7EvidencePath(path),
              let data = FileManager.default.contents(atPath: path),
              !data.isEmpty, data.count <= 4_096,
              let text = String(data: data, encoding: .utf8),
              !text.contains("\r") else {
            return nil
        }
        let normalized = text.hasSuffix("\n")
            ? String(text.dropLast()) : text
        guard !normalized.isEmpty, !normalized.contains("\n") else {
            return nil
        }
        return normalized
    }

    private static func readExactKeyValueRecord(
        path: String,
        keys: Set<String>
    ) -> [String: String]? {
        guard isGuardedT7EvidencePath(path),
              let data = FileManager.default.contents(atPath: path),
              !data.isEmpty, data.count <= 4_096,
              let text = String(data: data, encoding: .utf8),
              !text.contains("\r") else {
            return nil
        }
        let normalized = text.hasSuffix("\n")
            ? String(text.dropLast()) : text
        let lines = normalized.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard lines.count == keys.count else { return nil }
        var fields: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: "="),
                  separator != line.startIndex else {
                return nil
            }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            guard keys.contains(key), !value.isEmpty,
                  fields.updateValue(value, forKey: key) == nil else {
                return nil
            }
        }
        return Set(fields.keys) == keys ? fields : nil
    }

    private func waitForStableHostedCallPlayout(
        timeout: TimeInterval,
        stableFor stableDuration: TimeInterval,
        expectedOrigin: PhysicalHostedCallPlayoutOrigin,
        expectedSessionGeneration: UUID? = nil
    ) -> LiveHostedCallEvidence? {
        let deadline = Date().addingTimeInterval(timeout)
        var tracker:
            PhysicalHostedCallPlayoutContinuityTracker?
        var boundSessionGeneration = expectedSessionGeneration
        var stableRoute: String?
        var initialSnapshot:
            PhysicalHostedCallPlayoutSnapshot?
        var latestSnapshot:
            PhysicalHostedCallPlayoutSnapshot?
        var initialObservedAt: TimeInterval?
        var latestObservedAt: TimeInterval?
        var sampleLines: [String] = []

        while Date() < deadline {
            if app.state != .runningForeground || hasConnectionError {
                return nil
            }

            let now = ProcessInfo.processInfo.systemUptime
            let hostedElement =
                element("worldwideHostedCallPlayoutOracle")
            guard presentationValue == "active",
                  element("worldwideSessionState").value as? String
                    == "Connected",
                  element("worldwideAudioState").value as? String
                    == "Playing — iPhone call may reduce quality",
                  hostedElement.exists,
                  let encoded = hostedElement.value as? String,
                  let current =
                    PhysicalHostedCallPlayoutSnapshot(
                        accessibilityValue: encoded
                    ) else {
                if let latestObservedAt,
                   now - latestObservedAt
                    > maximumAudioOracleProgressGap {
                    return nil
                }
                RunLoop.current.run(
                    until: Date().addingTimeInterval(0.1)
                )
                continue
            }

            let microphoneState =
                element("worldwideMicrophoneState").value
                    as? String
            let microphoneValue = microphoneState ?? "missing"
            let rawMicrophoneElement =
                element("worldwideRawMicrophoneOracle")
            let rawMicrophoneValue =
                rawMicrophoneElement.value as? String
                    ?? "missing"
            if microphoneState != "Muted — iPhone call active"
                || rawMicrophoneElement.exists {
                XCTFail(
                    "Hosted-call candidate violated microphone isolation: origin=\(current.origin.rawValue) session=\(current.sessionGeneration) microphone=\(microphoneValue) rawOracleExists=\(rawMicrophoneElement.exists) rawOracle=\(rawMicrophoneValue)"
                )
                return nil
            }

            guard current.origin == expectedOrigin else {
                if let latestObservedAt,
                   now - latestObservedAt
                    > maximumAudioOracleProgressGap {
                    return nil
                }
                RunLoop.current.run(
                    until: Date().addingTimeInterval(0.1)
                )
                continue
            }

            let routeElement = element("worldwideSessionRoute")
            guard routeElement.exists,
                  let route = routeElement.value as? String,
                  acceptedRouteValues.contains(route) else {
                if let latestObservedAt,
                   now - latestObservedAt
                    > maximumAudioOracleProgressGap {
                    return nil
                }
                RunLoop.current.run(
                    until: Date().addingTimeInterval(0.1)
                )
                continue
            }

            let trackerSessionGeneration: UUID
            if let boundSessionGeneration {
                guard current.sessionGeneration
                        == boundSessionGeneration else {
                    XCTFail(
                        "Hosted-call media session changed after binding: expected=\(boundSessionGeneration) actual=\(current.sessionGeneration) origin=\(current.origin.rawValue)"
                    )
                    return nil
                }
                trackerSessionGeneration =
                    boundSessionGeneration
            } else {
                trackerSessionGeneration =
                    current.sessionGeneration
            }

            if let stableRoute, route != stableRoute {
                XCTFail(
                    "Hosted-call route changed during the accepted \(expectedOrigin.rawValue) window: expected=\(stableRoute) actual=\(route)"
                )
                return nil
            }

            if current == latestSnapshot {
                if let latestObservedAt,
                   now - latestObservedAt
                    > maximumAudioOracleProgressGap {
                    return nil
                }
                RunLoop.current.run(
                    until: Date().addingTimeInterval(0.1)
                )
                continue
            }

            if tracker == nil {
                var newTracker =
                    PhysicalHostedCallPlayoutContinuityTracker(
                        requiredDuration: stableDuration,
                        maximumProgressGap:
                            maximumAudioOracleProgressGap,
                        expectedSessionGeneration:
                            trackerSessionGeneration,
                        expectedPolicyID: current.policyID,
                        expectedOrigin: expectedOrigin,
                        expectedAudioPolicyGeneration:
                            current.audioPolicyGeneration,
                        expectedAuthorizationGeneration:
                            current.authorizationGeneration,
                        minimumAdvancementObservations: 3
                    )
                guard newTracker.observe(current, at: now)
                        == .waiting else {
                    XCTFail(
                        "Hosted-call baseline failed deterministic invariants for origin=\(current.origin.rawValue) session=\(current.sessionGeneration) route=\(route)."
                    )
                    return nil
                }
                tracker = newTracker
                boundSessionGeneration =
                    trackerSessionGeneration
                stableRoute = route
                initialSnapshot = current
                latestSnapshot = current
                initialObservedAt = now
                latestObservedAt = now
                var baselineLine = "t=0 baseline"
                baselineLine += " route=\(route)"
                baselineLine += " origin=\(current.origin.rawValue)"
                baselineLine += " session=\(current.sessionGeneration)"
                baselineLine += " policyID=\(current.policyID)"
                baselineLine += " audioPolicyGeneration=\(current.audioPolicyGeneration)"
                baselineLine += " systemAudioGeneration=\(current.systemAudioGeneration)"
                baselineLine += " authorizationGeneration=\(current.authorizationGeneration)"
                baselineLine += " nativeAuthorizationGeneration=\(current.nativeAuthorizationGeneration)"
                baselineLine += " nativeInputEnabled=\(current.inputBusEnabled)"
                baselineLine += " recordingRequests=\(current.unexpectedRecordingRequestCount)"
                baselineLine += " nativeCallbacks=\(current.callbackCount)"
                baselineLine += " nativeFrames=\(current.frameCount)"
                baselineLine += " nativePCMNonzero=\(current.pcmNonzeroSampleCount)"
                baselineLine += " nativePCMAbsolute=\(current.pcmAbsoluteSampleSum)"
                baselineLine += " inboundBytes=\(current.inboundBytes)"
                baselineLine += " inboundPackets=\(current.inboundPackets)"
                baselineLine += " inboundJitterEmitted=\(current.inboundJitterBufferEmittedCount)"
                baselineLine += " inboundSamples=\(current.inboundTotalSamplesReceived)"
                baselineLine += " inboundEnergy=\(current.inboundAudioEnergy)"
                baselineLine += " inboundDuration=\(current.inboundSamplesDuration)"
                sampleLines.append(baselineLine)
                continue
            }

            guard let previous = latestSnapshot,
                  let initialSnapshot,
                  let initialObservedAt,
                  let stableRoute,
                  route == stableRoute,
                  var activeTracker = tracker else {
                return nil
            }
            let result = activeTracker.observe(current, at: now)
            tracker = activeTracker
            if result == .rejected {
                XCTFail(
                    "Hosted-call continuity tracker rejected origin=\(current.origin.rawValue) session=\(current.sessionGeneration) route=\(route)."
                )
                return nil
            }

            var progressLine =
                "t=\(now - initialObservedAt)"
            progressLine +=
                " gap=\(now - (latestObservedAt ?? initialObservedAt))"
            progressLine += " route=\(route)"
            progressLine += " origin=\(current.origin.rawValue)"
            progressLine += " session=\(current.sessionGeneration)"
            progressLine += " policyID=\(current.policyID)"
            progressLine += " audioPolicyGeneration=\(current.audioPolicyGeneration)"
            progressLine += " systemAudioGeneration=\(current.systemAudioGeneration)"
            progressLine += " authorizationGeneration=\(current.authorizationGeneration)"
            progressLine += " nativeAuthorizationGeneration=\(current.nativeAuthorizationGeneration)"
            progressLine += " nativeInputEnabled=\(current.inputBusEnabled)"
            progressLine += " recordingRequests=\(current.unexpectedRecordingRequestCount)"
            progressLine += " nativeCallbacksDelta=\(current.callbackCount - previous.callbackCount)"
            progressLine += " nativeFramesDelta=\(current.frameCount - previous.frameCount)"
            progressLine += " nativePCMNonzeroDelta=\(current.pcmNonzeroSampleCount - previous.pcmNonzeroSampleCount)"
            progressLine += " nativePCMAbsoluteDelta=\(current.pcmAbsoluteSampleSum - previous.pcmAbsoluteSampleSum)"
            progressLine += " inboundBytesDelta=\(current.inboundBytes - previous.inboundBytes)"
            progressLine += " inboundPacketsDelta=\(current.inboundPackets - previous.inboundPackets)"
            progressLine += " inboundJitterEmittedDelta=\(current.inboundJitterBufferEmittedCount - previous.inboundJitterBufferEmittedCount)"
            progressLine += " inboundSamplesDelta=\(current.inboundTotalSamplesReceived - previous.inboundTotalSamplesReceived)"
            progressLine += " inboundEnergyDelta=\(current.inboundAudioEnergy - previous.inboundAudioEnergy)"
            progressLine += " inboundDurationDelta=\(current.inboundSamplesDuration - previous.inboundSamplesDuration)"
            sampleLines.append(progressLine)
            latestSnapshot = current
            latestObservedAt = now

            if result == .satisfied {
                return LiveHostedCallEvidence(
                    route: stableRoute,
                    initialSnapshot: initialSnapshot,
                    finalSnapshot: current,
                    elapsed: now - initialObservedAt,
                    sampleLog: sampleLines.joined(separator: "\n")
                )
            }

            RunLoop.current.run(
                until: Date().addingTimeInterval(0.1)
            )
        }

        return nil
    }

    private func waitForFreshPostCallOrdinaryPlayback(
        expectedSessionGeneration: UUID,
        excludedHostedAudioPolicyGenerations: Set<UUID>,
        timeout: TimeInterval,
        stableFor stableDuration: TimeInterval
    ) -> LivePostCallPlaybackEvidence? {
        guard excludedHostedAudioPolicyGenerations.count == 2 else {
            XCTFail(
                "Ordinary recovery requires exactly the startup and interruption hosted audio-policy generations to be excluded."
            )
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        var tracker: PhysicalAudioContinuityTracker?
        var postCallBaseline: PhysicalAudioPlayoutSnapshot?
        var latestSnapshot: PhysicalAudioPlayoutSnapshot?
        var initialObservedAt: TimeInterval?
        var latestObservedAt: TimeInterval?
        var stableRoute: String?
        var sampleLines: [String] = []
        let excludedHostedPolicyText =
            excludedHostedAudioPolicyGenerations
                .map { $0.uuidString.lowercased() }
                .sorted()
                .joined(separator: ",")

        while Date() < deadline {
            if app.state != .runningForeground || hasConnectionError {
                return nil
            }

            let now = ProcessInfo.processInfo.systemUptime
            let ordinaryElement =
                element("worldwideAudioPlayoutOracle")
            let hostedElement =
                element("worldwideHostedCallPlayoutOracle")
            if tracker != nil, hostedElement.exists {
                XCTFail(
                    "A hosted-call oracle reappeared after the fresh ordinary recovery baseline was accepted."
                )
                return nil
            }

            guard presentationValue == "active",
                  element("worldwideSessionState").value as? String
                    == "Connected",
                  element("worldwideAudioState").value as? String
                    == "Playing",
                  !hostedElement.exists,
                  ordinaryElement.exists,
                  let encoded = ordinaryElement.value as? String,
                  let current = PhysicalAudioPlayoutSnapshot(
                      accessibilityValue: encoded
                  ) else {
                if let latestObservedAt,
                   now - latestObservedAt
                    > maximumAudioOracleProgressGap {
                    return nil
                }
                RunLoop.current.run(
                    until: Date().addingTimeInterval(0.1)
                )
                continue
            }

            guard current.sessionGeneration
                    == expectedSessionGeneration else {
                XCTFail(
                    "Ordinary recovery replaced the media session: expected=\(expectedSessionGeneration) actual=\(current.sessionGeneration)."
                )
                return nil
            }

            let routeElement = element("worldwideSessionRoute")
            guard routeElement.exists,
                  let route = routeElement.value as? String,
                  acceptedRouteValues.contains(route) else {
                if let latestObservedAt,
                   now - latestObservedAt
                    > maximumAudioOracleProgressGap {
                    return nil
                }
                RunLoop.current.run(
                    until: Date().addingTimeInterval(0.1)
                )
                continue
            }

            if tracker == nil,
               excludedHostedAudioPolicyGenerations.contains(
                   current.audioPolicyGeneration
               ) {
                RunLoop.current.run(
                    until: Date().addingTimeInterval(0.1)
                )
                continue
            }

            if let stableRoute, route != stableRoute {
                XCTFail(
                    "Ordinary recovery route changed during the accepted proof window: expected=\(stableRoute) actual=\(route)."
                )
                return nil
            }
            if let postCallBaseline,
               current.audioPolicyGeneration
                != postCallBaseline.audioPolicyGeneration {
                XCTFail(
                    "Ordinary recovery audio-policy generation changed after its fresh baseline: expected=\(postCallBaseline.audioPolicyGeneration) actual=\(current.audioPolicyGeneration)."
                )
                return nil
            }

            if current == latestSnapshot {
                if let latestObservedAt,
                   now - latestObservedAt
                    > maximumAudioOracleProgressGap {
                    return nil
                }
                RunLoop.current.run(
                    until: Date().addingTimeInterval(0.1)
                )
                continue
            }

            if tracker == nil {
                var newTracker = PhysicalAudioContinuityTracker(
                    requiredDuration: stableDuration,
                    maximumProgressGap:
                        maximumAudioOracleProgressGap,
                    expectedSessionGeneration:
                        expectedSessionGeneration,
                    expectedAudioPolicyGeneration:
                        current.audioPolicyGeneration
                )
                guard newTracker.observe(current, at: now)
                        == .waiting else {
                    XCTFail(
                        "Fresh ordinary recovery baseline failed deterministic native-audio invariants."
                    )
                    return nil
                }
                tracker = newTracker
                postCallBaseline = current
                latestSnapshot = current
                initialObservedAt = now
                latestObservedAt = now
                stableRoute = route
                var baselineLine = "t=0 newBaseline"
                baselineLine += " origin=ordinary"
                baselineLine += " route=\(route)"
                baselineLine += " session=\(current.sessionGeneration)"
                baselineLine += " policyID=none"
                baselineLine += " audioPolicyGeneration=\(current.audioPolicyGeneration)"
                baselineLine += " authorizationGeneration=none"
                baselineLine += " excludedHostedAudioPolicyGenerations=\(excludedHostedPolicyText)"
                baselineLine += " nativeCallbacks=\(current.callbackCount)"
                baselineLine += " nativeFrames=\(current.frameCount)"
                baselineLine += " nativePCMSamples=\(current.pcmSampleCount)"
                baselineLine += " nativePCMNonzero=\(current.pcmNonzeroSampleCount)"
                baselineLine += " nativePCMAbsolute=\(current.pcmAbsoluteSampleSum)"
                baselineLine += " inboundEnergy=\(current.inboundAudioEnergy)"
                baselineLine += " inboundDuration=\(current.inboundSamplesDuration)"
                sampleLines.append(baselineLine)
                continue
            }

            guard route == stableRoute,
                  let previous = latestSnapshot,
                  let postCallBaseline,
                  let initialObservedAt,
                  current.audioPolicyGeneration
                    == postCallBaseline.audioPolicyGeneration,
                  var activeTracker = tracker else {
                return nil
            }

            let result = activeTracker.observe(current, at: now)
            tracker = activeTracker
            if result == .rejected {
                XCTFail(
                    "Fresh ordinary recovery continuity tracker rejected session=\(current.sessionGeneration) audioPolicy=\(current.audioPolicyGeneration) route=\(route)."
                )
                return nil
            }

            var progressLine =
                "t=\(now - initialObservedAt)"
            progressLine +=
                " gap=\(now - (latestObservedAt ?? initialObservedAt))"
            progressLine += " origin=ordinary"
            progressLine += " route=\(route)"
            progressLine += " session=\(current.sessionGeneration)"
            progressLine += " policyID=none"
            progressLine += " audioPolicyGeneration=\(current.audioPolicyGeneration)"
            progressLine += " authorizationGeneration=none"
            progressLine += " nativeCallbacksDelta=\(current.callbackCount - previous.callbackCount)"
            progressLine += " nativeFramesDelta=\(current.frameCount - previous.frameCount)"
            progressLine += " nativePCMSamplesDelta=\(current.pcmSampleCount - previous.pcmSampleCount)"
            progressLine += " nativePCMNonzeroDelta=\(current.pcmNonzeroSampleCount - previous.pcmNonzeroSampleCount)"
            progressLine += " nativePCMAbsoluteDelta=\(current.pcmAbsoluteSampleSum - previous.pcmAbsoluteSampleSum)"
            progressLine += " inboundEnergyDelta=\(current.inboundAudioEnergy - previous.inboundAudioEnergy)"
            progressLine += " inboundDurationDelta=\(current.inboundSamplesDuration - previous.inboundSamplesDuration)"
            sampleLines.append(progressLine)
            latestSnapshot = current
            latestObservedAt = now

            if result == .satisfied {
                return LivePostCallPlaybackEvidence(
                    route: route,
                    excludedHostedAudioPolicyGenerations:
                        excludedHostedAudioPolicyGenerations,
                    ordinaryAudioPolicyGeneration:
                        postCallBaseline.audioPolicyGeneration,
                    postCallBaseline: postCallBaseline,
                    finalAudioSnapshot: current,
                    elapsed: now - initialObservedAt,
                    sampleLog: sampleLines.joined(separator: "\n")
                )
            }

            RunLoop.current.run(
                until: Date().addingTimeInterval(0.1)
            )
        }

        return nil
    }

    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.state != .runningForeground || hasConnectionError {
                return false
            }
            if element.exists, element.isEnabled {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func waitForStableLiveScreenWithRemoteInput(
        timeout: TimeInterval,
        stableFor stableDuration: TimeInterval
    ) -> LiveScreenEvidence? {
        let deadline = Date().addingTimeInterval(timeout)
        var tracker = PhysicalVideoContinuityTracker(
            requiredDuration: stableDuration,
            maximumProgressGap: maximumVideoOracleProgressGap
        )
        var showAcknowledgement: PhysicalScreenAcknowledgementSnapshot?
        var initialVideoSnapshot: PhysicalVideoRenderSnapshot?
        while Date() < deadline {
            if app.state != .runningForeground || hasConnectionError {
                return nil
            }

            let screenVideo = element("worldwideMacScreenVideo")
            let screenIsLive = app.staticTexts["Screen live"].exists
            let remoteInput = element("worldwideRemoteInputEnabled")
            let acknowledgementElement = element("worldwideScreenAcknowledgementOracle")
            let screenFrameIsVisible = screenVideo.exists
                && screenVideo.frame.width > 1
                && screenVideo.frame.height > 1
            if screenFrameIsVisible,
               screenIsLive,
               remoteInput.exists,
               let encodedVideo = screenVideo.value as? String,
               let currentVideo = PhysicalVideoRenderSnapshot(
                   accessibilityValue: encodedVideo
               ),
               currentVideo.frameCount > 0,
               currentVideo.width > 0,
               currentVideo.height > 0,
               acknowledgementElement.exists,
               let encodedAcknowledgement = acknowledgementElement.value as? String,
               let currentAcknowledgement = PhysicalScreenAcknowledgementSnapshot(
                   accessibilityValue: encodedAcknowledgement
               ),
               currentAcknowledgement.command == .show,
               currentAcknowledgement.state == .active {
                let now = ProcessInfo.processInfo.systemUptime
                if showAcknowledgement == nil {
                    showAcknowledgement = currentAcknowledgement
                    initialVideoSnapshot = currentVideo
                } else if currentAcknowledgement != showAcknowledgement {
                    return nil
                }
                switch tracker.observe(currentVideo, at: now) {
                case .waiting:
                    break
                case .satisfied:
                    if let showAcknowledgement, let initialVideoSnapshot {
                        return LiveScreenEvidence(
                            showAcknowledgement: showAcknowledgement,
                            initialVideoSnapshot: initialVideoSnapshot,
                            finalVideoSnapshot: currentVideo
                        )
                    }
                case .rejected:
                    return nil
                }
            } else {
                tracker = PhysicalVideoContinuityTracker(
                    requiredDuration: stableDuration,
                    maximumProgressGap: maximumVideoOracleProgressGap
                )
                showAcknowledgement = nil
                initialVideoSnapshot = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    private func waitForHostAcknowledgedScreenHide(
        after showAcknowledgement: PhysicalScreenAcknowledgementSnapshot,
        timeout: TimeInterval
    ) -> PhysicalScreenAcknowledgementSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.state != .runningForeground || hasConnectionError {
                return nil
            }

            let acknowledgementElement = element("worldwideScreenAcknowledgementOracle")
            if !element("worldwideMacScreenVideo").exists,
               !element("worldwideRemoteInputEnabled").exists,
               !app.staticTexts["Screen live"].exists,
               !app.buttons["hideWorldwideMacScreen"].exists,
               acknowledgementElement.exists,
               let encodedAcknowledgement = acknowledgementElement.value as? String,
               let acknowledgement = PhysicalScreenAcknowledgementSnapshot(
                   accessibilityValue: encodedAcknowledgement
               ),
               acknowledgement.sessionGeneration
                    == showAcknowledgement.sessionGeneration,
               acknowledgement.requestID > showAcknowledgement.requestID,
               acknowledgement.command == .hide,
               acknowledgement.state == .inactive {
                return acknowledgement
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    private var livePlaybackObservation: String {
        let presentation = presentationValue ?? "missing"
        let session = element("worldwideSessionState").value as? String ?? "missing"
        let audio = element("worldwideAudioState").value as? String ?? "missing"
        let route = element("worldwideSessionRoute").value as? String ?? "missing"
        let oracle = element("worldwideAudioPlayoutOracle").value as? String ?? "missing"
        let hosted = element("worldwideHostedCallPlayoutOracle").value as? String ?? "missing"
        let microphone =
            element("worldwideMicrophoneState").value as? String
                ?? "missing"
        let rawMicrophoneElement =
            element("worldwideRawMicrophoneOracle")
        let rawMicrophone =
            rawMicrophoneElement.value as? String
                ?? "missing"
        return "presentation=\(presentation), session=\(session), audio=\(audio), route=\(route), worldwideMicrophoneState=\(microphone), worldwideRawMicrophoneOracleExists=\(rawMicrophoneElement.exists), worldwideRawMicrophoneOracle=\(rawMicrophone), nativeOracle=\(oracle), hostedOracle=\(hosted), appState=\(app.state.rawValue), connectionError=\(hasConnectionError)"
    }

    private var liveRawMicrophoneObservation: String {
        let microphone =
            element("worldwideMicrophoneState").value as? String
                ?? "missing"
        let oracle =
            element("worldwideRawMicrophoneOracle").value as? String
                ?? "missing"
        return "microphone=\(microphone), rawOracle=\(oracle), appState=\(app.state.rawValue), connectionError=\(hasConnectionError)"
    }

    private var liveScreenObservation: String {
        let screenVideo = element("worldwideMacScreenVideo")
        let frame = screenVideo.exists ? String(describing: screenVideo.frame) : "missing"
        let screenIsLive = app.staticTexts["Screen live"].exists
        let remoteInputExists = element("worldwideRemoteInputEnabled").exists
        let hideActionExists = app.buttons["hideWorldwideMacScreen"].exists
        let videoOracle = screenVideo.value as? String ?? "missing"
        let acknowledgement = element("worldwideScreenAcknowledgementOracle").value as? String ?? "missing"
        return "videoExists=\(screenVideo.exists), videoFrame=\(frame), videoOracle=\(videoOracle), screenAcknowledgement=\(acknowledgement), screenLive=\(screenIsLive), remoteInputCapability=\(remoteInputExists), hideAction=\(hideActionExists), appState=\(app.state.rawValue), connectionError=\(hasConnectionError)"
    }

    private func waitForHostFailureToReturnToSavedPair(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // No launch occurs inside the retry loop. Treat a crash, termination, or background
            // transition as failure instead of accidentally accepting a newly initialized view.
            if app.state != .runningForeground {
                return false
            }

            // A transient or persistent historical error is a regression. In particular, do not
            // allow a later idle state to make the test pass after briefly publishing the stale
            // "Mac disconnected" media error.
            if hasConnectionError {
                return false
            }

            let routeIsGone = !element("worldwideSessionRoute").exists
            let reconnectIsAvailable = app.buttons["connectPairedWorldwide"].exists
            if presentationValue == "pairedIdle",
               routeIsGone,
               reconnectIsAvailable {
                return element("worldwidePairedMac").exists
                    && element("worldwidePairingSaved").exists
                    && !element("worldwideInvitationCode").exists
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func assertActivePresentation(
        route expectedRoute: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertPresentation("active", file: file, line: line)
        let disconnect = app.buttons["disconnectWorldwide"]
        XCTAssertTrue(disconnect.exists, file: file, line: line)
        XCTAssertEqual(
            disconnect.label,
            "Disconnect Remote Mac",
            file: file,
            line: line
        )

        let route = element("worldwideSessionRoute")
        XCTAssertTrue(route.exists, file: file, line: line)
        XCTAssertEqual(route.label, "Route", file: file, line: line)
        XCTAssertEqual(route.value as? String, expectedRoute, file: file, line: line)
        XCTAssertTrue(
            acceptedRouteValues.contains(expectedRoute),
            "Only a proven Direct or TURN relay route is acceptable",
            file: file,
            line: line
        )
    }

    private func assertPresentation(
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let oracle = element("worldwidePresentationState")
        XCTAssertTrue(
            oracle.waitForExistence(timeout: 10),
            "The worldwide presentation oracle is missing",
            file: file,
            line: line
        )
        XCTAssertEqual(presentationValue, expected, file: file, line: line)
    }

    private var presentationValue: String? {
        element("worldwidePresentationState").value as? String
    }

    private var hasConnectionError: Bool {
        connectionErrorIdentifiers.contains { element($0).exists }
            || app.staticTexts[
                "The Mac disconnected. Reconnect to the saved paired Mac when it is available."
            ].exists
    }

    private var connectionErrorIdentifiers: [String] {
        [
            "worldwidePreparationError",
            "worldwideMediaError",
            "worldwideAudioError",
            "worldwideSavedPairUnavailable",
            "worldwidePairingStorageError",
        ]
    }

    private var acceptedRouteValues: Set<String> {
        ["Direct", "TURN relay"]
    }

    private func addRouteEvidence(
        _ route: String,
        phase: String,
        to activity: XCTActivity
    ) {
        assertActivePresentation(route: route)
        let attachment = XCTAttachment(string: route)
        attachment.name = "WebRTC route - \(phase)"
        attachment.lifetime = .keepAlways
        activity.add(attachment)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }
}
