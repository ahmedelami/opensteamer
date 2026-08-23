import Foundation
import RemoteSessionCore

/// Parses ICE username fragments at session, media-section, and candidate scope.
enum ICEUsernameFragmentParser {
    private static let sessionDescriptionPrefix = "a=ice-ufrag:"
    private static let mediaDescriptionPrefix = "m="
    private static let mediaIdentifierPrefix = "a=mid:"

    static func fragments(inSessionDescription sdp: String) -> Set<String> {
        Set(
            sdp.split(whereSeparator: \.isNewline).compactMap { line in
                guard line.hasPrefix(sessionDescriptionPrefix) else { return nil }
                let value = line.dropFirst(sessionDescriptionPrefix.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        )
    }

    static func mapping(inSessionDescription sdp: String) -> ICEUsernameFragmentMap? {
        /// Mutable parse state before session-level inheritance has been resolved.
        struct MutableMediaSection {
            let mLineIndex: Int32
            var mid: String?
            var fragment: String?
        }

        var sessionFragment: String?
        var sections: [MutableMediaSection] = []

        for rawLine in sdp.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix(mediaDescriptionPrefix) {
                guard let index = Int32(exactly: sections.count) else { return nil }
                sections.append(
                    MutableMediaSection(
                        mLineIndex: index,
                        mid: nil,
                        fragment: nil
                    )
                )
                continue
            }

            if line.hasPrefix(sessionDescriptionPrefix) {
                let value = line.dropFirst(sessionDescriptionPrefix.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty,
                      !value.contains(where: \.isWhitespace) else {
                    return nil
                }
                if sections.isEmpty {
                    if let sessionFragment, sessionFragment != value { return nil }
                    sessionFragment = value
                } else {
                    let index = sections.index(before: sections.endIndex)
                    if let fragment = sections[index].fragment, fragment != value { return nil }
                    sections[index].fragment = value
                }
                continue
            }

            if line.hasPrefix(mediaIdentifierPrefix) {
                guard !sections.isEmpty else { return nil }
                let value = line.dropFirst(mediaIdentifierPrefix.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty,
                      !value.contains(where: \.isWhitespace) else {
                    return nil
                }
                let index = sections.index(before: sections.endIndex)
                if let mid = sections[index].mid, mid != value { return nil }
                sections[index].mid = value
            }
        }

        guard !sections.isEmpty else { return nil }
        var observedMIDs = Set<String>()
        var declaredFragments = Set<String>()
        if let sessionFragment {
            declaredFragments.insert(sessionFragment)
        }
        let immutableSections: [ICEUsernameFragmentMap.MediaSection] = sections.compactMap {
            section in
            if let mid = section.mid, !observedMIDs.insert(mid).inserted {
                return nil
            }
            let effectiveFragment = section.fragment ?? sessionFragment
            if let fragment = section.fragment {
                declaredFragments.insert(fragment)
            }
            return ICEUsernameFragmentMap.MediaSection(
                mLineIndex: section.mLineIndex,
                mid: section.mid,
                effectiveFragment: effectiveFragment
            )
        }
        guard immutableSections.count == sections.count else { return nil }
        return ICEUsernameFragmentMap(
            declaredFragments: declaredFragments,
            mediaSections: immutableSections
        )
    }

    static func fragment(inCandidateSDP sdp: String) -> String? {
        let tokens = sdp.split(whereSeparator: \.isWhitespace)
        guard let index = tokens.firstIndex(where: {
            String($0).caseInsensitiveCompare("ufrag") == .orderedSame
        }), tokens.indices.contains(index + 1) else {
            return nil
        }
        let value = String(tokens[index + 1])
        return value.isEmpty ? nil : value
    }
}

/// Resolves each SDP media section to the ICE generation it accepts.
struct ICEUsernameFragmentMap: Equatable, Sendable {
    /// One SDP media section and the effective ICE generation after inheritance.
    struct MediaSection: Equatable, Sendable {
        let mLineIndex: Int32
        let mid: String?
        let effectiveFragment: String?
    }

    let declaredFragments: Set<String>
    let mediaSections: [MediaSection]

    func effectiveFragment(
        sdpMid: String?,
        sdpMLineIndex: Int32?
    ) -> String? {
        mediaSection(
            sdpMid: sdpMid,
            sdpMLineIndex: sdpMLineIndex
        )?.effectiveFragment
    }

    func mediaSection(
        sdpMid: String?,
        sdpMLineIndex: Int32?
    ) -> MediaSection? {
        let sectionByMID = sdpMid.flatMap { mid in
            mediaSections.first(where: { $0.mid == mid })
        }
        let sectionByIndex = sdpMLineIndex.flatMap { index in
            mediaSections.first(where: { $0.mLineIndex == index })
        }

        switch (sdpMid, sdpMLineIndex) {
        case (.some, .some):
            guard let sectionByMID,
                  let sectionByIndex,
                  sectionByMID.mLineIndex == sectionByIndex.mLineIndex else {
                return nil
            }
            return sectionByMID
        case (.some, .none):
            return sectionByMID
        case (.none, .some):
            return sectionByIndex
        case (.none, .none):
            return nil
        }
    }
}

/// Rejects candidates that are ambiguous or belong to a stale ICE generation.
enum ICECandidateUsernameFragmentValidator {
    static func validatedCandidate(
        _ candidate: RemoteICECandidate,
        against mapping: ICEUsernameFragmentMap,
        requiresExplicitFragment: Bool
    ) -> RemoteICECandidate? {
        guard let section = mapping.mediaSection(
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex
        ), let expectedFragment = section.effectiveFragment else {
            return nil
        }

        let inlineFragment = ICEUsernameFragmentParser.fragment(
            inCandidateSDP: candidate.sdp
        )
        if let declaredFragment = candidate.usernameFragment,
           let inlineFragment,
           declaredFragment != inlineFragment {
            return nil
        }

        let suppliedFragment = candidate.usernameFragment ?? inlineFragment
        if let suppliedFragment {
            guard suppliedFragment == expectedFragment else { return nil }
        } else if requiresExplicitFragment {
            return nil
        }

        return RemoteICECandidate(
            sdp: candidate.sdp,
            sdpMid: candidate.sdpMid ?? section.mid,
            sdpMLineIndex: candidate.sdpMLineIndex ?? section.mLineIndex,
            usernameFragment: suppliedFragment ?? expectedFragment
        )
    }
}
