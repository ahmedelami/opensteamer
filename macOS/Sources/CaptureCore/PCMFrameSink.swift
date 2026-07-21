import Foundation
import Streaming

/// Destination for a configured stream of framed PCM packets.
///
/// Implementations must receive `configureStream(_:)` before frames and are
/// responsible for preserving packet boundaries for their transport.
public protocol PCMFrameSink: AnyObject, Sendable {
    /// Publishes stream-wide format information to the receiver.
    func configureStream(_ header: PCMStreamHeader)
    /// Sends one timestamped PCM payload.
    func sendPCMFrame(metadata: PCMPacketMetadata, pcmBytes: Data)
}
