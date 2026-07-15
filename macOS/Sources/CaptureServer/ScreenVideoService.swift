import CaptureCore
import CoreMedia
import Foundation
import Server
import Utilities

final class ScreenVideoService: @unchecked Sendable,
    ScreenVideoSampleConsumer,
    VideoTCPServerEventHandler
{
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
    private let maximumWidth: Int
    private let framesPerSecond: Int
    private let bitrate: UInt32
    private let logger: Logger
    private let server: VideoTCPServer
    private let lock = NSLock()
    private var state = PipelineState()

    init(
        host: String,
        port: UInt16,
        bonjourName: String?,
        authToken: String?,
        displayID: UInt32?,
        maximumWidth: Int,
        framesPerSecond: Int,
        bitrate: UInt32,
        logger: Logger
    ) throws {
        self.displayID = displayID
        self.maximumWidth = maximumWidth
        self.framesPerSecond = framesPerSecond
        self.bitrate = bitrate
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

    func start() throws {
        try server.start()
    }

    func stop() async {
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
        _ = await lifecycleTask?.result
        await stopPipeline()
    }

    func snapshot() -> VideoTCPServerSnapshot {
        server.snapshot()
    }

    func videoServerViewerConnected(_ sessionID: VideoViewerSessionID) {
        let generation = UUID()
        let previousTask = lock.withLock { () -> Task<Void, Never>? in
            let previous = state.lifecycleTask
            state.generation = generation
            state.viewerConnected = true
            state.viewerSessionID = sessionID
            return previous
        }
        let task = Task { [weak self] in
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

    func videoServerViewerDisconnected(_ sessionID: VideoViewerSessionID) {
        schedulePipelineStop(for: sessionID)
    }

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

        let source = ScreenVideoCaptureSource(
            displayID: displayID,
            maximumWidth: maximumWidth,
            framesPerSecond: framesPerSecond,
            consumer: self,
            logger: logger
        )
        let shouldStart = lock.withLock { () -> Bool in
            guard state.generation == generation,
                  state.viewerConnected,
                  state.viewerSessionID == sessionID else {
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
                await stopSource(source, context: "after viewer disconnect")
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
                await stopSource(source, context: "after stale encoder startup")
                encoder.finish()
            }
        } catch {
            await stopSource(source, context: "after pipeline failure")
            logger.error("Screen video pipeline failed: \(error.localizedDescription)")
            let failedSessionID = lock.withLock { () -> VideoViewerSessionID? in
                guard state.generation == generation,
                      state.viewerSessionID == sessionID else {
                    return nil
                }
                state.source = nil
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
        let task = Task { [weak self] in
            _ = await transition.previousTask?.result
            await self?.stopPipeline()
        }
        lock.withLock {
            if state.generation == generation {
                state.lifecycleTask = task
            } else {
                task.cancel()
            }
        }
    }

    private func stopPipeline() async {
        let stopped = lock.withLock { () -> (
            ScreenVideoCaptureSource?,
            H264ScreenVideoEncoder?,
            ScreenVideoFrameReservation?
        ) in
            let values = (state.source, state.encoder, state.pendingReservation)
            state.source = nil
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
            await stopSource(source, context: "during pipeline teardown")
        }
        stopped.1?.finish()
    }

    private func stopSource(_ source: ScreenVideoCaptureSource, context: String) async {
        do {
            try await source.stop()
        } catch {
            logger.error(
                "Could not stop screen video capture \(context): \(error.localizedDescription)"
            )
        }
    }

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
