@preconcurrency import LiveKitWebRTC
import CoreFoundation
import Foundation

/// Strictly parsed evidence from one sender-scoped native statistics report.
struct WebRTCIPhoneMicrophoneOutboundStatistics: Equatable, Sendable {
    let reportTimestampMicroseconds: Double
    let outboundRTPRecordIDs: [String]
    let packetsSent: UInt64
    let bytesSent: UInt64
    let totalAudioEnergy: Double?
    let totalSamplesDuration: Double?
    let sourceReportWasLinked: Bool
}

/// Receiver-scoped inbound RTP evidence for the dedicated iPhone microphone lane.
///
/// The native receiver passed to `statistics(for:)` is the security boundary. These fields are
/// intentionally limited to aggregate counters that can establish media progress without
/// retaining SDP, SSRCs, track identifiers, or any microphone content.
struct WebRTCIPhoneMicrophoneInboundStatistics: Equatable, Sendable {
    let statistics: WebRTCAudioStatistics
}

/// Reduces browser-style native WebRTC statistics into stable product diagnostics.
enum WebRTCStatisticsParser {
    private enum AudioTotals {
        case missing
        case values(energy: Double, duration: Double)
        case invalid
    }

    /// Parses the native report without retaining Objective-C statistics objects.
    static func parse(_ report: LKRTCStatisticsReport) -> WebRTCStatisticsSnapshot {
        parse(records: records(from: report))
    }

    static func records(
        from report: LKRTCStatisticsReport
    ) -> [WebRTCStatisticsRecord] {
        report.statistics.values.map { statistic in
            WebRTCStatisticsRecord(
                id: statistic.id as String,
                type: statistic.type as String,
                values: statistic.values
            )
        }
    }

    /// Parses value records; this overload is the deterministic unit-test seam.
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

    /// Parses only outbound RTP belonging to the exact sender-specific native report request.
    ///
    /// When native identifiers are present they must match exactly. If identifiers are omitted,
    /// sender-specific API scoping is accepted only when every otherwise-unanchored audio outbound
    /// record remains unambiguous. Every exact encoding is aggregated with checked arithmetic.
    /// Source totals are never selected by media kind or array order: an audio-source/media-source
    /// record is linked only through the exact `mediaSourceId`.
    static func parseIPhoneMicrophoneSender(
        _ report: LKRTCStatisticsReport,
        expectedSenderID: String,
        expectedTrackID: String,
        expectedMID: String
    ) -> WebRTCIPhoneMicrophoneOutboundStatistics? {
        parseIPhoneMicrophoneSender(
            records: records(from: report),
            reportTimestampMicroseconds: report.timestamp_us,
            expectedSenderID: expectedSenderID,
            expectedTrackID: expectedTrackID,
            expectedMID: expectedMID
        )
    }

    /// Parses only the inbound RTP selected by a native receiver-scoped statistics request.
    ///
    /// A receiver-specific report may omit browser-style identifiers. That omission is accepted
    /// only when the report contains exactly one audio inbound-RTP record. When `mid` or
    /// `trackIdentifier` is present it must match the captured dedicated receiver exactly. Any
    /// ambiguity, malformed progress counter, or extra audio inbound stream fails closed.
    static func parseIPhoneMicrophoneReceiver(
        _ report: LKRTCStatisticsReport,
        expectedTrackID: String,
        expectedMID: String
    ) -> WebRTCIPhoneMicrophoneInboundStatistics? {
        parseIPhoneMicrophoneReceiver(
            records: records(from: report),
            expectedTrackID: expectedTrackID,
            expectedMID: expectedMID
        )
    }

    static func parseIPhoneMicrophoneReceiver(
        records: [WebRTCStatisticsRecord],
        expectedTrackID: String,
        expectedMID: String
    ) -> WebRTCIPhoneMicrophoneInboundStatistics? {
        guard !expectedTrackID.isEmpty,
              !expectedMID.isEmpty,
              records.allSatisfy({ !$0.id.isEmpty }),
              Set(records.map(\.id)).count == records.count else {
            return nil
        }

        let inboundAudio = records.filter { record in
            record.type == "inbound-rtp"
                && mediaKind(in: record.values) == "audio"
        }
        guard inboundAudio.count == 1,
              let inbound = inboundAudio.first else {
            return nil
        }

        for (key, expected) in [
            ("trackIdentifier", expectedTrackID),
            ("mid", expectedMID),
        ] {
            guard inbound.values[key] != nil else { continue }
            guard string(key, in: inbound.values) == expected else {
                return nil
            }
        }

        // These are the only counters consumed as microphone-freshness evidence. Reject signed,
        // fractional, Boolean, overflowing, or otherwise malformed values instead of allowing
        // NSNumber conversion to manufacture apparent forward progress.
        for key in [
            "bytesReceived",
            "packetsReceived",
            "jitterBufferEmittedCount",
            "totalSamplesReceived",
        ] where inbound.values[key] != nil {
            guard strictUnsigned(key, in: inbound.values) != nil else {
                return nil
            }
        }

        return WebRTCIPhoneMicrophoneInboundStatistics(
            statistics: audioStatistics(record: inbound)
        )
    }

    static func parseIPhoneMicrophoneSender(
        records: [WebRTCStatisticsRecord],
        reportTimestampMicroseconds: Double,
        expectedSenderID: String,
        expectedTrackID: String,
        expectedMID: String
    ) -> WebRTCIPhoneMicrophoneOutboundStatistics? {
        guard !expectedSenderID.isEmpty,
              !expectedTrackID.isEmpty,
              !expectedMID.isEmpty,
              records.allSatisfy({ !$0.id.isEmpty }),
              Set(records.map(\.id)).count == records.count else {
            return nil
        }

        let allOutboundAudio = records.filter { record in
            record.type == "outbound-rtp"
                && mediaKind(in: record.values) == "audio"
        }
        guard !allOutboundAudio.isEmpty else { return nil }

        let classified = allOutboundAudio.map { record in
            (
                record: record,
                disposition: exactSenderIdentifierDisposition(
                    in: record.values,
                    expectedSenderID: expectedSenderID,
                    expectedTrackID: expectedTrackID,
                    expectedMID: expectedMID
                )
            )
        }
        let exactOutbound = classified
            .filter { $0.disposition == .exact }
            .map { $0.record }
        let genericOutbound = classified
            .filter { $0.disposition == .generic }
            .map { $0.record }

        let outboundAudio: [WebRTCStatisticsRecord]
        if exactOutbound.isEmpty {
            guard !genericOutbound.isEmpty,
                  classified.allSatisfy({
                    $0.disposition == .generic
                  }) else {
                return nil
            }
            outboundAudio = genericOutbound
        } else {
            guard genericOutbound.isEmpty else { return nil }
            outboundAudio = exactOutbound
        }

        guard let packetsSent = summedUnsigned(
            "packetsSent",
            in: outboundAudio
        ), let bytesSent = summedUnsigned(
            "bytesSent",
            in: outboundAudio
        ) else {
            return nil
        }

        let outboundTotals = combinedAudioTotals(in: outboundAudio)
        if case .invalid = outboundTotals { return nil }

        var sourceIdentifier: String?
        var sourceIdentifierWasMissing = false
        for outbound in outboundAudio {
            guard outbound.values["mediaSourceId"] != nil else {
                sourceIdentifierWasMissing = true
                continue
            }
            guard let value = string(
                "mediaSourceId",
                in: outbound.values
            ), !value.isEmpty else {
                return nil
            }
            if let sourceIdentifier, sourceIdentifier != value {
                return nil
            }
            sourceIdentifier = value
        }
        guard sourceIdentifier == nil || !sourceIdentifierWasMissing else {
            return nil
        }

        var sourceTotals = AudioTotals.missing
        var sourceReportWasLinked = false
        if let sourceIdentifier {
            let linkedSources = records.filter {
                $0.id == sourceIdentifier
            }
            guard linkedSources.count == 1,
                  let source = linkedSources.first,
                  source.type == "media-source"
                    || source.type == "audio-source",
                  mediaKind(in: source.values) == "audio",
                  string("trackIdentifier", in: source.values)
                    == expectedTrackID else {
                return nil
            }
            sourceReportWasLinked = true
            sourceTotals = audioTotals(in: source.values)
            if case .invalid = sourceTotals { return nil }
        }

        guard let totals = selectedAudioTotals(
            outbound: outboundTotals,
            source: sourceTotals
        ) else {
            return nil
        }

        return WebRTCIPhoneMicrophoneOutboundStatistics(
            reportTimestampMicroseconds:
                reportTimestampMicroseconds,
            outboundRTPRecordIDs:
                outboundAudio.map(\.id).sorted(),
            packetsSent: packetsSent,
            bytesSent: bytesSent,
            totalAudioEnergy: totals.energy,
            totalSamplesDuration: totals.duration,
            sourceReportWasLinked: sourceReportWasLinked
        )
    }

    private enum ExactSenderIdentifierDisposition: Equatable {
        case exact
        case generic
        case other
    }

    private static func exactSenderIdentifierDisposition(
        in values: [String: Any],
        expectedSenderID: String,
        expectedTrackID: String,
        expectedMID: String
    ) -> ExactSenderIdentifierDisposition {
        var sawIdentifier = false
        for (key, expected) in [
            ("senderId", expectedSenderID),
            ("trackIdentifier", expectedTrackID),
            ("mid", expectedMID),
        ] {
            guard values[key] != nil else { continue }
            sawIdentifier = true
            guard string(key, in: values) == expected else {
                return .other
            }
        }
        return sawIdentifier ? .exact : .generic
    }

    private static func summedUnsigned(
        _ key: String,
        in records: [WebRTCStatisticsRecord]
    ) -> UInt64? {
        var total: UInt64 = 0
        for record in records {
            guard let value = strictUnsigned(key, in: record.values) else {
                return nil
            }
            let result = total.addingReportingOverflow(value)
            guard !result.overflow,
                  result.partialValue <= UInt64(Int64.max) else {
                return nil
            }
            total = result.partialValue
        }
        return total
    }

    private static func combinedAudioTotals(
        in records: [WebRTCStatisticsRecord]
    ) -> AudioTotals {
        var energy = 0.0
        var duration = 0.0
        var sawMissing = false
        var sawValues = false
        for record in records {
            switch audioTotals(in: record.values) {
            case .missing:
                sawMissing = true
            case let .values(recordEnergy, recordDuration):
                sawValues = true
                let combinedEnergy = energy + recordEnergy
                let combinedDuration = duration + recordDuration
                guard combinedEnergy.isFinite,
                      combinedDuration.isFinite,
                      combinedEnergy <= 1_000_000_000,
                      combinedDuration <= 1_000_000_000 else {
                    return .invalid
                }
                energy = combinedEnergy
                duration = combinedDuration
            case .invalid:
                return .invalid
            }
        }
        guard !(sawMissing && sawValues) else {
            return .invalid
        }
        return sawValues
            ? .values(energy: energy, duration: duration)
            : .missing
    }

    private static func audioTotals(
        in values: [String: Any]
    ) -> AudioTotals {
        let hasEnergy = values["totalAudioEnergy"] != nil
        let hasDuration = values["totalSamplesDuration"] != nil
        switch (hasEnergy, hasDuration) {
        case (false, false):
            return .missing
        case (true, true):
            guard let energy = strictNonnegativeDouble(
                "totalAudioEnergy",
                in: values
            ), let duration = strictNonnegativeDouble(
                "totalSamplesDuration",
                in: values
            ) else {
                return .invalid
            }
            return .values(energy: energy, duration: duration)
        default:
            return .invalid
        }
    }

    private static func selectedAudioTotals(
        outbound: AudioTotals,
        source: AudioTotals
    ) -> (energy: Double?, duration: Double?)? {
        switch (source, outbound) {
        case (.missing, .missing):
            return (nil, nil)
        case let (.values(energy, duration), .missing):
            return (energy, duration)
        case let (.missing, .values(energy, duration)):
            return (energy, duration)
        case let (
            .values(sourceEnergy, sourceDuration),
            .values(outboundEnergy, outboundDuration)
        ):
            guard approximatelyEqual(sourceEnergy, outboundEnergy),
                  approximatelyEqual(sourceDuration, outboundDuration) else {
                return nil
            }
            return (sourceEnergy, sourceDuration)
        case (.invalid, _), (_, .invalid):
            return nil
        }
    }

    private static func approximatelyEqual(
        _ lhs: Double,
        _ rhs: Double
    ) -> Bool {
        let scale = max(1, abs(lhs), abs(rhs))
        return abs(lhs - rhs) <= scale * 0.000_000_001
    }

    private static func strictUnsigned(
        _ key: String,
        in values: [String: Any]
    ) -> UInt64? {
        guard let number = values[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }

        switch String(cString: number.objCType) {
        case "c", "s", "i", "l", "q":
            let value = number.int64Value
            guard value >= 0 else { return nil }
            return UInt64(value)
        case "C", "S", "I", "L", "Q":
            let value = number.uint64Value
            guard value <= UInt64(Int64.max) else { return nil }
            return value
        case "f", "d":
            let value = number.doubleValue
            guard value.isFinite,
                  value >= 0,
                  value.rounded(.towardZero) == value,
                  value <= 9_007_199_254_740_991 else {
                return nil
            }
            return UInt64(value)
        default:
            return nil
        }
    }

    private static func strictNonnegativeDouble(
        _ key: String,
        in values: [String: Any]
    ) -> Double? {
        guard let number = values[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let value = number.doubleValue
        guard value.isFinite,
              value >= 0,
              value <= 1_000_000_000 else {
            return nil
        }
        return value
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

/// A platform-neutral projection of one native statistics record.
struct WebRTCStatisticsRecord {
    let id: String
    let type: String
    let values: [String: Any]
}
