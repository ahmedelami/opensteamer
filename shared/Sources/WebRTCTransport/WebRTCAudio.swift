@preconcurrency import LiveKitWebRTC
import AVFoundation
import CoreMedia
import Foundation

/// A remote WebRTC audio track. Native WebRTC renders enabled remote tracks through its
/// audio-device module; this wrapper gives the application an explicit lifetime and mute gate.
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
/// A native receive tap used by loopback tests to prove that encoded PCM traverses the custom
/// ADM graph, Opus sender, network peer, decoder, and remote track—not merely SDP negotiation.
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

/// Feeds ScreenCaptureKit PCM into WebRTC's AudioEngine input graph.
///
/// The player queue is deliberately bounded. If capture gets ahead of the audio engine, queued
/// buffers are discarded before the newest buffer is scheduled so latency cannot grow without
/// bound after a stall or route transition.
public final class MacExternalAudioCapturer: NSObject, @unchecked Sendable {
    #if os(macOS)
    private static let maximumQueuedDuration: TimeInterval = 0.120

    private let audioDeviceModule: LKRTCAudioDeviceModule
    private let queue = DispatchQueue(label: "AudioStreamer.WebRTC.ExternalAudio")
    private let queueKey = DispatchSpecificKey<Void>()
    private var playerNode = AVAudioPlayerNode()
    private var playerMixerNode = AVAudioMixerNode()

    // LiveKit's AudioEngine observer contract forbids retaining the engine; ADM owns its lifetime.
    private weak var configuredEngine: AVAudioEngine?
    private var playerIsAttached = false
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var isEnabled = false
    private var scheduledFrames: AVAudioFramePosition = 0
    private var schedulingGeneration: UInt64 = 0
    #if DEBUG
    private var receivedBufferCount = 0
    private var scheduledBufferCount = 0
    private var disabledDropCount = 0
    private var graphNotReadyDropCount = 0
    private var conversionDropCount = 0
    private var sampleBufferImportDropCount = 0
    private var lastSampleBufferImportStatus: OSStatus?
    private var inputConfigurationCount = 0
    #endif

    /// `AVAudioConverter` declares its input callback `@Sendable` even though it invokes it
    /// synchronously for this conversion. Keep the single-use mutable state behind a lock so the
    /// code remains correct (and warning-free) if that implementation detail changes.
    private final class ConversionInput: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: AVAudioPCMBuffer?

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func take(
            status: UnsafeMutablePointer<AVAudioConverterInputStatus>
        ) -> AVAudioBuffer? {
            lock.lock()
            defer { lock.unlock() }
            guard let buffer else {
                // This is one temporarily available chunk in a continuous PCM stream. EOS would
                // permanently drain the reused sample-rate converter; `noDataNow` preserves its
                // filter/priming state for the next ScreenCaptureKit buffer.
                status.pointee = .noDataNow
                return nil
            }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }

    init(audioDeviceModule: LKRTCAudioDeviceModule) {
        self.audioDeviceModule = audioDeviceModule
        super.init()
        queue.setSpecific(key: queueKey, value: ())
        audioDeviceModule.observer = self
    }

    deinit {
        audioDeviceModule.observer = nil
        syncOnQueue {
            tearDownPlayer(detach: true)
        }
    }

    /// Accepts one ScreenCaptureKit audio sample buffer. Invalid, unsupported, stale, or excess
    /// PCM is dropped; capture callbacks are never blocked on WebRTC playback.
    public func capture(sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else {
            return
        }
        let importedPCM = Self.makePCMBuffer(from: sampleBuffer)
        guard let pcmBuffer = importedPCM.buffer else {
            #if DEBUG
            queue.async { [weak self] in
                self?.sampleBufferImportDropCount += 1
                self?.lastSampleBufferImportStatus = importedPCM.status
            }
            #endif
            return
        }

        queue.async { [weak self] in
            self?.schedule(pcmBuffer)
        }
    }

    /// Drops all queued PCM and resets conversion state.
    public func reset() {
        syncOnQueue {
            resetScheduledAudio()
        }
    }

    func setEnabled(_ enabled: Bool) {
        syncOnQueue {
            guard isEnabled != enabled else {
                if !enabled { resetScheduledAudio() }
                return
            }
            isEnabled = enabled
            if !enabled {
                resetScheduledAudio()
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
        guard playerIsReady, let targetFormat else {
            #if DEBUG
            graphNotReadyDropCount += 1
            #endif
            return
        }
        guard let buffer = convertedBuffer(sourceBuffer, to: targetFormat) else {
            #if DEBUG
            conversionDropCount += 1
            #endif
            return
        }

        let maximumFrames = AVAudioFramePosition(
            (targetFormat.sampleRate * Self.maximumQueuedDuration).rounded(.up)
        )
        let incomingFrames = AVAudioFramePosition(buffer.frameLength)
        guard incomingFrames > 0, incomingFrames <= maximumFrames else { return }

        if scheduledFrames + incomingFrames > maximumFrames {
            resetScheduledAudio()
        }
        guard isEnabled else { return }
        scheduledFrames += incomingFrames
        #if DEBUG
        scheduledBufferCount += 1
        #endif
        let generation = schedulingGeneration
        playerNode.scheduleBuffer(
            buffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, generation == schedulingGeneration else { return }
                scheduledFrames = max(0, scheduledFrames - incomingFrames)
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func convertedBuffer(
        _ sourceBuffer: AVAudioPCMBuffer,
        to targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if sourceBuffer.format == targetFormat {
            return sourceBuffer
        }

        if converter == nil
            || converterSourceFormat != sourceBuffer.format
            || converter?.outputFormat != targetFormat {
            converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat)
            converterSourceFormat = sourceBuffer.format
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / sourceBuffer.format.sampleRate
        guard ratio.isFinite, ratio > 0 else { return nil }
        let capacity = AVAudioFrameCount(
            min(
                Double(UInt32.max),
                ceil(Double(sourceBuffer.frameLength) * ratio) + 32
            )
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            return nil
        }

        let input = ConversionInput(sourceBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) {
            _, inputStatus in
            input.take(status: inputStatus)
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else {
            converter.reset()
            return nil
        }
        return output
    }

    private func configureInput(
        engine: AVAudioEngine,
        destination: AVAudioNode,
        format: AVAudioFormat
    ) -> Int {
        // Match LiveKit's pinned PlayerNodeHook: AVAudioPlayerNode cannot render Int16, so a
        // Float32 edge feeds a mixer that converts to the ADM destination's exact format.
        guard let playerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: format.channelCount,
            interleaved: format.isInterleaved
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
            targetFormat = playerFormat
            converter = nil
            converterSourceFormat = nil
            scheduledFrames = 0
            schedulingGeneration &+= 1
        }
        // The pinned AudioEngine ADM callback is OSStatus-style: zero means the custom graph was
        // installed successfully (the same contract used by LiveKit's PlayerNodeHook tests).
        return 0
    }

    #if DEBUG
    func diagnosticsForTesting() -> MacExternalAudioCapturerDiagnostics {
        syncOnQueue {
            MacExternalAudioCapturerDiagnostics(
                isEnabled: isEnabled,
                hasConfiguredEngine: configuredEngine != nil,
                engineIsRunning: configuredEngine?.isRunning == true,
                playerIsAttached: playerIsAttached,
                playerIsReady: playerIsReady,
                playerIsPlaying: playerNode.isPlaying,
                targetSampleRate: targetFormat?.sampleRate,
                targetChannelCount: targetFormat.map { Int($0.channelCount) },
                inputConfigurationCount: inputConfigurationCount,
                receivedBufferCount: receivedBufferCount,
                scheduledBufferCount: scheduledBufferCount,
                disabledDropCount: disabledDropCount,
                graphNotReadyDropCount: graphNotReadyDropCount,
                conversionDropCount: conversionDropCount,
                sampleBufferImportDropCount: sampleBufferImportDropCount,
                lastSampleBufferImportStatus: lastSampleBufferImportStatus
            )
        }
    }
    #endif

    private func resetScheduledAudio() {
        schedulingGeneration &+= 1
        scheduledFrames = 0
        converter?.reset()
        playerNode.stop()
        playerNode.reset()
    }

    private var playerIsReady: Bool {
        playerIsAttached
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
    func setEnabled(_ enabled: Bool) {}
    #endif
}

#if DEBUG && os(macOS)
struct MacExternalAudioCapturerDiagnostics: CustomStringConvertible, Sendable {
    let isEnabled: Bool
    let hasConfiguredEngine: Bool
    let engineIsRunning: Bool
    let playerIsAttached: Bool
    let playerIsReady: Bool
    let playerIsPlaying: Bool
    let targetSampleRate: Double?
    let targetChannelCount: Int?
    let inputConfigurationCount: Int
    let receivedBufferCount: Int
    let scheduledBufferCount: Int
    let disabledDropCount: Int
    let graphNotReadyDropCount: Int
    let conversionDropCount: Int
    let sampleBufferImportDropCount: Int
    let lastSampleBufferImportStatus: OSStatus?

    var description: String {
        let sampleRate = targetSampleRate.map { String($0) } ?? "nil"
        let channels = targetChannelCount.map { String($0) } ?? "nil"
        return [
            "enabled=\(isEnabled)",
            "configured=\(hasConfiguredEngine)",
            "running=\(engineIsRunning)",
            "attached=\(playerIsAttached)",
            "ready=\(playerIsReady)",
            "playing=\(playerIsPlaying)",
            "format=\(sampleRate)/\(channels)ch",
            "configs=\(inputConfigurationCount)",
            "received=\(receivedBufferCount)",
            "scheduled=\(scheduledBufferCount)",
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
        // Manual rendering is the privacy boundary: no physical microphone source may enter the
        // graph, and the pinned ADM's render sink is fixed 48 kHz interleaved Int16 mono.
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

/// Coordinates WebRTC's receive-only audio unit with an iOS background-playback session.
@MainActor
public final class WebRTCAudioPlaybackSession {
    #if os(iOS)
    // Avoid constructing the process-wide WebRTC audio singleton merely because a SwiftUI
    // lifecycle object was initialized. Startup stays side-effect-free until audio is activated.
    private var session: LKRTCAudioSession { LKRTCAudioSession.sharedInstance() }
    private var localActivationCount = 0
    #endif

    public init() {}

    public func activate() throws {
        #if os(iOS)
        let configuration = Self.playbackConfiguration()
        LKRTCAudioSessionConfiguration.setWebRTC(configuration)
        session.useManualAudio = true
        session.ignoresPreferredAttributeConfigurationErrors = true
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try session.setConfiguration(configuration)
        if localActivationCount == 0 {
            try session.setActive(true)
            localActivationCount += 1
        }
        session.isAudioEnabled = true
        #endif
    }

    public func recover() throws {
        #if os(iOS)
        let configuration = Self.playbackConfiguration()
        LKRTCAudioSessionConfiguration.setWebRTC(configuration)
        session.useManualAudio = true
        session.ignoresPreferredAttributeConfigurationErrors = true
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try session.setConfiguration(configuration)
        if !session.isActive {
            try session.setActive(true)
            localActivationCount += 1
        }
        session.isAudioEnabled = true
        #endif
    }

    public func deactivate() {
        #if os(iOS)
        session.isAudioEnabled = false
        guard localActivationCount > 0 else { return }
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        while localActivationCount > 0 {
            do {
                try session.setActive(false)
                localActivationCount -= 1
            } catch {
                // Preserve the unbalanced count so a later deactivate can retry safely.
                break
            }
        }
        #endif
    }

    #if os(iOS)
    private static func playbackConfiguration() -> LKRTCAudioSessionConfiguration {
        let configuration = LKRTCAudioSessionConfiguration()
        configuration.category = AVAudioSession.Category.playback.rawValue
        configuration.categoryOptions = [.allowAirPlay, .mixWithOthers]
        configuration.mode = AVAudioSession.Mode.moviePlayback.rawValue
        configuration.sampleRate = 48_000
        configuration.ioBufferDuration = 0.010
        configuration.inputNumberOfChannels = 0
        // The pinned WebRTC audio-device module renders this Opus downlink as truthful mono.
        // Do not advertise a stereo session preference that the negotiated media cannot supply.
        configuration.outputNumberOfChannels = 1
        return configuration
    }
    #endif
}
