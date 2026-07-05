import AVFoundation
import Foundation
import Streaming
import Utilities

public final class AudioRenderer {
    private var engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode
    private let format: AVAudioFormat
    private let renderBlock: AVAudioSourceNodeRenderBlock
    private let lock = NSLock()
    private var attached = false
    private var running = false

    public init(header: PCMStreamHeader, provider: PCMFrameProvider) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(header.sampleRate),
            channels: AVAudioChannelCount(header.channels),
            interleaved: false
        ) else {
            throw AudioRendererError.unsupportedFormat
        }

        let renderBlock: AVAudioSourceNodeRenderBlock = { _, _, frameCount, audioBufferList in
            provider.render(frameCount: Int(frameCount), audioBufferList: audioBufferList)
            return noErr
        }
        self.format = format
        self.renderBlock = renderBlock
        self.sourceNode = AVAudioSourceNode(renderBlock: renderBlock)
    }

    public func start() throws {
        try lock.withLock {
            try startLocked()
        }
    }

    public func pause() {
        lock.withLock {
            guard running else { return }
            engine.pause()
            running = false
        }
    }

    public func restart() throws {
        try lock.withLock {
            guard attached else { return }
            rebuildGraphLocked()
            try startLocked()
        }
    }

    public func stop() {
        lock.withLock {
            guard attached || running else { return }
            engine.stop()
            if attached {
                engine.detach(sourceNode)
            }
            running = false
            attached = false
        }
    }
}

public extension AudioRenderer {
    var isRunning: Bool {
        lock.withLock {
            running
        }
    }

    var stateDescription: String {
        lock.withLock {
            if running {
                return "Running"
            }
            if attached {
                return "Paused"
            }
            return "Stopped"
        }
    }
}

private extension AudioRenderer {
    func startLocked() throws {
        if !attached {
            attachGraphLocked()
        }

        guard !running, !engine.isRunning else {
            running = engine.isRunning
            return
        }

        try engine.start()
        running = true
    }

    func attachGraphLocked() {
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.prepare()
        attached = true
    }

    func rebuildGraphLocked() {
        engine.stop()
        if attached {
            engine.detach(sourceNode)
        }
        engine = AVAudioEngine()
        sourceNode = AVAudioSourceNode(renderBlock: renderBlock)
        attached = false
        running = false
        attachGraphLocked()
    }
}

public enum AudioRendererError: LocalizedError {
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "Unsupported audio output format"
        }
    }
}
