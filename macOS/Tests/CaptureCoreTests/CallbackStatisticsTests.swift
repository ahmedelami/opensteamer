import Foundation
import XCTest
@testable import CaptureCore

/// Covers the small, stateful summaries emitted by the real-time audio callback.
///
/// The timestamps are synthetic monotonic nanoseconds, so these tests validate interval math
/// deterministically without depending on scheduler timing. Metric fixtures cover ordering in
/// both directions to ensure the summaries retain true extrema rather than the latest sample.
final class CallbackStatisticsTests: XCTestCase {
    func testCallbackStatisticsTracksIntervals() {
        var stats = CallbackStatistics()

        stats.recordCallback(uptimeNanoseconds: 1_000_000_000)
        stats.recordCallback(uptimeNanoseconds: 1_020_000_000)
        stats.recordCallback(uptimeNanoseconds: 1_040_000_000)

        XCTAssertEqual(stats.count, 3)
        XCTAssertLessThan(abs(stats.averageInterval - 0.02), 0.0001)
        XCTAssertLessThan(abs((stats.minimumInterval ?? 0) - 0.02), 0.0001)
        XCTAssertLessThan(abs((stats.maximumInterval ?? 0) - 0.02), 0.0001)
    }

    func testMetricSummaryTracksRanges() {
        var summary = MetricSummary()

        summary.record(AudioMetrics(rms: 0.2, peak: 0.4, frameCount: 10, channels: 2))
        summary.record(AudioMetrics(rms: 0.1, peak: 0.7, frameCount: 10, channels: 2))

        XCTAssertEqual(summary.minimumRMS, 0.1)
        XCTAssertEqual(summary.maximumRMS, 0.2)
        XCTAssertEqual(summary.minimumPeak, 0.4)
        XCTAssertEqual(summary.maximumPeak, 0.7)
    }
}
