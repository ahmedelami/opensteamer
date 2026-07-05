import XCTest
@testable import CaptureCore

final class BlackHoleRouteHealthTests: XCTestCase {
    func testRouteHealthRequiresEveryEndpointToMatchExpectedDevice() {
        let expected = "BlackHole2ch_UID"
        let matching = BlackHoleRouteEndpointHealth(
            label: "Default Output",
            name: "BlackHole 2ch",
            uid: expected,
            matchesExpected: true
        )
        let mismatched = BlackHoleRouteEndpointHealth(
            label: "Default Input",
            name: "Mac mini Speakers",
            uid: "BuiltInSpeakerDevice",
            matchesExpected: false
        )

        let healthy = BlackHoleRouteHealth(
            expectedName: "BlackHole 2ch",
            expectedUID: expected,
            defaultOutput: matching,
            defaultSystemOutput: matching,
            defaultInput: matching,
            captureDevice: matching
        )
        XCTAssertTrue(healthy.isHealthy)

        let unhealthy = BlackHoleRouteHealth(
            expectedName: "BlackHole 2ch",
            expectedUID: expected,
            defaultOutput: matching,
            defaultSystemOutput: matching,
            defaultInput: mismatched,
            captureDevice: matching
        )
        XCTAssertFalse(unhealthy.isHealthy)
        XCTAssertTrue(unhealthy.render().contains("UNHEALTHY"))
    }
}
