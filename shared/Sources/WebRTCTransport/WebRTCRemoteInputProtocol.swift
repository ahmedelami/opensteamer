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
    public let supportsFocusedWindowResize: Bool

    public init(
        inputSessionID: UUID,
        screenRequestID: UInt64,
        protocolVersion: Int = Self.currentProtocolVersion,
        maxMessageBytes: Int = Self.maximumMessageBytes,
        supportsPrimaryDrag: Bool = false,
        supportsScroll: Bool = false,
        supportsFocusedWindowResize: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.inputSessionID = inputSessionID
        self.screenRequestID = screenRequestID
        self.maxMessageBytes = maxMessageBytes
        self.supportsPrimaryDrag = supportsPrimaryDrag
        self.supportsScroll = supportsScroll
        self.supportsFocusedWindowResize = supportsFocusedWindowResize
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case inputSessionID
        case screenRequestID
        case maxMessageBytes
        case supportsPrimaryDrag
        case supportsScroll
        case supportsFocusedWindowResize
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
        let supportsFocusedWindowResize = if container.contains(.supportsFocusedWindowResize) {
            try container.decode(Bool.self, forKey: .supportsFocusedWindowResize)
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
            supportsScroll: supportsScroll,
            supportsFocusedWindowResize: supportsFocusedWindowResize
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
        try container.encode(supportsFocusedWindowResize, forKey: .supportsFocusedWindowResize)
    }

    var isValid: Bool {
        protocolVersion == Self.currentProtocolVersion
            && inputSessionID != Self.zeroUUID
            && screenRequestID > 0
            && maxMessageBytes == Self.maximumMessageBytes
    }

    private static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

/// A finite rectangle in the encoded frame's inclusive unit square.
public struct WebRTCNormalizedRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey { case x, y, width, height }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(Double.self, forKey: .x)
        let y = try container.decode(Double.self, forKey: .y)
        let width = try container.decode(Double.self, forKey: .width)
        let height = try container.decode(Double.self, forKey: .height)
        guard Self.isValid(x: x, y: y, width: width, height: height) else {
            throw DecodingError.dataCorruptedError(
                forKey: .x,
                in: container,
                debugDescription: "Invalid normalized rectangle."
            )
        }
        self.init(x: x, y: y, width: width, height: height)
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid normalized rectangle.")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
    }

    var isValid: Bool {
        Self.isValid(x: x, y: y, width: width, height: height)
    }

    private static func isValid(x: Double, y: Double, width: Double, height: Double) -> Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && x >= 0 && y >= 0 && width > 0 && height > 0
            && x <= 1 && y <= 1
            && width <= 1 - x && height <= 1 - y
    }
}

/// Opaque, session-bound focused-window authority and its content-free video rectangle.
public struct WebRTCWindowResizeTarget: Codable, Equatable, Sendable {
    public let generation: UUID
    public let normalizedFrame: WebRTCNormalizedRect

    public init(generation: UUID, normalizedFrame: WebRTCNormalizedRect) {
        self.generation = generation
        self.normalizedFrame = normalizedFrame
    }

    private enum CodingKeys: String, CodingKey { case generation, normalizedFrame }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let generation = try container.decode(UUID.self, forKey: .generation)
        let normalizedFrame = try container.decode(WebRTCNormalizedRect.self, forKey: .normalizedFrame)
        guard generation != WebRTCInputCapability.zeroUUIDForValidation,
              normalizedFrame.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .generation,
                in: container,
                debugDescription: "Invalid focused-window resize target."
            )
        }
        self.init(generation: generation, normalizedFrame: normalizedFrame)
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid focused-window resize target.")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generation, forKey: .generation)
        try container.encode(normalizedFrame, forKey: .normalizedFrame)
    }

    var isValid: Bool {
        generation != WebRTCInputCapability.zeroUUIDForValidation && normalizedFrame.isValid
    }
}

/// Identifies which resize operation produced the returned current target.
public enum WebRTCWindowResizeFeedbackKind: String, Codable, Sendable {
    case targetAcquired
    case windowSelected
    case resizeCommitted
}

/// Content-free result for one focused-window resize action.
public struct WebRTCWindowResizeFeedback: Codable, Equatable, Sendable {
    public let kind: WebRTCWindowResizeFeedbackKind
    /// Echoes the one-shot authority consumed by a successful commit. Target acquisition and
    /// selection omit this field; their returned target has no predecessor on this request.
    public let committedTargetGeneration: UUID?
    public let target: WebRTCWindowResizeTarget

    public init(
        kind: WebRTCWindowResizeFeedbackKind,
        committedTargetGeneration: UUID? = nil,
        target: WebRTCWindowResizeTarget
    ) {
        self.kind = kind
        self.committedTargetGeneration = committedTargetGeneration
        self.target = target
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case committedTargetGeneration
        case target
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(WebRTCWindowResizeFeedbackKind.self, forKey: .kind)
        let committedTargetGeneration = try container.decodeIfPresent(
            UUID.self,
            forKey: .committedTargetGeneration
        )
        let target = try container.decode(WebRTCWindowResizeTarget.self, forKey: .target)
        guard Self.isValid(
            kind: kind,
            committedTargetGeneration: committedTargetGeneration,
            target: target
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Invalid focused-window resize feedback."
            )
        }
        self.init(
            kind: kind,
            committedTargetGeneration: committedTargetGeneration,
            target: target
        )
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Invalid focused-window resize feedback.")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(
            committedTargetGeneration,
            forKey: .committedTargetGeneration
        )
        try container.encode(target, forKey: .target)
    }

    var isValid: Bool {
        Self.isValid(
            kind: kind,
            committedTargetGeneration: committedTargetGeneration,
            target: target
        )
    }

    private static func isValid(
        kind: WebRTCWindowResizeFeedbackKind,
        committedTargetGeneration: UUID?,
        target: WebRTCWindowResizeTarget
    ) -> Bool {
        guard target.isValid else { return false }
        switch kind {
        case .targetAcquired, .windowSelected:
            return committedTargetGeneration == nil
        case .resizeCommitted:
            return committedTargetGeneration != nil
                && committedTargetGeneration != WebRTCInputCapability.zeroUUIDForValidation
                && committedTargetGeneration != target.generation
        }
    }
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
    case requestFocusedWindowResizeTarget
    case selectWindowForResize(at: WebRTCNormalizedPoint)
    case commitFocusedWindowResize(
        targetGeneration: UUID,
        start: WebRTCNormalizedPoint,
        end: WebRTCNormalizedPoint
    )
    case insertText(String, focusGeneration: UInt64)
    case backspace(focusGeneration: UInt64)
    case returnKey(focusGeneration: UInt64)

    private enum Kind: String, Codable {
        case tap
        case primaryDrag
        case scroll
        case focusedWindowResizeTarget
        case focusedWindowSelection
        case focusedWindowResizeCommit
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
        case targetGeneration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .tap:
            guard !container.contains(.start), !container.contains(.end),
                  !container.contains(.anchor), !container.contains(.deltaX),
                  !container.contains(.deltaY),
                  !container.contains(.text), !container.contains(.focusGeneration),
                  !container.contains(.targetGeneration) else {
                throw Self.invalidAction(in: container)
            }
            self = .tap(try container.decode(WebRTCNormalizedPoint.self, forKey: .point))
        case .primaryDrag:
            guard !container.contains(.point), !container.contains(.text),
                  !container.contains(.anchor), !container.contains(.deltaX),
                  !container.contains(.deltaY),
                  !container.contains(.focusGeneration),
                  !container.contains(.targetGeneration) else {
                throw Self.invalidAction(in: container)
            }
            self = .primaryDrag(
                start: try container.decode(WebRTCNormalizedPoint.self, forKey: .start),
                end: try container.decode(WebRTCNormalizedPoint.self, forKey: .end)
            )
        case .scroll:
            guard !container.contains(.point), !container.contains(.start),
                  !container.contains(.end), !container.contains(.text),
                  !container.contains(.focusGeneration),
                  !container.contains(.targetGeneration) else {
                throw Self.invalidAction(in: container)
            }
            let anchor = try container.decode(WebRTCNormalizedPoint.self, forKey: .anchor)
            let deltaX = try container.decode(Int32.self, forKey: .deltaX)
            let deltaY = try container.decode(Int32.self, forKey: .deltaY)
            guard Self.isValidScrollDelta(deltaX: deltaX, deltaY: deltaY) else {
                throw Self.invalidAction(in: container)
            }
            self = .scroll(anchor: anchor, deltaX: deltaX, deltaY: deltaY)
        case .focusedWindowResizeTarget:
            guard !container.contains(.point), !container.contains(.start),
                  !container.contains(.end), !container.contains(.anchor),
                  !container.contains(.deltaX), !container.contains(.deltaY),
                  !container.contains(.text), !container.contains(.focusGeneration),
                  !container.contains(.targetGeneration) else {
                throw Self.invalidAction(in: container)
            }
            self = .requestFocusedWindowResizeTarget
        case .focusedWindowSelection:
            guard !container.contains(.start), !container.contains(.end),
                  !container.contains(.anchor), !container.contains(.deltaX),
                  !container.contains(.deltaY), !container.contains(.text),
                  !container.contains(.focusGeneration),
                  !container.contains(.targetGeneration) else {
                throw Self.invalidAction(in: container)
            }
            self = .selectWindowForResize(
                at: try container.decode(WebRTCNormalizedPoint.self, forKey: .point)
            )
        case .focusedWindowResizeCommit:
            guard !container.contains(.point), !container.contains(.anchor),
                  !container.contains(.deltaX), !container.contains(.deltaY),
                  !container.contains(.text), !container.contains(.focusGeneration) else {
                throw Self.invalidAction(in: container)
            }
            let targetGeneration = try container.decode(UUID.self, forKey: .targetGeneration)
            guard targetGeneration != WebRTCInputCapability.zeroUUIDForValidation else {
                throw Self.invalidAction(in: container)
            }
            self = .commitFocusedWindowResize(
                targetGeneration: targetGeneration,
                start: try container.decode(WebRTCNormalizedPoint.self, forKey: .start),
                end: try container.decode(WebRTCNormalizedPoint.self, forKey: .end)
            )
        case .text:
            guard !container.contains(.point), !container.contains(.start),
                  !container.contains(.end), !container.contains(.anchor),
                  !container.contains(.deltaX), !container.contains(.deltaY),
                  !container.contains(.targetGeneration) else {
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
                  !container.contains(.text), !container.contains(.targetGeneration) else {
                throw Self.invalidAction(in: container)
            }
            let generation = try container.decode(UInt64.self, forKey: .focusGeneration)
            guard generation > 0 else { throw Self.invalidAction(in: container) }
            self = .backspace(focusGeneration: generation)
        case .returnKey:
            guard !container.contains(.point), !container.contains(.start),
                  !container.contains(.end), !container.contains(.anchor),
                  !container.contains(.deltaX), !container.contains(.deltaY),
                  !container.contains(.text), !container.contains(.targetGeneration) else {
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
        case .requestFocusedWindowResizeTarget:
            try container.encode(Kind.focusedWindowResizeTarget, forKey: .kind)
        case .selectWindowForResize(let point):
            try container.encode(Kind.focusedWindowSelection, forKey: .kind)
            try container.encode(point, forKey: .point)
        case .commitFocusedWindowResize(let targetGeneration, let start, let end):
            try container.encode(Kind.focusedWindowResizeCommit, forKey: .kind)
            try container.encode(targetGeneration, forKey: .targetGeneration)
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
        case .scroll(let anchor, let deltaX, let deltaY):
            anchor.isValid && Self.isValidScrollDelta(deltaX: deltaX, deltaY: deltaY)
        case .requestFocusedWindowResizeTarget:
            true
        case .selectWindowForResize(let point):
            point.isValid
        case .commitFocusedWindowResize(let generation, let start, let end):
            generation != WebRTCInputCapability.zeroUUIDForValidation
                && start.isValid && end.isValid
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
        case .scroll, .requestFocusedWindowResizeTarget,
             .selectWindowForResize, .commitFocusedWindowResize:
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
    public let windowResize: WebRTCWindowResizeFeedback?

    public init(
        id: UInt64,
        screenRequestID: UInt64,
        inputSessionID: UUID,
        result: WebRTCInputFeedbackResult,
        rejectionReason: WebRTCInputRejectionReason? = nil,
        screenFormatChanging: Bool = false,
        focus: WebRTCInputFocus = .none,
        windowResize: WebRTCWindowResizeFeedback? = nil
    ) {
        self.id = id
        self.screenRequestID = screenRequestID
        self.inputSessionID = inputSessionID
        self.result = result
        self.rejectionReason = rejectionReason
        self.screenFormatChanging = screenFormatChanging
        self.focus = focus
        self.windowResize = windowResize
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case screenRequestID
        case inputSessionID
        case result
        case rejectionReason
        case screenFormatChanging
        case focus
        case windowResize
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
        let windowResize = try container.decodeIfPresent(
            WebRTCWindowResizeFeedback.self,
            forKey: .windowResize
        )
        guard id > 0,
              screenRequestID > 0,
              inputSessionID != WebRTCInputCapability.zeroUUIDForValidation,
              focus.isValid,
              Self.hasValidRejectionShape(
                  result: result,
                  rejectionReason: rejectionReason,
                  screenFormatChanging: screenFormatChanging,
                  windowResize: windowResize
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
            focus: focus,
            windowResize: windowResize
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
        try container.encodeIfPresent(windowResize, forKey: .windowResize)
    }

    var isValid: Bool {
        id > 0
            && screenRequestID > 0
            && inputSessionID != WebRTCInputCapability.zeroUUIDForValidation
            && focus.isValid
            && (windowResize?.isValid ?? true)
            && Self.hasValidRejectionShape(
                result: result,
                rejectionReason: rejectionReason,
                screenFormatChanging: screenFormatChanging,
                windowResize: windowResize
            )
    }

    private static func hasValidRejectionShape(
        result: WebRTCInputFeedbackResult,
        rejectionReason: WebRTCInputRejectionReason?,
        screenFormatChanging: Bool,
        windowResize: WebRTCWindowResizeFeedback?
    ) -> Bool {
        switch result {
        case .accepted:
            rejectionReason == nil && !screenFormatChanging
        case .rejected:
            rejectionReason != nil
                && (!screenFormatChanging || rejectionReason == .rateLimited)
                && windowResize == nil
        }
    }
}

private extension WebRTCInputCapability {
    static var zeroUUIDForValidation: UUID { zeroUUID }
}
