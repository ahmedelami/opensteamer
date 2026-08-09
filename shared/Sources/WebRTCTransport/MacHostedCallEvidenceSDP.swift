import Foundation

/// Final host-side ordering gate for native FaceTime observations. The screen-service actor may
/// reenter while a prior cross-actor send is suspended, so the peer independently rejects a native
/// observation older than the last one sent for the same authorization and challenge binding.
enum WebRTCMacHostedCallObservationSendPolicy {
    static func admits(
        observationSequence: UInt64,
        highestSentSequence: UInt64,
        bindingMatches: Bool
    ) -> Bool {
        observationSequence > 0
            && (!bindingMatches
                || observationSequence > highestSentSequence)
    }
}

/// Bidirectional capability negotiation for challenge-bound Mac-hosted call evidence.
///
/// A new host advertises in its offer and the viewer echoes only when that exact offer carried the
/// same version. Version 4 adds a distinct prospectively armed preflight acknowledgement, so
/// neither side sends the evidence control kinds to a peer implementing the earlier call-only
/// challenge contract.
enum MacHostedCallEvidenceSDP {
    static let currentProtocolVersion = 4
    static let attributeName =
        "x-opensteamer-mac-hosted-call-evidence"
    static let attributeLine =
        "a=\(attributeName):\(currentProtocolVersion)"

    static func advertisingHostSupport(in sessionDescription: String) -> String {
        insertingCapabilityIfNeeded(in: sessionDescription)
    }

    static func advertisingViewerSupport(
        in sessionDescription: String,
        remoteOfferSDP: String
    ) -> String {
        guard peerSupportsEvidence(in: remoteOfferSDP) else {
            return sessionDescription
        }
        return insertingCapabilityIfNeeded(in: sessionDescription)
    }

    private static func insertingCapabilityIfNeeded(
        in sessionDescription: String
    ) -> String {
        guard !peerSupportsEvidence(in: sessionDescription) else {
            return sessionDescription
        }
        let separator = sessionDescription.contains("\r\n") ? "\r\n" : "\n"
        let preservesTrailingSeparator = sessionDescription.hasSuffix(separator)
        var lines = sessionDescription.components(separatedBy: separator)
        if preservesTrailingSeparator, lines.last == "" {
            lines.removeLast()
        }
        let insertionIndex = lines.firstIndex(where: {
            $0.hasPrefix("m=")
        }) ?? lines.endIndex
        lines.insert(attributeLine, at: insertionIndex)
        let result = lines.joined(separator: separator)
        return preservesTrailingSeparator ? result + separator : result
    }

    static func peerSupportsEvidence(in sessionDescription: String) -> Bool {
        // Swift treats CRLF as one extended grapheme cluster, so Character-based splitting on
        // `\n` does not split standards-compliant WebRTC SDP. Match the exact line-ending policy
        // used by the injector instead.
        let separator = sessionDescription.contains("\r\n") ? "\r\n" : "\n"
        for line in sessionDescription.components(separatedBy: separator) {
            if line.hasPrefix("m=") {
                return false
            }
            if line == attributeLine {
                return true
            }
        }
        return false
    }
}
