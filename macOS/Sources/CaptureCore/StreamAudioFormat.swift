import CoreMedia
import Foundation

/// Sendable snapshot of the Core Audio format attached to captured samples.
public struct StreamAudioFormat: Sendable {
    public let sampleRate: Double
    public let channelCount: Int
    public let formatFlags: UInt32
    public let bitsPerChannel: UInt32
    public let bytesPerFrame: UInt32
    public let isFloat: Bool
    public let isInterleaved: Bool

    /// Copies an `AudioStreamBasicDescription` so it can safely cross queues.
    init(_ description: AudioStreamBasicDescription) {
        sampleRate = description.mSampleRate
        channelCount = Int(description.mChannelsPerFrame)
        formatFlags = description.mFormatFlags
        bitsPerChannel = description.mBitsPerChannel
        bytesPerFrame = description.mBytesPerFrame
        isFloat = (description.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        isInterleaved = (description.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
    }
}
