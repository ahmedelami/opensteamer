import Foundation

/// Validation failures for the legacy PCM wire format.
public enum PacketParserError: LocalizedError {
    case invalidHeader
    case unsupportedVersion(UInt16)
    case unsupportedFormat(UInt16)
    case unsupportedSampleRate(UInt32)
    case unsupportedChannelCount(UInt16)
    case invalidPacketLength(UInt32)
    case emptyPacket
    case invalidPayloadByteCount(expected: UInt64, actual: UInt64)

    public var errorDescription: String? {
        switch self {
        case .invalidHeader:
            "Invalid stream header"
        case .unsupportedVersion(let version):
            "Unsupported stream version \(version)"
        case .unsupportedFormat(let format):
            "Unsupported stream format \(format)"
        case .unsupportedSampleRate(let sampleRate):
            "Unsupported stream sample rate \(sampleRate)"
        case .unsupportedChannelCount(let channels):
            "Unsupported stream channel count \(channels)"
        case .invalidPacketLength(let length):
            "Invalid packet length \(length)"
        case .emptyPacket:
            "Invalid packet with zero audio frames"
        case .invalidPayloadByteCount(let expected, let actual):
            "Invalid payload byte count: expected \(expected), got \(actual)"
        }
    }
}

/// Parses attacker-controlled PCM framing without trusting declared lengths or media parameters.
public enum PacketParser {
    /// Parses and validates the fixed-width stream header.
    public static func parseHeader(_ data: Data) throws -> PCMStreamHeader {
        guard data.count == PCMStreamProtocol.headerByteCount,
              String(decoding: data[0..<4], as: UTF8.self) == PCMStreamProtocol.magic else {
            throw PacketParserError.invalidHeader
        }

        let version = data.readUInt16LE(at: 4)
        guard version == PCMStreamProtocol.version else {
            throw PacketParserError.unsupportedVersion(version)
        }

        let headerLength = data.readUInt16LE(at: 6)
        guard headerLength == PCMStreamProtocol.headerLength else {
            throw PacketParserError.invalidHeader
        }

        let sampleRate = data.readUInt32LE(at: 8)
        let channels = data.readUInt16LE(at: 12)
        let format = data.readUInt16LE(at: 14)
        let flags = data.readUInt32LE(at: 16)
        guard sampleRate > 0, sampleRate <= 192_000 else {
            throw PacketParserError.unsupportedSampleRate(sampleRate)
        }
        guard channels > 0, channels <= 8 else {
            throw PacketParserError.unsupportedChannelCount(channels)
        }
        guard format == PCMStreamProtocol.formatPCM16LE else {
            throw PacketParserError.unsupportedFormat(format)
        }

        return PCMStreamHeader(sampleRate: sampleRate, channels: channels, format: format, flags: flags)
    }

    /// Parses presentation metadata after validating the packet's declared total length.
    public static func parsePacketHeader(_ data: Data) throws -> PCMPacketMetadata {
        guard data.count == PCMStreamProtocol.packetHeaderByteCount else {
            throw PacketParserError.invalidPacketLength(UInt32(data.count))
        }

        let packetLength = data.readUInt32LE(at: 0)
        guard packetLength >= UInt32(PCMStreamProtocol.packetHeaderByteCount),
              packetLength <= PCMStreamProtocol.maximumPacketByteCount else {
            throw PacketParserError.invalidPacketLength(packetLength)
        }

        return PCMPacketMetadata(
            sequence: data.readUInt32LE(at: 4),
            presentationTimestampNanoseconds: data.readUInt64LE(at: 8),
            frameCount: data.readUInt32LE(at: 16)
        )
    }

    /// Decodes and bounds the four-byte total packet length prefix.
    public static func packetLength(_ data: Data) throws -> UInt32 {
        guard data.count == 4 else {
            throw PacketParserError.invalidPacketLength(UInt32(data.count))
        }
        let packetLength = data.readUInt32LE(at: 0)
        guard packetLength >= UInt32(PCMStreamProtocol.packetHeaderByteCount),
              packetLength <= PCMStreamProtocol.maximumPacketByteCount else {
            throw PacketParserError.invalidPacketLength(packetLength)
        }
        return packetLength
    }

    /// Verifies that frame count, channel count, and PCM sample width imply the received payload.
    public static func validatePayloadByteCount(
        packetLength: UInt32,
        metadata: PCMPacketMetadata,
        channels: UInt16
    ) throws {
        guard metadata.frameCount > 0 else {
            throw PacketParserError.emptyPacket
        }
        let actual = UInt64(packetLength) - UInt64(PCMStreamProtocol.packetHeaderByteCount)
        let expected = UInt64(metadata.frameCount) * UInt64(channels) * UInt64(MemoryLayout<Int16>.size)
        guard actual == expected else {
            throw PacketParserError.invalidPayloadByteCount(expected: expected, actual: actual)
        }
    }
}

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        var value: UInt16 = 0
        for index in 0..<2 {
            value |= UInt16(self[offset + index]) << (index * 8)
        }
        return value
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(self[offset + index]) << (index * 8)
        }
        return value
    }

    func readUInt64LE(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(self[offset + index]) << (index * 8)
        }
        return value
    }
}
