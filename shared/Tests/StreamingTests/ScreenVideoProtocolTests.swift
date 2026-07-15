import Foundation
import Testing
@testable import Streaming

struct ScreenVideoProtocolTests {
    @Test func preambleRoundTrips() throws {
        let data = ScreenVideoFraming.makePreamble()
        #expect(data.count == ScreenVideoProtocol.preambleByteCount)
        #expect(try ScreenVideoFraming.parsePreamble(data) == ScreenVideoPreamble())
    }

    @Test func preambleRejectsWrongMagicVersionLengthAndTrailingBytes() throws {
        var wrongMagic = ScreenVideoFraming.makePreamble()
        wrongMagic[0] = 0
        #expect(throws: ScreenVideoProtocolError.invalidMagic) {
            try ScreenVideoFraming.parsePreamble(wrongMagic)
        }

        var wrongVersion = ScreenVideoFraming.makePreamble()
        wrongVersion[4] = 2
        #expect(throws: ScreenVideoProtocolError.unsupportedVersion(2)) {
            try ScreenVideoFraming.parsePreamble(wrongVersion)
        }

        #expect(throws: ScreenVideoProtocolError.unexpectedByteCount(expected: 8, actual: 7)) {
            try ScreenVideoFraming.parsePreamble(Data(ScreenVideoFraming.makePreamble().prefix(7)))
        }

        var trailing = ScreenVideoFraming.makePreamble()
        trailing.append(0)
        #expect(throws: ScreenVideoProtocolError.unexpectedByteCount(expected: 8, actual: 9)) {
            try ScreenVideoFraming.parsePreamble(trailing)
        }
    }

    @Test func packetRoundTripsAndRejectsTrailingBytes() throws {
        let packet = ScreenVideoPacket(
            type: .frame,
            flags: [.keyFrame],
            generation: 7,
            sequence: 42,
            presentationTimestampNanoseconds: 123_456,
            payload: Data([1, 2, 3, 4])
        )
        let data = try ScreenVideoFraming.makePacket(packet)
        #expect(try ScreenVideoFraming.parsePacket(data) == packet)

        var trailing = data
        trailing.append(0)
        #expect(throws: ScreenVideoProtocolError.unexpectedByteCount(
            expected: data.count,
            actual: data.count + 1
        )) {
            try ScreenVideoFraming.parsePacket(trailing)
        }
    }

    @Test func packetRejectsUnknownTypeTruncationAndOversizedPayload() throws {
        let packet = ScreenVideoPacket(
            type: .acknowledgement,
            generation: 1,
            sequence: 3,
            presentationTimestampNanoseconds: 0
        )
        let data = try ScreenVideoFraming.makePacket(packet)

        var unknownType = data
        unknownType[4] = 0x7f
        #expect(throws: ScreenVideoProtocolError.unknownPacketType(0x7f)) {
            try ScreenVideoFraming.parsePacket(unknownType)
        }

        #expect(throws: ScreenVideoProtocolError.truncated) {
            try ScreenVideoFraming.parsePacket(Data(data.prefix(12)))
        }

        var oversizedHeader = Data(repeating: 0, count: ScreenVideoProtocol.packetHeaderByteCount)
        let oversized = ScreenVideoProtocol.maximumPayloadByteCount + 1
        for index in 0..<4 {
            oversizedHeader[index] = UInt8(truncatingIfNeeded: oversized >> (index * 8))
        }
        oversizedHeader[4] = ScreenVideoPacketType.frame.rawValue
        oversizedHeader[6] = UInt8(ScreenVideoProtocol.packetHeaderByteCount)
        #expect(throws: ScreenVideoProtocolError.payloadTooLarge(Int(oversized))) {
            try ScreenVideoFraming.parsePacketHeader(oversizedHeader)
        }

        let oversizedPacket = ScreenVideoPacket(
            type: .frame,
            generation: 1,
            sequence: 1,
            presentationTimestampNanoseconds: 0,
            payload: Data(repeating: 0, count: Int(oversized))
        )
        #expect(throws: ScreenVideoProtocolError.payloadTooLarge(Int(oversized))) {
            try ScreenVideoFraming.makePacket(oversizedPacket)
        }
    }

    @Test func streamParserHandlesOneByteFragmentsAndConcatenatedPackets() throws {
        let first = ScreenVideoPacket(
            type: .configuration,
            generation: 1,
            sequence: 0,
            presentationTimestampNanoseconds: 0,
            payload: Data([9, 8, 7])
        )
        let second = ScreenVideoPacket(
            type: .frame,
            flags: [.keyFrame],
            generation: 1,
            sequence: 1,
            presentationTimestampNanoseconds: 33_000_000,
            payload: Data([6, 5, 4, 3])
        )
        var stream = ScreenVideoFraming.makePreamble()
        stream.append(try ScreenVideoFraming.makePacket(first))
        stream.append(try ScreenVideoFraming.makePacket(second))

        let parser = ScreenVideoStreamParser()
        var events: [ScreenVideoStreamEvent] = []
        for byte in stream {
            parser.append(Data([byte]))
            while let event = try parser.nextEvent() {
                events.append(event)
            }
        }

        #expect(events == [.ready(ScreenVideoPreamble()), .packet(first), .packet(second)])
    }

    @Test func streamParserRejectsPacketBeforePreamble() throws {
        let packet = ScreenVideoPacket(
            type: .frame,
            generation: 1,
            sequence: 1,
            presentationTimestampNanoseconds: 0
        )
        let parser = ScreenVideoStreamParser()
        parser.append(try ScreenVideoFraming.makePacket(packet))
        #expect(throws: ScreenVideoProtocolError.invalidMagic) {
            try parser.nextEvent()
        }
    }

    @Test func configurationRoundTripsAndEveryTruncationThrows() throws {
        let configuration = ScreenVideoConfiguration(
            width: 1_920,
            height: 1_080,
            nalUnitHeaderLength: 4,
            framesPerSecondMilli: 60_000,
            bitrate: 12_000_000,
            parameterSets: [
                ScreenVideoParameterSet(nalUnitType: 7, bytes: Data([0x67, 1, 2, 3])),
                ScreenVideoParameterSet(nalUnitType: 8, bytes: Data([0x68, 4, 5]))
            ]
        )
        let data = try ScreenVideoFraming.makeConfiguration(configuration)
        #expect(try ScreenVideoFraming.parseConfiguration(data) == configuration)

        for length in 0..<data.count {
            #expect(throws: (any Error).self) {
                try ScreenVideoFraming.parseConfiguration(Data(data.prefix(length)))
            }
        }
    }

    @Test func configurationRejectsMalformedLengthsAndTrailingBytes() throws {
        let configuration = ScreenVideoConfiguration(
            width: 1_280,
            height: 720,
            nalUnitHeaderLength: 4,
            framesPerSecondMilli: 30_000,
            bitrate: 6_000_000,
            parameterSets: [ScreenVideoParameterSet(nalUnitType: 7, bytes: Data([0x67]))]
        )
        let data = try ScreenVideoFraming.makeConfiguration(configuration)

        var malformedLength = data
        malformedLength[24] = 10
        #expect(throws: ScreenVideoProtocolError.truncated) {
            try ScreenVideoFraming.parseConfiguration(malformedLength)
        }

        var trailing = data
        trailing.append(0)
        #expect(throws: (any Error).self) {
            try ScreenVideoFraming.parseConfiguration(trailing)
        }
    }

    @Test func configurationRejectsReservedThreeByteNALUnitLengths() throws {
        let parameterSets = [
            ScreenVideoParameterSet(nalUnitType: 7, bytes: Data([0x67, 1, 2, 3])),
            ScreenVideoParameterSet(nalUnitType: 8, bytes: Data([0x68, 4, 5]))
        ]

        for headerLength: UInt8 in [1, 2, 4] {
            let configuration = ScreenVideoConfiguration(
                width: 1_920,
                height: 1_080,
                nalUnitHeaderLength: headerLength,
                framesPerSecondMilli: 60_000,
                bitrate: 12_000_000,
                parameterSets: parameterSets
            )
            let data = try ScreenVideoFraming.makeConfiguration(configuration)
            #expect(try ScreenVideoFraming.parseConfiguration(data) == configuration)
        }

        let reserved = ScreenVideoConfiguration(
            width: 1_920,
            height: 1_080,
            nalUnitHeaderLength: 3,
            framesPerSecondMilli: 60_000,
            bitrate: 12_000_000,
            parameterSets: parameterSets
        )
        #expect(throws: ScreenVideoProtocolError.malformedConfiguration) {
            try ScreenVideoFraming.makeConfiguration(reserved)
        }

        var malformedWireData = try ScreenVideoFraming.makeConfiguration(
            ScreenVideoConfiguration(
                width: 1_920,
                height: 1_080,
                nalUnitHeaderLength: 4,
                framesPerSecondMilli: 60_000,
                bitrate: 12_000_000,
                parameterSets: parameterSets
            )
        )
        malformedWireData[8] = 3
        #expect(throws: ScreenVideoProtocolError.malformedConfiguration) {
            try ScreenVideoFraming.parseConfiguration(malformedWireData)
        }
    }
}
