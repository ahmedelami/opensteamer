@preconcurrency import LiveKitWebRTC
#if os(macOS)
import MacWebRTCAudioDeviceShim
#endif
import AVFoundation
import CoreMedia
import Foundation

/// A remote WebRTC audio track with an explicit lifetime, mute gate, and decoded-PCM sink API.
public final class WebRTCRemoteAudioTrack: @unchecked Sendable {
    private let nativeTrack: LKRTCAudioTrack
    public let trackID: String

    init(_ nativeTrack: LKRTCAudioTrack) {
        self.nativeTrack = nativeTrack
        trackID = nativeTrack.trackId as String
    }

    public var isEnabled: Bool {
        nativeTrack.isEnabled
    }

    public func setEnabled(_ enabled: Bool) {
        nativeTrack.isEnabled = enabled
    }

    func wrapsSameNativeTrack(as other: WebRTCRemoteAudioTrack) -> Bool {
        nativeTrack === other.nativeTrack
    }

    #if DEBUG
    func addRendererForTesting(_ renderer: WebRTCAudioPCMRenderer) {
        nativeTrack.add(renderer)
    }

    func removeRendererForTesting(_ renderer: WebRTCAudioPCMRenderer) {
        nativeTrack.remove(renderer)
    }
    #endif
}

#if DEBUG
/// Passive test tap only. Production iOS playout has one custom RemoteIO audio device and no
/// decoded-PCM renderer, AVAudioEngine, PCM copy, or application ring buffer.
final class WebRTCAudioPCMRenderer: NSObject, LKRTCAudioRenderer, @unchecked Sendable {
    private let handler: @Sendable (AVAudioPCMBuffer) -> Void

    init(handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.handler = handler
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        handler(pcmBuffer)
    }
}
#endif

/// Feeds ScreenCaptureKit PCM into WebRTC's input-only audio device.
///
/// The production custom device follows ScreenCaptureKit's source clock: each converted hardware
/// callback is synchronously delivered on this one serial queue with its full arbitrary frame
/// count. WebRTC's native FineAudioBuffer owns 10 ms splitting/accumulation; there is no app-side
/// recording timer, ring, resampler, jitter buffer, or synthetic silence.
public final class MacExternalAudioCapturer: NSObject, @unchecked Sendable {
    #if os(macOS)
    private static let capturedChannelCount: AVAudioChannelCount = 2

    private let audioDeviceModule: LKRTCAudioDeviceModule?
    private let stereoAudioDevice: ASMacStereoAudioDevice?
    private let queue = DispatchQueue(label: "AudioStreamer.WebRTC.ExternalAudio")
    private let queueKey = DispatchSpecificKey<Void>()
    private let captureEpochLock = NSLock()
    private var captureEpoch: UInt64 = 0
    private var playerNode = AVAudioPlayerNode()
    private var playerMixerNode = AVAudioMixerNode()

    // LiveKit's AudioEngine observer contract forbids retaining the engine; ADM owns its lifetime.
    private weak var configuredEngine: AVAudioEngine?
    private var playerIsAttached = false
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var isEnabled = false
    private var playoutState = AudioPlayoutQueueState()
    private var sourceTimelineState = AudioCaptureTimelineState()
    #if DEBUG
    private var receivedBufferCount = 0
    private var scheduledBufferCount = 0
    private var disabledDropCount = 0
    private var graphNotReadyDropCount = 0
    private var conversionDropCount = 0
    private var sampleBufferImportDropCount = 0
    private var lastSampleBufferImportStatus: OSStatus?
    private var inputConfigurationCount = 0
    private var admInputCallbackCount = 0
    private var admInputSampleRate: Double?
    private var admInputChannelCount: Int?
    private var admInputCommonFormat: AVAudioCommonFormat?
    private var admInputIsInterleaved: Bool?
    #endif

    /// Supplies at most the number of PCM frames requested by `AVAudioConverter`, retaining any
    /// unconsumed tail for its next input request.
    private final class ConversionInput: @unchecked Sendable {
        private let lock = NSLock()
        private let sourceBuffer: AVAudioPCMBuffer
        private var nextFrame: AVAudioFramePosition = 0
        private var failed = false

        init(_ buffer: AVAudioPCMBuffer) {
            sourceBuffer = buffer
        }

        var consumedFrameCount: AVAudioFramePosition {
            lock.lock()
            defer { lock.unlock() }
            return nextFrame
        }

        var hasRemainingFrames: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !failed
                && nextFrame < AVAudioFramePosition(sourceBuffer.frameLength)
        }

        var didFail: Bool {
            lock.lock()
            defer { lock.unlock() }
            return failed
        }

        func take(
            requestedPacketCount: AVAudioPacketCount,
            status: UnsafeMutablePointer<AVAudioConverterInputStatus>
        ) -> AVAudioBuffer? {
            lock.lock()
            defer { lock.unlock() }

            guard !failed, requestedPacketCount > 0 else {
                status.pointee = .noDataNow
                return nil
            }

            let sourceFrameCount = AVAudioFramePosition(sourceBuffer.frameLength)
            let remainingFrames = sourceFrameCount - nextFrame
            guard remainingFrames > 0 else {
                // Each ScreenCaptureKit buffer is one temporary part of a continuous stream.
                // `noDataNow` preserves the reused converter's state for the following buffer.
                status.pointee = .noDataNow
                return nil
            }

            let requestedFrames = min(
                remainingFrames,
                AVAudioFramePosition(requestedPacketCount)
            )
            guard requestedFrames > 0,
                  requestedFrames <= AVAudioFramePosition(UInt32.max) else {
                failed = true
                status.pointee = .noDataNow
                return nil
            }

            let suppliedBuffer: AVAudioPCMBuffer?
            if nextFrame == 0, requestedFrames == sourceFrameCount {
                suppliedBuffer = sourceBuffer
            } else {
                suppliedBuffer = Self.copyFrames(
                    from: sourceBuffer,
                    startingAt: nextFrame,
                    frameCount: AVAudioFrameCount(requestedFrames)
                )
            }
            guard let suppliedBuffer else {
                failed = true
                status.pointee = .noDataNow
                return nil
            }

            nextFrame += requestedFrames
            status.pointee = .haveData
            return suppliedBuffer
        }

        private static func copyFrames(
            from sourceBuffer: AVAudioPCMBuffer,
            startingAt startFrame: AVAudioFramePosition,
            frameCount: AVAudioFrameCount
        ) -> AVAudioPCMBuffer? {
            let sourceFrameCount = AVAudioFramePosition(sourceBuffer.frameLength)
            guard startFrame >= 0,
                  frameCount > 0,
                  startFrame + AVAudioFramePosition(frameCount) <= sourceFrameCount,
                  let copiedBuffer = AVAudioPCMBuffer(
                      pcmFormat: sourceBuffer.format,
                      frameCapacity: frameCount
                  ) else {
                return nil
            }

            copiedBuffer.frameLength = frameCount

            let bytesPerFrame = Int(
                sourceBuffer.format.streamDescription.pointee.mBytesPerFrame
            )
            guard bytesPerFrame > 0 else { return nil }

            let sourceByteOffset = Int(startFrame) * bytesPerFrame
            let byteCount = Int(frameCount) * bytesPerFrame
            let sourceAudioBufferList = UnsafeMutablePointer<AudioBufferList>(
                mutating: sourceBuffer.audioBufferList
            )
            let sourceBuffers = UnsafeMutableAudioBufferListPointer(
                sourceAudioBufferList
            )
            let destinationBuffers = UnsafeMutableAudioBufferListPointer(
                copiedBuffer.mutableAudioBufferList
            )
            guard sourceBuffers.count == destinationBuffers.count else {
                return nil
            }

            for index in 0..<sourceBuffers.count {
                let sourceAudioBuffer = sourceBuffers[index]
                let destinationAudioBuffer = destinationBuffers[index]
                guard sourceByteOffset + byteCount
                        <= Int(sourceAudioBuffer.mDataByteSize),
                      byteCount <= Int(destinationAudioBuffer.mDataByteSize),
                      let sourceData = sourceAudioBuffer.mData,
                      let destinationData = destinationAudioBuffer.mData else {
                    return nil
                }
                memcpy(
                    destinationData,
                    sourceData.advanced(by: sourceByteOffset),
                    byteCount
                )
            }

            return copiedBuffer
        }
    }

    init(audioDeviceModule: LKRTCAudioDeviceModule) {
        self.audioDeviceModule = audioDeviceModule
        stereoAudioDevice = nil
        super.init()
        queue.setSpecific(key: queueKey, value: ())
        audioDeviceModule.observer = self
    }

    /// Production Mac-host path. Unlike the legacy AudioEngine ADM bridge, this device requests
    /// two recording channels from WebRTC and accepts only 48 kHz interleaved Int16 stereo PCM.
    /// The device is input-only and never opens a physical microphone.
    init?(stereoAudioDevice: ASMacStereoAudioDevice) {
        guard let stereoFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: Self.capturedChannelCount,
            interleaved: true
        ) else {
            return nil
        }
        audioDeviceModule = nil
        self.stereoAudioDevice = stereoAudioDevice
        super.init()
        queue.setSpecific(key: queueKey, value: ())
        targetFormat = stereoFormat
    }

    deinit {
        audioDeviceModule?.observer = nil
        syncOnQueue {
            tearDownPlayer(detach: true)
        }
    }

    /// Accepts one ScreenCaptureKit audio sample buffer. Conversion and native delivery are
    /// synchronously serialized on the source queue: a slow downstream callback backpressures this
    /// capture callback instead of accumulating an unbounded hidden FIFO and drifting from live.
    public func capture(sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else {
            return
        }
        let epoch = captureEpochLock.withLock { captureEpoch }
        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sourceFrameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let sourceSampleRate = CMSampleBufferGetFormatDescription(sampleBuffer).map {
            AVAudioFormat(cmAudioFormatDescription: $0).sampleRate
        }
        let importedPCM = Self.makePCMBuffer(from: sampleBuffer)
        guard let pcmBuffer = importedPCM.buffer else {
            syncOnQueue {
                guard captureEpochLock.withLock({ captureEpoch == epoch }) else {
                    return
                }
                if let sourceSampleRate {
                    recordSourceTimeline(
                        presentationTimeStamp: sourcePTS,
                        frameCount: sourceFrameCount,
                        sampleRate: sourceSampleRate
                    )
                }
                #if DEBUG
                sampleBufferImportDropCount += 1
                lastSampleBufferImportStatus = importedPCM.status
                #endif
            }
            return
        }

        syncOnQueue {
            guard captureEpochLock.withLock({ captureEpoch == epoch }) else {
                return
            }
            recordSourceTimeline(
                presentationTimeStamp: sourcePTS,
                frameCount: sourceFrameCount,
                sampleRate: pcmBuffer.format.sampleRate
            )
            schedule(pcmBuffer)
        }
    }

    /// Drops all queued PCM and resets conversion state.
    public func reset() {
        syncOnQueue {
            resetScheduledAudio()
        }
    }

    /// Opens the device's generation gate only after the peer has proved the live sender APM is
    /// raw. A later native StartRecording invalidates this approval automatically.
    func approveCurrentRecordingGeneration() -> Bool {
        syncOnQueue {
            stereoAudioDevice?.approveCurrentRecordingGeneration() ?? true
        }
    }

    func setEnabled(_ enabled: Bool) {
        syncOnQueue {
            guard isEnabled != enabled else {
                if !enabled {
                    stereoAudioDevice?.revokeRecordingAdmission()
                    resetPlayerAndConverter()
                }
                return
            }
            invalidatePendingCaptures()
            isEnabled = enabled
            playoutState.setEnabled(
                enabled,
                renderedFrame: enabled ? nil : currentRenderedFrame()
            )
            if enabled {
                sourceTimelineState.resetBaseline()
            } else {
                stereoAudioDevice?.revokeRecordingAdmission()
                resetPlayerAndConverter()
            }
        }
    }

    private func schedule(_ sourceBuffer: AVAudioPCMBuffer) {
        #if DEBUG
        receivedBufferCount += 1
        #endif
        guard isEnabled else {
            #if DEBUG
            disabledDropCount += 1
            #endif
            return
        }
        if let stereoAudioDevice {
            schedule(sourceBuffer, on: stereoAudioDevice)
            return
        }
        guard playerIsReady, let targetFormat else {
            #if DEBUG
            graphNotReadyDropCount += 1
            #endif
            return
        }
        let maximumFrameCount = AVAudioFrameCount(
            AudioPlayoutQueueState.maximumQueuedFrames
        )
        guard let buffers = convertedBuffers(
            sourceBuffer,
            to: targetFormat,
            maximumFrameCount: maximumFrameCount
        ), !buffers.isEmpty else {
            #if DEBUG
            conversionDropCount += 1
            #endif
            return
        }

        let incomingFrames = buffers.reduce(Int64(0)) {
            $0 + Int64($1.frameLength)
        }
        guard incomingFrames > 0,
              incomingFrames <= AudioPlayoutQueueState.maximumQueuedFrames else {
            return
        }

        let decision = playoutState.enqueue(
            frameCount: incomingFrames,
            renderedFrame: currentRenderedFrame()
        )
        if decision.shouldResetPlayer {
            resetPlayerForRebuffering()
        }
        guard decision.accepted,
              let scheduleStartFrame = decision.scheduleStartFrame else {
            return
        }
        #if DEBUG
        scheduledBufferCount += 1
        #endif

        let generation = playoutState.generation
        var bufferEndFrame = scheduleStartFrame
        for buffer in buffers {
            bufferEndFrame += Int64(buffer.frameLength)
            let scheduledBufferEndFrame = bufferEndFrame
            playerNode.scheduleBuffer(
                buffer,
                at: nil,
                options: [],
                // The WebRTC ADM pulls this graph in AVAudioEngine manual-rendering mode.
                // There is no hardware playback sink, so `.dataPlayedBack` never fires;
                // `.dataRendered` marks the point at which the ADM actually consumed PCM.
                completionCallbackType: .dataRendered
            ) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    if playoutState.completeBuffer(
                        endingAt: scheduledBufferEndFrame,
                        generation: generation
                    ) == .rebuffer {
                        resetPlayerForRebuffering()
                    }
                }
            }
        }

        if decision.shouldStartPlayback {
            playerNode.play()
        }
    }

    private func schedule(
        _ sourceBuffer: AVAudioPCMBuffer,
        on stereoAudioDevice: ASMacStereoAudioDevice
    ) {
        guard playerIsReady, let targetFormat else {
            #if DEBUG
            graphNotReadyDropCount += 1
            #endif
            return
        }
        let maximumFrameCount = AVAudioFrameCount(
            AudioPlayoutQueueState.maximumQueuedFrames
        )
        guard let buffers = convertedBuffers(
            sourceBuffer,
            to: targetFormat,
            maximumFrameCount: maximumFrameCount
        ), !buffers.isEmpty else {
            #if DEBUG
            conversionDropCount += 1
            #endif
            return
        }

        for buffer in buffers {
            guard buffer.format.sampleRate == 48_000,
                  buffer.format.channelCount == Self.capturedChannelCount,
                  buffer.format.commonFormat == .pcmFormatInt16,
                  buffer.format.isInterleaved,
                  buffer.frameLength > 0 else {
                #if DEBUG
                conversionDropCount += 1
                #endif
                return
            }
            let audioBuffers = UnsafeMutableAudioBufferListPointer(
                buffer.mutableAudioBufferList
            )
            let frameCount = Int(buffer.frameLength)
            let requiredByteCount = frameCount
                * Int(Self.capturedChannelCount)
                * MemoryLayout<Int16>.size
            guard audioBuffers.count == 1,
                  audioBuffers[0].mNumberChannels == Self.capturedChannelCount,
                  Int(audioBuffers[0].mDataByteSize) >= requiredByteCount,
                  let data = audioBuffers[0].mData else {
                #if DEBUG
                conversionDropCount += 1
                #endif
                return
            }
            let accepted = stereoAudioDevice.deliverInterleavedStereoInt16(
                data.assumingMemoryBound(to: Int16.self),
                frameCount: UInt(frameCount)
            )
            guard accepted else {
                #if DEBUG
                conversionDropCount += 1
                #endif
                return
            }
            #if DEBUG
            scheduledBufferCount += 1
            #endif
        }
    }

    private func convertedBuffers(
        _ sourceBuffer: AVAudioPCMBuffer,
        to targetFormat: AVAudioFormat,
        maximumFrameCount: AVAudioFrameCount
    ) -> [AVAudioPCMBuffer]? {
        guard maximumFrameCount > 0 else { return nil }

        if sourceBuffer.format == targetFormat {
            guard sourceBuffer.frameLength <= maximumFrameCount else {
                return nil
            }
            return [sourceBuffer]
        }

        if converter == nil
            || converterSourceFormat != sourceBuffer.format
            || converter?.outputFormat != targetFormat {
            converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat)
            // This is a continuous live stream, not an offline file. Avoid adding a priming
            // delay every time ScreenCaptureKit changes format or capture is re-authorized.
            converter?.primeMethod = .none
            converterSourceFormat = sourceBuffer.format
        }
        guard let converter else { return nil }

        let input = ConversionInput(sourceBuffer)
        var outputs: [AVAudioPCMBuffer] = []
        var producedFrames: AVAudioFrameCount = 0

        while true {
            let outputCapacity: AVAudioFrameCount
            if producedFrames < maximumFrameCount {
                outputCapacity = maximumFrameCount - producedFrames
            } else {
                // Probe once beyond the bound. Any further converted frame means this entire
                // source buffer exceeds the bounded queue and must be dropped, not truncated.
                outputCapacity = 1
            }

            guard let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputCapacity
            ) else {
                converter.reset()
                return nil
            }

            let consumedBefore = input.consumedFrameCount
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) {
                requestedPacketCount, inputStatus in
                input.take(
                    requestedPacketCount: requestedPacketCount,
                    status: inputStatus
                )
            }
            let consumedAfter = input.consumedFrameCount

            guard status != .error,
                  conversionError == nil,
                  !input.didFail else {
                converter.reset()
                return nil
            }

            let outputFrameCount = output.frameLength
            if outputFrameCount > 0 {
                guard outputFrameCount <= maximumFrameCount - producedFrames else {
                    converter.reset()
                    return nil
                }
                outputs.append(output)
                producedFrames += outputFrameCount
            }

            if outputFrameCount == 0, consumedAfter == consumedBefore {
                guard !input.hasRemainingFrames else {
                    converter.reset()
                    return nil
                }
                break
            }
        }

        guard !outputs.isEmpty else {
            converter.reset()
            return nil
        }
        return outputs
    }

    private func configureInput(
        engine: AVAudioEngine,
        destination: AVAudioNode,
        format: AVAudioFormat
    ) -> Int {
        // Keep both captured channels through PCM conversion. AVAudioConverter's implicit
        // stereo-to-mono mapping selects channel zero on this path, so AVAudioMixerNode performs
        // the actual downmix before the fixed mono Int16 ADM destination.
        guard let playerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: Self.capturedChannelCount,
            interleaved: false
        ) else {
            return -1
        }
        syncOnQueue {
            #if DEBUG
            inputConfigurationCount += 1
            #endif
            if configuredEngine !== engine {
                tearDownPlayer(detach: true)
                playerNode = AVAudioPlayerNode()
                playerMixerNode = AVAudioMixerNode()
                engine.attach(playerNode)
                engine.attach(playerMixerNode)
                playerIsAttached = true
                configuredEngine = engine
            } else if playerIsAttached {
                resetScheduledAudio()
                engine.disconnectNodeOutput(playerNode)
                engine.disconnectNodeOutput(playerMixerNode)
            }

            engine.connect(playerNode, to: playerMixerNode, format: playerFormat)
            engine.connect(playerMixerNode, to: destination, format: format)
            // AVAudioMixerNode uses an equal-power stereo fold-down. Applying another -3 dB
            // makes the effective matrix (L + R) / 2 and prevents correlated stereo clipping.
            playerMixerNode.outputVolume = Float(1.0 / sqrt(2.0))
            targetFormat = playerFormat
            converter = nil
            converterSourceFormat = nil
            playoutState.resetForLifecycle()
        }
        // The pinned AudioEngine ADM callback is OSStatus-style: zero means the custom graph was
        // installed successfully (the same contract used by LiveKit's PlayerNodeHook tests).
        return 0
    }

    #if DEBUG
    func diagnosticsForTesting() -> MacExternalAudioCapturerDiagnostics {
        syncOnQueue {
            let device = stereoAudioDevice?.diagnostics
            return MacExternalAudioCapturerDiagnostics(
                isEnabled: isEnabled,
                usesCustomStereoDevice: stereoAudioDevice != nil,
                hasConfiguredEngine: device?.initialized == true || configuredEngine != nil,
                engineIsRunning: device?.recording == true || configuredEngine?.isRunning == true,
                playerIsAttached: playerIsAttached,
                playerIsReady: playerIsReady,
                playerIsPlaying: device?.recording == true || playerNode.isPlaying,
                targetSampleRate: targetFormat?.sampleRate,
                targetChannelCount: targetFormat.map { Int($0.channelCount) },
                inputConfigurationCount: stereoAudioDevice == nil ? inputConfigurationCount : 1,
                admInputCallbackCount: device.map { Int(clamping: $0.deliveryCallbackCount) }
                    ?? admInputCallbackCount,
                admInputSampleRate: stereoAudioDevice == nil ? admInputSampleRate : 48_000,
                admInputChannelCount: stereoAudioDevice == nil ? admInputChannelCount : 2,
                admInputCommonFormat: stereoAudioDevice == nil
                    ? admInputCommonFormat
                    : .pcmFormatInt16,
                admInputIsInterleaved: stereoAudioDevice == nil
                    ? admInputIsInterleaved
                    : true,
                customDeviceRecording: device?.recording ?? false,
                customDeviceDeliveredFrames: device.map {
                    Int64(clamping: $0.deliveredFrameCount)
                } ?? 0,
                customDeviceRejectedFrames: device.map {
                    Int64(clamping: $0.rejectedFrameCount)
                } ?? 0,
                customDeviceDeliveryFailures: device.map {
                    Int(clamping: $0.deliveryFailureCount)
                } ?? 0,
                customDeviceNativeDeliveryErrors: device.map {
                    Int(clamping: $0.nativeDeliveryErrorCount)
                } ?? 0,
                customDeviceRenderInvocations: device.map {
                    Int64(clamping: $0.renderInvocationCount)
                } ?? 0,
                customDeviceRenderCopiedFrames: device.map {
                    Int64(clamping: $0.renderCopiedFrameCount)
                } ?? 0,
                customDeviceRenderCopiedSampleElements: device.map {
                    Int64(clamping: $0.renderCopiedSampleElementCount)
                } ?? 0,
                customDeviceRenderNotInvoked: device.map {
                    Int(clamping: $0.renderNotInvokedCount)
                } ?? 0,
                customDeviceRenderMultipleInvocations: device.map {
                    Int(clamping: $0.renderMultipleInvocationCount)
                } ?? 0,
                customDeviceRenderValidationFailures: device.map {
                    Int(clamping: $0.renderValidationFailureCount)
                } ?? 0,
                customDevicePrefilledInputDeliveries: device.map {
                    Int(clamping: $0.prefilledInputDataDeliveryCount)
                } ?? 0,
                customDeviceTimestampResets: device.map {
                    Int(clamping: $0.timestampResetCount)
                } ?? 0,
                customDeviceThreadChanges: device.map {
                    Int(clamping: $0.deliveryThreadChangeCount)
                } ?? 0,
                customDeviceRecordingGeneration: device.map {
                    Int64(clamping: $0.recordingGeneration)
                } ?? 0,
                customDeviceApprovedRecordingGeneration: device.map {
                    Int64(clamping: $0.approvedRecordingGeneration)
                } ?? 0,
                customDeviceAdmissionBlockedFrames: device.map {
                    Int64(clamping: $0.admissionBlockedFrameCount)
                } ?? 0,
                receivedBufferCount: receivedBufferCount,
                scheduledBufferCount: scheduledBufferCount,
                disabledDropCount: disabledDropCount,
                graphNotReadyDropCount: graphNotReadyDropCount,
                conversionDropCount: conversionDropCount,
                sampleBufferImportDropCount: sampleBufferImportDropCount,
                lastSampleBufferImportStatus: lastSampleBufferImportStatus,
                runtime: runtimeDiagnosticsLocked()
            )
        }
    }
    #endif

    private func resetScheduledAudio() {
        invalidatePendingCaptures()
        playoutState.resetForLifecycle(renderedFrame: currentRenderedFrame())
        sourceTimelineState.resetBaseline()
        resetPlayerAndConverter()
    }

    private func resetPlayerAndConverter() {
        converter?.reset()
        if stereoAudioDevice != nil {
            return
        }
        playerNode.stop()
        playerNode.reset()
    }

    private func resetPlayerForRebuffering() {
        playerNode.stop()
        playerNode.reset()
    }

    private func currentRenderedFrame() -> Int64? {
        guard playoutState.phase == .playing else {
            return nil
        }
        return Self.renderedSampleTime(from: playerNode.lastRenderTime) { [playerNode] in
            playerNode.playerTime(forNodeTime: $0)
        }
    }

    static func renderedSampleTime(
        from nodeTime: AVAudioTime?,
        resolvingPlayerTime: (AVAudioTime) -> AVAudioTime?
    ) -> Int64? {
        guard let nodeTime,
              nodeTime.isSampleTimeValid || nodeTime.isHostTimeValid,
              let playerTime = resolvingPlayerTime(nodeTime),
              playerTime.isSampleTimeValid,
              playerTime.sampleTime >= 0 else {
            return nil
        }
        return playerTime.sampleTime
    }

    private func invalidatePendingCaptures() {
        captureEpochLock.withLock { captureEpoch &+= 1 }
    }

    private func recordSourceTimeline(
        presentationTimeStamp: CMTime,
        frameCount: Int,
        sampleRate: Double
    ) {
        sourceTimelineState.observe(
            presentationTimeStamp: presentationTimeStamp,
            frameCount: frameCount,
            sampleRate: sampleRate
        )
    }

    public func runtimeDiagnostics() -> MacExternalAudioCapturerRuntimeDiagnostics {
        syncOnQueue { runtimeDiagnosticsLocked() }
    }

    private func runtimeDiagnosticsLocked() -> MacExternalAudioCapturerRuntimeDiagnostics {
        if let stereoAudioDevice {
            let device = stereoAudioDevice.diagnostics
            let phase: String
            if !isEnabled {
                phase = "disabled"
            } else if device.recording {
                phase = "direct"
            } else {
                phase = "waiting"
            }
            return MacExternalAudioCapturerRuntimeDiagnostics(
                phase: phase,
                generation: playoutState.generation,
                queuedFrames: 0,
                queueHighWaterFrames: 0,
                underruns: 0,
                rebuffers: 0,
                overflowDrops: 0,
                overflowDroppedFrames: 0,
                lifecycleDiscardedFrames: Int64(clamping: device.rejectedFrameCount),
                staleCompletions: 0,
                sourceGaps: sourceTimelineState.gapCount,
                sourceOverlaps: sourceTimelineState.overlapCount,
                maximumSourceDiscontinuityFrames: sourceTimelineState.maximumDiscontinuityFrames
            )
        }
        let phase: String
        switch playoutState.phase {
        case .disabled:
            phase = "disabled"
        case .buffering:
            phase = "buffering"
        case .playing:
            phase = "playing"
        }
        return MacExternalAudioCapturerRuntimeDiagnostics(
            phase: phase,
            generation: playoutState.generation,
            queuedFrames: playoutState.queuedFrames,
            queueHighWaterFrames: playoutState.queueHighWaterFrames,
            underruns: playoutState.underrunCount,
            rebuffers: playoutState.rebufferCount,
            overflowDrops: playoutState.overflowDropCount,
            overflowDroppedFrames: playoutState.overflowDroppedFrames,
            lifecycleDiscardedFrames: playoutState.lifecycleDiscardedFrames,
            staleCompletions: playoutState.staleCompletionCount,
            sourceGaps: sourceTimelineState.gapCount,
            sourceOverlaps: sourceTimelineState.overlapCount,
            maximumSourceDiscontinuityFrames: sourceTimelineState.maximumDiscontinuityFrames
        )
    }

    private var playerIsReady: Bool {
        if let stereoAudioDevice {
            let diagnostics = stereoAudioDevice.diagnostics
            return diagnostics.initialized
                && targetFormat?.sampleRate == 48_000
                && targetFormat?.channelCount == Self.capturedChannelCount
                && targetFormat?.commonFormat == .pcmFormatInt16
                && targetFormat?.isInterleaved == true
        }
        return playerIsAttached
            && configuredEngine?.isRunning == true
            && playerNode.engine != nil
            && inputGraphIsConnected
            && targetFormat != nil
    }

    private var inputGraphIsConnected: Bool {
        guard let configuredEngine else { return false }
        return !configuredEngine.outputConnectionPoints(
            for: playerNode,
            outputBus: 0
        ).isEmpty && !configuredEngine.outputConnectionPoints(
            for: playerMixerNode,
            outputBus: 0
        ).isEmpty
    }

    private func tearDownPlayer(detach: Bool) {
        resetScheduledAudio()
        guard let engine = configuredEngine, playerIsAttached else {
            playerIsAttached = false
            configuredEngine = nil
            targetFormat = nil
            converter = nil
            converterSourceFormat = nil
            return
        }
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(playerMixerNode)
        if detach {
            engine.detach(playerNode)
            engine.detach(playerMixerNode)
            playerIsAttached = false
            configuredEngine = nil
        }
        targetFormat = nil
        converter = nil
        converterSourceFormat = nil
    }

    private func syncOnQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return operation()
        }
        return queue.sync(execute: operation)
    }

    private static func makePCMBuffer(
        from sampleBuffer: CMSampleBuffer
    ) -> (buffer: AVAudioPCMBuffer?, status: OSStatus?) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return (nil, nil)
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0,
              sampleCount <= Int(UInt32.max),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(sampleCount)
              ) else {
            return (nil, nil)
        }
        // AVAudioPCMBuffer exposes zero-sized AudioBuffer entries until frameLength is set. The
        // CoreMedia copy API requires a pre-populated list whose byte sizes describe capacity.
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(clamping: sampleCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return (nil, status) }
        return (buffer, status)
    }
    #else
    init(audioDeviceModule: LKRTCAudioDeviceModule) {
        super.init()
    }

    public func capture(sampleBuffer: CMSampleBuffer) {}
    public func reset() {}
    func approveCurrentRecordingGeneration() -> Bool { true }
    func setEnabled(_ enabled: Bool) {}
    #endif
}

#if os(macOS)
public struct MacExternalAudioCapturerRuntimeDiagnostics: Sendable {
    public let phase: String
    public let generation: UInt64
    public let queuedFrames: Int64
    public let queueHighWaterFrames: Int64
    public let underruns: Int
    public let rebuffers: Int
    public let overflowDrops: Int
    public let overflowDroppedFrames: Int64
    public let lifecycleDiscardedFrames: Int64
    public let staleCompletions: Int
    public let sourceGaps: Int
    public let sourceOverlaps: Int
    public let maximumSourceDiscontinuityFrames: Int64
}
#endif

#if DEBUG && os(macOS)
struct MacExternalAudioCapturerDiagnostics: CustomStringConvertible, Sendable {
    let isEnabled: Bool
    let usesCustomStereoDevice: Bool
    let hasConfiguredEngine: Bool
    let engineIsRunning: Bool
    let playerIsAttached: Bool
    let playerIsReady: Bool
    let playerIsPlaying: Bool
    let targetSampleRate: Double?
    let targetChannelCount: Int?
    let inputConfigurationCount: Int
    let admInputCallbackCount: Int
    let admInputSampleRate: Double?
    let admInputChannelCount: Int?
    let admInputCommonFormat: AVAudioCommonFormat?
    let admInputIsInterleaved: Bool?
    let customDeviceRecording: Bool
    let customDeviceDeliveredFrames: Int64
    let customDeviceRejectedFrames: Int64
    let customDeviceDeliveryFailures: Int
    let customDeviceNativeDeliveryErrors: Int
    let customDeviceRenderInvocations: Int64
    let customDeviceRenderCopiedFrames: Int64
    let customDeviceRenderCopiedSampleElements: Int64
    let customDeviceRenderNotInvoked: Int
    let customDeviceRenderMultipleInvocations: Int
    let customDeviceRenderValidationFailures: Int
    let customDevicePrefilledInputDeliveries: Int
    let customDeviceTimestampResets: Int
    let customDeviceThreadChanges: Int
    let customDeviceRecordingGeneration: Int64
    let customDeviceApprovedRecordingGeneration: Int64
    let customDeviceAdmissionBlockedFrames: Int64
    let receivedBufferCount: Int
    let scheduledBufferCount: Int
    let disabledDropCount: Int
    let graphNotReadyDropCount: Int
    let conversionDropCount: Int
    let sampleBufferImportDropCount: Int
    let lastSampleBufferImportStatus: OSStatus?
    let runtime: MacExternalAudioCapturerRuntimeDiagnostics

    var description: String {
        let sampleRate = targetSampleRate.map { String($0) } ?? "nil"
        let channels = targetChannelCount.map { String($0) } ?? "nil"
        let admSampleRate = admInputSampleRate.map { String($0) } ?? "nil"
        let admChannels = admInputChannelCount.map { String($0) } ?? "nil"
        let admCommonFormat = admInputCommonFormat.map { String($0.rawValue) } ?? "nil"
        let admInterleaved = admInputIsInterleaved.map { String($0) } ?? "nil"
        return [
            "enabled=\(isEnabled)",
            "customStereo=\(usesCustomStereoDevice)",
            "configured=\(hasConfiguredEngine)",
            "running=\(engineIsRunning)",
            "attached=\(playerIsAttached)",
            "ready=\(playerIsReady)",
            "playing=\(playerIsPlaying)",
            "format=\(sampleRate)/\(channels)ch",
            "admInput=\(admSampleRate)/\(admChannels)ch/common=\(admCommonFormat)/interleaved=\(admInterleaved)/callbacks=\(admInputCallbackCount)",
            "device(recording=\(customDeviceRecording),generation=\(customDeviceRecordingGeneration)/approved=\(customDeviceApprovedRecordingGeneration),delivered=\(customDeviceDeliveredFrames),rejected=\(customDeviceRejectedFrames),admissionBlocked=\(customDeviceAdmissionBlockedFrames),failures=\(customDeviceDeliveryFailures),nativeErrors=\(customDeviceNativeDeliveryErrors),render(invocations=\(customDeviceRenderInvocations),frames=\(customDeviceRenderCopiedFrames),elements=\(customDeviceRenderCopiedSampleElements),notInvoked=\(customDeviceRenderNotInvoked),multiple=\(customDeviceRenderMultipleInvocations),validation=\(customDeviceRenderValidationFailures),prefilled=\(customDevicePrefilledInputDeliveries)),timestampResets=\(customDeviceTimestampResets),threadChanges=\(customDeviceThreadChanges))",
            "configs=\(inputConfigurationCount)",
            "received=\(receivedBufferCount)",
            "scheduled=\(scheduledBufferCount)",
            "queue(phase=\(runtime.phase),frames=\(runtime.queuedFrames),high=\(runtime.queueHighWaterFrames),underruns=\(runtime.underruns),rebuffers=\(runtime.rebuffers),overflowDrops=\(runtime.overflowDrops))",
            "source(gaps=\(runtime.sourceGaps),overlaps=\(runtime.sourceOverlaps),maxFrames=\(runtime.maximumSourceDiscontinuityFrames))",
            "drops(disabled=\(disabledDropCount),graph=\(graphNotReadyDropCount),conversion=\(conversionDropCount),import=\(sampleBufferImportDropCount))",
            "importStatus=\(lastSampleBufferImportStatus.map { String($0) } ?? "nil")"
        ].joined(separator: " ")
    }
}
#endif

#if os(macOS)
extension MacExternalAudioCapturer: LKRTCAudioDeviceModuleDelegate {
    public func audioDeviceModule(
        _ audioDeviceModule: LKRTCAudioDeviceModule,
        didReceiveSpeechActivityEvent speechActivityEvent: LKRTCSpeechActivityEvent
    ) {}

    public func audioDeviceModule(
        _ audioDeviceModule: LKRTCAudioDeviceModule,
        didCreateEngine engine: AVAudioEngine
    ) -> Int {
        syncOnQueue {
            guard configuredEngine !== engine else { return }
            tearDownPlayer(detach: true)
            playerNode = AVAudioPlayerNode()
            playerMixerNode = AVAudioMixerNode()
            engine.attach(playerNode)
            engine.attach(playerMixerNode)
            playerIsAttached = true
            configuredEngine = engine
        }
        return 0
    }

    public func audioDeviceModule(
        _ audioDeviceModule: LKRTCAudioDeviceModule,
        willEnableEngine engine: AVAudioEngine,
        isPlayoutEnabled: Bool,
        isRecordingEnabled: Bool
    ) -> Int { 0 }

    public func audioDeviceModule(
        _ audioDeviceModule: LKRTCAudioDeviceModule,
        willStartEngine engine: AVAudioEngine,
        isPlayoutEnabled: Bool,
        isRecordingEnabled: Bool
    ) -> Int {
        // Player buffers are scheduled before `play()` after the engine is running.
        return 0
    }

    public func audioDeviceModule(
        _ audioDeviceModule: LKRTCAudioDeviceModule,
        didStopEngine engine: AVAudioEngine,
        isPlayoutEnabled: Bool,
        isRecordingEnabled: Bool
    ) -> Int {
        syncOnQueue {
            guard configuredEngine === engine else { return }
            resetScheduledAudio()
        }
        return 0
    }

    public func audioDeviceModule(
        _ audioDeviceModule: LKRTCAudioDeviceModule,
        didDisableEngine engine: AVAudioEngine,
        isPlayoutEnabled: Bool,
        isRecordingEnabled: Bool
    ) -> Int {
        syncOnQueue {
            guard configuredEngine === engine else { return }
            resetScheduledAudio()
        }
        return 0
    }

    public func audioDeviceModule(
        _ audioDeviceModule: LKRTCAudioDeviceModule,
        willReleaseEngine engine: AVAudioEngine
    ) -> Int {
        syncOnQueue {
            if configuredEngine === engine {
                tearDownPlayer(detach: true)
            }
        }
        return 0
    }

    public func audioDeviceModule(
        _ audioDeviceModule: LKRTCAudioDeviceModule,
        engine: AVAudioEngine,
        configureInputFromSource source: AVAudioNode?,
        toDestination destination: AVAudioNode,
        format: AVAudioFormat,
        context: [AnyHashable: Any]
    ) -> Int {
        syncOnQueue {
            #if DEBUG
            admInputCallbackCount += 1
            admInputSampleRate = format.sampleRate
            admInputChannelCount = Int(format.channelCount)
            admInputCommonFormat = format.commonFormat
            admInputIsInterleaved = format.isInterleaved
            #endif
        }
        // Manual rendering is the privacy boundary: no physical microphone source may enter the
        // legacy graph. Production hosts use the input-only custom stereo device above.
        guard source == nil,
              engine.isInManualRenderingMode,
              format.sampleRate == 48_000,
              format.channelCount == 1,
              format.commonFormat == .pcmFormatInt16,
              format.isInterleaved else {
            return -1
        }
        return configureInput(engine: engine, destination: destination, format: format)
    }

    public func audioDeviceModule(
        _ audioDeviceModule: LKRTCAudioDeviceModule,
        engine: AVAudioEngine,
        configureOutputFromSource source: AVAudioNode,
        toDestination destination: AVAudioNode?,
        format: AVAudioFormat,
        context: [AnyHashable: Any]
    ) -> Int {
        // This capturer replaces only input. Zero delegates playout graph construction back to
        // the ADM, avoiding a duplicate connection if host playout is enabled in the future.
        return 0
    }

    public func audioDeviceModuleDidUpdateDevices(
        _ audioDeviceModule: LKRTCAudioDeviceModule
    ) {}

}
#endif

#if os(iOS)
@MainActor
protocol WebRTCAudioSessionControlling: AnyObject {
    var isActive: Bool { get }
    var isAudioEnabled: Bool { get set }

    func prepareForManualAudio()
    func lockForConfiguration()
    func unlockForConfiguration()
    func configurePlayback(mode: AVAudioSession.Mode) throws
    func setActive(_ active: Bool) throws
}

@MainActor
private final class LiveKitWebRTCAudioSessionController: WebRTCAudioSessionControlling {
    private var session: LKRTCAudioSession { LKRTCAudioSession.sharedInstance() }

    var isActive: Bool { session.isActive }

    var isAudioEnabled: Bool {
        get { session.isAudioEnabled }
        set { session.isAudioEnabled = newValue }
    }

    func prepareForManualAudio() {
        session.useManualAudio = true
        session.ignoresPreferredAttributeConfigurationErrors = true
    }

    func lockForConfiguration() {
        session.lockForConfiguration()
    }

    func unlockForConfiguration() {
        session.unlockForConfiguration()
    }

    func configurePlayback(mode: AVAudioSession.Mode) throws {
        let configuration = WebRTCAudioPlaybackSession.playbackConfiguration(mode: mode)
        try session.setConfiguration(configuration)
        // Publish only a configuration that the native session actually accepted. A rejected
        // candidate must not poison WebRTC's process-wide default for later ADM initialization.
        LKRTCAudioSessionConfiguration.setWebRTC(configuration)
    }

    func setActive(_ active: Bool) throws {
        try session.setActive(active)
    }
}
#endif

/// Controls only WebRTC's manual global audio gate on iOS. The injected output-only audio device
/// is the sole owner of AVAudioSession configuration/activation and of the RemoteIO instance.
public enum WebRTCAudioPlaybackFailureStage: String, Sendable {
    case configuration
    case activation
}

public struct WebRTCAudioPlaybackSessionError: LocalizedError, Sendable {
    public let stage: WebRTCAudioPlaybackFailureStage
    public let underlyingDomain: String
    public let underlyingCode: Int
    public let attemptedMode: String
    public let compatibilityFallbackAttempted: Bool
    public let currentCategory: String
    public let currentMode: String
    public let currentCategoryOptions: UInt
    public let outputRoute: String
    public let secondaryAudioShouldBeSilenced: Bool
    public let otherAudioIsPlaying: Bool

    public var errorDescription: String? {
        let fallback = compatibilityFallbackAttempted ? "yes" : "no"
        return "WebRTC audio \(stage.rawValue) failed "
            + "(\(underlyingDomain) \(underlyingCode)); "
            + "attemptedMode=\(attemptedMode), fallback=\(fallback), "
            + "currentCategory=\(currentCategory), currentMode=\(currentMode), "
            + "currentOptions=\(currentCategoryOptions), route=\(outputRoute), "
            + "secondarySilenced=\(secondaryAudioShouldBeSilenced), "
            + "otherAudio=\(otherAudioIsPlaying)."
    }
}

@MainActor
public final class WebRTCAudioPlaybackSession {
    #if os(iOS)
    // Avoid constructing the process-wide WebRTC audio singleton merely because a SwiftUI
    // lifecycle object was initialized. Startup stays side-effect-free until audio is activated.
    private let sessionProvider: @MainActor () -> any WebRTCAudioSessionControlling
    private var providedSession: (any WebRTCAudioSessionControlling)?
    private var session: any WebRTCAudioSessionControlling {
        if let providedSession {
            return providedSession
        }
        let providedSession = sessionProvider()
        self.providedSession = providedSession
        return providedSession
    }
    #endif

    public init() {
        #if os(iOS)
        sessionProvider = { LiveKitWebRTCAudioSessionController() }
        #endif
    }

    #if os(iOS)
    init(session: any WebRTCAudioSessionControlling) {
        sessionProvider = { session }
    }
    #endif

    public func activate() throws {
        #if os(iOS)
        try configureAndActivate()
        #endif
    }

    public func recover() throws {
        #if os(iOS)
        try configureAndActivate()
        #endif
    }

    /// Places WebRTC in manual-audio mode while keeping its process-wide native audio gate
    /// closed. This is the only safe startup state while an iPhone cellular, FaceTime, or other
    /// CallKit call owns the final system route: do not activate or reconfigure AVAudioSession,
    /// and do not allow a queued RemoteIO rebuild to recreate call-quality playout.
    public func prepareManualAudioDisabled() {
        #if os(iOS)
        session.prepareForManualAudio()
        session.isAudioEnabled = false
        #endif
    }

    public func deactivate() {
        #if os(iOS)
        session.isAudioEnabled = false
        #endif
    }

    #if os(iOS)
    private func configureAndActivate() throws {
        session.prepareForManualAudio()
        // `isAudioEnabled == false` halts both incoming and outgoing native audio, including
        // custom RTCAudioDevice callbacks. Keep the gate open while the custom output device is
        // active; that device, not LKRTCAudioSession, owns category, mode, activation, and I/O.
        session.isAudioEnabled = true
    }

    static func playbackConfiguration(
        mode: AVAudioSession.Mode = .default
    ) -> LKRTCAudioSessionConfiguration {
        let configuration = LKRTCAudioSessionConfiguration()
        configuration.category = AVAudioSession.Category.playback.rawValue
        // Playback already supports AirPlay implicitly. Apple restricts the explicit
        // `allowAirPlay` option to `playAndRecord`; combining it with `playback` returns
        // `paramErr` (-50) on physical iPhones even though Simulator accepts it.
        configuration.categoryOptions = []
        // General Mac audio must not request MoviePlayback's route-dependent enhancement.
        // `.default` also avoids every voice/chat mode while retaining background playback.
        configuration.mode = mode.rawValue
        configuration.sampleRate = 48_000
        configuration.ioBufferDuration = 0.010
        // The injected output-only RemoteIO device keeps the two Opus channels independent.
        configuration.outputNumberOfChannels = 2
        return configuration
    }

    private static func sessionError(
        stage: WebRTCAudioPlaybackFailureStage,
        underlying error: Error,
        attemptedMode: AVAudioSession.Mode,
        compatibilityFallbackAttempted: Bool
    ) -> WebRTCAudioPlaybackSessionError {
        let underlying = error as NSError
        let nativeSession = AVAudioSession.sharedInstance()
        let route = nativeSession.currentRoute.outputs
            .map { $0.portType.rawValue }
            .joined(separator: ",")

        return WebRTCAudioPlaybackSessionError(
            stage: stage,
            underlyingDomain: underlying.domain,
            underlyingCode: underlying.code,
            attemptedMode: attemptedMode.rawValue,
            compatibilityFallbackAttempted: compatibilityFallbackAttempted,
            currentCategory: nativeSession.category.rawValue,
            currentMode: nativeSession.mode.rawValue,
            currentCategoryOptions: nativeSession.categoryOptions.rawValue,
            outputRoute: route.isEmpty ? "none" : route,
            secondaryAudioShouldBeSilenced: nativeSession.secondaryAudioShouldBeSilencedHint,
            otherAudioIsPlaying: nativeSession.isOtherAudioPlaying
        )
    }
    #endif
}
