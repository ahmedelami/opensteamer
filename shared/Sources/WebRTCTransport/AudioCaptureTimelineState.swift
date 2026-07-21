import CoreMedia
import Foundation

#if os(macOS)
/// Detects source-clock gaps and overlaps between consecutive captured audio buffers.
///
/// A one-frame tolerance absorbs timestamp rounding; larger discontinuities are diagnostic
/// evidence that cannot be inferred from WebRTC packet statistics alone.
struct AudioCaptureTimelineState: Sendable {
    private var lastEndPTS: CMTime?
    private(set) var gapCount = 0
    private(set) var overlapCount = 0
    private(set) var maximumDiscontinuityFrames: Int64 = 0

    /// Forgets the prior endpoint at a lifecycle or format boundary.
    mutating func resetBaseline() {
        lastEndPTS = nil
    }

    /// Advances the source timeline and records discontinuities in source-frame units.
    mutating func observe(
        presentationTimeStamp: CMTime,
        frameCount: Int,
        sampleRate: Double
    ) {
        guard presentationTimeStamp.isValid,
              presentationTimeStamp.isNumeric,
              frameCount > 0,
              sampleRate.isFinite,
              sampleRate > 0 else {
            resetBaseline()
            return
        }

        if let lastEndPTS {
            let delta = CMTimeSubtract(presentationTimeStamp, lastEndPTS)
            if delta.isNumeric {
                let discontinuityFrames = Int64((delta.seconds * sampleRate).rounded())
                if discontinuityFrames > 1 {
                    gapCount += 1
                } else if discontinuityFrames < -1 {
                    overlapCount += 1
                }
                maximumDiscontinuityFrames = max(
                    maximumDiscontinuityFrames,
                    Int64(clamping: discontinuityFrames.magnitude)
                )
            }
        }

        let duration = CMTime(
            seconds: Double(frameCount) / sampleRate,
            preferredTimescale: 1_000_000_000
        )
        lastEndPTS = CMTimeAdd(presentationTimeStamp, duration)
    }
}
#endif
