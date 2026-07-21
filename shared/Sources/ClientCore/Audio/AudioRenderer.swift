import AVFoundation
import Foundation
import Streaming
import Utilities

/// Owns the `AVAudioEngine` graph that pulls decoded PCM from a frame provider.
///
/// All graph mutations are serialized by an internal lock so interruption recovery can pause,
/// rebuild, or stop the renderer from a different callback without racing the render lifecycle.
public final class AudioRenderer {
    private var engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode
    private let format: AVAudioFormat
    private let renderBlock: AVAudioSourceNodeRenderBlock
    private let lock = NSLock()
    private var attached = false
    private var running = false

    /// Creates a renderer whose hardware-facing format matches the negotiated stream header.
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

    /// Attaches the graph if needed and starts pulling samples from the provider.
    public func start() throws {
        try lock.withLock {
            try startLocked()
        }
    }

    /// Pauses playback while retaining the graph for a fast resume.
    public func pause() {
        lock.withLock {
            guard running else { return }
            engine.pause()
            running = false
        }
    }

    /// Rebuilds and starts the graph after a route or media-services interruption.
    public func restart() throws {
        try lock.withLock {
            guard attached else { return }
            rebuildGraphLocked()
            try startLocked()
        }
    }

    /// Stops playback and detaches the source node.
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
    /// Whether the audio engine is currently rendering.
    var isRunning: Bool {
        lock.withLock {
            running
        }
    }

    /// A stable diagnostic description of the renderer lifecycle.
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

/// Failures encountered while constructing the audio output graph.
public enum AudioRendererError: LocalizedError {
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "Unsupported audio output format"
        }
    }
}
