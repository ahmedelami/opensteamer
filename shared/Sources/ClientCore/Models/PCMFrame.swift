import Foundation
import Streaming

/// One validated PCM packet, including transport metadata and little-endian sample bytes.
public struct PCMFrame: Sendable {
    public let metadata: PCMPacketMetadata
    public let pcmBytes: Data
    public let packetLength: UInt32

    /// Creates a frame after wire-level validation has completed.
    public init(metadata: PCMPacketMetadata, pcmBytes: Data, packetLength: UInt32) {
        self.metadata = metadata
        self.pcmBytes = pcmBytes
        self.packetLength = packetLength
    }
}
