import CoreAudio
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

    func testStrictInventoryPropagatesUIDPropertyFailureInsteadOfAbsence()
        throws {
        let status = OSStatus(-66_401)
        let inventory = BlackHoleStrictInventoryFake(
            deviceIDs: [7],
            names: [7: "BlackHole 2ch"],
            uids: [7: "BlackHole2ch_UID"],
            uidFailures: [7: status]
        )

        XCTAssertThrowsError(
            try BlackHoleRouteManager
                .blackHole2ChannelDeviceUID(
                    inventory: inventory
                )
        ) { error in
            guard case let CaptureError
                    .audioDeviceConfiguration(
                        operation,
                        observedStatus
                    ) = error else {
                return XCTFail(
                    "Expected strict UID property failure, got \(error)"
                )
            }
            XCTAssertEqual(observedStatus, status)
            XCTAssertEqual(
                operation,
                "injected device UID read",
                "The strict resolver must propagate the injected property error unchanged."
            )
        }
    }

    func testStrictInventoryAcceptsExactCanonicalUIDWithoutUnusedNameRead()
        throws {
        let status = OSStatus(-66_402)
        let inventory = BlackHoleStrictInventoryFake(
            deviceIDs: [8],
            names: [8: "BlackHole 2ch"],
            uids: [8: "BlackHole2ch_UID"],
            nameFailures: [8: status]
        )

        XCTAssertEqual(
            try BlackHoleRouteManager
                .blackHole2ChannelDeviceUID(
                    inventory: inventory
                ),
            "BlackHole2ch_UID"
        )
    }

    func testStrictInventoryStopsAtCanonicalUIDBeforeUnrelatedFailure()
        throws {
        let inventory = BlackHoleStrictInventoryFake(
            deviceIDs: [5, 6],
            names: [
                5: "Does Not Matter",
                6: "Unreadable Interface",
            ],
            uids: [
                5: "BlackHole2ch_UID",
            ],
            uidFailures: [6: OSStatus(-66_406)]
        )

        XCTAssertEqual(
            try BlackHoleRouteManager
                .blackHole2ChannelDeviceUID(
                    inventory: inventory
                ),
            "BlackHole2ch_UID"
        )
    }

    func testStrictInventoryContinuesPastUnrelatedFailureToLaterCanonicalUID()
        throws {
        let status = OSStatus(-66_403)
        let inventory = BlackHoleStrictInventoryFake(
            deviceIDs: [7, 8],
            names: [
                7: "Unreadable Interface",
                8: "Does Not Matter",
            ],
            uids: [
                8: "BlackHole2ch_UID",
            ],
            nameFailures: [8: OSStatus(-66_404)],
            uidFailures: [7: status]
        )

        XCTAssertEqual(
            try BlackHoleRouteManager
                .blackHole2ChannelDeviceUID(
                    inventory: inventory
                ),
            "BlackHole2ch_UID"
        )
    }

    func testStrictInventoryUsesNameFallbackOnlyWhenUIDIsMissingOrEmpty()
        throws {
        let nilUIDInventory = BlackHoleStrictInventoryFake(
            deviceIDs: [21],
            names: [21: "BlackHole 2ch"],
            uids: [:]
        )
        XCTAssertEqual(
            try BlackHoleRouteManager
                .blackHole2ChannelDeviceUID(
                    inventory: nilUIDInventory
                ),
            "BlackHole2ch_UID"
        )

        let emptyUIDInventory = BlackHoleStrictInventoryFake(
            deviceIDs: [22],
            names: [22: "BlackHole 2ch"],
            uids: [22: ""]
        )
        XCTAssertEqual(
            try BlackHoleRouteManager
                .blackHole2ChannelDeviceUID(
                    inventory: emptyUIDInventory
                ),
            "BlackHole2ch_UID"
        )
    }

    func testStrictInventoryNoTargetPlusUnreadableDeviceIsTransient()
        throws {
        let status = OSStatus(-66_405)
        let inventory = BlackHoleStrictInventoryFake(
            deviceIDs: [23, 24],
            names: [24: "Built-in Microphone"],
            uids: [24: "BuiltInMic_UID"],
            uidFailures: [23: status]
        )

        XCTAssertThrowsError(
            try BlackHoleRouteManager
                .blackHole2ChannelDeviceUID(
                    inventory: inventory
                )
        ) { error in
            guard case let CaptureError
                    .audioDeviceConfiguration(
                        operation,
                        observedStatus
                    ) = error else {
                return XCTFail(
                    "Expected transient strict inventory read failure, got \(error)"
                )
            }
            XCTAssertEqual(observedStatus, status)
            XCTAssertEqual(operation, "injected device UID read")
        }
    }

    func testOnlySuccessfulStrictInventoryWithoutCanonicalEndpointIsFactualAbsence()
        throws {
        let inventory = BlackHoleStrictInventoryFake(
            deviceIDs: [9],
            names: [9: "Built-in Microphone"],
            uids: [9: "BuiltInMic_UID"]
        )

        XCTAssertThrowsError(
            try BlackHoleRouteManager
                .blackHole2ChannelDeviceUID(
                    inventory: inventory
                )
        ) { error in
            guard case CaptureError
                    .audioDeviceNotFound = error else {
                return XCTFail(
                    "Expected factual absence, got \(error)"
                )
            }
        }
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

private struct BlackHoleStrictInventoryFake:
    BlackHoleRouteInventoryReading,
    Sendable
{
    let deviceIDs: [AudioDeviceID]
    let names: [AudioDeviceID: String]
    let uids: [AudioDeviceID: String]
    let nameFailures: [AudioDeviceID: OSStatus]
    let uidFailures: [AudioDeviceID: OSStatus]

    init(
        deviceIDs: [AudioDeviceID],
        names: [AudioDeviceID: String],
        uids: [AudioDeviceID: String],
        nameFailures:
            [AudioDeviceID: OSStatus] = [:],
        uidFailures:
            [AudioDeviceID: OSStatus] = [:]
    ) {
        self.deviceIDs = deviceIDs
        self.names = names
        self.uids = uids
        self.nameFailures = nameFailures
        self.uidFailures = uidFailures
    }

    func allDeviceIDs() throws
        -> [AudioDeviceID] {
        deviceIDs
    }

    func deviceName(
        _ deviceID: AudioDeviceID
    ) throws -> String {
        if let status = nameFailures[deviceID] {
            throw CaptureError
                .audioDeviceConfiguration(
                    "injected device name read",
                    status
                )
        }
        return names[deviceID] ?? ""
    }

    func deviceUID(
        _ deviceID: AudioDeviceID
    ) throws -> String? {
        if let status = uidFailures[deviceID] {
            throw CaptureError
                .audioDeviceConfiguration(
                    "injected device UID read",
                    status
                )
        }
        return uids[deviceID]
    }
}
