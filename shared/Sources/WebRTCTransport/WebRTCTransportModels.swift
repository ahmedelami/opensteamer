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

/// Controls whether ICE may use direct candidates or must prove the TURN fallback.
public enum WebRTCICEPolicy: String, Codable, Sendable {
    /// Lets ICE prefer a peer-to-peer candidate while retaining configured TURN as the standards-based reachability fallback.
    case directPreferred
    /// Forces TURN so the production fallback can be tested even on an easy local network.
    case relayOnly
}

/// Immutable inputs used to construct one role-specific WebRTC peer.
public struct WebRTCTransportConfiguration: Sendable {
    public let role: RemotePeerRole
    public let iceServers: [RemoteICEServer]
    public let icePolicy: WebRTCICEPolicy
    public let maximumVideoBitrate: Int?

    public init(
        role: RemotePeerRole,
        iceServers: [RemoteICEServer],
        icePolicy: WebRTCICEPolicy = .directPreferred,
        maximumVideoBitrate: Int? = nil
    ) {
        self.role = role
        self.iceServers = iceServers
        self.icePolicy = icePolicy
        self.maximumVideoBitrate = maximumVideoBitrate
    }
}

/// Stable projection of the native peer-connection lifecycle.
public enum WebRTCPeerState: String, Codable, Sendable {
    case new
    case connecting
    case connected
    case disconnected
    case failed
    case closed
}

/// Stable projection of the native ICE connection lifecycle.
public enum WebRTCICEState: String, Codable, Sendable {
    case new
    case checking
    case connected
    case completed
    case disconnected
    case failed
    case closed
    case unknown
}

/// Stable projection of native candidate-gathering progress.
public enum WebRTCICEGatheringState: String, Codable, Sendable {
    case new
    case gathering
    case complete
}

/// Stable projection of the ordered control data-channel lifecycle.
public enum WebRTCDataChannelState: String, Codable, Sendable {
    case connecting
    case open
    case closing
    case closed
}

/// The screen state the host has actually reached, not merely the state the viewer requested.
public enum WebRTCScreenState: String, Codable, CaseIterable, Sendable {
    case active
    case inactive
}

/// A monotonically identified command delivered over the ordered WebRTC control channel.
public struct WebRTCControlRequest: Codable, Equatable, Sendable {
    public let id: UInt64
    public let command: RemoteControlCommand

    public init(id: UInt64, command: RemoteControlCommand) {
        self.id = id
        self.command = command
    }
}

/// Confirmation that the host has completed a request and reached `state`.
public struct WebRTCControlAcknowledgement: Codable, Equatable, Sendable {
    public let id: UInt64
    public let state: WebRTCScreenState
    /// Present only when a successful Show/Active transition also authorizes this exact
    /// screen generation for remote input. Older v2 peers safely ignore this optional field.
    public let inputCapability: WebRTCInputCapability?

    public init(
        id: UInt64,
        state: WebRTCScreenState,
        inputCapability: WebRTCInputCapability? = nil
    ) {
        self.id = id
        self.state = state
        self.inputCapability = inputCapability
    }
}

/// A host-issued capability binding remote input to one successful Show/Active transition.
/// It deliberately rides inside the existing v2 acknowledgement so old v2 peers remain wire
/// compatible and never send input they do not understand.
public struct WebRTCInputCapability: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1
    public static let maximumMessageBytes = 4_096

    public let protocolVersion: Int
    public let inputSessionID: UUID
    public let screenRequestID: UInt64
    public let maxMessageBytes: Int
    public let supportsPrimaryDrag: Bool

    public init(
        inputSessionID: UUID,
        screenRequestID: UInt64,
        protocolVersion: Int = Self.currentProtocolVersion,
        maxMessageBytes: Int = Self.maximumMessageBytes,
        supportsPrimaryDrag: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.inputSessionID = inputSessionID
        self.screenRequestID = screenRequestID
        self.maxMessageBytes = maxMessageBytes
        self.supportsPrimaryDrag = supportsPrimaryDrag
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case inputSessionID
        case screenRequestID
        case maxMessageBytes
        case supportsPrimaryDrag
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        let inputSessionID = try container.decode(UUID.self, forKey: .inputSessionID)
        let screenRequestID = try container.decode(UInt64.self, forKey: .screenRequestID)
        let maxMessageBytes = try container.decode(Int.self, forKey: .maxMessageBytes)
        let supportsPrimaryDrag = if container.contains(.supportsPrimaryDrag) {
            try container.decode(Bool.self, forKey: .supportsPrimaryDrag)
        } else {
            false
        }
        guard protocolVersion == Self.currentProtocolVersion,
              inputSessionID != Self.zeroUUID,
              screenRequestID > 0,
              maxMessageBytes == Self.maximumMessageBytes else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Invalid remote-input capability."
            )
        }
        self.init(
            inputSessionID: inputSessionID,
            screenRequestID: screenRequestID,
            protocolVersion: protocolVersion,
            maxMessageBytes: maxMessageBytes,
            supportsPrimaryDrag: supportsPrimaryDrag
        )
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid remote-input capability.")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(inputSessionID, forKey: .inputSessionID)
        try container.encode(screenRequestID, forKey: .screenRequestID)
        try container.encode(maxMessageBytes, forKey: .maxMessageBytes)
        try container.encode(supportsPrimaryDrag, forKey: .supportsPrimaryDrag)
    }

    var isValid: Bool {
        protocolVersion == Self.currentProtocolVersion
            && inputSessionID != Self.zeroUUID
            && screenRequestID > 0
            && maxMessageBytes == Self.maximumMessageBytes
    }

    private static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

/// A finite point in the inclusive unit square used for resolution-independent input.
public struct WebRTCNormalizedPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    private enum CodingKeys: String, CodingKey { case x, y }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(Double.self, forKey: .x)
        let y = try container.decode(Double.self, forKey: .y)
        guard x.isFinite, y.isFinite,
              (0 ... 1).contains(x), (0 ... 1).contains(y) else {
            throw DecodingError.dataCorruptedError(
                forKey: .x,
                in: container,
                debugDescription: "Remote-input coordinates must be finite normalized values."
            )
        }
        self.init(x: x, y: y)
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid normalized point.")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
    }

    var isValid: Bool {
        x.isFinite && y.isFinite && (0 ... 1).contains(x) && (0 ... 1).contains(y)
    }
}

/// The intentionally small remote-input vocabulary. Return is distinct from inserted text so
/// control characters never enter the text path.
public enum WebRTCInputAction: Codable, Equatable, Sendable {
    case tap(WebRTCNormalizedPoint)
    case primaryDrag(start: WebRTCNormalizedPoint, end: WebRTCNormalizedPoint)
    case insertText(String, focusGeneration: UInt64)
    case backspace(focusGeneration: UInt64)
    case returnKey(focusGeneration: UInt64)

    private enum Kind: String, Codable {
        case tap
        case primaryDrag
        case text
        case backspace
        case returnKey = "return"
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case point
        case start
        case end
        case text
        case focusGeneration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .tap:
            guard !container.contains(.start), !container.contains(.end),
                  !container.contains(.text), !container.contains(.focusGeneration) else {
                throw Self.invalidAction(in: container)
            }
            self = .tap(try container.decode(WebRTCNormalizedPoint.self, forKey: .point))
        case .primaryDrag:
            guard !container.contains(.point), !container.contains(.text),
                  !container.contains(.focusGeneration) else {
                throw Self.invalidAction(in: container)
            }
            self = .primaryDrag(
                start: try container.decode(WebRTCNormalizedPoint.self, forKey: .start),
                end: try container.decode(WebRTCNormalizedPoint.self, forKey: .end)
            )
        case .text:
            guard !container.contains(.point), !container.contains(.start),
                  !container.contains(.end) else {
                throw Self.invalidAction(in: container)
            }
            let text = try container.decode(String.self, forKey: .text)
            let generation = try container.decode(UInt64.self, forKey: .focusGeneration)
            guard Self.isValidCommittedText(text), generation > 0 else {
                throw Self.invalidAction(in: container)
            }
            self = .insertText(text, focusGeneration: generation)
        case .backspace:
            guard !container.contains(.point), !container.contains(.start),
                  !container.contains(.end), !container.contains(.text) else {
                throw Self.invalidAction(in: container)
            }
            let generation = try container.decode(UInt64.self, forKey: .focusGeneration)
            guard generation > 0 else { throw Self.invalidAction(in: container) }
            self = .backspace(focusGeneration: generation)
        case .returnKey:
            guard !container.contains(.point), !container.contains(.start),
                  !container.contains(.end), !container.contains(.text) else {
                throw Self.invalidAction(in: container)
            }
            let generation = try container.decode(UInt64.self, forKey: .focusGeneration)
            guard generation > 0 else { throw Self.invalidAction(in: container) }
            self = .returnKey(focusGeneration: generation)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid remote-input action.")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tap(let point):
            try container.encode(Kind.tap, forKey: .kind)
            try container.encode(point, forKey: .point)
        case .primaryDrag(let start, let end):
            try container.encode(Kind.primaryDrag, forKey: .kind)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
        case .insertText(let text, let focusGeneration):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encode(focusGeneration, forKey: .focusGeneration)
        case .backspace(let focusGeneration):
            try container.encode(Kind.backspace, forKey: .kind)
            try container.encode(focusGeneration, forKey: .focusGeneration)
        case .returnKey(let focusGeneration):
            try container.encode(Kind.returnKey, forKey: .kind)
            try container.encode(focusGeneration, forKey: .focusGeneration)
        }
    }

    var isValid: Bool {
        switch self {
        case .tap(let point):
            point.isValid
        case .primaryDrag(let start, let end):
            start.isValid && end.isValid
        case .insertText(let text, let focusGeneration):
            focusGeneration > 0 && Self.isValidCommittedText(text)
        case .backspace(let focusGeneration), .returnKey(let focusGeneration):
            focusGeneration > 0
        }
    }

    /// Validates a whole committed-text chunk before it enters the remote-input queue or wire.
    /// AppKit's private-use function-key scalars are commands, not text, and are deliberately
    /// excluded along with control characters.
    public static func isValidCommittedText(_ text: String) -> Bool {
        !text.isEmpty
            && text.utf8.count <= 512
            && text.utf16.count <= 256
            && !text.unicodeScalars.contains(where: {
                (0x00 ... 0x1F).contains($0.value)
                    || (0x7F ... 0x9F).contains($0.value)
                    || (0xF700 ... 0xF8FF).contains($0.value)
            })
    }

    private static func invalidAction(
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> DecodingError {
        .dataCorruptedError(
            forKey: .kind,
            in: container,
            debugDescription: "Invalid remote-input action."
        )
    }
}

/// One monotonically identified input action bound to an active screen capability.
public struct WebRTCInputRequest: Codable, Equatable, Sendable {
    public let id: UInt64
    public let screenRequestID: UInt64
    public let inputSessionID: UUID
    public let action: WebRTCInputAction

    public init(
        id: UInt64,
        screenRequestID: UInt64,
        inputSessionID: UUID,
        action: WebRTCInputAction
    ) {
        self.id = id
        self.screenRequestID = screenRequestID
        self.inputSessionID = inputSessionID
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case screenRequestID
        case inputSessionID
        case action
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UInt64.self, forKey: .id)
        let screenRequestID = try container.decode(UInt64.self, forKey: .screenRequestID)
        let inputSessionID = try container.decode(UUID.self, forKey: .inputSessionID)
        let action = try container.decode(WebRTCInputAction.self, forKey: .action)
        guard id > 0,
              screenRequestID > 0,
              inputSessionID != WebRTCInputCapability.zeroUUIDForValidation,
              action.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Invalid remote-input request."
            )
        }
        self.init(
            id: id,
            screenRequestID: screenRequestID,
            inputSessionID: inputSessionID,
            action: action
        )
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid remote-input request.")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(screenRequestID, forKey: .screenRequestID)
        try container.encode(inputSessionID, forKey: .inputSessionID)
        try container.encode(action, forKey: .action)
    }

    var isValid: Bool {
        id > 0
            && screenRequestID > 0
            && inputSessionID != WebRTCInputCapability.zeroUUIDForValidation
            && action.isValid
    }
}

/// Host-reported editability state; secure fields never authorize committed-text insertion.
public enum WebRTCInputFocus: Codable, Equatable, Sendable {
    case none
    case editable(generation: UInt64, secure: Bool)

    private enum Kind: String, Codable { case none, editable }
    private enum CodingKeys: String, CodingKey { case kind, generation, secure }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .none:
            guard !container.contains(.generation), !container.contains(.secure) else {
                throw Self.invalidFocus(in: container)
            }
            self = .none
        case .editable:
            let generation = try container.decode(UInt64.self, forKey: .generation)
            guard generation > 0 else { throw Self.invalidFocus(in: container) }
            self = .editable(
                generation: generation,
                secure: try container.decode(Bool.self, forKey: .secure)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case .editable(let generation, let secure):
            guard generation > 0 else {
                throw EncodingError.invalidValue(
                    self,
                    .init(codingPath: encoder.codingPath, debugDescription: "Invalid focus generation.")
                )
            }
            try container.encode(Kind.editable, forKey: .kind)
            try container.encode(generation, forKey: .generation)
            try container.encode(secure, forKey: .secure)
        }
    }

    var isValid: Bool {
        if case .editable(let generation, _) = self { return generation > 0 }
        return true
    }

    private static func invalidFocus(
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> DecodingError {
        .dataCorruptedError(
            forKey: .kind,
            in: container,
            debugDescription: "Invalid remote-input focus."
        )
    }
}

/// Whether the host accepted a remote input request for OS injection.
public enum WebRTCInputFeedbackResult: String, Codable, Sendable {
    case accepted
    case rejected
}

/// Closed reasons for refusing input without exposing host UI or document contents.
public enum WebRTCInputRejectionReason: String, Codable, CaseIterable, Sendable {
    case inputDisabled
    case staleSession
    case invalidFocus
    case accessibilityPermissionRequired
    case eventPostingPermissionRequired
    case rateLimited
    case injectionFailed
    case invalidRequest
}

/// Result and focus state bound to the exact input and screen-generation identifiers.
public struct WebRTCInputFeedback: Codable, Equatable, Sendable {
    public let id: UInt64
    public let screenRequestID: UInt64
    public let inputSessionID: UUID
    public let result: WebRTCInputFeedbackResult
    public let rejectionReason: WebRTCInputRejectionReason?
    public let focus: WebRTCInputFocus

    public init(
        id: UInt64,
        screenRequestID: UInt64,
        inputSessionID: UUID,
        result: WebRTCInputFeedbackResult,
        rejectionReason: WebRTCInputRejectionReason? = nil,
        focus: WebRTCInputFocus = .none
    ) {
        self.id = id
        self.screenRequestID = screenRequestID
        self.inputSessionID = inputSessionID
        self.result = result
        self.rejectionReason = rejectionReason
        self.focus = focus
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case screenRequestID
        case inputSessionID
        case result
        case rejectionReason
        case focus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let result = try container.decode(WebRTCInputFeedbackResult.self, forKey: .result)
        let rejectionReason = try container.decodeIfPresent(
            WebRTCInputRejectionReason.self,
            forKey: .rejectionReason
        )
        let id = try container.decode(UInt64.self, forKey: .id)
        let screenRequestID = try container.decode(UInt64.self, forKey: .screenRequestID)
        let inputSessionID = try container.decode(UUID.self, forKey: .inputSessionID)
        let focus = try container.decode(WebRTCInputFocus.self, forKey: .focus)
        guard id > 0,
              screenRequestID > 0,
              inputSessionID != WebRTCInputCapability.zeroUUIDForValidation,
              focus.isValid,
              (result == .accepted ? rejectionReason == nil : rejectionReason != nil) else {
            throw DecodingError.dataCorruptedError(
                forKey: .result,
                in: container,
                debugDescription: "Invalid remote-input feedback."
            )
        }
        self.init(
            id: id,
            screenRequestID: screenRequestID,
            inputSessionID: inputSessionID,
            result: result,
            rejectionReason: rejectionReason,
            focus: focus
        )
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid remote-input feedback.")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(screenRequestID, forKey: .screenRequestID)
        try container.encode(inputSessionID, forKey: .inputSessionID)
        try container.encode(result, forKey: .result)
        try container.encodeIfPresent(rejectionReason, forKey: .rejectionReason)
        try container.encode(focus, forKey: .focus)
    }

    var isValid: Bool {
        id > 0
            && screenRequestID > 0
            && inputSessionID != WebRTCInputCapability.zeroUUIDForValidation
            && focus.isValid
            && (result == .accepted ? rejectionReason == nil : rejectionReason != nil)
    }
}

private extension WebRTCInputCapability {
    static var zeroUUIDForValidation: UUID { zeroUUID }
}

/// A host-owned, synchronously revocable capability for the single transition that exposes
/// screen media. The peer holds its lock across the final native-health check and Active ACK,
/// giving recovery/capture-stop code a deterministic ordering against that transition.
public final class WebRTCControlAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var isRevoked = false

    public init() {}

    public func revoke() {
        lock.lock()
        isRevoked = true
        lock.unlock()
    }

    public var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isRevoked
    }

    public func withValidAuthorization<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !isRevoked else {
            throw WebRTCTransportError.controlAuthorizationRevoked
        }
        return try operation()
    }
}

/// A host-owned, synchronously revocable capability for exposing captured system audio to the
/// WebRTC sender. It is intentionally independent of screen visibility: hiding the remote screen
/// must not mute audio, while any transport-uncertainty boundary revokes this gate immediately.
public final class WebRTCAudioAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var isRevoked = false

    public init() {}

    public func revoke() {
        lock.lock()
        isRevoked = true
        lock.unlock()
    }

    public var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isRevoked
    }

    public func withValidAuthorization<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !isRevoked else {
            throw WebRTCTransportError.audioAuthorizationRevoked
        }
        return try operation()
    }
}

/// A process-local, synchronously revocable gate for one remote-input generation.
///
/// This is deliberately not part of the Codable wire capability. The host service and
/// `WebRTCPeer` share the same instance so transport/capture uncertainty can linearize against
/// an already-queued request at the final OS-injection boundary. The viewer receives a separate
/// local instance so dismiss/background/Hide can likewise linearize against a queued send.
public final class WebRTCInputAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var isRevoked = false

    public init() {}

    public func revoke() {
        lock.lock()
        isRevoked = true
        lock.unlock()
    }

    public var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isRevoked
    }

    public func withValidAuthorization<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !isRevoked else {
            throw WebRTCTransportError.inputUnavailable
        }
        return try operation()
    }
}

/// Privacy-reduced ICE candidate classes used by diagnostics.
public enum WebRTCCandidateType: String, Codable, Sendable {
    case host
    case serverReflexive
    case peerReflexive
    case relay
    case unknown
}

/// Non-address ICE candidate metadata sufficient to explain direct versus relayed routing.
public struct WebRTCCandidateDiagnostics: Codable, Equatable, Sendable {
    public let type: WebRTCCandidateType
    public let transport: String?
    public let networkType: String?
    public let relayProtocol: String?

    public init(
        type: WebRTCCandidateType,
        transport: String? = nil,
        networkType: String? = nil,
        relayProtocol: String? = nil
    ) {
        self.type = type
        self.transport = transport
        self.networkType = networkType
        self.relayProtocol = relayProtocol
    }
}

/// Whether the selected ICE pair is peer-to-peer, TURN-relayed, or not yet classified.
public enum WebRTCICERouteKind: String, Codable, Sendable {
    case direct
    case relayed
    case unknown
}

/// The privacy-reduced local and remote candidates in the selected ICE route.
public struct WebRTCICERouteDiagnostics: Codable, Equatable, Sendable {
    public let kind: WebRTCICERouteKind
    public let local: WebRTCCandidateDiagnostics?
    public let remote: WebRTCCandidateDiagnostics?

    public init(
        kind: WebRTCICERouteKind,
        local: WebRTCCandidateDiagnostics? = nil,
        remote: WebRTCCandidateDiagnostics? = nil
    ) {
        self.kind = kind
        self.local = local
        self.remote = remote
    }
}

/// Stable outbound or inbound video counters extracted from a native statistics report.
public struct WebRTCVideoStatistics: Codable, Equatable, Sendable {
    public let bytes: UInt64?
    public let packets: UInt64?
    public let packetsLost: Int64?
    public let framesPerSecond: Double?
    public let frameWidth: Int?
    public let frameHeight: Int?
    public let framesEncodedOrDecoded: UInt64?

    public init(
        bytes: UInt64? = nil,
        packets: UInt64? = nil,
        packetsLost: Int64? = nil,
        framesPerSecond: Double? = nil,
        frameWidth: Int? = nil,
        frameHeight: Int? = nil,
        framesEncodedOrDecoded: UInt64? = nil
    ) {
        self.bytes = bytes
        self.packets = packets
        self.packetsLost = packetsLost
        self.framesPerSecond = framesPerSecond
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.framesEncodedOrDecoded = framesEncodedOrDecoded
    }
}

/// Stable audio quality, concealment, jitter-buffer, and transport counters.
public struct WebRTCAudioStatistics: Codable, Equatable, Sendable {
    public let bytes: UInt64?
    public let packets: UInt64?
    public let packetsLost: Int64?
    public let packetsDiscarded: UInt64?
    public let jitter: Double?
    public let jitterBufferDelay: Double?
    public let jitterBufferEmittedCount: UInt64?
    public let jitterBufferTargetDelay: Double?
    public let jitterBufferMinimumDelay: Double?
    public let totalSamplesReceived: UInt64?
    public let concealedSamples: UInt64?
    public let silentConcealedSamples: UInt64?
    public let concealmentEvents: UInt64?
    public let insertedSamplesForDeceleration: UInt64?
    public let removedSamplesForAcceleration: UInt64?
    public let totalAudioEnergy: Double?
    public let totalSamplesDuration: Double?
    public let audioLevel: Double?
    public let totalPacketSendDelay: Double?
    public let nackCount: UInt64?
    public let targetBitrate: Double?
    public let roundTripTime: Double?

    public init(
        bytes: UInt64? = nil,
        packets: UInt64? = nil,
        packetsLost: Int64? = nil,
        packetsDiscarded: UInt64? = nil,
        jitter: Double? = nil,
        jitterBufferDelay: Double? = nil,
        jitterBufferEmittedCount: UInt64? = nil,
        jitterBufferTargetDelay: Double? = nil,
        jitterBufferMinimumDelay: Double? = nil,
        totalSamplesReceived: UInt64? = nil,
        concealedSamples: UInt64? = nil,
        silentConcealedSamples: UInt64? = nil,
        concealmentEvents: UInt64? = nil,
        insertedSamplesForDeceleration: UInt64? = nil,
        removedSamplesForAcceleration: UInt64? = nil,
        totalAudioEnergy: Double? = nil,
        totalSamplesDuration: Double? = nil,
        audioLevel: Double? = nil,
        totalPacketSendDelay: Double? = nil,
        nackCount: UInt64? = nil,
        targetBitrate: Double? = nil,
        roundTripTime: Double? = nil
    ) {
        self.bytes = bytes
        self.packets = packets
        self.packetsLost = packetsLost
        self.packetsDiscarded = packetsDiscarded
        self.jitter = jitter
        self.jitterBufferDelay = jitterBufferDelay
        self.jitterBufferEmittedCount = jitterBufferEmittedCount
        self.jitterBufferTargetDelay = jitterBufferTargetDelay
        self.jitterBufferMinimumDelay = jitterBufferMinimumDelay
        self.totalSamplesReceived = totalSamplesReceived
        self.concealedSamples = concealedSamples
        self.silentConcealedSamples = silentConcealedSamples
        self.concealmentEvents = concealmentEvents
        self.insertedSamplesForDeceleration = insertedSamplesForDeceleration
        self.removedSamplesForAcceleration = removedSamplesForAcceleration
        self.totalAudioEnergy = totalAudioEnergy
        self.totalSamplesDuration = totalSamplesDuration
        self.audioLevel = audioLevel
        self.totalPacketSendDelay = totalPacketSendDelay
        self.nackCount = nackCount
        self.targetBitrate = targetBitrate
        self.roundTripTime = roundTripTime
    }
}

/// A timestamped diagnostic snapshot across route, video, and audio statistics.
public struct WebRTCStatisticsSnapshot: Codable, Equatable, Sendable {
    public let collectedAt: Date
    public let route: WebRTCICERouteDiagnostics?
    public let currentRoundTripTime: Double?
    public let availableOutgoingBitrate: Double?
    public let jitter: Double?
    public let outboundVideo: WebRTCVideoStatistics?
    public let inboundVideo: WebRTCVideoStatistics?
    public let audioSource: WebRTCAudioStatistics?
    public let outboundAudio: WebRTCAudioStatistics?
    public let inboundAudio: WebRTCAudioStatistics?
    public let remoteInboundAudio: WebRTCAudioStatistics?

    public init(
        collectedAt: Date = Date(),
        route: WebRTCICERouteDiagnostics? = nil,
        currentRoundTripTime: Double? = nil,
        availableOutgoingBitrate: Double? = nil,
        jitter: Double? = nil,
        outboundVideo: WebRTCVideoStatistics? = nil,
        inboundVideo: WebRTCVideoStatistics? = nil,
        audioSource: WebRTCAudioStatistics? = nil,
        outboundAudio: WebRTCAudioStatistics? = nil,
        inboundAudio: WebRTCAudioStatistics? = nil,
        remoteInboundAudio: WebRTCAudioStatistics? = nil
    ) {
        self.collectedAt = collectedAt
        self.route = route
        self.currentRoundTripTime = currentRoundTripTime
        self.availableOutgoingBitrate = availableOutgoingBitrate
        self.jitter = jitter
        self.outboundVideo = outboundVideo
        self.inboundVideo = inboundVideo
        self.audioSource = audioSource
        self.outboundAudio = outboundAudio
        self.inboundAudio = inboundAudio
        self.remoteInboundAudio = remoteInboundAudio
    }
}

/// A failed STUN/TURN candidate probe. This is diagnostic evidence, not by itself a
/// transport failure: ICE can still select a healthy candidate from another interface
/// or server URL.
public struct WebRTCIceCandidateError: Codable, Equatable, Sendable {
    public let address: String
    public let port: Int
    public let url: String
    public let errorCode: Int
    public let reason: String

    public init(
        address: String,
        port: Int,
        url: String,
        errorCode: Int,
        reason: String
    ) {
        self.address = address
        self.port = port
        self.url = url
        self.errorCode = errorCode
        self.reason = reason
    }
}

/// Bounded events emitted by `WebRTCPeer` to its signaling and media owner.
public enum WebRTCTransportEvent: Sendable {
    case outboundSignal(RemoteSignalPayload)
    case peerStateChanged(WebRTCPeerState)
    case iceStateChanged(WebRTCICEState)
    case iceGatheringStateChanged(WebRTCICEGatheringState)
    case dataChannelStateChanged(WebRTCDataChannelState)
    /// A new command for the host application to complete. The transport never acknowledges it itself.
    case controlRequestReceived(WebRTCControlRequest)
    /// The current viewer request was completed by the host. Stale and duplicate acknowledgements are suppressed.
    case controlAcknowledgementReceived(
        WebRTCControlAcknowledgement,
        inputAuthorization: WebRTCInputAuthorization?
    )
    /// A validated, session-bound input request for the host application to inject at most once.
    case inputRequestReceived(
        WebRTCInputRequest,
        authorization: WebRTCInputAuthorization
    )
    /// The host's result for a viewer input request. Duplicate feedback is suppressed.
    case inputFeedbackReceived(WebRTCInputFeedback)
    /// The input capability was fail-closed independently of screen media/control state.
    case inputSessionInvalidated(String)
    /// Legacy signaling control event. Worldwide data-channel control uses the typed request/ack events above.
    case controlReceived(RemoteControlCommand)
    case identityReceived(RemotePeerIdentity)
    case remoteAudioTrack(WebRTCRemoteAudioTrack)
    case remoteVideoTrack(WebRTCRemoteVideoTrack)
    case routeChanged(WebRTCICERouteDiagnostics)
    case statistics(WebRTCStatisticsSnapshot)
    case iceCandidateError(WebRTCIceCandidateError)
    case negotiationNeeded
    case ended(RemoteSessionEndReason)
    case diagnosticFailure(String)
}

/// Construction, signaling, authorization, and data-channel failures for WebRTC transport.
public enum WebRTCTransportError: Error, Equatable, LocalizedError, Sendable {
    case relayPolicyRequiresTURN
    case peerConnectionCreationFailed
    case audioTrackCreationFailed
    case videoTrackCreationFailed
    case dataChannelCreationFailed
    case invalidRole
    case alreadyStarted
    case iceRestartAlreadyInProgress
    case unexpectedSignal
    case invalidSessionDescription
    case invalidICECandidate
    case pendingRemoteCandidateLimitExceeded(Int)
    case dataChannelUnavailable
    case transportNotHealthy
    case dataChannelBackpressured
    case dataChannelSendFailed
    case controlRequestIDExhausted
    case controlAuthorizationRequired
    case controlAuthorizationRevoked
    case audioAuthorizationRevoked
    case unknownControlRequest(UInt64)
    case staleControlRequest(UInt64)
    case conflictingControlAcknowledgement(UInt64)
    case inputUnavailable
    case inputRequestIDExhausted
    case invalidInputCapability
    case invalidInputRequest
    case unknownInputRequest(UInt64)
    case staleInputRequest(UInt64)
    case conflictingInputFeedback(UInt64)
    case transportClosed
    case nativeFailure(String)

    public var errorDescription: String? {
        switch self {
        case .relayPolicyRequiresTURN:
            "Relay-only testing requires at least one TURN server."
        case .peerConnectionCreationFailed:
            "The WebRTC peer connection could not be created."
        case .audioTrackCreationFailed:
            "The WebRTC system-audio track could not be created."
        case .videoTrackCreationFailed:
            "The WebRTC screen video track could not be created."
        case .dataChannelCreationFailed:
            "The WebRTC control channel could not be created."
        case .invalidRole:
            "This operation is not valid for the peer role."
        case .alreadyStarted:
            "The WebRTC peer has already started."
        case .iceRestartAlreadyInProgress:
            "An ICE restart offer is already awaiting its answer."
        case .unexpectedSignal:
            "The signaling message is not valid in the current peer state."
        case .invalidSessionDescription:
            "The remote session description is invalid."
        case .invalidICECandidate:
            "The remote ICE candidate is invalid."
        case .pendingRemoteCandidateLimitExceeded(let limit):
            "The pre-description remote ICE candidate limit (\(limit)) was exceeded."
        case .dataChannelUnavailable:
            "The WebRTC control channel is not open."
        case .transportNotHealthy:
            "The WebRTC transport is not stable and healthy enough for remote media capture."
        case .dataChannelBackpressured:
            "The WebRTC control channel is temporarily backpressured."
        case .dataChannelSendFailed:
            "The WebRTC control message could not be sent."
        case .controlRequestIDExhausted:
            "The WebRTC control request identifier space was exhausted."
        case .controlAuthorizationRequired:
            "An Active screen acknowledgement requires a current capture authorization."
        case .controlAuthorizationRevoked:
            "The screen-control authorization was revoked before capture could be exposed."
        case .audioAuthorizationRevoked:
            "The system-audio authorization was revoked before capture could be exposed."
        case .unknownControlRequest(let id):
            "Control request \(id) is unknown."
        case .staleControlRequest(let id):
            "Control request \(id) is stale."
        case .conflictingControlAcknowledgement(let id):
            "Control request \(id) was already acknowledged with a different state."
        case .inputUnavailable:
            "Remote input is not authorized for the active screen session."
        case .inputRequestIDExhausted:
            "The remote-input request identifier space was exhausted."
        case .invalidInputCapability:
            "The remote-input capability is invalid for this screen request."
        case .invalidInputRequest:
            "The remote-input request is invalid."
        case .unknownInputRequest(let id):
            "Remote-input request \(id) is unknown."
        case .staleInputRequest(let id):
            "Remote-input request \(id) is stale."
        case .conflictingInputFeedback(let id):
            "Remote-input request \(id) was already completed with different feedback."
        case .transportClosed:
            "The WebRTC transport is closed."
        case .nativeFailure(let message):
            message
        }
    }
}
