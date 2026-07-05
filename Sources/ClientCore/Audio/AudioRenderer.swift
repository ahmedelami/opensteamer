import AVFoundation
import Foundation
import Streaming

public final class AudioRenderer {
    private let engine = AVAudioEngine()
    private let sourceNode: AVAudioSourceNode
    private let format: AVAudioFormat
    private var started = false

    public init(header: PCMStreamHeader, provider: PCMFrameProvider) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(header.sampleRate),
            channels: AVAudioChannelCount(header.channels),
            interleaved: false
        ) else {
            throw AudioRendererError.unsupportedFormat
        }

        self.format = format
        self.sourceNode = AVAudioSourceNode { _, _, frameCount, audioBufferList in
            provider.render(frameCount: Int(frameCount), audioBufferList: audioBufferList)
            return noErr
        }
    }

    public func start() throws {
        guard !started else { return }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        started = true
    }

    public func stop() {
        guard started else { return }
        engine.stop()
        engine.detach(sourceNode)
        started = false
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
