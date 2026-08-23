import XCTest

@testable import CaptureServer

final class CaptureDisplaySelectionTests: XCTestCase {
    func testExplicitDisplayRemainsBothSourcesWithoutVirtualDisplay() {
        let selection = CaptureDisplaySelection(
            explicitDisplayID: 7,
            virtualDisplayID: nil
        )

        XCTAssertEqual(selection.screenDisplayID, 7)
        XCTAssertEqual(selection.systemAudioDisplayID, 7)
    }

    func testVirtualDisplayChangesOnlyScreenSource() {
        let selection = CaptureDisplaySelection(
            explicitDisplayID: 7,
            virtualDisplayID: 42
        )

        XCTAssertEqual(selection.screenDisplayID, 42)
        XCTAssertEqual(selection.systemAudioDisplayID, 7)
    }

    func testHeadlessDefaultAudioSelectionStaysAutomatic() {
        let selection = CaptureDisplaySelection(
            explicitDisplayID: nil,
            virtualDisplayID: 42
        )

        XCTAssertEqual(selection.screenDisplayID, 42)
        XCTAssertNil(selection.systemAudioDisplayID)
    }
}
