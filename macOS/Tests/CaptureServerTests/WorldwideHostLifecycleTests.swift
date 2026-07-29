import XCTest
@testable import CaptureServer

/// Exercises the pure state machine that separates bootstrap pairing, availability, and media.
///
/// Exchange identifiers are treated as generation tokens. Late departure events must not clear
/// a newer connection, and availability must not begin until the pairing record is durable. These
/// are regression-critical because process restarts and network reordering exercise both cases.
final class WorldwideHostLifecycleTests: XCTestCase {
    func testPeerStateLogBindsConnectedEventToExactHostProcess() {
        XCTAssertEqual(
            WorldwideScreenService.peerStateLogMessage(
                state: "connected",
                processIdentifier: 42_071
            ),
            "Worldwide WebRTC peer state: connected pid=42071"
        )
    }

    func testDefaultInputLogBindsHealthyBoundaryToPeerAndHostProcess() {
        XCTAssertEqual(
            WorldwideScreenService.defaultInputSelectionLogMessage(
                peerGeneration: 9,
                processIdentifier: 42_071
            ),
            "Worldwide authenticated media route selected BlackHole " +
                "default input peerGeneration=9 pid=42071"
        )
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
