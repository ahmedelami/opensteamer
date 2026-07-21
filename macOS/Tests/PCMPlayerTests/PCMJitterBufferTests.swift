import Foundation
import XCTest
@testable import ClientCore

/// Defines the bounded-latency behavior of the PCM playback jitter buffer.
///
/// Overflow intentionally discards the oldest complete frames so playback converges toward live
/// audio instead of accumulating delay. Duration is measured in frames, independent of channels.
final class PCMJitterBufferTests: XCTestCase {
    func testJitterBufferDropsOldestFramesWhenCapacityIsExceeded() {
        let buffer = PCMJitterBuffer(channels: 2, capacityFrames: 2)
        let pcm = pcm16Data(samples: [1_000, 1_000, 2_000, 2_000, 3_000, 3_000])

        let appendedFrames = buffer.appendPCM16LE(pcm)

        XCTAssertEqual(appendedFrames, 3)
        XCTAssertEqual(buffer.bufferedFrames, 2)
        XCTAssertEqual(buffer.droppedFrames, 1)
        XCTAssertEqual(buffer.underrunFrames, 0)
    }

    func testJitterBufferReportsBufferedDuration() {
        let buffer = PCMJitterBuffer(channels: 2, sampleRate: 48_000, capacityFrames: 4_800)
        let pcm = pcm16Data(samples: Array(repeating: 1_000, count: 960))

        XCTAssertEqual(buffer.appendPCM16LE(pcm), 480)
        XCTAssertEqual(buffer.bufferedDuration, 0.01, accuracy: 0.0001)
    }
}

private func pcm16Data(samples: [Int16]) -> Data {
    // The network/player contract is interleaved signed PCM16 in little-endian byte order.
    var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
    for sample in samples {
        var little = sample.littleEndian
        withUnsafeBytes(of: &little) {
            data.append(contentsOf: $0)
        }
    }
    return data
}
