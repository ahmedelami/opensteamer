import Foundation
import XCTest
@testable import WAV

final class WAVWriterTests: XCTestCase {
    func testWAVWriterProducesPlayableHeaderAndDataSize() throws {
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("wav-writer-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        let writer = WAVWriter(url: url, sampleRate: 48_000, channels: 2)
        try writer.start()
        try writer.appendInterleavedFloat([0, 0.5, -0.5, 1.0])
        let summary = try writer.finish()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(summary.framesWritten, 2)
        XCTAssertEqual(summary.bytesWritten, 8)
    }
}
