import Foundation

/// Coordinates one live macOS audio source and a packet-oriented PCM sink.
///
/// A `nil` duration keeps the source alive until the enclosing task is cancelled.
/// Source shutdown is cancellation-shielded so Core Audio and ScreenCaptureKit do
/// not retain callbacks after the session supervisor moves on.
public final class StreamingCaptureManager {
    private let duration: TimeInterval?
    private let displayID: UInt32?
    private let captureMode: AudioCaptureMode
    private let sink: PCMFrameSink
    private let logger: Logger
    private let teardownDidBegin: @Sendable () -> Void
    private let makeCaptureStopWatchdog: @Sendable () -> Task<Void, Never>?

    /// Creates a capture run with an explicit backend and transport sink.
    public init(
        duration: TimeInterval?,
        displayID: UInt32?,
        captureMode: AudioCaptureMode,
        sink: PCMFrameSink,
        teardownDidBegin: @escaping @Sendable () -> Void = {},
        makeCaptureStopWatchdog: @escaping @Sendable () -> Task<Void, Never>? = { nil },
        logger: Logger
    ) {
        self.duration = duration
        self.displayID = displayID
        self.captureMode = captureMode
        self.sink = sink
        self.teardownDidBegin = teardownDidBegin
        self.makeCaptureStopWatchdog = makeCaptureStopWatchdog
        self.logger = logger
    }

    /// Runs capture to completion and returns counters after queued audio has drained.
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
            let source = ScreenCaptureAudioSource(
                displayID: displayID,
                makeStopWatchdog: makeCaptureStopWatchdog,
                logger: logger
            )
            try await Self.runStartedSource(
                start: { try await source.start(consumer: processor) },
                wait: { try await self.waitForRequestedDuration() },
                teardownDidBegin: teardownDidBegin,
                stop: { try await Self.stopScreenCaptureAudioSource(source) }
            )
        case .blackHoleInput:
            let source = BlackHoleInputAudioSource(logger: logger)
            try await Self.runStartedSource(
                start: { try source.start(consumer: processor) },
                wait: { try await self.waitForRequestedDuration() },
                teardownDidBegin: teardownDidBegin,
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
    /// wait error wins over an ordinary cleanup error. An unconfirmed native screen stop instead
    /// propagates its retained owner so process teardown cannot release the virtual display first.
    static func runStartedSource(
        start: () async throws -> Void,
        wait: () async throws -> Void,
        teardownDidBegin: @Sendable () -> Void = {},
        stop: @escaping () async throws -> Void
    ) async throws {
        try await start()
        let cleanupOperation = CancellationShieldedCleanup(stop)
        do {
            try await wait()
        } catch let waitError {
            teardownDidBegin()
            let cleanup = Task {
                try await cleanupOperation.run()
            }
            do {
                try await cleanup.value
            } catch let cleanupError {
                if hasUnconfirmedNativeScreenCaptureStop(cleanupError) {
                    throw cleanupError
                }
            }
            throw waitError
        }
        teardownDidBegin()
        let cleanup = Task {
            try await cleanupOperation.run()
        }
        try await cleanup.value
        try Task.checkCancellation()
    }

    /// Identifies a retained ScreenCaptureKit audio owner whose native stop remains uncertain.
    public static func hasUnconfirmedNativeScreenCaptureStop(_ error: any Error) -> Bool {
        error is any NativeScreenCaptureStopUnconfirmedError
    }

    /// Gives prompt native failures a second bounded attempt before retaining the exact owner.
    private static func stopScreenCaptureAudioSource(
        _ source: ScreenCaptureAudioSource
    ) async throws {
        var failureDescriptions: [String] = []
        for _ in 0..<2 {
            do {
                try await source.stop()
                return
            } catch {
                failureDescriptions.append(error.localizedDescription)
            }
        }
        throw RetainedScreenCaptureAudioStopError(
            source: source,
            failureDescriptions: failureDescriptions
        )
    }

    /// Waits for a fixed duration or cooperatively until task cancellation.
    private func waitForRequestedDuration() async throws {
        if let duration {
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        } else {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Logs queue-consistent progress without participating in capture control flow.
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

/// Marks the one cleanup failure that must take precedence over cancellation or wait errors.
public protocol NativeScreenCaptureStopUnconfirmedError: Error {}

/// Holds the exact audio source until Main takes the fail-closed process-exit path.
final class RetainedScreenCaptureAudioStopError:
    NativeScreenCaptureStopUnconfirmedError,
    LocalizedError,
    @unchecked Sendable
{
    private let retainedSource: ScreenCaptureAudioSource
    private let failureDescriptions: [String]

    init(source: ScreenCaptureAudioSource, failureDescriptions: [String]) {
        retainedSource = source
        self.failureDescriptions = failureDescriptions
    }

    var errorDescription: String? {
        let detail = failureDescriptions.last ?? "unknown ScreenCaptureKit error"
        return "ScreenCaptureKit audio did not confirm shutdown after two attempts: \(detail)"
    }
}

/// Transfers a single source-owned cleanup closure into an uncancelled task after capture waiting
/// has ended. `runStartedSource` awaits that task before returning, so the unchecked boundary is
/// limited to this one, lock-enforced ownership handoff rather than declaring the mutable capture
/// source itself `Sendable`.
private final class CancellationShieldedCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (() async throws -> Void)?

    /// Takes ownership of the source-specific stop operation.
    init(_ operation: @escaping () async throws -> Void) {
        self.operation = operation
    }

    /// Executes the stop operation at most once, regardless of competing cleanup paths.
    func run() async throws {
        guard let operation = takeOperation() else { return }
        try await operation()
    }

    /// Atomically consumes the only reference to the cleanup operation.
    private func takeOperation() -> (() async throws -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let operation = operation
        self.operation = nil
        return operation
    }
}
