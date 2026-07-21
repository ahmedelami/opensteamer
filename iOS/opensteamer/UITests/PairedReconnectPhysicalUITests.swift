import XCTest

/// Release gate for the exact physical failure reported from the distributed production build. The test deliberately
/// launches the production bundle rather than the side-by-side `.dev` app so it observes the
/// user's real Keychain pair. A shell preflight must first prove the expected production build is
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

    /// Route and final monotonic audio snapshot from one verified playback window.
    private struct LivePlaybackEvidence {
        let route: String
        let finalAudioSnapshot: PhysicalAudioPlayoutSnapshot
    }

    // The visible product is opensteamer, but TestFlight updates retain the shipped bundle identity.
    private let app = XCUIApplication(bundleIdentifier: "org.example.AudioStreamer")
    // Audio diagnostics are published by the one-second WebRTC statistics task, so 1.5 seconds
    // permits one ordinary publication interval without allowing a late burst to launder a stall.
    private let maximumAudioOracleProgressGap: TimeInterval = 1.5
    // At a 60 fps source, a 750 ms decoded-frame stall is already user-visible.
    private let maximumVideoOracleProgressGap: TimeInterval = 0.75
    private let backgroundEvidenceDuration: TimeInterval = 35

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
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
        expectedSessionGeneration: UUID? = nil
    ) -> LivePlaybackEvidence? {
        let deadline = Date().addingTimeInterval(timeout)
        var stableRoute: String?
        var tracker = PhysicalAudioContinuityTracker(
            requiredDuration: stableDuration,
            maximumProgressGap: maximumAudioOracleProgressGap,
            expectedSessionGeneration: expectedSessionGeneration
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
                        expectedSessionGeneration: expectedSessionGeneration
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
                    expectedSessionGeneration: expectedSessionGeneration
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
                  current.failureCount == 0,
                  current.fullQualityInvariantsHold else {
                XCTFail("\(phase) replaced or degraded the media session while backgrounded")
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
                    playback.finalAudioSnapshot.sessionGeneration
            ),
            "\(phase) lost its Connected session, native audio playback, or live WebRTC route after Hide Screen. Last observation: \(livePlaybackObservation)"
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - audioContinuityStartedAt
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
        return "presentation=\(presentation), session=\(session), audio=\(audio), route=\(route), nativeOracle=\(oracle), appState=\(app.state.rawValue), connectionError=\(hasConnectionError)"
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
