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
}
