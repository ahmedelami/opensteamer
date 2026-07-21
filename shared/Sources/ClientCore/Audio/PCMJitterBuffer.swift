import AVFAudio
import AudioToolbox
import Foundation
import Utilities

/// A bounded, thread-safe PCM ring buffer shared by network ingestion and real-time playback.
///
/// The buffer drops its oldest sample on overflow and renders silence on underrun. Those events
/// are counted so callers can distinguish network starvation from an audio-device failure.
public final class PCMJitterBuffer: @unchecked Sendable, PCMFrameProvider {
    private let channels: Int
    private let sampleRate: Double
    private let capacitySamples: Int
    private let lock = NSLock()
    private var samples: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var availableSamples = 0
    private var droppedSamples = 0
    private var underrunSamples = 0
    private var lastRenderedRMS: Float = 0
    private var lastRenderedPeak: Float = 0

    /// Creates storage for `capacityFrames` interleaved frames.
    public init(channels: Int, sampleRate: Double = 48_000, capacityFrames: Int) {
        self.channels = channels
        self.sampleRate = max(sampleRate, 1)
        self.capacitySamples = max(capacityFrames * channels, channels)
        self.samples = Array(repeating: 0, count: self.capacitySamples)
    }

    /// The number of complete frames ready for playback.
    public var bufferedFrames: Int {
        lock.withLock {
            availableSamples / channels
        }
    }

    /// Approximate buffered playback time at the configured sample rate.
    public var bufferedDuration: TimeInterval {
        Double(bufferedFrames) / sampleRate
    }

    /// Complete frames discarded because incoming audio exceeded capacity.
    public var droppedFrames: Int {
        lock.withLock {
            droppedSamples / channels
        }
    }

    /// Complete frames for which silence was rendered because no audio was available.
    public var underrunFrames: Int {
        lock.withLock {
            underrunSamples / channels
        }
    }

    /// RMS and peak levels measured during the most recent render callback.
    public var renderLevel: (rms: Float, peak: Float) {
        lock.withLock {
            (lastRenderedRMS, lastRenderedPeak)
        }
    }

    /// Decodes little-endian signed 16-bit samples and returns the number of appended frames.
    public func appendPCM16LE(_ data: Data) -> Int {
        guard data.count >= MemoryLayout<Int16>.size else {
            return 0
        }

        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            let sampleCount = data.count / MemoryLayout<Int16>.size
            lock.lock()
            defer { lock.unlock() }

            for sampleIndex in 0..<sampleCount {
                let byteOffset = sampleIndex * 2
                let raw = UInt16(bytes[byteOffset]) | (UInt16(bytes[byteOffset + 1]) << 8)
                let value = Int16(bitPattern: raw)
                write(Float(value) / Float(Int16.max))
            }

            return sampleCount / channels
        }
    }

    /// Supplies non-interleaved floating-point samples to an audio-device render callback.
    public func render(frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard buffers.count >= channels else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        var sumSquares = 0.0
        var peak: Float = 0
        var renderedSamples = 0

        for frame in 0..<frameCount {
            if availableSamples >= channels {
                for channel in 0..<channels {
                    let output = buffers[channel].mData!.assumingMemoryBound(to: Float.self)
                    let sample = samples[(readIndex + channel) % capacitySamples]
                    output[frame] = sample
                    let absolute = abs(sample)
                    peak = max(peak, absolute)
                    sumSquares += Double(sample * sample)
                    renderedSamples += 1
                }
                readIndex = (readIndex + channels) % capacitySamples
                availableSamples -= channels
            } else {
                for channel in 0..<channels {
                    let output = buffers[channel].mData!.assumingMemoryBound(to: Float.self)
                    output[frame] = 0
                    renderedSamples += 1
                }
                underrunSamples += channels
            }
        }

        if renderedSamples > 0 {
            lastRenderedRMS = Float(sqrt(sumSquares / Double(renderedSamples)))
            lastRenderedPeak = peak
        } else {
            lastRenderedRMS = 0
            lastRenderedPeak = 0
        }
    }

    private func write(_ sample: Float) {
        if availableSamples == capacitySamples {
            readIndex = (readIndex + 1) % capacitySamples
            availableSamples -= 1
            droppedSamples += 1
        }

        samples[writeIndex] = sample
        writeIndex = (writeIndex + 1) % capacitySamples
        availableSamples += 1
    }
}
