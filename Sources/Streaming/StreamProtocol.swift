import Foundation

public enum PCMStreamProtocol {
    public static let magic = "MCAP"
    public static let version: UInt16 = 1
    public static let headerLength: UInt16 = 24
    public static let formatPCM16LE: UInt16 = 1
    public static let headerByteCount = Int(headerLength)
    public static let packetHeaderByteCount = 20
    public static let maximumPacketByteCount: UInt32 = 1_048_576
}

public struct PCMStreamHeader: Sendable {
    public let sampleRate: UInt32
    public let channels: UInt16
    public let format: UInt16
    public let flags: UInt32

    public init(
        sampleRate: UInt32,
        channels: UInt16,
        format: UInt16 = PCMStreamProtocol.formatPCM16LE,
        flags: UInt32 = 0
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.format = format
        self.flags = flags
    }
}

public struct PCMPacketMetadata: Sendable {
    public let sequence: UInt32
    public let presentationTimestampNanoseconds: UInt64
    public let frameCount: UInt32

    public init(sequence: UInt32, presentationTimestampNanoseconds: UInt64, frameCount: UInt32) {
        self.sequence = sequence
        self.presentationTimestampNanoseconds = presentationTimestampNanoseconds
        self.frameCount = frameCount
    }
}
