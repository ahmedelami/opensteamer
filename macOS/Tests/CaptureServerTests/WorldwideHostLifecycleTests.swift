import XCTest
@testable import CaptureServer

final class WorldwideHostLifecycleTests: XCTestCase {
    func testMediaDepartureReturnsPairedHostToAvailability() throws {
        var lifecycle = WorldwideHostLifecycle()
        try lifecycle.start(hasPairedViewer: true)
        try lifecycle.availabilityReady(exchangeID: "exchange-one")
        try lifecycle.mediaStarted(exchangeID: "exchange-one")

        lifecycle.availabilityPeerLeft(exchangeID: "exchange-one")
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
