import Foundation
import Streaming

public struct PCMFrame: Sendable {
    public let metadata: PCMPacketMetadata
    public let pcmBytes: Data
    public let packetLength: UInt32

    public init(metadata: PCMPacketMetadata, pcmBytes: Data, packetLength: UInt32) {
        self.metadata = metadata
        self.pcmBytes = pcmBytes
        self.packetLength = packetLength
    }
}
