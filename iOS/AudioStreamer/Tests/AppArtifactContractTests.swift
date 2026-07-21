import XCTest

/// Guards the release artifact contract that cannot be inferred from runtime unit behavior.
/// These checks fail when required app metadata is missing from the built product, preventing a
/// locally passing target from shipping without its platform configuration.
final class AppArtifactContractTests: XCTestCase {
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
