import Foundation
@testable import WebRTCTransport
import XCTest

/// Uses platform-neutral records to verify extraction of route, concealment, jitter-buffer,
/// sender, and remote-inbound evidence without requiring a live connection.
final class WebRTCStatisticsParserTests: XCTestCase {
    func testParsesInboundAudioConcealmentAndJitterBufferEvidence() throws {
        let snapshot = WebRTCStatisticsParser.parse(records: [
            WebRTCStatisticsRecord(
                id: "audio-in",
                type: "inbound-rtp",
                values: [
                    "kind": "audio",
                    "bytesReceived": NSNumber(value: 12_345),
                    "packetsReceived": NSNumber(value: 321),
                    "packetsLost": NSNumber(value: 4),
                    "packetsDiscarded": NSNumber(value: 3),
                    "jitter": NSNumber(value: 0.012),
                    "jitterBufferDelay": NSNumber(value: 2.4),
                    "jitterBufferEmittedCount": NSNumber(value: 240),
                    "jitterBufferTargetDelay": NSNumber(value: 0.06),
                    "jitterBufferMinimumDelay": NSNumber(value: 0.02),
                    "totalSamplesReceived": NSNumber(value: 48_000),
                    "concealedSamples": NSNumber(value: 960),
                    "silentConcealedSamples": NSNumber(value: 480),
                    "concealmentEvents": NSNumber(value: 2),
                    "insertedSamplesForDeceleration": NSNumber(value: 24),
                    "removedSamplesForAcceleration": NSNumber(value: 12),
                    "totalAudioEnergy": NSNumber(value: 8.5),
                    "totalSamplesDuration": NSNumber(value: 1.0),
                    "audioLevel": NSNumber(value: 0.3)
                ]
            )
        ])

        let audio = try XCTUnwrap(snapshot.inboundAudio)
        XCTAssertEqual(audio.bytes, 12_345)
        XCTAssertEqual(audio.packets, 321)
        XCTAssertEqual(audio.packetsLost, 4)
        XCTAssertEqual(audio.packetsDiscarded, 3)
        XCTAssertEqual(audio.jitter, 0.012)
        XCTAssertEqual(audio.jitterBufferDelay, 2.4)
        XCTAssertEqual(audio.jitterBufferEmittedCount, 240)
        XCTAssertEqual(audio.jitterBufferTargetDelay, 0.06)
        XCTAssertEqual(audio.jitterBufferMinimumDelay, 0.02)
        XCTAssertEqual(audio.totalSamplesReceived, 48_000)
        XCTAssertEqual(audio.concealedSamples, 960)
        XCTAssertEqual(audio.silentConcealedSamples, 480)
        XCTAssertEqual(audio.concealmentEvents, 2)
        XCTAssertEqual(audio.insertedSamplesForDeceleration, 24)
        XCTAssertEqual(audio.removedSamplesForAcceleration, 12)
        XCTAssertEqual(audio.totalAudioEnergy, 8.5)
        XCTAssertEqual(audio.totalSamplesDuration, 1.0)
        XCTAssertEqual(audio.audioLevel, 0.3)
    }

    func testParsesSenderAudioAndLinksRemoteInboundWithoutKind() throws {
        let snapshot = WebRTCStatisticsParser.parse(records: [
            WebRTCStatisticsRecord(
                id: "source",
                type: "media-source",
                values: [
                    "kind": "audio",
                    "audioLevel": NSNumber(value: 0.25),
                    "totalAudioEnergy": NSNumber(value: 4.0),
                    "totalSamplesDuration": NSNumber(value: 2.0)
                ]
            ),
            WebRTCStatisticsRecord(
                id: "audio-out",
                type: "outbound-rtp",
                values: [
                    "kind": "audio",
                    "bytesSent": NSNumber(value: 50_000),
                    "packetsSent": NSNumber(value: 100),
                    "totalPacketSendDelay": NSNumber(value: 0.5),
                    "nackCount": NSNumber(value: 1),
                    "targetBitrate": NSNumber(value: 64_000)
                ]
            ),
            WebRTCStatisticsRecord(
                id: "audio-remote-in",
                type: "remote-inbound-rtp",
                values: [
                    "localId": "audio-out",
                    "packetsLost": NSNumber(value: 2),
                    "jitter": NSNumber(value: 0.02),
                    "roundTripTime": NSNumber(value: 0.08)
                ]
            )
        ])

        XCTAssertEqual(try XCTUnwrap(snapshot.audioSource).audioLevel, 0.25)
        let outbound = try XCTUnwrap(snapshot.outboundAudio)
        XCTAssertEqual(outbound.bytes, 50_000)
        XCTAssertEqual(outbound.packets, 100)
        XCTAssertEqual(outbound.totalPacketSendDelay, 0.5)
        XCTAssertEqual(outbound.nackCount, 1)
        XCTAssertEqual(outbound.targetBitrate, 64_000)

        let remoteInbound = try XCTUnwrap(snapshot.remoteInboundAudio)
        XCTAssertEqual(remoteInbound.packetsLost, 2)
        XCTAssertEqual(remoteInbound.jitter, 0.02)
        XCTAssertEqual(remoteInbound.roundTripTime, 0.08)
    }

    func testRemoteInboundAudioPrefersTheSelectedOutboundLocalID() throws {
        let snapshot = WebRTCStatisticsParser.parse(records: [
            WebRTCStatisticsRecord(
                id: "stale-audio-remote-in",
                type: "remote-inbound-rtp",
                values: [
                    "kind": "audio",
                    "localId": "old-audio-out",
                    "packetsLost": NSNumber(value: 99)
                ]
            ),
            WebRTCStatisticsRecord(
                id: "audio-out",
                type: "outbound-rtp",
                values: [
                    "kind": "audio",
                    "packetsSent": NSNumber(value: 20)
                ]
            ),
            WebRTCStatisticsRecord(
                id: "current-audio-remote-in",
                type: "remote-inbound-rtp",
                values: [
                    "kind": "audio",
                    "localId": "audio-out",
                    "packetsLost": NSNumber(value: 1)
                ]
            )
        ])

        XCTAssertEqual(try XCTUnwrap(snapshot.remoteInboundAudio).packetsLost, 1)
    }
}
