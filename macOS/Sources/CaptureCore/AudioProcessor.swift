import CoreMedia
import Foundation
import WAV

/// Measures captured audio and appends it to a WAV file on one serial ownership queue.
///
/// ScreenCaptureKit is configured to invoke `consume(_:)` directly on `sampleHandlerQueue`.
/// The non-Sendable `CMSampleBuffer` is therefore extracted synchronously inside its callback
/// and is never retained by another asynchronous closure. `finish()` synchronizes with that
/// queue after source shutdown, so every accepted callback has completed before finalization.
public final class AudioProcessor: @unchecked Sendable, SampleBufferConsumer {
    private let outputURL: URL
    private let logger: Logger
    private let queue = DispatchQueue(label: "opensteamer.AudioProcessor")

    private var writer: WAVWriter?
    private var streamFormat: StreamAudioFormat?
    private var callbackStatistics = CallbackStatistics()
    private var metricSummary = MetricSummary()
    private var latestMetrics: AudioMetrics?
    private var framesWritten: Int64 = 0
    private var bytesWritten: Int64 = 0
    private var firstError: Error?
    private var sampleStorage: [Float] = []

    /// Creates a processor whose writer is initialized from the first valid buffer.
    public init(outputURL: URL, logger: Logger) {
        self.outputURL = outputURL
        self.logger = logger
    }

    /// The exact queue ScreenCaptureKit must use for this consumer's callbacks.
    var sampleHandlerQueue: DispatchQueue { queue }

    /// Processes one ScreenCaptureKit callback synchronously on the ownership queue.
    func consume(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        process(
            sampleBuffer,
            callbackTime: DispatchTime.now().uptimeNanoseconds
        )
    }

    /// Finalizes the WAV header after the source has stopped and queued callbacks have drained.
    ///
    /// The first processing failure wins and is rethrown after queue synchronization.
    public func finish() throws -> ProcessingSummary {
        dispatchPrecondition(condition: .notOnQueue(queue))
        var result: Result<ProcessingSummary, Error>!
        queue.sync {
            if let firstError {
                result = .failure(firstError)
                return
            }

            do {
                let wavSummary = try writer?.finish()
                if let wavSummary {
                    framesWritten = wavSummary.framesWritten
                    bytesWritten = wavSummary.bytesWritten
                }
                result = .success(
                    ProcessingSummary(
                        streamFormat: streamFormat,
                        callbackStatistics: callbackStatistics,
                        metricSummary: metricSummary,
                        framesWritten: framesWritten,
                        bytesWritten: bytesWritten
                    )
                )
            } catch {
                result = .failure(error)
            }
        }
        return try result.get()
    }

    /// Returns a queue-consistent progress snapshot for logging or diagnostics.
    public func latestSnapshot() -> MetricsSnapshot {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            MetricsSnapshot(
                callbackStatistics: callbackStatistics,
                latestMetrics: latestMetrics,
                framesWritten: framesWritten
            )
        }
    }

    /// Processes one buffer on `queue`; callers must not invoke it from other queues.
    private func process(_ sampleBuffer: CMSampleBuffer, callbackTime: UInt64) {
        guard firstError == nil else { return }
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else {
            logger.debug("Skipping invalid or not-ready sample buffer")
            return
        }

        do {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            callbackStatistics.recordCallback(
                uptimeNanoseconds: callbackTime,
                presentationTime: presentationTime.isValid ? presentationTime.seconds : nil
            )
            let pcm = try PCMExtractor.extract(sampleBuffer, reusing: &sampleStorage)

            if writer == nil {
                streamFormat = pcm.format
                let newWriter = WAVWriter(
                    url: outputURL,
                    sampleRate: pcm.format.sampleRate,
                    channels: pcm.channels
                )
                try newWriter.start()
                writer = newWriter
                logger.info("Audio format: \(pcm.format.sampleRate) Hz, \(pcm.channels) channels, float=\(pcm.format.isFloat), interleaved=\(pcm.format.isInterleaved)")
            }

            let metrics = AudioProcessor.computeMetrics(samples: pcm.samples, frameCount: pcm.frameCount, channels: pcm.channels)
            metricSummary.record(metrics)
            latestMetrics = metrics
            try writer?.appendInterleavedFloat(pcm.samples)
            framesWritten += Int64(pcm.frameCount)
        } catch {
            firstError = error
            logger.error("Audio processing failed: \(error.localizedDescription)")
        }
    }

    /// Calculates normalized RMS and peak levels across all interleaved samples.
    private static func computeMetrics(samples: [Float], frameCount: Int, channels: Int) -> AudioMetrics {
        guard !samples.isEmpty else {
            return AudioMetrics(rms: 0, peak: 0, frameCount: frameCount, channels: channels)
        }

        var sumSquares: Float = 0
        var peak: Float = 0

        for sample in samples {
            let absolute = abs(sample)
            peak = max(peak, absolute)
            sumSquares += sample * sample
        }

        let rms = sqrt(sumSquares / Float(samples.count))
        return AudioMetrics(rms: rms, peak: peak, frameCount: frameCount, channels: channels)
    }
}

/// Immutable progress view of a running `AudioProcessor`.
public struct MetricsSnapshot: Sendable {
    public let callbackStatistics: CallbackStatistics
    public let latestMetrics: AudioMetrics?
    public let framesWritten: Int64
}

/// Final state produced after an `AudioProcessor` has drained and closed its writer.
public struct ProcessingSummary: Sendable {
    public let streamFormat: StreamAudioFormat?
    public let callbackStatistics: CallbackStatistics
    public let metricSummary: MetricSummary
    public let framesWritten: Int64
    public let bytesWritten: Int64
}
