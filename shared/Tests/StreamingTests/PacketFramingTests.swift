import Foundation
import XCTest
@testable import Streaming

/// Pins the legacy PCM byte layout and proves malformed lengths, formats, and authentication
/// prefixes are rejected before payload allocation or playback.
final class PacketFramingTests: XCTestCase {
    func testStreamHeaderRoundTrips() throws {
        let header = PCMStreamHeader(sampleRate: 48_000, channels: 2)
        let data = PacketFramer.makeHeader(header)
        let parsed = try PacketParser.parseHeader(data)

        XCTAssertEqual(data.count, PCMStreamProtocol.headerByteCount)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "MCAP")
        XCTAssertEqual(data[6], UInt8(PCMStreamProtocol.headerLength))
        XCTAssertEqual(data[7], 0)
        XCTAssertEqual(parsed.sampleRate, 48_000)
        XCTAssertEqual(parsed.channels, 2)
        XCTAssertEqual(parsed.format, PCMStreamProtocol.formatPCM16LE)
        XCTAssertEqual(parsed.flags, 0)
    }

    func testAuthRequestRoundTrips() throws {
        let request = try PCMAuthProtocol.makeRequest(token: "test-token")
        let tokenLength = try PCMAuthProtocol.tokenLength(
            fromHeader: Data(request.prefix(PCMAuthProtocol.headerByteCount))
        )
        let token = try PCMAuthProtocol.parseToken(Data(request.suffix(tokenLength)))

        XCTAssertEqual(request.count, PCMAuthProtocol.headerByteCount + tokenLength)
        XCTAssertEqual(String(decoding: request[0..<4], as: UTF8.self), "MCAT")
        XCTAssertEqual(tokenLength, "test-token".utf8.count)
        XCTAssertEqual(token, "test-token")
    }

    func testAuthRequestRejectsEmptyToken() {
        XCTAssertThrowsError(try PCMAuthProtocol.makeRequest(token: "")) { error in
            XCTAssertTrue(error is PCMAuthError)
        }
    }

    func testPacketHeaderRoundTripsAndPreservesPayload() throws {
        let payload = Data([0x00, 0x01, 0xFE, 0xFF])
        let metadata = PCMPacketMetadata(
            sequence: 42,
            presentationTimestampNanoseconds: 123_456_789,
            frameCount: 1
        )

        let packet = PacketFramer.makePacket(metadata: metadata, pcmBytes: payload)
        let packetLength = try PacketParser.packetLength(Data(packet.prefix(4)))
        let parsed = try PacketParser.parsePacketHeader(Data(packet.prefix(PCMStreamProtocol.packetHeaderByteCount)))

        XCTAssertEqual(packetLength, UInt32(PCMStreamProtocol.packetHeaderByteCount + payload.count))
        XCTAssertEqual(parsed.sequence, 42)
        XCTAssertEqual(parsed.presentationTimestampNanoseconds, 123_456_789)
        XCTAssertEqual(parsed.frameCount, 1)
        XCTAssertEqual(packet.suffix(payload.count), payload)
        try PacketParser.validatePayloadByteCount(
            packetLength: packetLength,
            metadata: parsed,
            channels: 2
        )
    }

    func testPacketParserRejectsOversizedLength() {
        var length = PCMStreamProtocol.maximumPacketByteCount + 1
        let data = Data(bytes: &length, count: MemoryLayout<UInt32>.size)

        XCTAssertThrowsError(try PacketParser.packetLength(data)) { error in
            XCTAssertTrue(error is PacketParserError)
        }
    }

    func testPacketParserRejectsZeroFramePackets() throws {
        let metadata = PCMPacketMetadata(
            sequence: 1,
            presentationTimestampNanoseconds: 0,
            frameCount: 0
        )
        let packet = PacketFramer.makePacket(metadata: metadata, pcmBytes: Data())
        let packetLength = try PacketParser.packetLength(Data(packet.prefix(4)))
        let parsed = try PacketParser.parsePacketHeader(Data(packet.prefix(PCMStreamProtocol.packetHeaderByteCount)))

        XCTAssertThrowsError(
            try PacketParser.validatePayloadByteCount(
                packetLength: packetLength,
                metadata: parsed,
                channels: 2
            )
        ) { error in
            XCTAssertTrue(error is PacketParserError)
        }
    }

    func testStreamHeaderRejectsImpossibleAudioShape() {
        let invalidRate = PacketFramer.makeHeader(PCMStreamHeader(sampleRate: 0, channels: 2))
        let invalidChannels = PacketFramer.makeHeader(PCMStreamHeader(sampleRate: 48_000, channels: 0))

        XCTAssertThrowsError(try PacketParser.parseHeader(invalidRate)) { error in
            XCTAssertTrue(error is PacketParserError)
        }
        XCTAssertThrowsError(try PacketParser.parseHeader(invalidChannels)) { error in
            XCTAssertTrue(error is PacketParserError)
        }
    }
}
