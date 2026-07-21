import Foundation

/// One H.264 access unit emitted by the screen encoder.
///
/// `bytes` retain AVCC length prefixes. Key frames can carry SPS/PPS parameter
/// sets separately so a newly connected receiver can initialize its decoder.
public struct EncodedScreenVideoFrame: Sendable {
    public let bytes: Data
    public let presentationTimestampNanoseconds: UInt64
    public let isKeyFrame: Bool
    public let parameterSets: [Data]
    public let nalUnitHeaderLength: Int

    /// Creates an encoded frame with its source timestamp and decoder metadata.
    public init(
        bytes: Data,
        presentationTimestampNanoseconds: UInt64,
        isKeyFrame: Bool,
        parameterSets: [Data],
        nalUnitHeaderLength: Int
    ) {
        self.bytes = bytes
        self.presentationTimestampNanoseconds = presentationTimestampNanoseconds
        self.isKeyFrame = isKeyFrame
        self.parameterSets = parameterSets
        self.nalUnitHeaderLength = nalUnitHeaderLength
    }
}
