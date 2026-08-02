import CoreMedia
import Foundation
import Streaming

/// Converts captured audio callbacks into the project's framed PCM wire format.
///
/// ScreenCaptureKit invokes `consume(_:)` directly on `sampleHandlerQueue`, so its
/// non-Sendable `CMSampleBuffer` is extracted synchronously without a second handoff.
/// The BlackHole backend copies Audio Queue memory into a queue-independent value and enqueues
/// that value on the same queue. `completion` tracks those accepted asynchronous PCM
/// values so `finish()` cannot race them, while the queue owns all mutable state.
final class StreamingAudioProcessor: @unchecked Sendable, SampleBufferConsumer {
    private let sink: PCMFrameSink
    private let logger: Logger
    private let queue = DispatchQueue(label: "opensteamer.StreamingAudioProcessor")
    private let completion = DispatchGroup()
    private let callbackTimeProvider: @Sendable () -> UInt64
    private let enqueueLinearizationLock = NSLock()

    private var lastEnqueuedCallbackTime: UInt64?
    private var lastRecordedCallbackTime: UInt64?
    private var sampleStorage: [Float] = []
    private var converter = PCM16Converter()
    private var streamFormat: StreamAudioFormat?
    private var sequence: UInt32 = 0
    private var callbackStatistics = CallbackStatistics()
    private var metricSummary = MetricSummary()
    private var latestMetrics: AudioMetrics?
    private var framesStreamed: Int64 = 0
    private var bytesStreamed: Int64 = 0
    private var firstError: Error?
    private var diagnosticBuffersLogged = 0

    /// Creates a processor for one sink; processors are not reused across streams.
    init(
        sink: PCMFrameSink,
        logger: Logger,
        callbackTimeProvider: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.sink = sink
        self.logger = logger
        self.callbackTimeProvider = callbackTimeProvider
    }

    /// The exact queue ScreenCaptureKit must use for this consumer's callbacks.
    var sampleHandlerQueue: DispatchQueue { queue }

    /// Extracts one ScreenCaptureKit buffer synchronously on the ownership queue.
    func consume(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        process(
            sampleBuffer,
            callbackTime: callbackTimeProvider()
        )
    }

    /// Enqueues already-decoded PCM copied from the Core Audio input backend.
    func enqueue(_ pcm: PCMBuffer, presentationTimestampNanoseconds: UInt64?) {
        // Capture arrival time before any processing backlog, and keep timestamp capture,
        // group admission, and serial-queue submission in one linearization order.
        enqueueLinearizationLock.lock()
        let sampledCallbackTime = callbackTimeProvider()
        let callbackTime = max(
            sampledCallbackTime,
            lastEnqueuedCallbackTime ?? sampledCallbackTime
        )
        lastEnqueuedCallbackTime = callbackTime
        completion.enter()
        queue.async { [self] in
            defer { completion.leave() }
            process(
                pcm,
                callbackTime: callbackTime,
                presentationTimestampNanoseconds: presentationTimestampNanoseconds
            )
        }
        enqueueLinearizationLock.unlock()
    }

    /// Drains accepted callbacks and either returns final counters or the first error.
    func finish() throws -> StreamingProcessingSummary {
        dispatchPrecondition(condition: .notOnQueue(queue))
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

    /// Returns an immutable progress snapshot taken on the ownership queue.
    func latestSnapshot() -> StreamingMetricsSnapshot {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            StreamingMetricsSnapshot(
                callbackStatistics: callbackStatistics,
                latestMetrics: latestMetrics,
                framesStreamed: framesStreamed,
                bytesStreamed: bytesStreamed,
                packetsStreamed: Int64(sequence)
            )
        }
    }

    /// Extracts one CoreMedia buffer; must run only on the processor queue.
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

    /// Frames decoded PCM and sends it in sequence order to the transport sink.
    private func process(_ pcm: PCMBuffer, callbackTime: UInt64, presentationTimestampNanoseconds: UInt64?) {
        guard firstError == nil else { return }
        callbackStatistics.recordCallback(
            uptimeNanoseconds: orderedCallbackTime(callbackTime),
            presentationTime: presentationTimestampNanoseconds.map { Double($0) / 1_000_000_000 }
        )

        if streamFormat == nil {
            streamFormat = pcm.format
            let header = PCMStreamHeader(
                sampleRate: UInt32(pcm.format.sampleRate.rounded()),
                channels: UInt16(pcm.channels)
            )
            sink.configureStream(header)
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
        // Sequence and source time are transport metadata; PCM stays signed 16-bit LE.
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

    /// Defensively preserves the monotonic contract even if an injected clock regresses.
    private func orderedCallbackTime(_ callbackTime: UInt64) -> UInt64 {
        let ordered = max(
            callbackTime,
            lastRecordedCallbackTime ?? callbackTime
        )
        lastRecordedCallbackTime = ordered
        return ordered
    }

    /// Computes levels before quantization so diagnostics reflect the captured signal.
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

    /// Logs only a bounded startup sample to diagnose format/routing failures safely.
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
    /// Converts a valid, nonnegative media time without overflowing nanoseconds.
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

/// Immutable progress counters for a running streaming processor.
struct StreamingMetricsSnapshot: Sendable {
    let callbackStatistics: CallbackStatistics
    let latestMetrics: AudioMetrics?
    let framesStreamed: Int64
    let bytesStreamed: Int64
    let packetsStreamed: Int64
}

/// Final streaming counters returned after the processing queue drains.
struct StreamingProcessingSummary: Sendable {
    let streamFormat: StreamAudioFormat?
    let callbackStatistics: CallbackStatistics
    let metricSummary: MetricSummary
    let framesStreamed: Int64
    let bytesStreamed: Int64
    let packetsStreamed: Int64
}
