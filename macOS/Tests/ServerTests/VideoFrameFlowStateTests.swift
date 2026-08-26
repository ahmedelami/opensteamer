import Streaming
import XCTest
@testable import Server

final class VideoFrameFlowStateTests: XCTestCase {
    func testFormatDiscontinuityRetiresOutstandingFrameAndForcesFreshConfiguration() {
        let oldConfiguration = ScreenVideoConfiguration(
            width: 1_080,
            height: 1_920,
            nalUnitHeaderLength: 4,
            framesPerSecondMilli: 30_000,
            bitrate: 8_000_000,
            parameterSets: []
        )
        var state = VideoFrameFlowState()
        state.beginNewGeneration()
        let oldGeneration = state.generation
        state.nextSequence = 9
        state.activeReservationID = 41
        state.awaitingAcknowledgement = 8
        state.forceNextKeyFrame = false
        state.lastSentConfiguration = oldConfiguration

        state.beginNewGeneration()

        XCTAssertNotEqual(state.generation, oldGeneration)
        XCTAssertEqual(state.nextSequence, 0)
        XCTAssertNil(state.activeReservationID)
        XCTAssertNil(state.awaitingAcknowledgement)
        XCTAssertTrue(state.forceNextKeyFrame)
        XCTAssertNil(state.lastSentConfiguration)
        XCTAssertFalse(
            state.acknowledgementMatches(
                generation: oldGeneration,
                sequence: 8
            ),
            "A delayed acknowledgement from the retired canvas must be ignored"
        )
    }

    func testGenerationWrapNeverPublishesReservedZeroGeneration() {
        var state = VideoFrameFlowState()
        state.generation = .max

        state.beginNewGeneration()

        XCTAssertEqual(state.generation, 1)
    }
}
