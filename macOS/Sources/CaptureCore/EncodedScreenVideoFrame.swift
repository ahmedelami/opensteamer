import Foundation

public struct EncodedScreenVideoFrame: Sendable {
    public let bytes: Data
    public let presentationTimestampNanoseconds: UInt64
    public let isKeyFrame: Bool
    public let parameterSets: [Data]
    public let nalUnitHeaderLength: Int

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
