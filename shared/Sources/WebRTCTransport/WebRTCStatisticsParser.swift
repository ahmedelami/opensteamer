@preconcurrency import LiveKitWebRTC
import Foundation

enum WebRTCStatisticsParser {
    static func parse(_ report: LKRTCStatisticsReport) -> WebRTCStatisticsSnapshot {
        let records = report.statistics.values.map { statistic in
            WebRTCStatisticsRecord(
                id: statistic.id as String,
                type: statistic.type as String,
                values: statistic.values
            )
        }
        return parse(records: records)
    }

    static func parse(records: [WebRTCStatisticsRecord]) -> WebRTCStatisticsSnapshot {

        let selectedPair = selectedCandidatePair(in: records)
        let localCandidate = candidate(
            identifiedBy: selectedPair.flatMap { string("localCandidateId", in: $0.values) },
            in: records
        )
        let remoteCandidate = candidate(
            identifiedBy: selectedPair.flatMap { string("remoteCandidateId", in: $0.values) },
            in: records
        )
        let route: WebRTCICERouteDiagnostics?
        if localCandidate != nil || remoteCandidate != nil {
            route = WebRTCNativeDiagnostics.route(
                local: localCandidate,
                remote: remoteCandidate
            )
        } else {
            route = nil
        }

        let outboundVideo = records.first {
            $0.type == "outbound-rtp" && mediaKind(in: $0.values) == "video"
        }
        let inboundVideo = records.first {
            $0.type == "inbound-rtp" && mediaKind(in: $0.values) == "video"
        }
        let audioSource = records.first {
            $0.type == "media-source" && mediaKind(in: $0.values) == "audio"
        }
        let outboundAudio = records.first {
            $0.type == "outbound-rtp" && mediaKind(in: $0.values) == "audio"
        }
        let inboundAudio = records.first {
            $0.type == "inbound-rtp" && mediaKind(in: $0.values) == "audio"
        }
        let remoteInboundAudio = outboundAudio.flatMap { outboundAudio in
            records.first { record in
                record.type == "remote-inbound-rtp"
                    && string("localId", in: record.values) == outboundAudio.id
            }
        } ?? records.first { record in
            record.type == "remote-inbound-rtp"
                && mediaKind(in: record.values) == "audio"
        }

        return WebRTCStatisticsSnapshot(
            route: route,
            currentRoundTripTime: selectedPair.flatMap {
                double("currentRoundTripTime", in: $0.values)
            },
            availableOutgoingBitrate: selectedPair.flatMap {
                double("availableOutgoingBitrate", in: $0.values)
            },
            jitter: inboundVideo.flatMap { double("jitter", in: $0.values) },
            outboundVideo: outboundVideo.map {
                videoStatistics(record: $0, outbound: true)
            },
            inboundVideo: inboundVideo.map {
                videoStatistics(record: $0, outbound: false)
            },
            audioSource: audioSource.map(audioStatistics),
            outboundAudio: outboundAudio.map(audioStatistics),
            inboundAudio: inboundAudio.map(audioStatistics),
            remoteInboundAudio: remoteInboundAudio.map(audioStatistics)
        )
    }

    private static func selectedCandidatePair(
        in records: [WebRTCStatisticsRecord]
    ) -> WebRTCStatisticsRecord? {
        let selectedID = records
            .first(where: { $0.type == "transport" })
            .flatMap { string("selectedCandidatePairId", in: $0.values) }
        if let selectedID, let selected = records.first(where: { $0.id == selectedID }) {
            return selected
        }

        return records.first { record in
            guard record.type == "candidate-pair" else { return false }
            let nominated = bool("nominated", in: record.values) ?? false
            let selected = bool("selected", in: record.values) ?? false
            let succeeded = string("state", in: record.values)?.lowercased() == "succeeded"
            return succeeded && (nominated || selected)
        }
    }

    private static func candidate(
        identifiedBy identifier: String?,
        in records: [WebRTCStatisticsRecord]
    ) -> WebRTCCandidateDiagnostics? {
        guard
            let identifier,
            let record = records.first(where: { $0.id == identifier }),
            record.type == "local-candidate" || record.type == "remote-candidate"
        else {
            return nil
        }
        return WebRTCNativeDiagnostics.candidate(from: record.values)
    }

    private static func videoStatistics(
        record: WebRTCStatisticsRecord,
        outbound: Bool
    ) -> WebRTCVideoStatistics {
        WebRTCVideoStatistics(
            bytes: unsigned(outbound ? "bytesSent" : "bytesReceived", in: record.values),
            packets: unsigned(outbound ? "packetsSent" : "packetsReceived", in: record.values),
            packetsLost: signed("packetsLost", in: record.values),
            framesPerSecond: double("framesPerSecond", in: record.values),
            frameWidth: integer("frameWidth", in: record.values),
            frameHeight: integer("frameHeight", in: record.values),
            framesEncodedOrDecoded: unsigned(
                outbound ? "framesEncoded" : "framesDecoded",
                in: record.values
            )
        )
    }

    private static func audioStatistics(
        record: WebRTCStatisticsRecord
    ) -> WebRTCAudioStatistics {
        let outbound = record.type == "outbound-rtp"
        return WebRTCAudioStatistics(
            bytes: unsigned(outbound ? "bytesSent" : "bytesReceived", in: record.values),
            packets: unsigned(
                outbound ? "packetsSent" : "packetsReceived",
                in: record.values
            ),
            packetsLost: signed("packetsLost", in: record.values),
            packetsDiscarded: unsigned("packetsDiscarded", in: record.values),
            jitter: double("jitter", in: record.values),
            jitterBufferDelay: double("jitterBufferDelay", in: record.values),
            jitterBufferEmittedCount: unsigned(
                "jitterBufferEmittedCount",
                in: record.values
            ),
            jitterBufferTargetDelay: double(
                "jitterBufferTargetDelay",
                in: record.values
            ),
            jitterBufferMinimumDelay: double(
                "jitterBufferMinimumDelay",
                in: record.values
            ),
            totalSamplesReceived: unsigned("totalSamplesReceived", in: record.values),
            concealedSamples: unsigned("concealedSamples", in: record.values),
            silentConcealedSamples: unsigned("silentConcealedSamples", in: record.values),
            concealmentEvents: unsigned("concealmentEvents", in: record.values),
            insertedSamplesForDeceleration: unsigned(
                "insertedSamplesForDeceleration",
                in: record.values
            ),
            removedSamplesForAcceleration: unsigned(
                "removedSamplesForAcceleration",
                in: record.values
            ),
            totalAudioEnergy: double("totalAudioEnergy", in: record.values),
            totalSamplesDuration: double("totalSamplesDuration", in: record.values),
            audioLevel: double("audioLevel", in: record.values),
            totalPacketSendDelay: double("totalPacketSendDelay", in: record.values),
            nackCount: unsigned("nackCount", in: record.values),
            targetBitrate: double("targetBitrate", in: record.values),
            roundTripTime: double("roundTripTime", in: record.values)
        )
    }

    private static func mediaKind(in values: [String: Any]) -> String? {
        (string("kind", in: values) ?? string("mediaType", in: values))?.lowercased()
    }

    private static func string(_ key: String, in values: [String: Any]) -> String? {
        WebRTCNativeDiagnostics.string(key, in: values)
    }

    private static func double(_ key: String, in values: [String: Any]) -> Double? {
        WebRTCNativeDiagnostics.number(key, in: values)?.doubleValue
    }

    private static func integer(_ key: String, in values: [String: Any]) -> Int? {
        WebRTCNativeDiagnostics.number(key, in: values)?.intValue
    }

    private static func unsigned(_ key: String, in values: [String: Any]) -> UInt64? {
        WebRTCNativeDiagnostics.number(key, in: values)?.uint64Value
    }

    private static func signed(_ key: String, in values: [String: Any]) -> Int64? {
        WebRTCNativeDiagnostics.number(key, in: values)?.int64Value
    }

    private static func bool(_ key: String, in values: [String: Any]) -> Bool? {
        WebRTCNativeDiagnostics.number(key, in: values)?.boolValue
    }
}

struct WebRTCStatisticsRecord {
    let id: String
    let type: String
    let values: [String: Any]
}
