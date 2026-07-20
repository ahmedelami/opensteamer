import XCTest

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
