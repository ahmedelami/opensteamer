import XCTest

/// Release gate for the exact physical failure reported from the distributed production build. The test deliberately
/// launches the production bundle rather than the side-by-side `.dev` app so it observes the
/// user's real Keychain pair. A shell preflight must first prove the expected production build is
/// installed; missing pairing, accessibility identifiers, host availability, or any live route is
/// a failure, never a skip.
@MainActor
final class PairedReconnectPhysicalUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "org.example.AudioStreamer")

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

                let route = try connectAndRequireStableRoute(
                    phase: "host restart reconnect \(attempt)"
                )
                addRouteEvidence(route, phase: "host restart reconnect \(attempt)", to: activity)

                let liveAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                liveAttachment.name =
                    "test iPhone \(route) route before host restart \(attempt)"
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
            let firstRoute = try connectAndRequireStableRoute(
                phase: "explicit disconnect"
            )
            addRouteEvidence(firstRoute, phase: "before explicit disconnect", to: activity)
            app.buttons["disconnectWorldwide"].tap()
            XCTAssertTrue(
                waitForHostFailureToReturnToSavedPair(timeout: 45),
                "Explicit disconnect did not return to the clean saved-pair UI"
            )
            assertSavedPairIsIdleWithoutHistoricalError(
                expectedPairFingerprint: expectedPairFingerprint
            )

            let reconnectedRoute = try connectAndRequireStableRoute(
                phase: "same-process reconnect after explicit disconnect"
            )
            addRouteEvidence(
                reconnectedRoute,
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
            let route = try connectAndRequireStableRoute(
                phase: "cold-launch saved-pair reconnect"
            )
            addRouteEvidence(route, phase: "cold-launch saved-pair reconnect", to: activity)
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

    private func connectAndRequireStableRoute(phase: String) throws -> String {
        app.buttons["connectPairedWorldwide"].tap()
        return try XCTUnwrap(
            waitForStableLiveRouteWithoutError(timeout: 45, stableFor: 2),
            "\(phase) never reached a stable Direct or TURN relay route without an error"
        )
    }

    private func waitForStableLiveRouteWithoutError(
        timeout: TimeInterval,
        stableFor stableDuration: TimeInterval
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var stableRoute: String?
        var stableSince: Date?
        while Date() < deadline {
            if app.state != .runningForeground || hasConnectionError {
                return nil
            }

            let routeElement = element("worldwideSessionRoute")
            let route = routeElement.value as? String
            if presentationValue == "active",
               routeElement.exists,
               let route,
               acceptedRouteValues.contains(route) {
                if route != stableRoute {
                    stableRoute = route
                    stableSince = Date()
                } else if let stableSince,
                          Date().timeIntervalSince(stableSince) >= stableDuration {
                    return route
                }
            } else {
                stableRoute = nil
                stableSince = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
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
