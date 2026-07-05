import Foundation

public final class CaptureManager {
    private let duration: TimeInterval
    private let outputURL: URL
    private let displayID: UInt32?
    private let logger: Logger

    public init(duration: TimeInterval, outputURL: URL, displayID: UInt32?, logger: Logger) {
        self.duration = duration
        self.outputURL = outputURL
        self.displayID = displayID
        self.logger = logger
    }

    public func run() async throws -> CaptureReport {
        logger.info("Capture started")
        logger.info("Duration: \(String(format: "%.2f", duration)) s")
        logger.info("Output: \(outputURL.path)")

        let processor = AudioProcessor(outputURL: outputURL, logger: logger)
        let source = ScreenCaptureAudioSource(displayID: displayID, logger: logger)
        let startedAt = Date()

        try await source.start(consumer: processor)
        let logger = logger
        let monitor = Task {
            await CaptureManager.monitorProgress(processor: processor, logger: logger)
        }

        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        try await source.stop()
        monitor.cancel()

        let processing = try processor.finish()
        let elapsed = Date().timeIntervalSince(startedAt)
        logger.info("Capture stopped after \(String(format: "%.2f", elapsed)) s")

        return CaptureReport(
            duration: elapsed,
            outputURL: outputURL,
            streamFormat: processing.streamFormat,
            callbackStatistics: processing.callbackStatistics,
            metricSummary: processing.metricSummary,
            framesWritten: processing.framesWritten,
            bytesWritten: processing.bytesWritten
        )
    }

    private static func monitorProgress(processor: AudioProcessor, logger: Logger) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let snapshot = processor.latestSnapshot()
                let rms = snapshot.latestMetrics?.rms ?? 0
                let peak = snapshot.latestMetrics?.peak ?? 0
                logger.info(
                    "callbacks=\(snapshot.callbackStatistics.count) " +
                    "avgInterval=\(String(format: "%.4f", snapshot.callbackStatistics.averageInterval))s " +
                    "frames=\(snapshot.framesWritten) " +
                    "rms=\(String(format: "%.5f", rms)) " +
                    "peak=\(String(format: "%.5f", peak))"
                )
            } catch {
                return
            }
        }
    }
}
