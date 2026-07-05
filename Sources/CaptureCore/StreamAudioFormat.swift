import CoreMedia
import Foundation

public struct StreamAudioFormat: Sendable {
    public let sampleRate: Double
    public let channelCount: Int
    public let formatFlags: UInt32
    public let bitsPerChannel: UInt32
    public let bytesPerFrame: UInt32
    public let isFloat: Bool
    public let isInterleaved: Bool

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
