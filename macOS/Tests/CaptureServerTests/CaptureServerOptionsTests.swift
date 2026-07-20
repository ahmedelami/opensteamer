import XCTest
@testable import CaptureServer

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
            "--reset-worldwide-pairing",
        ])

        XCTAssertTrue(options.worldwideEnabled)
        XCTAssertTrue(options.resetWorldwidePairing)
        XCTAssertFalse(options.lanEnabled)
        XCTAssertNil(options.duration)
    }

    func testRemoteControlIsOffByDefaultInWorldwideMode() throws {
        let options = try CaptureServerOptions.parse(["CaptureServer", "--worldwide"])

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
            "--allow-remote-control",
        ])

        XCTAssertTrue(options.worldwideEnabled)
        XCTAssertTrue(options.allowRemoteControl)
        XCTAssertFalse(options.lanEnabled)
    }
}
