import CaptureCore
import XCTest
@testable import CaptureServer

/// Documents the command-line capability boundary for the unattended Mac host.
///
/// Pairing reset and remote input are worldwide-only operations. Remote control must remain an
/// explicit opt-in so adding worldwide connectivity cannot silently grant input injection.
final class CaptureServerOptionsTests: XCTestCase {
    func testDefaultTotalRTPBitrateCeilingIsFiftyMegabits() throws {
        let options = try CaptureServerOptions.parse(["CaptureServer"])

        XCTAssertEqual(options.screenBitrate, 12_000_000)
        XCTAssertEqual(options.worldwideTotalRTPBitrate, 50_000_000)
    }

    func testTotalRTPBitrateCeilingRejectsValuesAboveFiftyMegabits() {
        XCTAssertThrowsError(
            try CaptureServerOptions.parse([
                "CaptureServer",
                "--worldwide-bitrate",
                "50000001",
            ])
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "--worldwide-bitrate must be from 250000 through 50000000"
            )
        }
    }

    func testVirtualPhoneDisplayIsDisabledByDefault() throws {
        let options = try CaptureServerOptions.parse(["CaptureServer"])

        XCTAssertFalse(options.virtualPhoneDisplayEnabled)
        XCTAssertFalse(options.requiresExclusiveHostProcessLock)
    }

    func testVirtualPhoneDisplayRequiresExplicitFlag() throws {
        let options = try CaptureServerOptions.parse([
            "CaptureServer",
            "--virtual-phone-display",
        ])

        XCTAssertTrue(options.virtualPhoneDisplayEnabled)
        XCTAssertNil(options.displayID)
        XCTAssertTrue(options.requiresExclusiveHostProcessLock)
    }

    func testVirtualPhoneDisplayRejectsDisabledScreenService() {
        XCTAssertThrowsError(
            try CaptureServerOptions.parse([
                "CaptureServer",
                "--virtual-phone-display",
                "--no-screen",
            ])
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "--virtual-phone-display cannot be combined with --no-screen"
            )
        }
    }

    func testVirtualPhoneDisplayRejectsRuntimeDisplayIDConflict() {
        XCTAssertThrowsError(
            try CaptureServerOptions.parse([
                "CaptureServer",
                "--virtual-phone-display",
                "--display-id",
                "42",
            ])
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "--virtual-phone-display cannot be combined with --display-id"
            )
        }
    }

    func testResetPairingRequiresWorldwideMode() {
        XCTAssertThrowsError(
            try CaptureServerOptions.parse(["CaptureServer", "--reset-worldwide-pairing"])
        )
    }

    func testResetPairingPreservesWorldwideSecurityDefaults() throws {
        let options = try CaptureServerOptions.parse([
            "CaptureServer",
            "--worldwide",
            "--rendezvous-url",
            "wss://rendezvous.example.invalid",
            "--reset-worldwide-pairing",
        ], environment: [:])

        XCTAssertTrue(options.worldwideEnabled)
        XCTAssertTrue(options.resetWorldwidePairing)
        XCTAssertFalse(options.lanEnabled)
        XCTAssertNil(options.duration)
    }

    func testRemoteControlIsOffByDefaultInWorldwideMode() throws {
        let options = try CaptureServerOptions.parse([
            "CaptureServer",
            "--worldwide",
            "--rendezvous-url",
            "wss://rendezvous.example.invalid",
        ], environment: [:])

        XCTAssertTrue(options.worldwideEnabled)
        XCTAssertFalse(options.allowRemoteControl)
    }

    func testRemoteControlRequiresWorldwideMode() {
        XCTAssertThrowsError(
            try CaptureServerOptions.parse(["CaptureServer", "--allow-remote-control"])
        )
    }

    func testRemoteControlIsEnabledOnlyByExplicitWorldwideOptIn() throws {
        let options = try CaptureServerOptions.parse([
            "CaptureServer",
            "--worldwide",
            "--rendezvous-url",
            "wss://rendezvous.example.invalid",
            "--allow-remote-control",
        ], environment: [:])

        XCTAssertTrue(options.worldwideEnabled)
        XCTAssertTrue(options.allowRemoteControl)
        XCTAssertFalse(options.lanEnabled)
    }

    func testWorldwideModeRequiresExplicitRendezvousConfiguration() {
        XCTAssertThrowsError(
            try CaptureServerOptions.parse(
                ["CaptureServer", "--worldwide"],
                environment: [:]
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "--worldwide requires --rendezvous-url or OPENSTEAMER_RENDEZVOUS_URL"
            )
        }
    }

    func testWorldwideModeAcceptsRendezvousConfigurationFromEnvironment() throws {
        let options = try CaptureServerOptions.parse(
            ["CaptureServer", "--worldwide"],
            environment: [
                "OPENSTEAMER_RENDEZVOUS_URL": "wss://rendezvous.example.invalid",
            ]
        )

        XCTAssertEqual(
            options.rendezvousURL?.absoluteString,
            "wss://rendezvous.example.invalid"
        )
        XCTAssertFalse(options.lanEnabled)
    }

    func testLANCoexistenceSuppressesIPhoneMicrophoneForBothCaptureModesAndArgumentOrders()
        throws {
        let cases: [([String], AudioCaptureMode)] = [
            (
                [
                    "CaptureServer",
                    "--worldwide",
                    "--rendezvous-url",
                    "wss://rendezvous.example.invalid",
                    "--with-lan",
                ],
                .blackHoleInput
            ),
            (
                [
                    "CaptureServer",
                    "--with-lan",
                    "--capture-mode",
                    "screen",
                    "--worldwide",
                    "--rendezvous-url",
                    "wss://rendezvous.example.invalid",
                ],
                .screen
            ),
        ]

        for (arguments, expectedCaptureMode) in cases {
            let options = try CaptureServerOptions.parse(
                arguments,
                environment: [:]
            )
            XCTAssertTrue(options.worldwideEnabled)
            XCTAssertTrue(options.lanEnabled)
            XCTAssertTrue(options.screenEnabled)
            XCTAssertEqual(
                options.captureMode,
                expectedCaptureMode
            )
            XCTAssertEqual(
                options.iPhoneMicrophoneForwardingPolicy,
                .suppressedForLANCoexistence
            )
        }
    }

    func testWorldwideOnlyKeepsIPhoneMicrophoneForwardingEnabled()
        throws {
        let options = try CaptureServerOptions.parse(
            [
                "CaptureServer",
                "--worldwide",
                "--rendezvous-url",
                "wss://rendezvous.example.invalid",
            ],
            environment: [:]
        )

        XCTAssertFalse(options.lanEnabled)
        XCTAssertEqual(
            options.iPhoneMicrophoneForwardingPolicy,
            .enabled
        )
    }
}
