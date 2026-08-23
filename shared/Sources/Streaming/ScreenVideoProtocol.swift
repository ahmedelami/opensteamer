import Foundation

/// Constants for the versioned screen-video framing protocol.
public enum ScreenVideoProtocol {
    public static let magic = "MCVS"
    public static let version: UInt16 = 1
    public static let preambleByteCount = 8
    public static let packetHeaderByteCount = 24
    public static let configurationHeaderByteCount = 20
    public static let maximumPayloadByteCount: UInt32 = 8 * 1_024 * 1_024
}

/// The validated protocol version announced before screen-video packets.
public struct ScreenVideoPreamble: Sendable, Equatable {
    public let version: UInt16

    public init(version: UInt16 = ScreenVideoProtocol.version) {
        self.version = version
    }
}

/// Discriminators for media, lifecycle, and receiver-feedback packets.
public enum ScreenVideoPacketType: UInt8, Sendable {
    case configuration = 1
    case frame = 2
    case end = 3
    case acknowledgement = 0x80
    case keyFrameRequest = 0x81
}

/// Per-packet media flags used to resynchronize a decoder after loss or reconfiguration.
public struct ScreenVideoPacketFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8

    public static let keyFrame = ScreenVideoPacketFlags(rawValue: 1 << 0)
    public static let discontinuity = ScreenVideoPacketFlags(rawValue: 1 << 1)

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
}

/// A complete screen-video packet in host representation.
public struct ScreenVideoPacket: Sendable, Equatable {
    public let type: ScreenVideoPacketType
    public let flags: ScreenVideoPacketFlags
    public let generation: UInt32
    public let sequence: UInt32
    public let presentationTimestampNanoseconds: UInt64
    public let payload: Data

    public init(
        type: ScreenVideoPacketType,
        flags: ScreenVideoPacketFlags = [],
        generation: UInt32,
        sequence: UInt32,
        presentationTimestampNanoseconds: UInt64,
        payload: Data = Data()
    ) {
        self.type = type
        self.flags = flags
        self.generation = generation
        self.sequence = sequence
        self.presentationTimestampNanoseconds = presentationTimestampNanoseconds
        self.payload = payload
    }
}

/// Parsed fixed-width metadata used to bound and assemble a packet payload.
public struct ScreenVideoPacketHeader: Sendable, Equatable {
    public let payloadByteCount: UInt32
    public let type: ScreenVideoPacketType
    public let flags: ScreenVideoPacketFlags
    public let generation: UInt32
    public let sequence: UInt32
    public let presentationTimestampNanoseconds: UInt64
}

/// One H.264 parameter-set NAL unit and its wire type.
public struct ScreenVideoParameterSet: Sendable, Equatable {
    public let nalUnitType: UInt8
    public let bytes: Data

    public init(nalUnitType: UInt8, bytes: Data) {
        self.nalUnitType = nalUnitType
        self.bytes = bytes
    }
}

/// Decoder configuration carried ahead of H.264 screen frames.
public struct ScreenVideoConfiguration: Sendable, Equatable {
    public let width: UInt32
    public let height: UInt32
    public let nalUnitHeaderLength: UInt8
    public let framesPerSecondMilli: UInt32
    public let bitrate: UInt32
    public let parameterSets: [ScreenVideoParameterSet]

    public init(
        width: UInt32,
        height: UInt32,
        nalUnitHeaderLength: UInt8,
        framesPerSecondMilli: UInt32,
        bitrate: UInt32,
        parameterSets: [ScreenVideoParameterSet]
    ) {
        self.width = width
        self.height = height
        self.nalUnitHeaderLength = nalUnitHeaderLength
        self.framesPerSecondMilli = framesPerSecondMilli
        self.bitrate = bitrate
        self.parameterSets = parameterSets
    }
}

/// Encodes and validates preambles, packet envelopes, and H.264 decoder configuration.
public enum ScreenVideoFraming {
    /// Creates the fixed-width stream preamble for the current protocol version.
    public static func makePreamble() -> Data {
        var data = Data(capacity: ScreenVideoProtocol.preambleByteCount)
        data.append(contentsOf: ScreenVideoProtocol.magic.utf8)
        data.appendLittleEndian(ScreenVideoProtocol.version)
        data.appendLittleEndian(UInt16(ScreenVideoProtocol.preambleByteCount))
        return data
    }

    /// Validates a complete preamble before any packet bytes are accepted.
    public static func parsePreamble(_ data: Data) throws -> ScreenVideoPreamble {
        guard data.count == ScreenVideoProtocol.preambleByteCount else {
            throw ScreenVideoProtocolError.unexpectedByteCount(
                expected: ScreenVideoProtocol.preambleByteCount,
                actual: data.count
            )
        }
        guard String(decoding: data[0..<4], as: UTF8.self) == ScreenVideoProtocol.magic else {
            throw ScreenVideoProtocolError.invalidMagic
        }

        var cursor = ScreenVideoByteCursor(data: data, offset: 4)
        let version = try cursor.readUInt16LittleEndian()
        guard version == ScreenVideoProtocol.version else {
            throw ScreenVideoProtocolError.unsupportedVersion(version)
        }
        let headerByteCount = try cursor.readUInt16LittleEndian()
        guard headerByteCount == ScreenVideoProtocol.preambleByteCount else {
            throw ScreenVideoProtocolError.invalidPreamble
        }
        return ScreenVideoPreamble(version: version)
    }

    /// Encodes one bounded packet with an explicit payload length.
    public static func makePacket(_ packet: ScreenVideoPacket) throws -> Data {
        guard packet.payload.count <= Int(ScreenVideoProtocol.maximumPayloadByteCount) else {
            throw ScreenVideoProtocolError.payloadTooLarge(packet.payload.count)
        }

        var data = Data(capacity: ScreenVideoProtocol.packetHeaderByteCount + packet.payload.count)
        data.appendLittleEndian(UInt32(packet.payload.count))
        data.append(packet.type.rawValue)
        data.append(packet.flags.rawValue)
        data.appendLittleEndian(UInt16(ScreenVideoProtocol.packetHeaderByteCount))
        data.appendLittleEndian(packet.generation)
        data.appendLittleEndian(packet.sequence)
        data.appendLittleEndian(packet.presentationTimestampNanoseconds)
        data.append(packet.payload)
        return data
    }

    /// Parses a fixed-width packet header and rejects unknown types or oversized payloads.
    public static func parsePacketHeader(_ data: Data) throws -> ScreenVideoPacketHeader {
        guard data.count == ScreenVideoProtocol.packetHeaderByteCount else {
            throw ScreenVideoProtocolError.unexpectedByteCount(
                expected: ScreenVideoProtocol.packetHeaderByteCount,
                actual: data.count
            )
        }

        var cursor = ScreenVideoByteCursor(data: data)
        let payloadByteCount = try cursor.readUInt32LittleEndian()
        guard payloadByteCount <= ScreenVideoProtocol.maximumPayloadByteCount else {
            throw ScreenVideoProtocolError.payloadTooLarge(Int(payloadByteCount))
        }
        let typeRawValue = try cursor.readUInt8()
        guard let type = ScreenVideoPacketType(rawValue: typeRawValue) else {
            throw ScreenVideoProtocolError.unknownPacketType(typeRawValue)
        }
        let flags = ScreenVideoPacketFlags(rawValue: try cursor.readUInt8())
        let headerByteCount = try cursor.readUInt16LittleEndian()
        guard headerByteCount == ScreenVideoProtocol.packetHeaderByteCount else {
            throw ScreenVideoProtocolError.invalidPacketHeader
        }
        let generation = try cursor.readUInt32LittleEndian()
        let sequence = try cursor.readUInt32LittleEndian()
        let presentationTimestampNanoseconds = try cursor.readUInt64LittleEndian()

        return ScreenVideoPacketHeader(
            payloadByteCount: payloadByteCount,
            type: type,
            flags: flags,
            generation: generation,
            sequence: sequence,
            presentationTimestampNanoseconds: presentationTimestampNanoseconds
        )
    }

    /// Parses exactly one packet, rejecting both truncation and trailing bytes.
    public static func parsePacket(_ data: Data) throws -> ScreenVideoPacket {
        guard data.count >= ScreenVideoProtocol.packetHeaderByteCount else {
            throw ScreenVideoProtocolError.truncated
        }
        let headerData = Data(data.prefix(ScreenVideoProtocol.packetHeaderByteCount))
        let header = try parsePacketHeader(headerData)
        let expectedByteCount = ScreenVideoProtocol.packetHeaderByteCount + Int(header.payloadByteCount)
        guard data.count == expectedByteCount else {
            if data.count < expectedByteCount {
                throw ScreenVideoProtocolError.truncated
            }
            throw ScreenVideoProtocolError.unexpectedByteCount(
                expected: expectedByteCount,
                actual: data.count
            )
        }

        return ScreenVideoPacket(
            type: header.type,
            flags: header.flags,
            generation: header.generation,
            sequence: header.sequence,
            presentationTimestampNanoseconds: header.presentationTimestampNanoseconds,
            payload: Data(data.suffix(Int(header.payloadByteCount)))
        )
    }

    /// Encodes validated H.264 dimensions, rate hints, and parameter sets.
    public static func makeConfiguration(_ configuration: ScreenVideoConfiguration) throws -> Data {
        guard configuration.width > 0,
              configuration.height > 0,
              [1, 2, 4].contains(configuration.nalUnitHeaderLength),
              !configuration.parameterSets.isEmpty,
              configuration.parameterSets.count <= Int(UInt8.max) else {
            throw ScreenVideoProtocolError.malformedConfiguration
        }

        var payloadByteCount = ScreenVideoProtocol.configurationHeaderByteCount
        for parameterSet in configuration.parameterSets {
            guard !parameterSet.bytes.isEmpty,
                  parameterSet.bytes.count <= Int(ScreenVideoProtocol.maximumPayloadByteCount) else {
                throw ScreenVideoProtocolError.malformedConfiguration
            }
            payloadByteCount += 8 + parameterSet.bytes.count
        }
        guard payloadByteCount <= Int(ScreenVideoProtocol.maximumPayloadByteCount) else {
            throw ScreenVideoProtocolError.payloadTooLarge(payloadByteCount)
        }

        var data = Data(capacity: payloadByteCount)
        data.appendLittleEndian(configuration.width)
        data.appendLittleEndian(configuration.height)
        data.append(configuration.nalUnitHeaderLength)
        data.append(UInt8(configuration.parameterSets.count))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(configuration.framesPerSecondMilli)
        data.appendLittleEndian(configuration.bitrate)
        for parameterSet in configuration.parameterSets {
            data.append(parameterSet.nalUnitType)
            data.append(contentsOf: [0, 0, 0])
            data.appendLittleEndian(UInt32(parameterSet.bytes.count))
            data.append(parameterSet.bytes)
        }
        return data
    }

    /// Parses a bounded configuration payload and requires the cursor to consume every byte.
    public static func parseConfiguration(_ data: Data) throws -> ScreenVideoConfiguration {
        guard data.count <= Int(ScreenVideoProtocol.maximumPayloadByteCount) else {
            throw ScreenVideoProtocolError.payloadTooLarge(data.count)
        }
        guard data.count >= ScreenVideoProtocol.configurationHeaderByteCount else {
            throw ScreenVideoProtocolError.truncated
        }

        var cursor = ScreenVideoByteCursor(data: data)
        let width = try cursor.readUInt32LittleEndian()
        let height = try cursor.readUInt32LittleEndian()
        let nalUnitHeaderLength = try cursor.readUInt8()
        let parameterSetCount = Int(try cursor.readUInt8())
        _ = try cursor.readUInt16LittleEndian()
        let framesPerSecondMilli = try cursor.readUInt32LittleEndian()
        let bitrate = try cursor.readUInt32LittleEndian()

        guard width > 0,
              height > 0,
              [1, 2, 4].contains(nalUnitHeaderLength),
              parameterSetCount > 0 else {
            throw ScreenVideoProtocolError.malformedConfiguration
        }

        var parameterSets: [ScreenVideoParameterSet] = []
        parameterSets.reserveCapacity(parameterSetCount)
        for _ in 0..<parameterSetCount {
            let nalUnitType = try cursor.readUInt8()
            try cursor.skip(3)
            let byteCount = Int(try cursor.readUInt32LittleEndian())
            guard byteCount > 0 else {
                throw ScreenVideoProtocolError.malformedConfiguration
            }
            let bytes = try cursor.readData(byteCount: byteCount)
            parameterSets.append(ScreenVideoParameterSet(nalUnitType: nalUnitType, bytes: bytes))
        }
        guard cursor.isAtEnd else {
            throw ScreenVideoProtocolError.unexpectedByteCount(
                expected: cursor.offset,
                actual: data.count
            )
        }

        return ScreenVideoConfiguration(
            width: width,
            height: height,
            nalUnitHeaderLength: nalUnitHeaderLength,
            framesPerSecondMilli: framesPerSecondMilli,
            bitrate: bitrate,
            parameterSets: parameterSets
        )
    }
}

/// Strict framing and configuration failures for screen video.
public enum ScreenVideoProtocolError: LocalizedError, Equatable {
    case invalidMagic
    case unsupportedVersion(UInt16)
    case invalidPreamble
    case invalidPacketHeader
    case unknownPacketType(UInt8)
    case payloadTooLarge(Int)
    case malformedConfiguration
    case truncated
    case unexpectedByteCount(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidMagic:
            "Invalid screen video stream magic"
        case .unsupportedVersion(let version):
            "Unsupported screen video protocol version \(version)"
        case .invalidPreamble:
            "Invalid screen video stream preamble"
        case .invalidPacketHeader:
            "Invalid screen video packet header"
        case .unknownPacketType(let type):
            "Unknown screen video packet type \(type)"
        case .payloadTooLarge(let byteCount):
            "Screen video payload is too large (\(byteCount) bytes)"
        case .malformedConfiguration:
            "Malformed H.264 screen video configuration"
        case .truncated:
            "Screen video data ended before the declared length"
        case .unexpectedByteCount(let expected, let actual):
            "Expected \(expected) screen video bytes, received \(actual)"
        }
    }
}

private struct ScreenVideoByteCursor {
    let data: Data
    var offset: Int = 0

    var isAtEnd: Bool {
        offset == data.count
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw ScreenVideoProtocolError.truncated
        }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16LittleEndian() throws -> UInt16 {
        var value: UInt16 = 0
        for index in 0..<2 {
            value |= UInt16(try readUInt8()) << (index * 8)
        }
        return value
    }

    mutating func readUInt32LittleEndian() throws -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(try readUInt8()) << (index * 8)
        }
        return value
    }

    mutating func readUInt64LittleEndian() throws -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(try readUInt8()) << (index * 8)
        }
        return value
    }

    mutating func readData(byteCount: Int) throws -> Data {
        guard byteCount >= 0, offset <= data.count - byteCount else {
            throw ScreenVideoProtocolError.truncated
        }
        defer { offset += byteCount }
        return Data(data[offset..<(offset + byteCount)])
    }

    mutating func skip(_ byteCount: Int) throws {
        _ = try readData(byteCount: byteCount)
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        for index in 0..<2 {
            append(UInt8(truncatingIfNeeded: value >> (index * 8)))
        }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        for index in 0..<4 {
            append(UInt8(truncatingIfNeeded: value >> (index * 8)))
        }
    }

    mutating func appendLittleEndian(_ value: UInt64) {
        for index in 0..<8 {
            append(UInt8(truncatingIfNeeded: value >> (index * 8)))
        }
    }
}
