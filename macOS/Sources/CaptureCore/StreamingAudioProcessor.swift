import CoreMedia
import Foundation
import Streaming

final class StreamingAudioProcessor: @unchecked Sendable, SampleBufferConsumer {
    private let sink: PCMFrameSink
    private let logger: Logger
    private let queue = DispatchQueue(label: "MacCaptureVerifier.StreamingAudioProcessor")
    private let completion = DispatchGroup()

    private var sampleStorage: [Float] = []
    private var converter = PCM16Converter()
    private var streamFormat: StreamAudioFormat?
    private var headerSent = false
    private var sequence: UInt32 = 0
    private var callbackStatistics = CallbackStatistics()
    private var metricSummary = MetricSummary()
    private var latestMetrics: AudioMetrics?
    private var framesStreamed: Int64 = 0
    private var bytesStreamed: Int64 = 0
    private var firstError: Error?
    private var diagnosticBuffersLogged = 0

    init(sink: PCMFrameSink, logger: Logger) {
        self.sink = sink
        self.logger = logger
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        completion.enter()
        let callbackTime = DispatchTime.now().uptimeNanoseconds
        queue.async { [weak self] in
            defer { self?.completion.leave() }
            self?.process(sampleBuffer, callbackTime: callbackTime)
        }
    }

    func enqueue(_ pcm: PCMBuffer, presentationTimestampNanoseconds: UInt64?) {
        completion.enter()
        let callbackTime = DispatchTime.now().uptimeNanoseconds
        queue.async { [weak self] in
            defer { self?.completion.leave() }
            self?.process(pcm, callbackTime: callbackTime, presentationTimestampNanoseconds: presentationTimestampNanoseconds)
        }
    }

    func finish() throws -> StreamingProcessingSummary {
        completion.wait()
        var result: Result<StreamingProcessingSummary, Error>!
        queue.sync {
            if let firstError {
                result = .failure(firstError)
                return
            }

            result = .success(
                StreamingProcessingSummary(
                    streamFormat: streamFormat,
                    callbackStatistics: callbackStatistics,
                    metricSummary: metricSummary,
                    framesStreamed: framesStreamed,
                    bytesStreamed: bytesStreamed,
                    packetsStreamed: Int64(sequence)
                )
            )
        }
        return try result.get()
    }

    func latestSnapshot() -> StreamingMetricsSnapshot {
        queue.sync {
            StreamingMetricsSnapshot(
                callbackStatistics: callbackStatistics,
                latestMetrics: latestMetrics,
                framesStreamed: framesStreamed,
                bytesStreamed: bytesStreamed,
                packetsStreamed: Int64(sequence)
            )
        }
    }

    private func process(_ sampleBuffer: CMSampleBuffer, callbackTime: UInt64) {
        guard firstError == nil else { return }
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        do {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timestampNanos = presentationTime.nonNegativeNanoseconds ?? 0
            let pcm = try PCMExtractor.extract(sampleBuffer, reusing: &sampleStorage)
            process(pcm, callbackTime: callbackTime, presentationTimestampNanoseconds: timestampNanos)
        } catch {
            firstError = error
            logger.error("Streaming processing failed: \(error.localizedDescription)")
        }
    }

    private func process(_ pcm: PCMBuffer, callbackTime: UInt64, presentationTimestampNanoseconds: UInt64?) {
        callbackStatistics.recordCallback(
            uptimeNanoseconds: callbackTime,
            presentationTime: presentationTimestampNanoseconds.map { Double($0) / 1_000_000_000 }
        )

        if streamFormat == nil {
            streamFormat = pcm.format
            let header = PCMStreamHeader(
                sampleRate: UInt32(pcm.format.sampleRate.rounded()),
                channels: UInt16(pcm.channels)
            )
            sink.configureStream(header)
            headerSent = true
            logger.info(
                "Streaming format: \(pcm.format.sampleRate) Hz, \(pcm.channels) channels, " +
                "float=\(pcm.format.isFloat), interleaved=\(pcm.format.isInterleaved), " +
                "bits=\(pcm.format.bitsPerChannel)"
            )
        }

        let metrics = computeMetrics(samples: pcm.samples, frameCount: pcm.frameCount, channels: pcm.channels)
        metricSummary.record(metrics)
        latestMetrics = metrics
        logDiagnosticsIfNeeded(pcm: pcm, metrics: metrics)

        let pcmBytes = converter.convertInterleavedFloat(pcm.samples)
        let metadata = PCMPacketMetadata(
            sequence: sequence,
            presentationTimestampNanoseconds: presentationTimestampNanoseconds ?? 0,
            frameCount: UInt32(pcm.frameCount)
        )
        sink.sendPCMFrame(metadata: metadata, pcmBytes: pcmBytes)

        sequence &+= 1
        framesStreamed += Int64(pcm.frameCount)
        bytesStreamed += Int64(pcmBytes.count)
    }

    private func computeMetrics(samples: [Float], frameCount: Int, channels: Int) -> AudioMetrics {
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

        return AudioMetrics(rms: sqrt(sumSquares / Float(samples.count)), peak: peak, frameCount: frameCount, channels: channels)
    }

    private func logDiagnosticsIfNeeded(pcm: PCMBuffer, metrics: AudioMetrics) {
        guard diagnosticBuffersLogged < 5 else { return }
        diagnosticBuffersLogged += 1

        let preview = pcm.samples.prefix(16)
            .map { String(format: "%.5f", $0) }
            .joined(separator: ",")
        let dbFS = metrics.rms > 0
            ? 20 * log10(Double(metrics.rms))
            : -.infinity
        logger.info(
            "captureDiagnostic buffer=\(diagnosticBuffersLogged) " +
            "frames=\(pcm.frameCount) samples=\(pcm.samples.count) " +
            "rms=\(String(format: "%.6f", metrics.rms)) " +
            "peak=\(String(format: "%.6f", metrics.peak)) " +
            "dbFS=\(dbFS.isFinite ? String(format: "%.1f", dbFS) : "-inf") " +
            "firstSamples=[\(preview)]"
        )
    }
}

private extension CMTime {
    var nonNegativeNanoseconds: UInt64? {
        guard isValid, !isIndefinite, timescale > 0, value >= 0 else {
            return nil
        }

        let scale = Int64(timescale)
        let wholeSeconds = value / scale
        let remainder = value % scale
        guard wholeSeconds >= 0,
              UInt64(wholeSeconds) <= UInt64.max / 1_000_000_000 else {
            return nil
        }

        let wholeNanoseconds = UInt64(wholeSeconds) * 1_000_000_000
        let remainderNanoseconds = UInt64(remainder) * 1_000_000_000 / UInt64(scale)
        return wholeNanoseconds + remainderNanoseconds
    }
}

struct StreamingMetricsSnapshot: Sendable {
    let callbackStatistics: CallbackStatistics
    let latestMetrics: AudioMetrics?
    let framesStreamed: Int64
    let bytesStreamed: Int64
    let packetsStreamed: Int64
}

struct StreamingProcessingSummary: Sendable {
    let streamFormat: StreamAudioFormat?
    let callbackStatistics: CallbackStatistics
    let metricSummary: MetricSummary
    let framesStreamed: Int64
    let bytesStreamed: Int64
    let packetsStreamed: Int64
}
