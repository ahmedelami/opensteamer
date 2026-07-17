import CoreMedia
import Foundation

#if os(macOS)
struct AudioCaptureTimelineState: Sendable {
    private var lastEndPTS: CMTime?
    private(set) var gapCount = 0
    private(set) var overlapCount = 0
    private(set) var maximumDiscontinuityFrames: Int64 = 0

    mutating func resetBaseline() {
        lastEndPTS = nil
    }

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
