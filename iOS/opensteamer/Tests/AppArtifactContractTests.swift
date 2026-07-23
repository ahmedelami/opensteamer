import XCTest

/// Guards the release artifact contract that cannot be inferred from runtime unit behavior.
/// These checks fail when required app metadata is missing from the built product, preventing a
/// locally passing target from shipping without its platform configuration.
final class AppArtifactContractTests: XCTestCase {
    /// Reads the hosted app bundle produced by Xcode, rather than source configuration, so the
    /// test catches drift between XcodeGen input, the generated project, and the shipped artifact.
    func testBuiltApplicationKeepsRenamedVisibleIdentityAndUpgradeBundle() throws {
        let info = Bundle.main.infoDictionary

        XCTAssertEqual(info?["CFBundleDisplayName"] as? String, "opensteamer")
        XCTAssertEqual(info?["CFBundleName"] as? String, "opensteamer")
        XCTAssertEqual(info?["CFBundleExecutable"] as? String, "opensteamer")
        XCTAssertEqual(
            Bundle.main.bundleIdentifier,
            "org.example.AudioStreamer.dev",
            "The Debug bundle identifier is intentionally preserved for upgrade continuity."
        )
        XCTAssertEqual(
            info?["NSLocalNetworkUsageDescription"] as? String,
            "opensteamer finds the Mac capture server on your local Wi-Fi network."
        )
        XCTAssertEqual(
            info?["NSCameraUsageDescription"] as? String,
            "opensteamer may request camera access through its real-time communication framework only when you explicitly start a camera-capable sharing feature. Ordinary audio and screen streaming do not access the camera."
        )
    }

    func testBuiltApplicationDeclaresOnlyBackgroundAudio() throws {
        let modes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        )

        XCTAssertEqual(
            modes,
            ["audio"],
            "The built app must retain Background Audio without adding call-oriented modes."
        )
    }
}
