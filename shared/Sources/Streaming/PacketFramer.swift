import Foundation

public enum PacketFramer {
    public static func makeHeader(_ header: PCMStreamHeader) -> Data {
        var data = Data(capacity: PCMStreamProtocol.headerByteCount)
        data.appendASCII(PCMStreamProtocol.magic)
        data.appendLE(PCMStreamProtocol.version)
        data.appendLE(PCMStreamProtocol.headerLength)
        data.appendLE(header.sampleRate)
        data.appendLE(header.channels)
        data.appendLE(header.format)
        data.appendLE(header.flags)
        data.appendLE(UInt32(0))
        return data
    }

    public static func makePacket(metadata: PCMPacketMetadata, pcmBytes: Data) -> Data {
        let packetLength = UInt32(PCMStreamProtocol.packetHeaderByteCount + pcmBytes.count)
        var data = Data(capacity: Int(packetLength))
        data.appendLE(packetLength)
        data.appendLE(metadata.sequence)
        data.appendLE(metadata.presentationTimestampNanoseconds)
        data.appendLE(metadata.frameCount)
        data.append(pcmBytes)
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ text: String) {
        append(contentsOf: text.utf8)
    }

    mutating func appendLE(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt64) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
