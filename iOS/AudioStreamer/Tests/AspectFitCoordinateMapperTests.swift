import CoreGraphics
import XCTest
@testable import AudioStreamer

final class AspectFitCoordinateMapperTests: XCTestCase {
    func testWideVideoMapsCenterAndRejectsTopLetterbox() throws {
        let container = CGSize(width: 390, height: 700)
        let video = CGSize(width: 1_920, height: 1_080)
        let visibleRect = try XCTUnwrap(
            AspectFitCoordinateMapper.visibleVideoRect(
                containerSize: container,
                videoSize: video
            )
        )

        let center = try XCTUnwrap(
            AspectFitCoordinateMapper.normalizedPoint(
                for: CGPoint(x: visibleRect.midX, y: visibleRect.midY),
                containerSize: container,
                videoSize: video
            )
        )
        XCTAssertEqual(center.x, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(center.y, 0.5, accuracy: 0.000_001)
        XCTAssertNil(
            AspectFitCoordinateMapper.normalizedPoint(
                for: CGPoint(x: container.width / 2, y: visibleRect.minY - 1),
                containerSize: container,
                videoSize: video
            )
        )
    }

    func testPortraitVideoRejectsSideLetterboxAndPreservesEdges() throws {
        let container = CGSize(width: 700, height: 390)
        let video = CGSize(width: 1_080, height: 1_920)
        let visibleRect = try XCTUnwrap(
            AspectFitCoordinateMapper.visibleVideoRect(
                containerSize: container,
                videoSize: video
            )
        )

        XCTAssertNil(
            AspectFitCoordinateMapper.normalizedPoint(
                for: CGPoint(x: visibleRect.minX - 1, y: visibleRect.midY),
                containerSize: container,
                videoSize: video
            )
        )
        let minimum = try XCTUnwrap(
            AspectFitCoordinateMapper.normalizedPoint(
                for: CGPoint(x: visibleRect.minX, y: visibleRect.minY),
                containerSize: container,
                videoSize: video
            )
        )
        let maximum = try XCTUnwrap(
            AspectFitCoordinateMapper.normalizedPoint(
                for: CGPoint(x: visibleRect.maxX, y: visibleRect.maxY),
                containerSize: container,
                videoSize: video
            )
        )
        XCTAssertEqual(minimum, .zero)
        XCTAssertEqual(maximum.x, 1, accuracy: 0.000_001)
        XCTAssertEqual(maximum.y, 1, accuracy: 0.000_001)
    }

    func testInvalidGeometryAndNonfiniteLocationsFailClosed() {
        XCTAssertNil(
            AspectFitCoordinateMapper.visibleVideoRect(
                containerSize: .zero,
                videoSize: CGSize(width: 1_920, height: 1_080)
            )
        )
        XCTAssertNil(
            AspectFitCoordinateMapper.normalizedPoint(
                for: CGPoint(x: CGFloat.infinity, y: 20),
                containerSize: CGSize(width: 390, height: 700),
                videoSize: CGSize(width: 1_920, height: 1_080)
            )
        )
        XCTAssertNil(
            AspectFitCoordinateMapper.visibleVideoRect(
                containerSize: CGSize(width: 390, height: 700),
                videoSize: CGSize(width: CGFloat.nan, height: 1_080)
            )
        )
    }
}
