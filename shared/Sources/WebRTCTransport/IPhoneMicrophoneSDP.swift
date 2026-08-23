import Foundation

/// Product-owned logical classification for remote audio after peer-level receiver validation.
///
/// These labels are neither native WebRTC track IDs nor SDP MSID track tokens.
public enum WebRTCRemoteAudioLane: String, Equatable, Sendable {
    case systemAudio = "system-audio"
    case iPhoneMicrophone = "iphone-microphone"
}

/// Native sender-track and stream labels used while constructing the two negotiated audio lanes.
public enum WebRTCAudioTrackIdentifiers {
    public static let systemAudio = "system-audio"
    public static let iPhoneMicrophone = "iphone-microphone"
    public static let iPhoneMicrophoneStream = "iphone-microphone-stream"
}

/// Narrows only the host-offered iPhone microphone media section to mono Opus.
///
/// The existing high-fidelity policy deliberately rewrites every Opus section. The
/// microphone section must therefore be identified by its recvOnly offer direction and
/// MID, then corrected without weakening the independent system-audio section.
enum IPhoneMicrophoneSDP {
    static func systemAudioMID(inHostOffer sdp: String) -> String? {
        audioMID(inHostOffer: sdp, direction: "a=sendonly")
    }

    static func microphoneMID(inHostOffer sdp: String) -> String? {
        audioMID(inHostOffer: sdp, direction: "a=recvonly")
    }

    private static func audioMID(
        inHostOffer sdp: String,
        direction: String
    ) -> String? {
        let lines = normalizedLines(sdp)
        for range in mediaSectionRanges(in: lines) {
            let section = lines[range]
            guard section.first?.hasPrefix("m=audio ") == true,
                  section.contains(direction),
                  let midLine = section.first(where: { $0.hasPrefix("a=mid:") }) else {
                continue
            }
            let mid = String(midLine.dropFirst("a=mid:".count))
            if !mid.isEmpty {
                return mid
            }
        }
        return nil
    }

    static func applyingMonoPolicy(
        to sdp: String,
        microphoneMID: String?
    ) -> String {
        guard let microphoneMID, !microphoneMID.isEmpty else { return sdp }

        var lines = normalizedLines(sdp)
        guard let range = mediaSectionRanges(in: lines).first(where: { range in
            lines[range].contains("a=mid:\(microphoneMID)")
        }) else {
            return sdp
        }

        var section = Array(lines[range])
        let opusPayloads = section.compactMap { line -> String? in
            guard line.hasPrefix("a=rtpmap:") else { return nil }
            let value = line.dropFirst("a=rtpmap:".count)
            let pieces = value.split(separator: " ", maxSplits: 1)
            guard pieces.count == 2,
                  pieces[1].lowercased().hasPrefix("opus/48000/") else {
                return nil
            }
            return String(pieces[0])
        }

        for payload in opusPayloads {
            rewriteOpusFMTP(payload: payload, in: &section)
        }
        lines.replaceSubrange(range, with: section)

        let separator = sdp.contains("\r\n") ? "\r\n" : "\n"
        return lines.joined(separator: separator)
    }

    private static func rewriteOpusFMTP(
        payload: String,
        in section: inout [String]
    ) {
        let prefix = "a=fmtp:\(payload)"
        if let index = section.firstIndex(where: {
            $0 == prefix || $0.hasPrefix(prefix + " ")
        }) {
            let existing = section[index].dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespaces)
            var parameters = existing
                .split(separator: ";", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            parameters.removeAll { parameter in
                guard let key = parameter
                    .split(separator: "=", maxSplits: 1)
                    .first?
                    .lowercased() else {
                    return false
                }
                return key == "stereo"
                    || key == "sprop-stereo"
                    || key == "maxaveragebitrate"
            }
            parameters.append("stereo=0")
            parameters.append("sprop-stereo=0")
            section[index] = prefix + " " + parameters.joined(separator: ";")
            return
        }

        guard let rtpmapIndex = section.firstIndex(where: {
            $0.hasPrefix("a=rtpmap:\(payload) ")
        }) else {
            return
        }
        section.insert(
            prefix + " stereo=0;sprop-stereo=0",
            at: section.index(after: rtpmapIndex)
        )
    }

    private static func normalizedLines(_ sdp: String) -> [String] {
        sdp.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private static func mediaSectionRanges(
        in lines: [String]
    ) -> [Range<Int>] {
        let starts = lines.indices.filter { lines[$0].hasPrefix("m=") }
        return starts.enumerated().map { index, start in
            let end = index + 1 < starts.count ? starts[index + 1] : lines.endIndex
            return start..<end
        }
    }
}
