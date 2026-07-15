@preconcurrency import LiveKitWebRTC
import Foundation

enum WebRTCStatisticsParser {
    static func parse(_ report: LKRTCStatisticsReport) -> WebRTCStatisticsSnapshot {
        let records = report.statistics.values.map { statistic in
            Record(
                id: statistic.id as String,
                type: statistic.type as String,
                values: statistic.values
            )
        }

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

        let outbound = records.first {
            $0.type == "outbound-rtp" && mediaKind(in: $0.values) == "video"
        }
        let inbound = records.first {
            $0.type == "inbound-rtp" && mediaKind(in: $0.values) == "video"
        }

        return WebRTCStatisticsSnapshot(
            route: route,
            currentRoundTripTime: selectedPair.flatMap {
                double("currentRoundTripTime", in: $0.values)
            },
            availableOutgoingBitrate: selectedPair.flatMap {
                double("availableOutgoingBitrate", in: $0.values)
            },
            jitter: inbound.flatMap { double("jitter", in: $0.values) },
            outboundVideo: outbound.map { videoStatistics(record: $0, outbound: true) },
            inboundVideo: inbound.map { videoStatistics(record: $0, outbound: false) }
        )
    }

    private static func selectedCandidatePair(in records: [Record]) -> Record? {
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
        in records: [Record]
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
        record: Record,
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

private struct Record {
    let id: String
    let type: String
    let values: [String: Any]
}
