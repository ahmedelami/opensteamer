import Foundation

/// The product's Opus policy for system audio.
///
/// WebRTC advertises Opus as `opus/48000/2` even when it will encode one channel, so the channel
/// intent must be carried by fmtp. This transform operates only on local SDP and discovers every
/// Opus payload number from its audio media section instead of relying on the commonly used 111.
/// Remote descriptions remain untouched, allowing an older peer to negotiate the subset it knows.
enum OpusStereoSDP {
    static let maximumAverageBitrateBps = 192_000

    private static let managedParameters: [(key: String, value: String)] = [
        ("stereo", "1"),
        ("sprop-stereo", "1"),
        ("maxaveragebitrate", String(maximumAverageBitrateBps))
    ]

    static func applyingHighFidelityPolicy(to sessionDescription: String) -> String {
        let separator = sessionDescription.contains("\r\n") ? "\r\n" : "\n"
        var lines = sessionDescription.components(separatedBy: separator)
        var mediaStart = 0

        while mediaStart < lines.endIndex {
            guard lines[mediaStart].lowercased().hasPrefix("m=audio ") else {
                mediaStart += 1
                continue
            }

            let mediaEnd = lines[(mediaStart + 1)...].firstIndex(where: {
                $0.hasPrefix("m=")
            }) ?? lines.endIndex
            var section = Array(lines[mediaStart..<mediaEnd])
            applyPolicy(toAudioSection: &section)
            lines.replaceSubrange(mediaStart..<mediaEnd, with: section)
            mediaStart += section.count
        }

        return lines.joined(separator: separator)
    }

    /// An answer may narrow an offer but must not introduce format parameters the offer did not
    /// advertise. Product offers always carry the complete policy; older offers therefore retain
    /// their native mono-compatible answer instead of being upgraded unilaterally.
    static func applyingHighFidelityAnswerPolicy(
        to sessionDescription: String,
        remoteOffer: String
    ) -> String {
        guard advertisesCompleteHighFidelityPolicy(remoteOffer) else {
            return sessionDescription
        }
        return applyingHighFidelityPolicy(to: sessionDescription)
    }

    private static func applyPolicy(toAudioSection lines: inout [String]) {
        let mappings = lines.enumerated().compactMap { index, line -> (Int, String)? in
            guard let payload = opusPayloadType(fromRtpMap: line) else { return nil }
            return (index, payload)
        }

        // Work backwards so inserting a missing fmtp line cannot invalidate an earlier index.
        for (rtpMapIndex, payload) in mappings.reversed() {
            if let fmtpIndex = lines.indices.first(where: {
                fmtpPayloadType(from: lines[$0]) == payload
            }) {
                lines[fmtpIndex] = mergingManagedParameters(
                    into: lines[fmtpIndex],
                    payload: payload
                )
            } else {
                lines.insert(
                    formatParametersLine(payload: payload, retainedParameters: []),
                    at: rtpMapIndex + 1
                )
            }
        }
    }

    private static func opusPayloadType(fromRtpMap line: String) -> String? {
        let prefix = "a=rtpmap:"
        guard line.lowercased().hasPrefix(prefix) else { return nil }
        let remainder = line.dropFirst(prefix.count)
        guard let separatorIndex = remainder.firstIndex(where: \.isWhitespace) else {
            return nil
        }

        let payload = remainder[..<separatorIndex]
        let encoding = remainder[separatorIndex...]
            .trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: \.isWhitespace)
            .first
        guard !payload.isEmpty,
              payload.allSatisfy(\.isNumber),
              encoding?.caseInsensitiveCompare("opus/48000/2") == .orderedSame else {
            return nil
        }
        return String(payload)
    }

    private static func fmtpPayloadType(from line: String) -> String? {
        let prefix = "a=fmtp:"
        guard line.lowercased().hasPrefix(prefix) else { return nil }
        let payload = line.dropFirst(prefix.count).prefix { !$0.isWhitespace }
        guard !payload.isEmpty, payload.allSatisfy(\.isNumber) else { return nil }
        return String(payload)
    }

    private static func mergingManagedParameters(
        into line: String,
        payload: String
    ) -> String {
        let prefix = "a=fmtp:\(payload)"
        let retainedParameters = line.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespaces)
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { parameter in
                guard let key = parameterKey(parameter) else { return true }
                return !managedParameters.contains(where: {
                    key.caseInsensitiveCompare($0.key) == .orderedSame
                })
            }
        return formatParametersLine(
            payload: payload,
            retainedParameters: retainedParameters
        )
    }

    private static func parameterKey(_ parameter: String) -> String? {
        guard let equals = parameter.firstIndex(of: "=") else { return nil }
        let key = parameter[..<equals].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    private static func formatParametersLine(
        payload: String,
        retainedParameters: [String]
    ) -> String {
        let policyParameters = managedParameters.map { "\($0.key)=\($0.value)" }
        return "a=fmtp:\(payload) \((retainedParameters + policyParameters).joined(separator: ";"))"
    }

    private static func advertisesCompleteHighFidelityPolicy(
        _ sessionDescription: String
    ) -> Bool {
        let separator = sessionDescription.contains("\r\n") ? "\r\n" : "\n"
        let lines = sessionDescription.components(separatedBy: separator)
        var mediaStart = 0
        var foundOpus = false

        while mediaStart < lines.endIndex {
            guard lines[mediaStart].lowercased().hasPrefix("m=audio ") else {
                mediaStart += 1
                continue
            }
            let mediaEnd = lines[(mediaStart + 1)...].firstIndex(where: {
                $0.hasPrefix("m=")
            }) ?? lines.endIndex
            let section = Array(lines[mediaStart..<mediaEnd])
            let payloads = section.compactMap(opusPayloadType(fromRtpMap:))

            for payload in payloads {
                foundOpus = true
                guard let fmtp = section.first(where: {
                    fmtpPayloadType(from: $0) == payload
                }), containsCompletePolicy(fmtp) else {
                    return false
                }
            }
            mediaStart = mediaEnd
        }

        return foundOpus
    }

    private static func containsCompletePolicy(_ formatParametersLine: String) -> Bool {
        guard let payload = fmtpPayloadType(from: formatParametersLine) else { return false }
        let prefix = "a=fmtp:\(payload)"
        let parameters = formatParametersLine.dropFirst(prefix.count)
            .split(separator: ";", omittingEmptySubsequences: true)
            .reduce(into: [String: String]()) { result, parameter in
                guard let equals = parameter.firstIndex(of: "=") else { return }
                let key = parameter[..<equals].trimmingCharacters(in: .whitespaces)
                let value = parameter[parameter.index(after: equals)...]
                    .trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return }
                result[key.lowercased()] = value
            }

        return managedParameters.allSatisfy { parameters[$0.key] == $0.value }
    }
}
