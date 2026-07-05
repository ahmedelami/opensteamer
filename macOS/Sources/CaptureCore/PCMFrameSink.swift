import Foundation
import Streaming

public protocol PCMFrameSink: AnyObject, Sendable {
    func configureStream(_ header: PCMStreamHeader)
    func sendPCMFrame(metadata: PCMPacketMetadata, pcmBytes: Data)
}
