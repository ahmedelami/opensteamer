import Foundation

/// Echoed opt-in for host-originated screen-media pause/resume messages carried inside the existing
/// ordered v2 control channel. An old viewer never echoes this exact session attribute, so the host
/// must retain the legacy nonzero video floor and must not send it an unknown control kind.
enum ScreenMediaSuspensionSDP {
    static let currentProtocolVersion = 1
    static let attributeName = "x-opensteamer-screen-media-suspension"
    static let attributeLine = "a=\(attributeName):\(currentProtocolVersion)"

    static func advertisingHostSupport(in sessionDescription: String) -> String {
        insertingCapabilityIfNeeded(in: sessionDescription)
    }

    static func advertisingViewerSupport(
        in sessionDescription: String,
        remoteOfferSDP: String
    ) -> String {
        guard peerSupportsSuspension(in: remoteOfferSDP) else {
            return sessionDescription
        }
        return insertingCapabilityIfNeeded(in: sessionDescription)
    }

    /// A host may quiesce the video encoding only when this exact offer advertised v1 and this
    /// exact answer echoed v1. A unilateral or stale local advertisement is not negotiation.
    static func wasNegotiated(
        hostOfferSDP: String,
        viewerAnswerSDP: String
    ) -> Bool {
        peerSupportsSuspension(in: hostOfferSDP)
            && peerSupportsSuspension(in: viewerAnswerSDP)
    }

    private static func insertingCapabilityIfNeeded(
        in sessionDescription: String
    ) -> String {
        guard !peerSupportsSuspension(in: sessionDescription) else {
            return sessionDescription
        }
        let separator = sessionDescription.contains("\r\n") ? "\r\n" : "\n"
        let preservesTrailingSeparator = sessionDescription.hasSuffix(separator)
        var lines = sessionDescription.components(separatedBy: separator)
        if preservesTrailingSeparator, lines.last == "" {
            lines.removeLast()
        }
        let insertionIndex = lines.firstIndex(where: { $0.hasPrefix("m=") })
            ?? lines.endIndex
        lines.insert(attributeLine, at: insertionIndex)
        let result = lines.joined(separator: separator)
        return preservesTrailingSeparator ? result + separator : result
    }

    static func peerSupportsSuspension(in sessionDescription: String) -> Bool {
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
