import XCTest
@testable import CaptureCore

/// Verifies the aggregate route-health contract used before audio capture begins.
///
/// A route is healthy only when every participating Core Audio endpoint resolves to the
/// configured BlackHole device. This protects against accepting a partially configured route
/// that would either capture silence or send system audio to an unintended endpoint.
final class BlackHoleRouteHealthTests: XCTestCase {
    func testExactTwoChannelResolverUsesUIDAuthorityAndExactNameFallback() throws {
        let exactUIDWithArbitraryName = AudioRoute(
            deviceID: 1,
            name: "Arbitrary Device Label",
            uid: "BlackHole2ch_UID"
        )
        XCTAssertEqual(
            try BlackHoleRouteManager.blackHole2ChannelDeviceUID(
                in: [exactUIDWithArbitraryName]
            ),
            "BlackHole2ch_UID"
        )
        XCTAssertEqual(
            try BlackHoleRouteManager.resolveBlackHole2ChannelRoute(
                in: [exactUIDWithArbitraryName]
            ).deviceID,
            1
        )

        let exactNameWithoutUID = AudioRoute(
            deviceID: 2,
            name: "BlackHole 2ch",
            uid: nil
        )
        XCTAssertEqual(
            try BlackHoleRouteManager.blackHole2ChannelDeviceUID(
                in: [exactNameWithoutUID]
            ),
            "BlackHole2ch_UID"
        )

        let exactNameWithEmptyUID = AudioRoute(
            deviceID: 3,
            name: "BlackHole 2ch",
            uid: ""
        )
        XCTAssertEqual(
            try BlackHoleRouteManager.resolveBlackHole2ChannelRoute(
                in: [exactNameWithEmptyUID]
            ).deviceID,
            3
        )

        let rejectedRoutes = [
            AudioRoute(
                deviceID: 10,
                name: "BlackHole 2ch",
                uid: "Conflicting_UID"
            ),
            AudioRoute(
                deviceID: 11,
                name: "BlackHole 2ch",
                uid: " "
            ),
            AudioRoute(
                deviceID: 12,
                name: "BlackHole",
                uid: nil
            ),
            AudioRoute(
                deviceID: 13,
                name: "Prefix BlackHole 2ch",
                uid: nil
            ),
            AudioRoute(
                deviceID: 14,
                name: "BlackHole 2ch Suffix",
                uid: nil
            ),
            AudioRoute(
                deviceID: 15,
                name: "Aggregate BlackHole 2ch",
                uid: nil
            ),
            AudioRoute(
                deviceID: 16,
                name: "BlackHole 16ch",
                uid: "BlackHole16ch_UID"
            ),
            AudioRoute(
                deviceID: 17,
                name: "BlackHole 64ch",
                uid: "BlackHole64ch_UID"
            ),
            AudioRoute(
                deviceID: 18,
                name: "blackhole2ch",
                uid: nil
            ),
            AudioRoute(
                deviceID: 19,
                name: "BlackHole 2ch Aggregate",
                uid: "AggregateDevice_UID"
            ),
        ]

        for route in rejectedRoutes {
            XCTAssertThrowsError(
                try BlackHoleRouteManager.resolveBlackHole2ChannelRoute(
                    in: [route]
                ),
                "Unexpectedly accepted \(route.name) / \(route.uid ?? "nil")"
            )
        }
    }

    func testOrderedLookalikesSelectOnlyValidExactEndpoint() throws {
        let routes = [
            AudioRoute(
                deviceID: 41,
                name: "BlackHole 16ch",
                uid: "BlackHole16ch_UID"
            ),
            AudioRoute(
                deviceID: 42,
                name: "BlackHole 64ch",
                uid: "BlackHole64ch_UID"
            ),
            AudioRoute(
                deviceID: 51,
                name: "BlackHole 2ch",
                uid: "BlackHole2ch_UID"
            ),
        ]

        let selected = try BlackHoleRouteManager.resolveBlackHole2ChannelRoute(
            in: routes
        )
        XCTAssertEqual(selected.deviceID, 51)
        XCTAssertEqual(selected.name, "BlackHole 2ch")
        XCTAssertEqual(selected.uid, "BlackHole2ch_UID")
    }

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
