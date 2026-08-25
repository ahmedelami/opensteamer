import CaptureCore
import CoreMedia
import Foundation
import Server
import Utilities

/// Lock-owned frame-count and wall-clock debounce state for the trusted-LAN capture pipeline.
/// Tokens invalidate deadlines that are already enqueued when concrete geometry recovers or a
/// newer pipeline generation takes ownership.
struct ScreenVideoServiceFormatRenegotiationState: Sendable {
    struct Observation: Sendable {
        let action: ScreenVideoFormatRenegotiationDetector.Action
        let fallbackToken: UInt64?
    }

    private var detector = ScreenVideoFormatRenegotiationDetector()
    private var nextFallbackToken: UInt64 = 0
    private var scheduledFallbackToken: UInt64?

    mutating func observe(_ geometry: ScreenVideoFrameGeometry?) -> Observation {
        let action = detector.observe(geometry)
        switch action {
        case .forwardFrame, .renegotiate:
            invalidateFallback()
            return Observation(action: action, fallbackToken: nil)
        case .dropFrame:
            guard detector.hasPendingFormatChange,
                  scheduledFallbackToken == nil else {
                return Observation(action: action, fallbackToken: nil)
            }
            nextFallbackToken &+= 1
            if nextFallbackToken == 0 {
                nextFallbackToken = 1
            }
            scheduledFallbackToken = nextFallbackToken
            return Observation(action: action, fallbackToken: nextFallbackToken)
        }
    }

    mutating func fallbackDeadlineDidFire(_ token: UInt64) -> Bool {
        guard scheduledFallbackToken == token else { return false }
        scheduledFallbackToken = nil
        return detector.requestRenegotiationAfterFallbackDeadline()
    }

    mutating func invalidateFallback() {
        scheduledFallbackToken = nil
    }

    mutating func reset() {
        scheduledFallbackToken = nil
        detector.reset()
    }
}

/// Lazily runs trusted-LAN screen capture and H.264 encoding for one TCP viewer.
///
/// `lock` owns the cross-framework pipeline state. UUID generations invalidate stale
/// async startup/teardown tasks, while `VideoTCPServer` reservations ensure at most one
/// encoded frame is in flight or awaiting acknowledgement. Capture is stopped whenever
/// its owning viewer session ends.
final class ScreenVideoService: @unchecked Sendable,
    ScreenVideoSampleConsumer,
    VideoTCPServerEventHandler
{
    typealias FormatRenegotiationFallbackScheduler =
        @Sendable (
            _ delay: TimeInterval,
            _ action: @escaping @Sendable () -> Void
        ) -> Void

    private static let maximumDisplayModeStartupRetries = 3
    static let formatRenegotiationFallbackDelay =
        ScreenVideoFormatRenegotiationDetector.fallbackDelay

    /// Lock-protected resources and identities for the current viewer pipeline.
    private struct PipelineState {
        var generation = UUID()
        var viewerConnected = false
        var viewerSessionID: VideoViewerSessionID?
        var source: ScreenVideoCaptureSource?
        var sourceSessionID: VideoViewerSessionID?
        var encoder: H264ScreenVideoEncoder?
        var format: ScreenVideoCaptureFormat?
        var pendingReservation: ScreenVideoFrameReservation?
        var pendingReservationPipelineGeneration: UUID?
        var lifecycleTask: Task<Void, Never>?
        var displayModeRestartPending = false
        var displayModeChangedDuringRestart = false
        var displayModeRestartSource: ScreenVideoCaptureSource?
        var displayModeTransportDiscontinuityApplied = false
        var formatRenegotiation = ScreenVideoServiceFormatRenegotiationState()
    }

    private let displayID: UInt32?
    private let displayRequirement: ScreenVideoDisplayRequirement?
    private let maximumWidth: Int
    private let framesPerSecond: Int
    private let bitrate: UInt32
    private let makeCaptureStopWatchdog: @Sendable () -> Task<Void, Never>?
    private let scheduleFormatRenegotiationFallback:
        FormatRenegotiationFallbackScheduler
    private let logger: Logger
    private let server: VideoTCPServer
    private let lock = NSLock()
    private var state = PipelineState()

    /// Creates the server and capture configuration without starting either resource.
    init(
        host: String,
        port: UInt16,
        bonjourName: String?,
        authToken: String?,
        displayID: UInt32?,
        displayRequirement: ScreenVideoDisplayRequirement?,
        maximumWidth: Int,
        framesPerSecond: Int,
        bitrate: UInt32,
        makeCaptureStopWatchdog: @escaping @Sendable () -> Task<Void, Never>? = { nil },
        scheduleFormatRenegotiationFallback:
            @escaping FormatRenegotiationFallbackScheduler = { delay, action in
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + delay,
                    execute: action
                )
            },
        logger: Logger
    ) throws {
        self.displayID = displayID
        self.displayRequirement = displayRequirement
        self.maximumWidth = maximumWidth
        self.framesPerSecond = framesPerSecond
        self.bitrate = bitrate
        self.makeCaptureStopWatchdog = makeCaptureStopWatchdog
        self.scheduleFormatRenegotiationFallback =
            scheduleFormatRenegotiationFallback
        self.logger = logger
        self.server = try VideoTCPServer(
            host: host,
            port: port,
            bonjourName: bonjourName,
            authToken: authToken,
            logger: logger
        )
        server.setEventHandler(self)
    }

    /// Starts the TCP listener; capture remains lazy until a viewer authenticates.
    func start() throws {
        try server.start()
    }

    /// Stops accepting viewers and synchronously revokes the active pipeline generation.
    @discardableResult
    func revoke() -> Task<Void, Never>? {
        server.stop()
        let lifecycleTask = lock.withLock { () -> Task<Void, Never>? in
            state.generation = UUID()
            state.viewerConnected = false
            state.viewerSessionID = nil
            state.formatRenegotiation.invalidateFallback()
            let task = state.lifecycleTask
            state.lifecycleTask = nil
            return task
        }
        lifecycleTask?.cancel()
        return lifecycleTask
    }

    /// Stops accepting viewers, revokes the active generation, and drains native teardown.
    @discardableResult
    func stop() async -> Bool {
        let lifecycleTask = revoke()
        return await finishStop(afterRevoking: lifecycleTask)
    }

    /// Completes teardown after a caller has already synchronously revoked transport gates.
    @discardableResult
    func finishStop(afterRevoking lifecycleTask: Task<Void, Never>?) async -> Bool {
        // Stop the installed source before joining a possibly wedged startup. The source's
        // stop-during-start path owns the virtual-display watchdog and releases that startup.
        await stopPipeline()
        _ = await lifecycleTask?.result
        if lock.withLock({ state.source != nil }) {
            // A failed native stop remains owned and retryable; make one final bounded attempt
            // before the enclosing process-level teardown policy takes over.
            await stopPipeline()
        }
        return lock.withLock { state.source == nil }
    }

    /// Returns transport counters from the underlying server.
    func snapshot() -> VideoTCPServerSnapshot {
        server.snapshot()
    }

    // MARK: - Video server events

    /// Serializes a new viewer startup behind any previous lifecycle task.
    func videoServerViewerConnected(_ sessionID: VideoViewerSessionID) {
        let generation = UUID()
        let previousTask = lock.withLock { () -> Task<Void, Never>? in
            let previous = state.lifecycleTask
            state.generation = generation
            state.viewerConnected = true
            state.viewerSessionID = sessionID
            state.formatRenegotiation.invalidateFallback()
            return previous
        }
        previousTask?.cancel()
        let task = Task { [weak self] in
            guard !Task.isCancelled,
                  let self,
                  await stopPipeline(expectedGeneration: generation) else {
                return
            }
            _ = await previousTask?.result
            guard !Task.isCancelled else { return }
            await startPipeline(generation: generation, sessionID: sessionID)
        }
        lock.withLock {
            if state.generation == generation {
                state.lifecycleTask = task
            } else {
                task.cancel()
            }
        }
    }

    /// Schedules teardown only for the viewer that still owns the pipeline.
    func videoServerViewerDisconnected(_ sessionID: VideoViewerSessionID) {
        schedulePipelineStop(for: sessionID)
    }

    /// Forwards transport recovery to the encoder belonging to the active viewer.
    func videoServerRequestedKeyFrame() {
        let encoder = lock.withLock { () -> H264ScreenVideoEncoder? in
            guard state.viewerConnected,
                  state.sourceSessionID == state.viewerSessionID else {
                return nil
            }
            return state.encoder
        }
        encoder?.requestKeyFrame()
    }

    // MARK: - Capture callbacks

    /// Reserves transport capacity before submitting a captured frame to the encoder.
    func consumeScreenVideoSample(_ sampleBuffer: CMSampleBuffer) {
        let generation = lock.withLock { state.generation }
        consumeScreenVideoSample(
            sampleBuffer,
            expectedPipelineGeneration: generation
        )
    }

    /// Revalidates the exact pipeline generation after transport reservation and before encode.
    private func consumeScreenVideoSample(
        _ sampleBuffer: CMSampleBuffer,
        expectedPipelineGeneration: UUID
    ) {
        guard let reservation = server.reserveFrameForEncoding() else { return }
        let encoder = lock.withLock { () -> H264ScreenVideoEncoder? in
            guard state.generation == expectedPipelineGeneration,
                  state.viewerConnected,
                  state.sourceSessionID == state.viewerSessionID,
                  state.pendingReservation == nil,
                  !state.displayModeRestartPending,
                  let encoder = state.encoder else {
                return nil
            }
            state.pendingReservation = reservation
            state.pendingReservationPipelineGeneration = expectedPipelineGeneration
            return encoder
        }

        guard let encoder else {
            server.cancelFrameReservation(reservation, requestKeyFrame: false)
            return
        }

        if reservation.forceKeyFrame {
            encoder.requestKeyFrame()
        }
        do {
            let accepted = try encoder.encodeIfAvailable(sampleBuffer)
            if !accepted {
                clearReservation(reservation, requestKeyFrame: reservation.forceKeyFrame)
            }
        } catch {
            logger.error("Could not submit screen frame: \(error.localizedDescription)")
            clearReservation(reservation, requestKeyFrame: true)
        }
    }

    /// Rebuilds the fixed-size H.264 pipeline when ScreenCaptureKit reports that a live display
    /// mode is now inset inside the stream's startup surface. The mismatched frame is deliberately
    /// dropped so the viewer never treats ScreenCaptureKit's temporary bars as the selected mode.
    func consumeScreenVideoSample(
        _ sampleBuffer: CMSampleBuffer,
        frameGeometry: ScreenVideoFrameGeometry?
    ) {
        let transition = lock.withLock { () -> (
            observation: ScreenVideoServiceFormatRenegotiationState.Observation,
            generation: UUID
        )? in
            guard state.viewerConnected,
                  state.sourceSessionID == state.viewerSessionID,
                  state.encoder != nil,
                  !state.displayModeRestartPending else {
                return nil
            }
            return (
                state.formatRenegotiation.observe(frameGeometry),
                state.generation
            )
        }
        guard let transition else { return }
        switch transition.observation.action {
        case .forwardFrame:
            consumeScreenVideoSample(
                sampleBuffer,
                expectedPipelineGeneration: transition.generation
            )
        case .dropFrame:
            break
        case .renegotiate:
            schedulePipelineRestartForDisplayModeChange(
                expectedPipelineGeneration: transition.generation
            )
        }
        if let fallbackToken = transition.observation.fallbackToken {
            scheduleFormatRenegotiationFallback(
                Self.formatRenegotiationFallbackDelay
            ) { [weak self] in
                self?.formatRenegotiationFallbackDidFire(
                    fallbackToken,
                    expectedPipelineGeneration: transition.generation
                )
            }
        }
    }

    private func formatRenegotiationFallbackDidFire(
        _ token: UInt64,
        expectedPipelineGeneration: UUID
    ) {
        let shouldRestart = lock.withLock { () -> Bool in
            guard state.formatRenegotiation.fallbackDeadlineDidFire(token),
                  state.generation == expectedPipelineGeneration,
                  state.viewerConnected,
                  state.sourceSessionID == state.viewerSessionID,
                  state.encoder != nil,
                  !state.displayModeRestartPending else {
                return false
            }
            return true
        }
        guard shouldRestart else { return }
        schedulePipelineRestartForDisplayModeChange(
            expectedPipelineGeneration: expectedPipelineGeneration
        )
    }

    /// Treats Core Graphics' post-configuration mode event as the authoritative restart trigger.
    /// Frame geometry remains a fallback and suppresses any temporary inset frames.
    func screenVideoCaptureSourceDisplayModeDidChange(
        _ source: ScreenVideoCaptureSource
    ) {
        schedulePipelineRestartForDisplayModeChange(reportedBy: source)
    }

    /// Fails the owning viewer when ScreenCaptureKit stops outside normal teardown.
    func screenVideoCaptureSource(
        _ source: ScreenVideoCaptureSource,
        didStopWithErrorDescription errorDescription: String
    ) {
        let sessionID = lock.withLock { () -> VideoViewerSessionID? in
            guard state.viewerConnected,
                  state.source === source,
                  state.sourceSessionID == state.viewerSessionID else {
                return nil
            }
            return state.sourceSessionID
        }
        guard let sessionID else { return }
        logger.error("Screen video capture stopped unexpectedly: \(errorDescription)")
        server.failActiveViewer(
            sessionID,
            reason: "screen capture stopped unexpectedly"
        )
    }

    // MARK: - Pipeline lifecycle

    /// Starts capture then installs an encoder only if the viewer generation remains current.
    private func startPipeline(
        generation: UUID,
        sessionID: VideoViewerSessionID,
        remainingDisplayModeStartupRetries: Int = maximumDisplayModeStartupRetries
    ) async {
        guard lock.withLock({
            state.generation == generation &&
                state.viewerConnected &&
                state.viewerSessionID == sessionID
        }) else {
            return
        }

        let retainedSource = lock.withLock { () -> ScreenVideoCaptureSource? in
            guard state.sourceSessionID == nil else { return nil }
            return state.source
        }
        if let retainedSource {
            let stopped = await stopSource(
                retainedSource,
                context: "before replacement pipeline startup"
            )
            releaseSource(retainedSource, afterConfirmedStop: stopped)
            guard stopped else {
                let stillCurrent = lock.withLock {
                    state.generation == generation
                        && state.viewerConnected
                        && state.viewerSessionID == sessionID
                        && state.source === retainedSource
                }
                if stillCurrent {
                    server.failActiveViewer(
                        sessionID,
                        reason: "previous screen capture stop remained unconfirmed"
                    )
                }
                return
            }
        }

        let source = ScreenVideoCaptureSource(
            displayID: displayID,
            displayRequirement: displayRequirement,
            maximumWidth: maximumWidth,
            framesPerSecond: framesPerSecond,
            consumer: self,
            makeStopWatchdog: makeCaptureStopWatchdog,
            logger: logger
        )
        let shouldStart = lock.withLock { () -> Bool in
            guard state.generation == generation,
                  state.viewerConnected,
                  state.viewerSessionID == sessionID,
                  state.source == nil else {
                return false
            }
            state.source = source
            state.sourceSessionID = sessionID
            return true
        }
        guard shouldStart else { return }

        do {
            let format = try await source.start()
            guard lock.withLock({
                state.generation == generation &&
                    state.viewerConnected &&
                    state.viewerSessionID == sessionID &&
                    state.source === source &&
                    state.sourceSessionID == sessionID
            }) else {
                let stopped = await stopSource(source, context: "after viewer disconnect")
                releaseSource(source, afterConfirmedStop: stopped)
                return
            }

            let encoder = try H264ScreenVideoEncoder(
                width: Int32(format.width),
                height: Int32(format.height),
                framesPerSecond: Int32(format.framesPerSecond),
                bitrate: Int32(bitrate)
            ) { [weak self] result in
                self?.didEncode(
                    result,
                    expectedPipelineGeneration: generation
                )
            }

            let installation = lock.withLock { () -> (
                installed: Bool,
                repeatRestart: Bool,
                requiresTransportDiscontinuity: Bool
            ) in
                guard state.generation == generation,
                      state.viewerConnected,
                      state.viewerSessionID == sessionID,
                      state.source === source,
                      state.sourceSessionID == sessionID else {
                    return (false, false, false)
                }
                if state.displayModeChangedDuringRestart {
                    state.sourceSessionID = nil
                    state.displayModeChangedDuringRestart = false
                    state.displayModeRestartSource = source
                    return (false, true, false)
                }
                let requiresTransportDiscontinuity = state.displayModeRestartPending
                    && !state.displayModeTransportDiscontinuityApplied
                state.encoder = encoder
                state.format = format
                state.displayModeRestartPending = false
                state.displayModeChangedDuringRestart = false
                state.displayModeRestartSource = nil
                state.displayModeTransportDiscontinuityApplied = false
                state.formatRenegotiation.reset()
                return (true, false, requiresTransportDiscontinuity)
            }
            if installation.repeatRestart {
                let stopped = await stopSource(
                    source,
                    context: "before repeated display-mode pipeline startup"
                )
                releaseSource(source, afterConfirmedStop: stopped)
                encoder.finish()
                guard remainingDisplayModeStartupRetries > 0 else {
                    lock.withLock {
                        if state.generation == generation {
                            state.displayModeRestartPending = false
                            state.displayModeChangedDuringRestart = false
                            state.displayModeRestartSource = nil
                            state.displayModeTransportDiscontinuityApplied = false
                            state.formatRenegotiation.reset()
                        }
                    }
                    server.failActiveViewer(
                        sessionID,
                        reason: "display mode kept changing during screen capture startup"
                    )
                    return
                }
                await startPipeline(
                    generation: generation,
                    sessionID: sessionID,
                    remainingDisplayModeStartupRetries:
                        remainingDisplayModeStartupRetries - 1
                )
            } else if !installation.installed {
                let stopped = await stopSource(source, context: "after stale encoder startup")
                releaseSource(source, afterConfirmedStop: stopped)
                encoder.finish()
            } else {
                if installation.requiresTransportDiscontinuity {
                    guard server.beginCaptureFormatDiscontinuity(for: sessionID) else {
                        throw ScreenVideoCaptureError.startCancelled
                    }
                }
                try source.beginSampleDelivery()
            }
        } catch {
            let stopped = await stopSource(source, context: "after pipeline failure")
            logger.error("Screen video pipeline failed: \(error.localizedDescription)")
            let displayModeChangedDuringStart = Self.isDisplayModeChangedDuringStart(error)
            let failure = lock.withLock { () -> (
                failedSessionID: VideoViewerSessionID?,
                retryDisplayModeStart: Bool
            ) in
                guard state.generation == generation,
                      state.viewerSessionID == sessionID else {
                    return (nil, false)
                }
                if stopped, state.source === source {
                    state.source = nil
                }
                state.sourceSessionID = nil
                state.encoder = nil
                state.format = nil
                if displayModeChangedDuringStart,
                   remainingDisplayModeStartupRetries > 0,
                   state.viewerConnected {
                    state.displayModeRestartPending = true
                    state.displayModeChangedDuringRestart = false
                    state.displayModeRestartSource = source
                    state.formatRenegotiation.reset()
                    return (nil, true)
                }
                state.displayModeRestartPending = false
                state.displayModeChangedDuringRestart = false
                state.displayModeRestartSource = nil
                state.displayModeTransportDiscontinuityApplied = false
                state.formatRenegotiation.reset()
                return (state.viewerConnected ? sessionID : nil, false)
            }
            if failure.retryDisplayModeStart {
                await startPipeline(
                    generation: generation,
                    sessionID: sessionID,
                    remainingDisplayModeStartupRetries:
                        remainingDisplayModeStartupRetries - 1
                )
            } else if let failedSessionID = failure.failedSessionID {
                server.failActiveViewer(
                    failedSessionID,
                    reason: "screen capture or encoder failed"
                )
            }
        }
    }

    private static func isDisplayModeChangedDuringStart(_ error: any Error) -> Bool {
        guard let captureError = error as? ScreenVideoCaptureError else { return false }
        if case .displayModeChangedDuringStart = captureError {
            return true
        }
        return false
    }

    /// Invalidates startup and sequences teardown after preceding lifecycle work.
    private func schedulePipelineStop(for sessionID: VideoViewerSessionID) {
        let generation = UUID()
        let transition = lock.withLock { () -> (
            accepted: Bool,
            previousTask: Task<Void, Never>?
        ) in
            guard state.viewerSessionID == sessionID else {
                return (false, nil)
            }
            let previous = state.lifecycleTask
            state.generation = generation
            state.viewerConnected = false
            state.viewerSessionID = nil
            state.formatRenegotiation.invalidateFallback()
            return (true, previous)
        }
        guard transition.accepted else { return }
        transition.previousTask?.cancel()
        let task = Task { [weak self] in
            // Enter source.stop() before joining startup so its watchdog covers a native start
            // that ignores cancellation. Generation revocation prevents a not-yet-installed
            // source from appearing after this first snapshot.
            guard !Task.isCancelled,
                  let self,
                  await stopPipeline(expectedGeneration: generation) else {
                return
            }
            _ = await transition.previousTask?.result
            if !Task.isCancelled,
               lock.withLock({
                   state.generation == generation && state.source != nil
               }) {
                await stopPipeline(expectedGeneration: generation)
            }
        }
        lock.withLock {
            if state.generation == generation {
                state.lifecycleTask = task
            } else {
                task.cancel()
            }
        }
    }

    /// Serializes a live display-mode restart behind the current pipeline lifecycle without
    /// disconnecting the authenticated LAN viewer. A new transport generation clears the old ACK
    /// deadline before a replacement encoder publishes fresh configuration and a key frame.
    private func schedulePipelineRestartForDisplayModeChange(
        reportedBy reportingSource: ScreenVideoCaptureSource? = nil,
        expectedPipelineGeneration: UUID? = nil
    ) {
        let generation = UUID()
        let transition = lock.withLock { () -> (
            accepted: Bool,
            sessionID: VideoViewerSessionID?,
            previousTask: Task<Void, Never>?
        ) in
            guard state.viewerConnected,
                  let sessionID = state.viewerSessionID,
                  state.sourceSessionID == sessionID,
                  let source = state.source,
                  expectedPipelineGeneration.map({ $0 == state.generation }) != false,
                  reportingSource == nil || source === reportingSource else {
                return (false, nil, nil)
            }
            state.formatRenegotiation.invalidateFallback()
            if state.displayModeRestartPending {
                if let reportingSource,
                   reportingSource !== state.displayModeRestartSource {
                    state.displayModeChangedDuringRestart = true
                }
                return (false, nil, nil)
            }
            state.displayModeRestartPending = true
            state.displayModeChangedDuringRestart = false
            state.displayModeRestartSource = source
            state.displayModeTransportDiscontinuityApplied = false
            let previous = state.lifecycleTask
            state.generation = generation
            return (true, sessionID, previous)
        }
        guard transition.accepted, let sessionID = transition.sessionID else { return }

        // Retire the old acknowledgement timer before native stop/start can consume its remaining
        // two-second budget. The replacement's retained startup frame then has an empty flow slot.
        guard server.beginCaptureFormatDiscontinuity(for: sessionID) else {
            schedulePipelineStop(for: sessionID)
            return
        }
        let discontinuityRemainsCurrent = lock.withLock { () -> Bool in
            guard state.generation == generation,
                  state.viewerConnected,
                  state.viewerSessionID == sessionID,
                  state.displayModeRestartPending else {
                return false
            }
            state.displayModeTransportDiscontinuityApplied = true
            return true
        }
        guard discontinuityRemainsCurrent else { return }

        transition.previousTask?.cancel()
        let task = Task { [weak self] in
            guard !Task.isCancelled,
                  let self,
                  await stopPipeline(
                      expectedGeneration: generation,
                      preservingDisplayModeRestart: true
                  ) else {
                return
            }
            _ = await transition.previousTask?.result
            guard !Task.isCancelled,
                  lock.withLock({
                      state.generation == generation
                          && state.viewerConnected
                          && state.viewerSessionID == sessionID
                  }) else {
                return
            }
            await startPipeline(generation: generation, sessionID: sessionID)
        }
        lock.withLock {
            if state.generation == generation {
                state.lifecycleTask = task
            } else {
                task.cancel()
            }
        }
    }

    /// Revokes delivery while retaining native ownership until shutdown is confirmed.
    @discardableResult
    private func stopPipeline(
        expectedGeneration: UUID? = nil,
        preservingDisplayModeRestart: Bool = false
    ) async -> Bool {
        let stopped = lock.withLock { () -> (
            ScreenVideoCaptureSource?,
            H264ScreenVideoEncoder?,
            ScreenVideoFrameReservation?
        )? in
            if let expectedGeneration,
               state.generation != expectedGeneration {
                return nil
            }
            let values = (state.source, state.encoder, state.pendingReservation)
            state.sourceSessionID = nil
            state.encoder = nil
            state.format = nil
            state.pendingReservation = nil
            state.pendingReservationPipelineGeneration = nil
            if !preservingDisplayModeRestart {
                state.displayModeRestartPending = false
                state.displayModeChangedDuringRestart = false
                state.displayModeRestartSource = nil
                state.displayModeTransportDiscontinuityApplied = false
                state.formatRenegotiation.reset()
            }
            return values
        }
        guard let stopped else { return false }
        if let reservation = stopped.2 {
            server.cancelFrameReservation(reservation, requestKeyFrame: false)
        }
        if let source = stopped.0 {
            let didStop = await stopSource(source, context: "during pipeline teardown")
            releaseSource(source, afterConfirmedStop: didStop)
        }
        stopped.1?.finish()
        return true
    }

    /// Performs ScreenCaptureKit cleanup while reporting whether native ownership may be released.
    @discardableResult
    private func stopSource(_ source: ScreenVideoCaptureSource, context: String) async -> Bool {
        do {
            try await source.stop()
            return true
        } catch {
            logger.error(
                "Could not stop screen video capture \(context): \(error.localizedDescription)"
            )
            return false
        }
    }

    /// Drops the source only after its exact native stream has acknowledged shutdown.
    private func releaseSource(
        _ source: ScreenVideoCaptureSource,
        afterConfirmedStop didStop: Bool
    ) {
        guard didStop else { return }
        lock.withLock {
            if state.source === source {
                state.source = nil
                state.sourceSessionID = nil
            }
        }
    }

    /// Resolves the sole pending reservation with an encoded frame or recovery request.
    private func didEncode(
        _ result: Result<EncodedScreenVideoFrame, Error>,
        expectedPipelineGeneration: UUID
    ) {
        let pending = lock.withLock { () -> (
            ScreenVideoFrameReservation?,
            ScreenVideoCaptureFormat?
        ) in
            guard state.pendingReservationPipelineGeneration
                == expectedPipelineGeneration else {
                return (nil, nil)
            }
            let reservation = state.pendingReservation
            let deliveryIsCurrent = expectedPipelineGeneration == state.generation
                && !state.displayModeRestartPending
            let values = (
                reservation,
                deliveryIsCurrent ? state.format : nil
            )
            state.pendingReservation = nil
            state.pendingReservationPipelineGeneration = nil
            return values
        }
        guard let reservation = pending.0 else { return }

        switch result {
        case .success(let frame):
            guard let format = pending.1 else {
                server.cancelFrameReservation(reservation, requestKeyFrame: true)
                return
            }
            server.sendEncodedFrame(
                frame,
                reservation: reservation,
                format: format,
                bitrate: bitrate
            )
        case .failure(let error):
            logger.error("Screen encoder callback failed: \(error.localizedDescription)")
            server.cancelFrameReservation(reservation, requestKeyFrame: true)
        }
    }

    /// Releases matching local/server reservation state after rejected submission.
    private func clearReservation(
        _ reservation: ScreenVideoFrameReservation,
        requestKeyFrame: Bool
    ) {
        lock.withLock {
            if state.pendingReservation?.id == reservation.id {
                state.pendingReservation = nil
                state.pendingReservationPipelineGeneration = nil
            }
        }
        server.cancelFrameReservation(reservation, requestKeyFrame: requestKeyFrame)
    }
}
