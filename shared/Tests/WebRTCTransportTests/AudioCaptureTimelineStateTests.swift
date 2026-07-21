import CoreMedia
@testable import WebRTCTransport
import XCTest

#if os(macOS)
/// Verifies timestamp continuity in source-frame units, including the one-frame rounding tolerance
/// and reset behavior that prevent false gap or overlap diagnostics.
final class AudioCaptureTimelineStateTests: XCTestCase {
    func testTwentyMillisecondSourceTimelineRemainsContinuous() {
        var state = AudioCaptureTimelineState()

        for index in 0..<771 {
            state.observe(
                presentationTimeStamp: CMTime(value: CMTimeValue(index * 960), timescale: 48_000),
                frameCount: 960,
                sampleRate: 48_000
            )
        }

        XCTAssertEqual(state.gapCount, 0)
        XCTAssertEqual(state.overlapCount, 0)
        XCTAssertEqual(state.maximumDiscontinuityFrames, 0)
    }

    func testSourceGapAndOverlapAreMeasuredInFrames() {
        var state = AudioCaptureTimelineState()
        state.observe(
            presentationTimeStamp: .zero,
            frameCount: 960,
            sampleRate: 48_000
        )
        state.observe(
            presentationTimeStamp: CMTime(value: 1_920, timescale: 48_000),
            frameCount: 960,
            sampleRate: 48_000
        )
        state.observe(
            presentationTimeStamp: CMTime(value: 2_400, timescale: 48_000),
            frameCount: 960,
            sampleRate: 48_000
        )

        XCTAssertEqual(state.gapCount, 1)
        XCTAssertEqual(state.overlapCount, 1)
        XCTAssertEqual(state.maximumDiscontinuityFrames, 960)
    }

    func testLifecycleResetStartsANewContinuityBaseline() {
        var state = AudioCaptureTimelineState()
        state.observe(
            presentationTimeStamp: .zero,
            frameCount: 960,
            sampleRate: 48_000
        )
        state.resetBaseline()
        state.observe(
            presentationTimeStamp: CMTime(value: 30_000, timescale: 48_000),
            frameCount: 960,
            sampleRate: 48_000
        )

        XCTAssertEqual(state.gapCount, 0)
        XCTAssertEqual(state.overlapCount, 0)
    }
}
#endif
