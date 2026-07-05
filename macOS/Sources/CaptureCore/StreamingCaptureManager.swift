import Foundation

public final class StreamingCaptureManager {
    private let duration: TimeInterval?
    private let displayID: UInt32?
    private let captureMode: AudioCaptureMode
    private let sink: PCMFrameSink
    private let logger: Logger

    public init(
        duration: TimeInterval?,
        displayID: UInt32?,
        captureMode: AudioCaptureMode,
        sink: PCMFrameSink,
        logger: Logger
    ) {
        self.duration = duration
        self.displayID = displayID
        self.captureMode = captureMode
        self.sink = sink
        self.logger = logger
    }

    public func run() async throws -> StreamingCaptureReport {
        logger.info("Streaming capture started with mode=\(captureMode.rawValue)")
        let processor = StreamingAudioProcessor(sink: sink, logger: logger)
        let startedAt = Date()

        let logger = logger
        let monitor = Task {
            await StreamingCaptureManager.monitorProgress(processor: processor, logger: logger)
        }

        switch captureMode {
        case .screen:
            let source = ScreenCaptureAudioSource(displayID: displayID, logger: logger)
            try await source.start(consumer: processor)
            try await waitForRequestedDuration()
            try await source.stop()
        case .blackHoleInput:
            let source = BlackHoleInputAudioSource(logger: logger)
            try source.start(consumer: processor)
            try await waitForRequestedDuration()
            source.stop()
        }

        monitor.cancel()

        let summary = try processor.finish()
        let elapsed = Date().timeIntervalSince(startedAt)
        logger.info("Streaming capture stopped after \(String(format: "%.2f", elapsed)) s")

        return StreamingCaptureReport(
            duration: elapsed,
            streamFormat: summary.streamFormat,
            callbackStatistics: summary.callbackStatistics,
            metricSummary: summary.metricSummary,
            framesStreamed: summary.framesStreamed,
            bytesStreamed: summary.bytesStreamed,
            packetsStreamed: summary.packetsStreamed
        )
    }

    private func waitForRequestedDuration() async throws {
        if let duration {
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        } else {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private static func monitorProgress(processor: StreamingAudioProcessor, logger: Logger) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let snapshot = processor.latestSnapshot()
                let rms = snapshot.latestMetrics?.rms ?? 0
                let peak = snapshot.latestMetrics?.peak ?? 0
                logger.info(
                    "callbacks=\(snapshot.callbackStatistics.count) " +
                    "packets=\(snapshot.packetsStreamed) " +
                    "bytes=\(snapshot.bytesStreamed) " +
                    "avgInterval=\(String(format: "%.4f", snapshot.callbackStatistics.averageInterval))s " +
                    "rms=\(String(format: "%.5f", rms)) " +
                    "peak=\(String(format: "%.5f", peak))"
                )
            } catch {
                return
            }
        }
    }
}
