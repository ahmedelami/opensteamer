import CoreMedia
import Foundation
import WAV

public final class AudioProcessor: @unchecked Sendable, SampleBufferConsumer {
    private let outputURL: URL
    private let logger: Logger
    private let queue = DispatchQueue(label: "MacCaptureVerifier.AudioProcessor")
    private let completion = DispatchGroup()

    private var writer: WAVWriter?
    private var streamFormat: StreamAudioFormat?
    private var callbackStatistics = CallbackStatistics()
    private var metricSummary = MetricSummary()
    private var latestMetrics: AudioMetrics?
    private var framesWritten: Int64 = 0
    private var bytesWritten: Int64 = 0
    private var firstError: Error?
    private var sampleStorage: [Float] = []

    public init(outputURL: URL, logger: Logger) {
        self.outputURL = outputURL
        self.logger = logger
    }

    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        completion.enter()
        let callbackTime = DispatchTime.now().uptimeNanoseconds
        queue.async { [weak self] in
            defer { self?.completion.leave() }
            self?.process(sampleBuffer, callbackTime: callbackTime)
        }
    }

    public func finish() throws -> ProcessingSummary {
        completion.wait()
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

    public func latestSnapshot() -> MetricsSnapshot {
        queue.sync {
            MetricsSnapshot(
                callbackStatistics: callbackStatistics,
                latestMetrics: latestMetrics,
                framesWritten: framesWritten
            )
        }
    }

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

public struct MetricsSnapshot: Sendable {
    public let callbackStatistics: CallbackStatistics
    public let latestMetrics: AudioMetrics?
    public let framesWritten: Int64
}

public struct ProcessingSummary: Sendable {
    public let streamFormat: StreamAudioFormat?
    public let callbackStatistics: CallbackStatistics
    public let metricSummary: MetricSummary
    public let framesWritten: Int64
    public let bytesWritten: Int64
}
