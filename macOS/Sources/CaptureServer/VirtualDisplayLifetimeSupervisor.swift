import Foundation

/// Polls the complete owned-display invariant without mutating the user's display arrangement.
struct VirtualDisplayLifetimeMonitor: Sendable {
    typealias ValidityProbe = @Sendable () -> Bool
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    let pollInterval: Duration
    let isValid: ValidityProbe
    let sleeper: Sleeper

    static func live(isValid: @escaping ValidityProbe) -> Self {
        Self(
            pollInterval: .milliseconds(50),
            isValid: isValid,
            sleeper: { duration in
                try await Task.sleep(for: duration)
            }
        )
    }

    func waitUntilInvalid() async throws {
        while true {
            try Task.checkCancellation()
            guard isValid() else { return }
            try await sleeper(pollInterval)
        }
    }
}

/// Starts fail-closed supervision immediately after virtual-display ownership is established.
enum VirtualDisplayLifetimeSupervisor {
    typealias WatchdogSleeper = @Sendable (Duration) async throws -> Void

    static func start(
        monitor: VirtualDisplayLifetimeMonitor?,
        onInvalidation: @escaping @Sendable () -> Void,
        watchdogGracePeriod: Duration = .seconds(10),
        watchdogSleeper: @escaping WatchdogSleeper = { duration in
            try await Task.sleep(for: duration)
        },
        watchdogArmed: @escaping @Sendable () -> Void = {},
        terminateProcess: (@Sendable () -> Void)? = nil
    ) -> Task<Void, Never>? {
        guard let monitor else { return nil }
        return Task {
            do {
                try await monitor.waitUntilInvalid()
                guard !Task.isCancelled else { return }
            } catch {
                // Normal host teardown cancels the monitor. It must not be treated as drift.
                return
            }

            // Arm the independent fallback before any synchronous framework gate is touched.
            // Input revocation or a native stop can itself wedge, and must not prevent the
            // process-level deadline from starting.
            let watchdogTask = terminateProcess.map { terminateProcess in
                Task<Void, Never> {
                    do {
                        try await watchdogSleeper(watchdogGracePeriod)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    terminateProcess()
                }
            }
            if watchdogTask != nil {
                watchdogArmed()
            }
            onInvalidation()

            // Main normally observes the invalidation, drains every native service, restores
            // audio routing, closes the display, and cancels this task. A hard exit is only the
            // bounded fallback when framework teardown itself becomes permanently wedged.
            guard let watchdogTask else { return }
            await withTaskCancellationHandler {
                await watchdogTask.value
            } onCancel: {
                watchdogTask.cancel()
            }
        }
    }
}

/// Starts a process-level deadline for every teardown that owns a virtual display.
///
/// Native ScreenCaptureKit and WindowServer calls have no reliable cancellation guarantee. This
/// task is intentionally independent from those awaits so a normal duration, signal, or unrelated
/// service error cannot retain the replacement display and exclusive host lock indefinitely.
enum VirtualDisplayTeardownWatchdog {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    static func start(
        gracePeriod: Duration = .seconds(10),
        sleeper: @escaping Sleeper = { duration in
            try await Task.sleep(for: duration)
        },
        terminateProcess: @escaping @Sendable () -> Void
    ) -> Task<Void, Never> {
        Task {
            do {
                try await sleeper(gracePeriod)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            terminateProcess()
        }
    }
}

/// One idempotent teardown deadline shared by Main, service lifetime, and internal coordinators.
final class VirtualDisplayTeardownDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private let terminalGracePeriod: Duration
    private let nativeCaptureGracePeriod: Duration
    private let mediaServiceGracePeriod: Duration
    private let initializationGracePeriod: Duration
    private let sleeper: VirtualDisplayTeardownWatchdog.Sleeper
    private let terminateProcess: @Sendable () -> Void
    private var watchdogTask: Task<Void, Never>?
    private var isCancelled = false

    init(
        gracePeriod: Duration = VirtualDisplayTeardownBudgets.terminal,
        nativeCaptureGracePeriod: Duration = VirtualDisplayTeardownBudgets.nativeCapture,
        mediaServiceGracePeriod: Duration = VirtualDisplayTeardownBudgets.mediaService,
        initializationGracePeriod: Duration = VirtualDisplayTeardownBudgets.initialization,
        sleeper: @escaping VirtualDisplayTeardownWatchdog.Sleeper = { duration in
            try await Task.sleep(for: duration)
        },
        terminateProcess: @escaping @Sendable () -> Void
    ) {
        terminalGracePeriod = gracePeriod
        self.nativeCaptureGracePeriod = nativeCaptureGracePeriod
        self.mediaServiceGracePeriod = mediaServiceGracePeriod
        self.initializationGracePeriod = initializationGracePeriod
        self.sleeper = sleeper
        self.terminateProcess = terminateProcess
    }

    /// Starts the deadline exactly once, before the caller enters any native teardown await.
    func arm() {
        lock.withLock {
            guard watchdogTask == nil, !isCancelled else { return }
            watchdogTask = VirtualDisplayTeardownWatchdog.start(
                gracePeriod: terminalGracePeriod,
                sleeper: sleeper,
                terminateProcess: terminateProcess
            )
        }
    }

    /// Bounds one exact native capture start/stop without consuming the terminal deadline.
    func makeNativeCaptureWatchdog() -> Task<Void, Never> {
        makeIndependentWatchdog(gracePeriod: nativeCaptureGracePeriod)
    }

    /// Bounds the whole worldwide media close, including sequential native and transport work.
    func makeMediaServiceWatchdog() -> Task<Void, Never> {
        makeIndependentWatchdog(gracePeriod: mediaServiceGracePeriod)
    }

    /// Bounds the private WindowServer initializer independently from capture teardown.
    func makeInitializationWatchdog() -> Task<Void, Never> {
        makeIndependentWatchdog(gracePeriod: initializationGracePeriod)
    }

    private func makeIndependentWatchdog(
        gracePeriod: Duration
    ) -> Task<Void, Never> {
        VirtualDisplayTeardownWatchdog.start(
            gracePeriod: gracePeriod,
            sleeper: sleeper,
            terminateProcess: terminateProcess
        )
    }

    /// Cancels the deadline only after service teardown and display removal are both proven.
    func cancel() async {
        let task = lock.withLock { () -> Task<Void, Never>? in
            isCancelled = true
            defer { watchdogTask = nil }
            return watchdogTask
        }
        task?.cancel()
        await task?.value
    }
}

/// Separate budgets prevent a valid sequence of native closes from exhausting its outer owner.
enum VirtualDisplayTeardownBudgets {
    static let nativeCapture: Duration = .seconds(10)
    static let mediaService: Duration = .seconds(45)
    static let initialization: Duration = .seconds(40)
    static let nonVirtualProcessCleanup: Duration = .seconds(60)
    // Two LAN native attempts, one whole worldwide close, then at most two restoration probes.
    static let combinedVirtualTeardownEnvelope: Duration = .seconds(89)
    static let terminal: Duration = .seconds(105)
}

/// One buffered wake-up that makes an owned-display failure observable by Main's async run loop.
final class VirtualDisplayInvalidationSignal: @unchecked Sendable {
    let events: AsyncStream<Void>

    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var didSignal = false

    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream
        continuation = pair.continuation
    }

    func signal() {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !didSignal else { return false }
            didSignal = true
            return true
        }
        guard shouldSignal else { return }
        continuation.yield(())
        continuation.finish()
    }
}

enum VirtualDisplayLifetimeError: LocalizedError, Equatable, Sendable {
    case displayInvalid

    var errorDescription: String? {
        "The adjustable display disappeared or no longer owns the sole main-display topology."
    }
}
