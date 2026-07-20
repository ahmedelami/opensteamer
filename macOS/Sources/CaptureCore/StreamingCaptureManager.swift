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
        defer { monitor.cancel() }

        switch captureMode {
        case .screen:
            let source = ScreenCaptureAudioSource(displayID: displayID, logger: logger)
            try await Self.runStartedSource(
                start: { try await source.start(consumer: processor) },
                wait: { try await self.waitForRequestedDuration() },
                stop: { try await source.stop() }
            )
        case .blackHoleInput:
            let source = BlackHoleInputAudioSource(logger: logger)
            try await Self.runStartedSource(
                start: { try source.start(consumer: processor) },
                wait: { try await self.waitForRequestedDuration() },
                stop: { source.stop() }
            )
        }

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

    /// Runs one capture source and guarantees one best-effort stop after a successfully started
    /// source, including when the wait is cancelled by worldwide-host supervision. The original
    /// wait error wins over a cleanup error so cancellation still reaches the process supervisor.
    static func runStartedSource(
        start: () async throws -> Void,
        wait: () async throws -> Void,
        stop: @escaping () async throws -> Void
    ) async throws {
        try await start()
        let cleanupOperation = CancellationShieldedCleanup(stop)
        do {
            try await wait()
        } catch {
            let cleanup = Task {
                try await cleanupOperation.run()
            }
            _ = try? await cleanup.value
            throw error
        }
        let cleanup = Task {
            try await cleanupOperation.run()
        }
        try await cleanup.value
        try Task.checkCancellation()
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

/// Transfers a single source-owned cleanup closure into an uncancelled task after capture waiting
/// has ended. `runStartedSource` awaits that task before returning, so the unchecked boundary is
/// limited to this one, lock-enforced ownership handoff rather than declaring the mutable capture
/// source itself `Sendable`.
private final class CancellationShieldedCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (() async throws -> Void)?

    init(_ operation: @escaping () async throws -> Void) {
        self.operation = operation
    }

    func run() async throws {
        guard let operation = takeOperation() else { return }
        try await operation()
    }

    private func takeOperation() -> (() async throws -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let operation = operation
        self.operation = nil
        return operation
    }
}
