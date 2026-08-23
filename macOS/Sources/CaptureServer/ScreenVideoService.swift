import CaptureCore
import CoreMedia
import Foundation
import Server
import Utilities

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
        var lifecycleTask: Task<Void, Never>?
    }

    private let displayID: UInt32?
    private let displayRequirement: ScreenVideoDisplayRequirement?
    private let maximumWidth: Int
    private let framesPerSecond: Int
    private let bitrate: UInt32
    private let makeCaptureStopWatchdog: @Sendable () -> Task<Void, Never>?
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
        logger: Logger
    ) throws {
        self.displayID = displayID
        self.displayRequirement = displayRequirement
        self.maximumWidth = maximumWidth
        self.framesPerSecond = framesPerSecond
        self.bitrate = bitrate
        self.makeCaptureStopWatchdog = makeCaptureStopWatchdog
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
            return previous
        }
        previousTask?.cancel()
        let task = Task { [weak self] in
            await self?.stopPipeline()
            _ = await previousTask?.result
            await self?.startPipeline(generation: generation, sessionID: sessionID)
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
        guard let reservation = server.reserveFrameForEncoding() else { return }
        let encoder = lock.withLock { () -> H264ScreenVideoEncoder? in
            guard state.viewerConnected,
                  state.sourceSessionID == state.viewerSessionID,
                  state.pendingReservation == nil,
                  let encoder = state.encoder else {
                return nil
            }
            state.pendingReservation = reservation
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
        sessionID: VideoViewerSessionID
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
                self?.didEncode(result)
            }

            let installed = lock.withLock { () -> Bool in
                guard state.generation == generation,
                      state.viewerConnected,
                      state.viewerSessionID == sessionID,
                      state.source === source,
                      state.sourceSessionID == sessionID else {
                    return false
                }
                state.encoder = encoder
                state.format = format
                return true
            }
            if !installed {
                let stopped = await stopSource(source, context: "after stale encoder startup")
                releaseSource(source, afterConfirmedStop: stopped)
                encoder.finish()
            }
        } catch {
            let stopped = await stopSource(source, context: "after pipeline failure")
            logger.error("Screen video pipeline failed: \(error.localizedDescription)")
            let failedSessionID = lock.withLock { () -> VideoViewerSessionID? in
                guard state.generation == generation,
                      state.viewerSessionID == sessionID else {
                    return nil
                }
                if stopped, state.source === source {
                    state.source = nil
                }
                state.sourceSessionID = nil
                state.encoder = nil
                state.format = nil
                return state.viewerConnected ? sessionID : nil
            }
            if let failedSessionID {
                server.failActiveViewer(
                    failedSessionID,
                    reason: "screen capture or encoder failed"
                )
            }
        }
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
            return (true, previous)
        }
        guard transition.accepted else { return }
        transition.previousTask?.cancel()
        let task = Task { [weak self] in
            // Enter source.stop() before joining startup so its watchdog covers a native start
            // that ignores cancellation. Generation revocation prevents a not-yet-installed
            // source from appearing after this first snapshot.
            await self?.stopPipeline()
            _ = await transition.previousTask?.result
            if let self, lock.withLock({ state.source != nil }) {
                await stopPipeline()
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

    /// Revokes delivery while retaining native ownership until shutdown is confirmed.
    private func stopPipeline() async {
        let stopped = lock.withLock { () -> (
            ScreenVideoCaptureSource?,
            H264ScreenVideoEncoder?,
            ScreenVideoFrameReservation?
        ) in
            let values = (state.source, state.encoder, state.pendingReservation)
            state.sourceSessionID = nil
            state.encoder = nil
            state.format = nil
            state.pendingReservation = nil
            return values
        }
        if let reservation = stopped.2 {
            server.cancelFrameReservation(reservation, requestKeyFrame: false)
        }
        if let source = stopped.0 {
            let didStop = await stopSource(source, context: "during pipeline teardown")
            releaseSource(source, afterConfirmedStop: didStop)
        }
        stopped.1?.finish()
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
    private func didEncode(_ result: Result<EncodedScreenVideoFrame, Error>) {
        let pending = lock.withLock { () -> (
            ScreenVideoFrameReservation?,
            ScreenVideoCaptureFormat?
        ) in
            let values = (state.pendingReservation, state.format)
            state.pendingReservation = nil
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
            }
        }
        server.cancelFrameReservation(reservation, requestKeyFrame: requestKeyFrame)
    }
}
