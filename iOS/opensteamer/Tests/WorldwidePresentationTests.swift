import XCTest
@testable import opensteamer

/// Verifies the pure worldwide-card reducer and prepared-session handoff ownership.
/// These tests ensure one UI surface wins at a time and a superseded asynchronous close cannot
/// publish an error or connect a client after a replacement preparation owns the generation.
@MainActor
final class WorldwidePresentationTests: XCTestCase {
    func testRendezvousEndpointPrefersOpensteamerConfiguration() {
        let endpoint = WorldwideSessionViewModel.rendezvousEndpoint(
            debugOverride: nil,
            infoDictionary: [
                "OpensteamerRendezvousURL": "wss://opensteamer.example.test",
                "AudioStreamerRendezvousURL": "wss://legacy.example.test",
            ]
        )

        XCTAssertEqual(endpoint, URL(string: "wss://opensteamer.example.test"))
    }

    func testRendezvousEndpointFallsBackToLegacyConfiguration() {
        let endpoint = WorldwideSessionViewModel.rendezvousEndpoint(
            debugOverride: nil,
            infoDictionary: [
                "OpensteamerRendezvousURL": "$(OPENSTEAMER_RENDEZVOUS_URL)",
                "AudioStreamerRendezvousURL": "wss://legacy.example.test",
            ]
        )

        XCTAssertEqual(endpoint, URL(string: "wss://legacy.example.test"))
    }

    func testSupersededPreparedSessionCannotConnectAtHandoffEntry() async {
        let staleGeneration = UUID()
        let currentGeneration = UUID()
        var connectCount = 0
        var closeCount = 0
        var publicationCount = 0

        await BrowserView.handoffPreparedWorldwideSession(
            generation: staleGeneration,
            isCurrentGeneration: { currentGeneration == staleGeneration },
            connect: {
                connectCount += 1
                return false
            },
            close: {
                closeCount += 1
            },
            reportActiveSessionConflict: {
                publicationCount += 1
            }
        )

        XCTAssertNotEqual(currentGeneration, staleGeneration)
        XCTAssertEqual(connectCount, 0)
        XCTAssertEqual(closeCount, 1, "The stale task must close only its prepared client")
        XCTAssertEqual(publicationCount, 0)
    }

    func testSupersededPreparedSessionCannotPublishAfterNonCooperativeClose() async {
        let generation = UUID()
        var currentGeneration = generation
        var connectCount = 0
        var closeCount = 0
        var publicationCount = 0
        let closeGate = NonCooperativePreparedSessionCloseGate()

        let handoff = Task { @MainActor in
            await BrowserView.handoffPreparedWorldwideSession(
                generation: generation,
                isCurrentGeneration: { currentGeneration == generation },
                connect: {
                    connectCount += 1
                    return false
                },
                close: {
                    closeCount += 1
                    await closeGate.wait()
                },
                reportActiveSessionConflict: {
                    publicationCount += 1
                }
            )
        }

        await closeGate.waitUntilSuspended()
        currentGeneration = UUID()
        await closeGate.resume()
        await handoff.value

        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(
            publicationCount,
            0,
            "A superseded task must not publish after its non-cooperative close resumes"
        )
    }

    func testCurrentPreparedSessionConflictPublishesOnlyAfterCloseCompletes() async {
        let generation = UUID()
        let currentGeneration = generation
        var events: [String] = []

        await BrowserView.handoffPreparedWorldwideSession(
            generation: generation,
            isCurrentGeneration: { currentGeneration == generation },
            connect: {
                events.append("connect")
                return false
            },
            close: {
                events.append("close")
            },
            reportActiveSessionConflict: {
                events.append("publish")
            }
        )

        XCTAssertEqual(currentGeneration, generation)
        XCTAssertEqual(events, ["connect", "close", "publish"])
    }

    func testPairedMacAccessibilityFingerprintIsStableAndDoesNotExposeRawPairID() {
        let pairID = UUID(uuidString: "8F7C27DC-20F1-40D9-8444-1E1775F5CF48")!
        let first = BrowserView.WorldwidePresentation.PairedMac(
            pairID: pairID,
            displayName: "Test Mac",
            isPairingActive: true
        )
        let reconstructed = BrowserView.WorldwidePresentation.PairedMac(
            pairID: pairID,
            displayName: "Renamed Mac",
            isPairingActive: true
        )
        let otherPair = BrowserView.WorldwidePresentation.PairedMac(
            pairID: UUID(uuidString: "165A38F7-48D8-498A-A1D4-111B512BE2CD")!,
            displayName: "Test Mac",
            isPairingActive: true
        )

        XCTAssertEqual(first.accessibilityFingerprint, reconstructed.accessibilityFingerprint)
        XCTAssertNotEqual(first.accessibilityFingerprint, otherPair.accessibilityFingerprint)
        XCTAssertFalse(first.accessibilityFingerprint.contains(pairID.uuidString.lowercased()))
        XCTAssertNotNil(
            first.accessibilityFingerprint.range(
                of: #"^pair-[0-9a-f]{24}$"#,
                options: .regularExpression
            )
        )
    }

    func testActiveSessionWinsAndOwnsCurrentMediaMetadata() {
        let pair = pairedMac()
        let expiration = Date(timeIntervalSince1970: 1_800_000_000)
        let presentation = BrowserView.worldwidePresentation(
            input(
                hasActiveSession: true,
                isPreparingFreshSession: true,
                pairedMac: pair,
                savedPairState: .unavailableAfterDeadline(
                    .init(attemptID: UUID(), pairID: pair.pairID)
                ),
                preparationError: "Old preparation error",
                mediaError: "Current media error",
                audioError: "Current audio error",
                invitationExpiresAt: expiration
            )
        )

        guard case .active(let activeSession) = presentation.surface else {
            return XCTFail("An active media session must own the presentation")
        }
        XCTAssertEqual(activeSession.stateText, "Connected")
        XCTAssertEqual(activeSession.routeText, "Direct")
        XCTAssertEqual(presentation.status, .mediaError("Current media error"))
        XCTAssertEqual(presentation.invitationExpiresAt, expiration)
        XCTAssertEqual(presentation.primaryActionTitle, "Disconnect Remote Mac")
        XCTAssertEqual(presentation.accessibilityValue, "active")
    }

    func testActiveAudioErrorWinsOnlyWhenThereIsNoMediaError() {
        let expiration = Date(timeIntervalSince1970: 1_800_000_000)
        let presentation = BrowserView.worldwidePresentation(
            input(
                hasActiveSession: true,
                audioError: "Playback unavailable",
                invitationExpiresAt: expiration
            )
        )

        XCTAssertEqual(presentation.status, .audioError("Playback unavailable"))
        XCTAssertEqual(presentation.invitationExpiresAt, expiration)
        XCTAssertEqual(presentation.accessibilityValue, "active")
    }

    func testCurrentPreparationWinsOverDeadlinePairAndHistoricalMedia() {
        let pair = pairedMac()
        let presentation = BrowserView.worldwidePresentation(
            input(
                isPreparingFreshSession: true,
                pairedMac: pair,
                savedPairState: .unavailableAfterDeadline(
                    .init(attemptID: UUID(), pairID: pair.pairID)
                ),
                preparationError: "Current preparation error",
                mediaError: "Old media error",
                audioError: "Old audio error",
                invitationExpiresAt: Date()
            )
        )

        guard case .preparing(let preparingSession) = presentation.surface else {
            return XCTFail("Current preparation must precede retained-pair idle state")
        }
        XCTAssertEqual(preparingSession.stateText, "Finding paired Mac")
        XCTAssertEqual(
            presentation.status,
            .preparationError("Current preparation error")
        )
        XCTAssertNil(presentation.invitationExpiresAt)
        XCTAssertEqual(presentation.primaryActionTitle, "Cancel")
        XCTAssertEqual(presentation.accessibilityValue, "preparing")
    }

    func testMatchingDeadlineProducesSavedPairUnavailableRecovery() {
        let pair = pairedMac()
        let presentation = BrowserView.worldwidePresentation(
            input(
                pairedMac: pair,
                savedPairState: .unavailableAfterDeadline(
                    .init(attemptID: UUID(), pairID: pair.pairID)
                ),
                preparationError: "Superseded preparation error",
                mediaError: "Superseded media error",
                audioError: "Superseded audio error",
                invitationExpiresAt: Date()
            )
        )

        XCTAssertEqual(presentation.surface, .savedPairUnavailable(pair))
        XCTAssertEqual(
            presentation.status,
            .savedPairUnavailable(
                title: "Paired Mac Unavailable",
                message: BrowserView.savedPairUnavailableMessage
            )
        )
        XCTAssertNil(presentation.invitationExpiresAt)
        XCTAssertEqual(presentation.primaryActionTitle, "Retry Saved Pairing")
        XCTAssertEqual(presentation.accessibilityValue, "savedPairUnavailable")
    }

    func testPairedIdleUsesPreparationFailureBeforeCurrentMediaFailure() {
        let pair = pairedMac()
        let presentation = BrowserView.worldwidePresentation(
            input(
                pairedMac: pair,
                preparationError: "Current preparation error",
                mediaError: "Current terminal media error",
                audioError: "Old audio error",
                invitationExpiresAt: Date()
            )
        )

        XCTAssertEqual(presentation.surface, .pairedIdle(pair))
        XCTAssertEqual(
            presentation.status,
            .preparationError("Current preparation error")
        )
        XCTAssertNil(presentation.invitationExpiresAt)
        XCTAssertEqual(presentation.primaryActionTitle, "Connect to Paired Mac")
        XCTAssertEqual(presentation.accessibilityValue, "pairedIdle")
    }

    func testDeadlineForSupersededPairFallsBackToCurrentPairedIdle() {
        let pair = pairedMac()
        let presentation = BrowserView.worldwidePresentation(
            input(
                pairedMac: pair,
                savedPairState: .unavailableAfterDeadline(
                    .init(attemptID: UUID(), pairID: UUID())
                ),
                mediaError: "Old media error"
            )
        )

        XCTAssertEqual(presentation.surface, .pairedIdle(pair))
        XCTAssertEqual(presentation.status, .mediaError("Old media error"))
        XCTAssertEqual(presentation.primaryActionTitle, "Connect to Paired Mac")
        XCTAssertEqual(presentation.accessibilityValue, "pairedIdle")
    }

    func testOrdinaryPairedIdleFallsBackToCurrentMediaError() {
        let pair = pairedMac()
        let presentation = BrowserView.worldwidePresentation(
            input(
                pairedMac: pair,
                mediaError: "The secure media connection closed."
            )
        )

        XCTAssertEqual(presentation.surface, .pairedIdle(pair))
        XCTAssertEqual(
            presentation.status,
            .mediaError("The secure media connection closed.")
        )
        XCTAssertEqual(presentation.accessibilityValue, "pairedIdle")
    }

    func testActualSessionFailureSurvivesPassiveLifecycleUntilFreshAttempt() {
        let viewModel = WorldwideSessionViewModel()
        let pair = pairedMac()
        let terminalError = "The secure media connection closed."

        viewModel.debugFailSessionForTests(terminalError)
        XCTAssertFalse(viewModel.hasActiveSession)
        XCTAssertEqual(viewModel.lastError, terminalError)

        func currentPresentation() -> BrowserView.WorldwidePresentation {
            BrowserView.worldwidePresentation(
                input(
                    hasActiveSession: viewModel.hasActiveSession,
                    pairedMac: pair,
                    mediaError: viewModel.lastError
                )
            )
        }

        var presentation = currentPresentation()
        XCTAssertEqual(presentation.surface, .pairedIdle(pair))
        XCTAssertEqual(presentation.status, .mediaError(terminalError))
        XCTAssertEqual(presentation.accessibilityValue, "pairedIdle")

        viewModel.handleAppBecameInactive()
        viewModel.handleAppEnteredBackground()
        viewModel.handleAppBecameActive()
        presentation = currentPresentation()
        XCTAssertEqual(presentation.status, .mediaError(terminalError))
        XCTAssertEqual(presentation.accessibilityValue, "pairedIdle")

        viewModel.beginFreshConnectionAttempt()
        presentation = currentPresentation()
        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(presentation.surface, .pairedIdle(pair))
        XCTAssertNil(presentation.status)
        XCTAssertEqual(presentation.accessibilityValue, "pairedIdle")
    }

    func testRecoverablePairUsesFinishActionFromSamePresentation() {
        let pair = pairedMac(isPairingActive: false)
        let presentation = BrowserView.worldwidePresentation(input(pairedMac: pair))

        XCTAssertEqual(presentation.surface, .pairedIdle(pair))
        XCTAssertEqual(presentation.primaryActionTitle, "Finish Secure Pairing")
        XCTAssertEqual(presentation.accessibilityValue, "pairedIdle")
    }

    func testUnpairedBootstrapErrorPrecedenceIsPreparationThenMedia() {
        let preparationError = BrowserView.worldwidePresentation(
            input(
                preparationError: "Preparation failed",
                mediaError: "Media failed",
                audioError: "Stale audio error",
                invitationExpiresAt: Date()
            )
        )
        XCTAssertEqual(preparationError.surface, .bootstrap)
        XCTAssertEqual(
            preparationError.status,
            .preparationError("Preparation failed")
        )
        XCTAssertNil(preparationError.invitationExpiresAt)
        XCTAssertEqual(preparationError.accessibilityValue, "preparationError")

        let mediaError = BrowserView.worldwidePresentation(
            input(mediaError: "Media failed")
        )
        XCTAssertEqual(mediaError.status, .mediaError("Media failed"))
        XCTAssertEqual(mediaError.accessibilityValue, "mediaError")
    }

    func testCleanBootstrapSuppressesInactiveAudioAndInvitationHistory() {
        let presentation = BrowserView.worldwidePresentation(
            input(
                audioError: "Stale audio error",
                invitationExpiresAt: Date()
            )
        )

        XCTAssertEqual(presentation.surface, .bootstrap)
        XCTAssertNil(presentation.status)
        XCTAssertNil(presentation.invitationExpiresAt)
        XCTAssertEqual(presentation.primaryActionTitle, "Pair and Connect Securely")
        XCTAssertEqual(presentation.accessibilityValue, "bootstrap")
    }

    // MARK: - Pure presentation fixtures

    private func pairedMac(
        isPairingActive: Bool = true
    ) -> BrowserView.WorldwidePresentation.PairedMac {
        .init(
            pairID: UUID(),
            displayName: "Test Mac",
            isPairingActive: isPairingActive
        )
    }

    private func input(
        hasActiveSession: Bool = false,
        isPreparingFreshSession: Bool = false,
        pairedMac: BrowserView.WorldwidePresentation.PairedMac? = nil,
        savedPairState: SavedPairConnectionState = .idle,
        preparationError: String? = nil,
        mediaError: String? = nil,
        audioError: String? = nil,
        invitationExpiresAt: Date? = nil
    ) -> BrowserView.WorldwidePresentationInput {
        .init(
            hasActiveSession: hasActiveSession,
            activeStateText: "Connected",
            activeAudioStateText: "Playing",
            canResumeAudioPlayback: false,
            audioRecoveryButtonTitle: "Resume Audio",
            isPeerConnected: true,
            routeText: "Direct",
            isPreparingFreshSession: isPreparingFreshSession,
            preparationStateText: "Finding paired Mac",
            pairedMac: pairedMac,
            savedPairState: savedPairState,
            preparationError: preparationError,
            mediaError: mediaError,
            audioError: audioError,
            invitationExpiresAt: invitationExpiresAt
        )
    }
}

/// Simulates a close operation that ignores cancellation until the test explicitly releases it.
private actor NonCooperativePreparedSessionCloseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isSuspended = false

    func wait() async {
        isSuspended = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSuspended() async {
        while !isSuspended {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
