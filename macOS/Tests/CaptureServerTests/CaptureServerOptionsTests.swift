import XCTest
@testable import CaptureServer

/// Documents the command-line capability boundary for the unattended Mac host.
///
/// Pairing reset and remote input are worldwide-only operations. Remote control must remain an
/// explicit opt-in so adding worldwide connectivity cannot silently grant input injection.
final class CaptureServerOptionsTests: XCTestCase {
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
                "--worldwide requires --rendezvous-url or AUDIOSTREAMER_RENDEZVOUS_URL"
            )
        }
    }

    func testWorldwideModeAcceptsRendezvousConfigurationFromEnvironment() throws {
        let options = try CaptureServerOptions.parse(
            ["CaptureServer", "--worldwide"],
            environment: [
                "AUDIOSTREAMER_RENDEZVOUS_URL": "wss://rendezvous.example.invalid",
            ]
        )

        XCTAssertEqual(
            options.rendezvousURL?.absoluteString,
            "wss://rendezvous.example.invalid"
        )
        XCTAssertFalse(options.lanEnabled)
    }
}
