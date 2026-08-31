import Foundation

/// Bidirectional opt-in for the isolated, best-effort client screen-diagnostics lane.
///
/// An old peer never echoes this exact session attribute, so neither side may send a diagnostics
/// heartbeat until the exact offer/answer pair has negotiated version 1.
enum ScreenClientDiagnosticsSDP {
    static let currentProtocolVersion = 1
    static let attributeName = "x-opensteamer-screen-client-diagnostics"
    static let attributeLine = "a=\(attributeName):\(currentProtocolVersion)"

    static func advertisingHostSupport(in sessionDescription: String) -> String {
        insertingCapabilityIfNeeded(in: sessionDescription)
    }

    static func advertisingViewerSupport(
        in sessionDescription: String,
        remoteOfferSDP: String
    ) -> String {
        guard peerSupportsDiagnostics(in: remoteOfferSDP) else {
            return sessionDescription
        }
        return insertingCapabilityIfNeeded(in: sessionDescription)
    }

    static func wasNegotiated(
        hostOfferSDP: String,
        viewerAnswerSDP: String
    ) -> Bool {
        peerSupportsDiagnostics(in: hostOfferSDP)
            && peerSupportsDiagnostics(in: viewerAnswerSDP)
    }

    static func peerSupportsDiagnostics(in sessionDescription: String) -> Bool {
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

    private static func insertingCapabilityIfNeeded(
        in sessionDescription: String
    ) -> String {
        guard !peerSupportsDiagnostics(in: sessionDescription) else {
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
}
