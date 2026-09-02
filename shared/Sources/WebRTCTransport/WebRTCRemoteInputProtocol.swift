import Foundation

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
    public let supportsScroll: Bool

    public init(
        inputSessionID: UUID,
        screenRequestID: UInt64,
        protocolVersion: Int = Self.currentProtocolVersion,
        maxMessageBytes: Int = Self.maximumMessageBytes,
        supportsPrimaryDrag: Bool = false,
        supportsScroll: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.inputSessionID = inputSessionID
        self.screenRequestID = screenRequestID
        self.maxMessageBytes = maxMessageBytes
        self.supportsPrimaryDrag = supportsPrimaryDrag
        self.supportsScroll = supportsScroll
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case inputSessionID
        case screenRequestID
        case maxMessageBytes
        case supportsPrimaryDrag
        case supportsScroll
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
        let supportsScroll = if container.contains(.supportsScroll) {
            try container.decode(Bool.self, forKey: .supportsScroll)
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
            supportsPrimaryDrag: supportsPrimaryDrag,
            supportsScroll: supportsScroll
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
        try container.encode(supportsScroll, forKey: .supportsScroll)
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

/// The decoded video dimensions the viewer used to normalize a pointer action.
///
/// WebRTC may adapt and align the exact pixel count in transit, so the host permits only bounded
/// alignment error around this shape. Binding every tap and drag to the frame that was actually
/// visible rejects a delayed materially different gesture after a live display-mode change.
public struct WebRTCInputVideoSize: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey { case width, height }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        guard Self.isValid(width: width, height: height) else {
            throw DecodingError.dataCorruptedError(
                forKey: .width,
                in: container,
                debugDescription: "Invalid viewer video dimensions."
            )
        }
        self.init(width: width, height: height)
    }

    public func encode(to encoder: any Encoder) throws {
        guard Self.isValid(width: width, height: height) else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Invalid viewer video dimensions."
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
    }

    var isValid: Bool {
        Self.isValid(width: width, height: height)
    }

    private static func isValid(width: Int, height: Int) -> Bool {
        // The upper bound keeps an untrusted wire value away from integer/ratio extremes while
        // remaining far above every supported WebRTC and Apple display dimension.
        (2 ... 32_768).contains(width) && (2 ... 32_768).contains(height)
    }
}

/// The intentionally small remote-input vocabulary. Return is distinct from inserted text so
/// control characters never enter the text path.
public enum WebRTCInputAction: Codable, Equatable, Sendable {
    /// Maximum absolute pixel-unit delta accepted in one atomic scroll request.
    public static let maximumScrollDeltaMagnitude: Int32 = 4_096

    case tap(WebRTCNormalizedPoint)
    case primaryDrag(start: WebRTCNormalizedPoint, end: WebRTCNormalizedPoint)
    /// Incremental finger displacement in rendered-video pixel units: positive x is right and
    /// positive y is down. The host owns the single conversion to native scroll-wheel semantics.
    case scroll(anchor: WebRTCNormalizedPoint, deltaX: Int32, deltaY: Int32)
    case insertText(String, focusGeneration: UInt64)
    case backspace(focusGeneration: UInt64)
    case returnKey(focusGeneration: UInt64)

    private enum Kind: String, Codable {
        case tap
        case primaryDrag
        case scroll
        case text
        case backspace
        case returnKey = "return"
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case point
        case start
        case end
        case anchor
        case deltaX
        case deltaY
        case text
        case focusGeneration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .tap:
            guard !container.contains(.start), !container.contains(.end),
                  !container.contains(.anchor), !container.contains(.deltaX),
                  !container.contains(.deltaY),
                  !container.contains(.text), !container.contains(.focusGeneration) else {
                throw Self.invalidAction(in: container)
            }
            self = .tap(try container.decode(WebRTCNormalizedPoint.self, forKey: .point))
        case .primaryDrag:
            guard !container.contains(.point), !container.contains(.text),
                  !container.contains(.anchor), !container.contains(.deltaX),
                  !container.contains(.deltaY),
                  !container.contains(.focusGeneration) else {
                throw Self.invalidAction(in: container)
            }
            self = .primaryDrag(
                start: try container.decode(WebRTCNormalizedPoint.self, forKey: .start),
                end: try container.decode(WebRTCNormalizedPoint.self, forKey: .end)
            )
        case .scroll:
            guard !container.contains(.point), !container.contains(.start),
                  !container.contains(.end), !container.contains(.text),
                  !container.contains(.focusGeneration) else {
                throw Self.invalidAction(in: container)
            }
            let anchor = try container.decode(WebRTCNormalizedPoint.self, forKey: .anchor)
            let deltaX = try container.decode(Int32.self, forKey: .deltaX)
            let deltaY = try container.decode(Int32.self, forKey: .deltaY)
            guard Self.isValidScrollDelta(deltaX: deltaX, deltaY: deltaY) else {
                throw Self.invalidAction(in: container)
            }
            self = .scroll(anchor: anchor, deltaX: deltaX, deltaY: deltaY)
        case .text:
            guard !container.contains(.point), !container.contains(.start),
                  !container.contains(.end), !container.contains(.anchor),
                  !container.contains(.deltaX), !container.contains(.deltaY) else {
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
                  !container.contains(.end), !container.contains(.anchor),
                  !container.contains(.deltaX), !container.contains(.deltaY),
                  !container.contains(.text) else {
                throw Self.invalidAction(in: container)
            }
            let generation = try container.decode(UInt64.self, forKey: .focusGeneration)
            guard generation > 0 else { throw Self.invalidAction(in: container) }
            self = .backspace(focusGeneration: generation)
        case .returnKey:
            guard !container.contains(.point), !container.contains(.start),
                  !container.contains(.end), !container.contains(.anchor),
                  !container.contains(.deltaX), !container.contains(.deltaY),
                  !container.contains(.text) else {
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
        case .scroll(let anchor, let deltaX, let deltaY):
            try container.encode(Kind.scroll, forKey: .kind)
            try container.encode(anchor, forKey: .anchor)
            try container.encode(deltaX, forKey: .deltaX)
            try container.encode(deltaY, forKey: .deltaY)
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
        case .scroll(let anchor, let deltaX, let deltaY):
            anchor.isValid && Self.isValidScrollDelta(deltaX: deltaX, deltaY: deltaY)
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

    private static func isValidScrollDelta(deltaX: Int32, deltaY: Int32) -> Bool {
        let validRange = -maximumScrollDeltaMagnitude ... maximumScrollDeltaMagnitude
        return (deltaX != 0 || deltaY != 0)
            && validRange.contains(deltaX)
            && validRange.contains(deltaY)
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
    public let viewerVideoSize: WebRTCInputVideoSize?

    public init(
        id: UInt64,
        screenRequestID: UInt64,
        inputSessionID: UUID,
        action: WebRTCInputAction,
        viewerVideoSize: WebRTCInputVideoSize? = nil
    ) {
        self.id = id
        self.screenRequestID = screenRequestID
        self.inputSessionID = inputSessionID
        self.action = action
        self.viewerVideoSize = viewerVideoSize
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case screenRequestID
        case inputSessionID
        case action
        case viewerVideoSize
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UInt64.self, forKey: .id)
        let screenRequestID = try container.decode(UInt64.self, forKey: .screenRequestID)
        let inputSessionID = try container.decode(UUID.self, forKey: .inputSessionID)
        let action = try container.decode(WebRTCInputAction.self, forKey: .action)
        let viewerVideoSize = try container.decodeIfPresent(
            WebRTCInputVideoSize.self,
            forKey: .viewerVideoSize
        )
        guard id > 0,
              screenRequestID > 0,
              inputSessionID != WebRTCInputCapability.zeroUUIDForValidation,
              action.isValid,
              Self.viewerVideoSize(viewerVideoSize, isValidFor: action) else {
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
            action: action,
            viewerVideoSize: viewerVideoSize
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
        try container.encodeIfPresent(viewerVideoSize, forKey: .viewerVideoSize)
    }

    var isValid: Bool {
        id > 0
            && screenRequestID > 0
            && inputSessionID != WebRTCInputCapability.zeroUUIDForValidation
            && action.isValid
            && Self.viewerVideoSize(viewerVideoSize, isValidFor: action)
    }

    private static func viewerVideoSize(
        _ viewerVideoSize: WebRTCInputVideoSize?,
        isValidFor action: WebRTCInputAction
    ) -> Bool {
        switch action {
        case .tap, .primaryDrag:
            return viewerVideoSize?.isValid ?? true
        case .scroll:
            return viewerVideoSize?.isValid == true
        case .insertText, .backspace, .returnKey:
            return viewerVideoSize == nil
        }
    }
}

/// Host-reported editability state; secure fields retain the same generation-bound authority
/// while asking the viewer to use privacy-preserving keyboard traits.
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
    /// Content-free refinement of `.rateLimited`; omitted on the wire when false so clients from
    /// before this field continue decoding the established feedback shape.
    public let screenFormatChanging: Bool
    public let focus: WebRTCInputFocus

    public init(
        id: UInt64,
        screenRequestID: UInt64,
        inputSessionID: UUID,
        result: WebRTCInputFeedbackResult,
        rejectionReason: WebRTCInputRejectionReason? = nil,
        screenFormatChanging: Bool = false,
        focus: WebRTCInputFocus = .none
    ) {
        self.id = id
        self.screenRequestID = screenRequestID
        self.inputSessionID = inputSessionID
        self.result = result
        self.rejectionReason = rejectionReason
        self.screenFormatChanging = screenFormatChanging
        self.focus = focus
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case screenRequestID
        case inputSessionID
        case result
        case rejectionReason
        case screenFormatChanging
        case focus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let result = try container.decode(WebRTCInputFeedbackResult.self, forKey: .result)
        let rejectionReason = try container.decodeIfPresent(
            WebRTCInputRejectionReason.self,
            forKey: .rejectionReason
        )
        let screenFormatChanging = try container.decodeIfPresent(
            Bool.self,
            forKey: .screenFormatChanging
        ) ?? false
        let id = try container.decode(UInt64.self, forKey: .id)
        let screenRequestID = try container.decode(UInt64.self, forKey: .screenRequestID)
        let inputSessionID = try container.decode(UUID.self, forKey: .inputSessionID)
        let focus = try container.decode(WebRTCInputFocus.self, forKey: .focus)
        guard id > 0,
              screenRequestID > 0,
              inputSessionID != WebRTCInputCapability.zeroUUIDForValidation,
              focus.isValid,
              Self.hasValidRejectionShape(
                  result: result,
                  rejectionReason: rejectionReason,
                  screenFormatChanging: screenFormatChanging
              ) else {
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
            screenFormatChanging: screenFormatChanging,
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
        if screenFormatChanging {
            try container.encode(true, forKey: .screenFormatChanging)
        }
        try container.encode(focus, forKey: .focus)
    }

    var isValid: Bool {
        id > 0
            && screenRequestID > 0
            && inputSessionID != WebRTCInputCapability.zeroUUIDForValidation
            && focus.isValid
            && Self.hasValidRejectionShape(
                result: result,
                rejectionReason: rejectionReason,
                screenFormatChanging: screenFormatChanging
            )
    }

    private static func hasValidRejectionShape(
        result: WebRTCInputFeedbackResult,
        rejectionReason: WebRTCInputRejectionReason?,
        screenFormatChanging: Bool
    ) -> Bool {
        switch result {
        case .accepted:
            rejectionReason == nil && !screenFormatChanging
        case .rejected:
            rejectionReason != nil
                && (!screenFormatChanging || rejectionReason == .rateLimited)
        }
    }
}

private extension WebRTCInputCapability {
    static var zeroUUIDForValidation: UUID { zeroUUID }
}
