import Foundation
@testable import WebRTCTransport
import XCTest

/// Uses platform-neutral records to verify extraction of route, concealment, jitter-buffer,
/// sender, and remote-inbound evidence without requiring a live connection.
final class WebRTCStatisticsParserTests: XCTestCase {
    func testParserPreservesTheSequenceAssignedBeforeNativeCollection() {
        let snapshot = WebRTCStatisticsParser.parse(
            records: [],
            collectionSequence: 37
        )

        XCTAssertEqual(snapshot.collectionSequence, 37)
    }

    func testSelectedCandidatePairIsOrderIndependentAcrossDuplicateTransportReferences()
        throws {
        let records = [
            WebRTCStatisticsRecord(
                id: "transport-one",
                type: "transport",
                values: ["selectedCandidatePairId": "pair"]
            ),
            WebRTCStatisticsRecord(
                id: "transport-two",
                type: "transport",
                values: ["selectedCandidatePairId": "pair"]
            ),
            WebRTCStatisticsRecord(
                id: "pair",
                type: "candidate-pair",
                values: [
                    "state": "succeeded",
                    "currentRoundTripTime": NSNumber(value: 0.025),
                    "availableOutgoingBitrate": NSNumber(value: 50_000_000),
                ]
            ),
        ]

        for orderedRecords in [records, Array(records.reversed())] {
            let snapshot = WebRTCStatisticsParser.parse(
                records: orderedRecords
            )
            XCTAssertEqual(snapshot.currentRoundTripTime, 0.025)
            XCTAssertEqual(snapshot.availableOutgoingBitrate, 50_000_000)
        }
    }

    func testConflictingTransportSelectedPairsFailClosed() {
        let snapshot = WebRTCStatisticsParser.parse(records: [
            WebRTCStatisticsRecord(
                id: "transport-one",
                type: "transport",
                values: ["selectedCandidatePairId": "pair-one"]
            ),
            WebRTCStatisticsRecord(
                id: "transport-two",
                type: "transport",
                values: ["selectedCandidatePairId": "pair-two"]
            ),
            WebRTCStatisticsRecord(
                id: "pair-one",
                type: "candidate-pair",
                values: ["state": "succeeded"]
            ),
            WebRTCStatisticsRecord(
                id: "pair-two",
                type: "candidate-pair",
                values: ["state": "succeeded"]
            ),
        ])

        XCTAssertNil(snapshot.currentRoundTripTime)
        XCTAssertNil(snapshot.availableOutgoingBitrate)
        XCTAssertNil(snapshot.route)
    }

    func testTransportReferenceToWrongRecordTypeFailsClosed() {
        let snapshot = WebRTCStatisticsParser.parse(records: [
            WebRTCStatisticsRecord(
                id: "transport",
                type: "transport",
                values: ["selectedCandidatePairId": "not-a-pair"]
            ),
            WebRTCStatisticsRecord(
                id: "not-a-pair",
                type: "codec",
                values: [
                    "currentRoundTripTime": NSNumber(value: 0.001),
                    "availableOutgoingBitrate": NSNumber(value: 99_000_000),
                ]
            ),
        ])

        XCTAssertNil(snapshot.currentRoundTripTime)
        XCTAssertNil(snapshot.availableOutgoingBitrate)
    }

    func testMalformedExplicitTransportReferenceCannotUseFallbackPair() {
        let pair = WebRTCStatisticsRecord(
            id: "pair",
            type: "candidate-pair",
            values: [
                "state": "succeeded",
                "nominated": NSNumber(value: true),
                "availableOutgoingBitrate": NSNumber(value: 50_000_000),
            ]
        )
        let malformedReference = WebRTCStatisticsRecord(
            id: "malformed-transport",
            type: "transport",
            values: ["selectedCandidatePairId": NSNumber(value: 7)]
        )
        let validReference = WebRTCStatisticsRecord(
            id: "valid-transport",
            type: "transport",
            values: ["selectedCandidatePairId": "pair"]
        )

        for transports in [
            [malformedReference],
            [validReference, malformedReference],
        ] {
            let snapshot = WebRTCStatisticsParser.parse(
                records: transports + [pair]
            )
            XCTAssertNil(snapshot.currentRoundTripTime)
            XCTAssertNil(snapshot.availableOutgoingBitrate)
            XCTAssertNil(snapshot.route)
        }
    }

    func testMalformedSelectedPairStateAndEmptyReferenceFailClosed() {
        let malformedStateSnapshot = WebRTCStatisticsParser.parse(records: [
            WebRTCStatisticsRecord(
                id: "transport",
                type: "transport",
                values: ["selectedCandidatePairId": "pair"]
            ),
            WebRTCStatisticsRecord(
                id: "pair",
                type: "candidate-pair",
                values: [
                    "state": NSNumber(value: 1),
                    "availableOutgoingBitrate": NSNumber(value: 50_000_000),
                ]
            ),
        ])
        XCTAssertNil(malformedStateSnapshot.availableOutgoingBitrate)

        let emptyReferenceSnapshot = WebRTCStatisticsParser.parse(records: [
            WebRTCStatisticsRecord(
                id: "transport",
                type: "transport",
                values: ["selectedCandidatePairId": ""]
            ),
            WebRTCStatisticsRecord(
                id: "",
                type: "candidate-pair",
                values: [
                    "state": "succeeded",
                    "availableOutgoingBitrate": NSNumber(value: 50_000_000),
                ]
            ),
        ])
        XCTAssertNil(emptyReferenceSnapshot.availableOutgoingBitrate)
    }

    func testAmbiguousFallbackCandidatePairsFailClosed() {
        let snapshot = WebRTCStatisticsParser.parse(records: [
            WebRTCStatisticsRecord(
                id: "pair-one",
                type: "candidate-pair",
                values: [
                    "state": "succeeded",
                    "nominated": NSNumber(value: true),
                    "availableOutgoingBitrate": NSNumber(value: 1_000_000),
                ]
            ),
            WebRTCStatisticsRecord(
                id: "pair-two",
                type: "candidate-pair",
                values: [
                    "state": "succeeded",
                    "selected": NSNumber(value: true),
                    "availableOutgoingBitrate": NSNumber(value: 2_000_000),
                ]
            ),
        ])

        XCTAssertNil(snapshot.availableOutgoingBitrate)
    }

    func testParsesOutboundVideoPacketQueueDelay() throws {
        let snapshot = WebRTCStatisticsParser.parse(records: [
            WebRTCStatisticsRecord(
                id: "screen-video-out",
                type: "outbound-rtp",
                values: [
                    "kind": "video",
                    "packetsSent": NSNumber(value: 120),
                    "totalPacketSendDelay": NSNumber(value: 1.25),
                ]
            ),
        ])

        let video = try XCTUnwrap(snapshot.outboundVideo)
        XCTAssertEqual(video.packets, 120)
        XCTAssertEqual(video.totalPacketSendDelay, 1.25)
    }

    func testPrimaryVideoStatisticsExcludeRTXIndependentOfRecordOrder() throws {
        let primaryCodec = WebRTCStatisticsRecord(
            id: "primary-codec",
            type: "codec",
            values: ["mimeType": "video/H264"]
        )
        let repairCodec = WebRTCStatisticsRecord(
            id: "repair-codec",
            type: "codec",
            values: ["mimeType": "video/rtx"]
        )
        let primary = WebRTCStatisticsRecord(
            id: "screen-video-out",
            type: "outbound-rtp",
            values: [
                "kind": "video",
                "codecId": "primary-codec",
                "packetsSent": NSNumber(value: 120),
                "totalPacketSendDelay": NSNumber(value: 1.25),
            ]
        )
        let repair = WebRTCStatisticsRecord(
            id: "screen-video-rtx",
            type: "outbound-rtp",
            values: [
                "kind": "video",
                "codecId": "repair-codec",
                "packetsSent": NSNumber(value: 999),
                "totalPacketSendDelay": NSNumber(value: 99),
            ]
        )
        let records = [primaryCodec, repairCodec, primary, repair]

        for orderedRecords in [records, Array(records.reversed())] {
            let video = try XCTUnwrap(
                WebRTCStatisticsParser.parse(records: orderedRecords)
                    .outboundVideo
            )
            XCTAssertEqual(video.packets, 120)
            XCTAssertEqual(video.totalPacketSendDelay, 1.25)
        }
    }

    func testPrimaryVideoStatisticsFailClosedOnUnclassifiedAmbiguity() {
        let snapshot = WebRTCStatisticsParser.parse(records: [
            WebRTCStatisticsRecord(
                id: "video-one",
                type: "outbound-rtp",
                values: ["kind": "video"]
            ),
            WebRTCStatisticsRecord(
                id: "video-two",
                type: "outbound-rtp",
                values: ["kind": "video"]
            ),
        ])

        XCTAssertNil(snapshot.outboundVideo)
    }

    func testParsesOnlyOneExactReceiverScopedIPhoneMicrophoneInboundRecord() throws {
        let parsed = WebRTCStatisticsParser.parseIPhoneMicrophoneReceiver(
            records: [
                WebRTCStatisticsRecord(
                    id: "iphone-microphone-inbound",
                    type: "inbound-rtp",
                    values: [
                        "kind": "audio",
                        "mid": "2",
                        "trackIdentifier": "iphone-microphone",
                        "bytesReceived": NSNumber(value: 12_345),
                        "packetsReceived": NSNumber(value: 321),
                        "jitterBufferEmittedCount": NSNumber(value: 240),
                        "totalSamplesReceived": NSNumber(value: 48_000),
                        "totalAudioEnergy": NSNumber(value: 0.25),
                        "audioLevel": NSNumber(value: 0.1),
                    ]
                ),
                WebRTCStatisticsRecord(
                    id: "unrelated-video",
                    type: "inbound-rtp",
                    values: [
                        "kind": "video",
                        "packetsReceived": NSNumber(value: 999),
                    ]
                ),
            ],
            expectedTrackID: "iphone-microphone",
            expectedMID: "2"
        )

        let statistics = try XCTUnwrap(parsed?.statistics)
        XCTAssertEqual(statistics.bytes, 12_345)
        XCTAssertEqual(statistics.packets, 321)
        XCTAssertEqual(statistics.jitterBufferEmittedCount, 240)
        XCTAssertEqual(statistics.totalSamplesReceived, 48_000)
        XCTAssertEqual(statistics.totalAudioEnergy, 0.25)
        XCTAssertEqual(statistics.audioLevel, 0.1)
    }

    func testReceiverScopedIPhoneMicrophoneParserFailsClosedOnAmbiguityMismatchAndMalformedProgress() {
        func record(
            id: String,
            mid: String = "2",
            trackID: String = "iphone-microphone",
            packets: NSNumber = NSNumber(value: 1)
        ) -> WebRTCStatisticsRecord {
            WebRTCStatisticsRecord(
                id: id,
                type: "inbound-rtp",
                values: [
                    "kind": "audio",
                    "mid": mid,
                    "trackIdentifier": trackID,
                    "packetsReceived": packets,
                ]
            )
        }

        let invalidReports: [[WebRTCStatisticsRecord]] = [
            [record(id: "wrong-mid", mid: "1")],
            [record(id: "wrong-track", trackID: "system-audio")],
            [record(id: "one"), record(id: "two")],
            [record(id: "fractional", packets: NSNumber(value: 1.5))],
            [record(id: "negative", packets: NSNumber(value: -1))],
            [record(id: "duplicate"), record(id: "duplicate")],
        ]

        for records in invalidReports {
            XCTAssertNil(
                WebRTCStatisticsParser.parseIPhoneMicrophoneReceiver(
                    records: records,
                    expectedTrackID: "iphone-microphone",
                    expectedMID: "2"
                )
            )
        }
    }

    func testReceiverScopedIPhoneMicrophoneSamplerRejectsEveryRolloverBoundary() throws {
        let peerEpoch = UUID()
        let captured = WebRTCIPhoneMicrophoneReceiverStatisticsValidation(
            peerEpoch: peerEpoch,
            negotiationEpoch: 4,
            receiverID: "receiver",
            remoteTrackID: "iphone-microphone",
            mid: "2"
        )
        let parsed = WebRTCIPhoneMicrophoneInboundStatistics(
            statistics: WebRTCAudioStatistics(packets: 10)
        )

        XCTAssertEqual(
            WebRTCIPhoneMicrophoneReceiverStatisticsSampler.evaluate(
                parsed: parsed,
                captured: captured,
                current: captured,
                nativeOwnershipIsCurrent: true
            )?.packets,
            10
        )
        XCTAssertNil(
            WebRTCIPhoneMicrophoneReceiverStatisticsSampler.evaluate(
                parsed: parsed,
                captured: captured,
                current: WebRTCIPhoneMicrophoneReceiverStatisticsValidation(
                    peerEpoch: peerEpoch,
                    negotiationEpoch: 5,
                    receiverID: "receiver",
                    remoteTrackID: "iphone-microphone",
                    mid: "2"
                ),
                nativeOwnershipIsCurrent: true
            )
        )
        XCTAssertNil(
            WebRTCIPhoneMicrophoneReceiverStatisticsSampler.evaluate(
                parsed: parsed,
                captured: captured,
                current: captured,
                nativeOwnershipIsCurrent: false
            )
        )
        XCTAssertNil(
            WebRTCIPhoneMicrophoneReceiverStatisticsSampler.evaluate(
                parsed: parsed,
                captured: captured,
                current: nil,
                nativeOwnershipIsCurrent: true
            )
        )
    }

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
