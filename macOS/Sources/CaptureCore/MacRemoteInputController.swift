import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// A display-relative point received from a remote viewer.
///
/// Coordinates use the captured image's top-left origin and must be in `0...1`.
/// Core Graphics display bounds use that same global orientation, including negative
/// origins on displays arranged to the left or above the primary display.
public struct MacRemoteNormalizedPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    var isValid: Bool {
        x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
    }
}

public struct MacRemoteInputPermissionStatus: Equatable, Sendable {
    public let accessibilityTrusted: Bool
    public let postEventAllowed: Bool

    public init(accessibilityTrusted: Bool, postEventAllowed: Bool) {
        self.accessibilityTrusted = accessibilityTrusted
        self.postEventAllowed = postEventAllowed
    }

    public var isAuthorized: Bool {
        accessibilityTrusted && postEventAllowed
    }
}

public enum MacRemoteInputArmResult: Equatable, Sendable {
    case armed
    case disabled
    case permissionRequired(MacRemoteInputPermissionStatus)
    case displayUnavailable
}

public enum MacRemoteInputFocus: Equatable, Sendable {
    case none
    case editable(generation: UInt64, secure: Bool)
}

public enum MacRemoteInputKey: Equatable, Sendable {
    case backspace
    case returnKey
}

public enum MacRemoteInputRejection: Equatable, Sendable {
    case disabled
    case permissionRequired
    case staleSession
    case invalidPoint
    case invalidText
    case rateLimited
    case displayUnavailable
    case focusChanged
    case primaryButtonInUse
    case injectionFailed
}

public enum MacRemoteInputResult: Equatable, Sendable {
    case accepted(MacRemoteInputFocus)
    case rejected(MacRemoteInputRejection)
}

/// Serializes and authorizes remote input for one active screen-sharing session.
///
/// The controller is disabled unless the host explicitly opts in. Each action must
/// match both the active Show request and its fresh input-session UUID. Keyboard
/// authorization is narrower still: it is granted only after the same editable AX
/// element that was hit-tested before a click becomes focused after that click.
public final class MacRemoteInputController: @unchecked Sendable {
    private static let focusPollInterval: TimeInterval = 0.005
    private static let maximumFocusWait: TimeInterval = 0.050
    private static let maximumEditableAncestorDepth = 12

    private let allowRemoteControl: Bool
    private let system: any MacRemoteInputSystem
    private let clock: any MacRemoteInputClock
    private let lock = NSLock()

    private var activeSession: ActiveSession?
    private var authorizedFocus: AuthorizedFocus?
    private var nextFocusGeneration: UInt64 = 0

    private var tapBucket: TokenBucket
    private var keyBucket: TokenBucket
    private var textBucket: TokenBucket

    public init(allowRemoteControl: Bool) {
        let clock = SystemMacRemoteInputClock()
        self.allowRemoteControl = allowRemoteControl
        self.system = CoreGraphicsMacRemoteInputSystem()
        self.clock = clock
        let now = clock.now()
        self.tapBucket = TokenBucket(capacity: 12, refillPerSecond: 8, now: now)
        self.keyBucket = TokenBucket(capacity: 40, refillPerSecond: 25, now: now)
        self.textBucket = TokenBucket(capacity: 4_096, refillPerSecond: 2_048, now: now)
    }

    init(
        allowRemoteControl: Bool,
        system: any MacRemoteInputSystem,
        clock: any MacRemoteInputClock
    ) {
        self.allowRemoteControl = allowRemoteControl
        self.system = system
        self.clock = clock
        let now = clock.now()
        self.tapBucket = TokenBucket(capacity: 12, refillPerSecond: 8, now: now)
        self.keyBucket = TokenBucket(capacity: 40, refillPerSecond: 25, now: now)
        self.textBucket = TokenBucket(capacity: 4_096, refillPerSecond: 2_048, now: now)
    }

    /// Checks the only two TCC grants used by remote input. This never checks or
    /// requests Input Monitoring because synthesized events do not require it.
    public func permissionStatus(promptIfNeeded: Bool = false) -> MacRemoteInputPermissionStatus {
        withLock {
            system.permissionStatus(promptIfNeeded: promptIfNeeded)
        }
    }

    /// Replaces any previous authorization and arms one exact active screen share.
    @discardableResult
    public func arm(
        displayID: UInt32,
        screenRequestID: UInt64,
        inputSessionID: UUID
    ) -> MacRemoteInputArmResult {
        withLock {
            armLocked(
                displayID: displayID,
                screenRequestID: screenRequestID,
                inputSessionID: inputSessionID
            )
        }
    }

    private func armLocked(
        displayID: UInt32,
        screenRequestID: UInt64,
        inputSessionID: UUID
    ) -> MacRemoteInputArmResult {
        revokeState()

        guard allowRemoteControl else {
            return .disabled
        }

        let permissions = system.permissionStatus(promptIfNeeded: false)
        guard permissions.isAuthorized else {
            return .permissionRequired(permissions)
        }

        guard validDisplayBounds(for: displayID) != nil else {
            return .displayUnavailable
        }

        activeSession = ActiveSession(
            displayID: displayID,
            screenRequestID: screenRequestID,
            inputSessionID: inputSessionID
        )
        resetRateLimits(now: clock.now())
        return .armed
    }

    /// Immediately revokes the active input session and any focused-element grant.
    public func revoke() {
        withLock {
            revokeState()
        }
    }

    public func handleTap(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        normalizedPoint: MacRemoteNormalizedPoint
    ) -> MacRemoteInputResult {
        withLock {
            handleTapLocked(
                screenRequestID: screenRequestID,
                inputSessionID: inputSessionID,
                normalizedPoint: normalizedPoint
            )
        }
    }

    private func handleTapLocked(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        normalizedPoint: MacRemoteNormalizedPoint
    ) -> MacRemoteInputResult {
        // Every tap invalidates the prior keyboard grant, even when this tap is
        // malformed or rate-limited.
        authorizedFocus = nil

        guard allowRemoteControl else {
            return .rejected(.disabled)
        }
        guard let session = matchingSession(
            screenRequestID: screenRequestID,
            inputSessionID: inputSessionID
        ) else {
            return .rejected(.staleSession)
        }
        guard normalizedPoint.isValid else {
            return .rejected(.invalidPoint)
        }
        guard hasCurrentPermissions() else {
            revokeState()
            return .rejected(.permissionRequired)
        }
        guard let displayBounds = validDisplayBounds(for: session.displayID) else {
            revokeState()
            return .rejected(.displayUnavailable)
        }
        guard tapBucket.consume(1, at: clock.now()) else {
            return .rejected(.rateLimited)
        }

        let globalPoint = MacRemoteInputCoordinateMapper.globalPoint(
            normalizedPoint,
            in: displayBounds
        )
        let hitEditable = system.element(at: globalPoint).flatMap(editableAncestor(from:))

        // The real backend constructs both events before it posts either one.
        guard system.postMouseClick(at: globalPoint) else {
            return .rejected(.injectionFailed)
        }

        guard let hitEditable else {
            return .accepted(.none)
        }

        guard let focusedEditable = waitForFocusedEditableElement(
            matching: hitEditable.element
        ) else {
            return .accepted(.none)
        }

        nextFocusGeneration &+= 1
        if nextFocusGeneration == 0 {
            nextFocusGeneration = 1
        }
        let focus = AuthorizedFocus(
            element: focusedEditable.element,
            generation: nextFocusGeneration
        )
        authorizedFocus = focus
        return .accepted(.editable(generation: focus.generation, secure: false))
    }

    /// Performs one complete primary-button drag for the exact active screen share.
    ///
    /// This is deliberately an atomic action rather than a remotely held mouse state:
    /// the backend constructs down, dragged, and up events before posting any of them.
    public func handlePrimaryDrag(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        start: MacRemoteNormalizedPoint,
        end: MacRemoteNormalizedPoint
    ) -> MacRemoteInputResult {
        withLock {
            handlePrimaryDragLocked(
                screenRequestID: screenRequestID,
                inputSessionID: inputSessionID,
                start: start,
                end: end
            )
        }
    }

    private func handlePrimaryDragLocked(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        start: MacRemoteNormalizedPoint,
        end: MacRemoteNormalizedPoint
    ) -> MacRemoteInputResult {
        // Any pointer action invalidates the prior keyboard grant, including a
        // malformed, stale, denied, or rate-limited drag.
        authorizedFocus = nil

        guard allowRemoteControl else {
            return .rejected(.disabled)
        }
        guard let session = matchingSession(
            screenRequestID: screenRequestID,
            inputSessionID: inputSessionID
        ) else {
            return .rejected(.staleSession)
        }
        guard start.isValid, end.isValid else {
            return .rejected(.invalidPoint)
        }
        guard hasCurrentPermissions() else {
            revokeState()
            return .rejected(.permissionRequired)
        }
        guard let displayBounds = validDisplayBounds(for: session.displayID) else {
            revokeState()
            return .rejected(.displayUnavailable)
        }
        guard !system.isPhysicalPrimaryButtonPressed() else {
            return .rejected(.primaryButtonInUse)
        }
        // Taps and atomic drags share one pointer-action budget so alternating
        // action kinds cannot bypass the host's documented click rate limit.
        guard tapBucket.consume(1, at: clock.now()) else {
            return .rejected(.rateLimited)
        }

        let globalStart = MacRemoteInputCoordinateMapper.globalPoint(start, in: displayBounds)
        let globalEnd = MacRemoteInputCoordinateMapper.globalPoint(end, in: displayBounds)
        let hitEditable = system.element(at: globalStart).flatMap(editableAncestor(from:))

        guard system.postPrimaryDrag(from: globalStart, to: globalEnd) else {
            return .rejected(.injectionFailed)
        }

        guard let hitEditable,
              let focusedEditable = waitForFocusedEditableElement(
                  matching: hitEditable.element
              ) else {
            return .accepted(.none)
        }

        nextFocusGeneration &+= 1
        if nextFocusGeneration == 0 {
            nextFocusGeneration = 1
        }
        let focus = AuthorizedFocus(
            element: focusedEditable.element,
            generation: nextFocusGeneration
        )
        authorizedFocus = focus
        return .accepted(.editable(generation: focus.generation, secure: false))
    }

    public func insertText(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        focusGeneration: UInt64,
        text: String
    ) -> MacRemoteInputResult {
        withLock {
            insertTextLocked(
                screenRequestID: screenRequestID,
                inputSessionID: inputSessionID,
                focusGeneration: focusGeneration,
                text: text
            )
        }
    }

    private func insertTextLocked(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        focusGeneration: UInt64,
        text: String
    ) -> MacRemoteInputResult {
        let authorization = authorizeKeyboardAction(
            screenRequestID: screenRequestID,
            inputSessionID: inputSessionID,
            focusGeneration: focusGeneration
        )
        guard let focus = authorization.focus else {
            return rejectKeyboardAction(authorization.rejection ?? .focusChanged)
        }

        guard let byteCount = Self.validatedTextByteCount(text) else {
            return rejectKeyboardAction(.invalidText)
        }
        guard textBucket.consume(Double(byteCount), at: clock.now()) else {
            return rejectKeyboardAction(.rateLimited)
        }
        guard verifyFocusedElement(focus) else {
            return rejectKeyboardAction(.focusChanged)
        }
        // No suspension occurs between the final focus check and event injection.
        guard system.postUnicodeText(text) else {
            return rejectKeyboardAction(.injectionFailed)
        }
        return .accepted(.editable(generation: focus.generation, secure: false))
    }

    public func pressKey(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        focusGeneration: UInt64,
        key: MacRemoteInputKey
    ) -> MacRemoteInputResult {
        withLock {
            pressKeyLocked(
                screenRequestID: screenRequestID,
                inputSessionID: inputSessionID,
                focusGeneration: focusGeneration,
                key: key
            )
        }
    }

    private func pressKeyLocked(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        focusGeneration: UInt64,
        key: MacRemoteInputKey
    ) -> MacRemoteInputResult {
        let authorization = authorizeKeyboardAction(
            screenRequestID: screenRequestID,
            inputSessionID: inputSessionID,
            focusGeneration: focusGeneration
        )
        guard let focus = authorization.focus else {
            return rejectKeyboardAction(authorization.rejection ?? .focusChanged)
        }
        guard keyBucket.consume(1, at: clock.now()) else {
            return rejectKeyboardAction(.rateLimited)
        }
        guard verifyFocusedElement(focus) else {
            return rejectKeyboardAction(.focusChanged)
        }
        // No suspension occurs between the final focus check and event injection.
        guard system.postKey(key) else {
            return rejectKeyboardAction(.injectionFailed)
        }
        return .accepted(.editable(generation: focus.generation, secure: false))
    }

    static func validatedTextByteCount(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }

        let utf8Count = text.utf8.count
        guard utf8Count <= 512, text.utf16.count <= 256 else { return nil }

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F, 0xF700...0xF8FF:
                // AppKit represents function/navigation keys in this private-use range.
                // They are key commands, not committed text, and remain outside the protocol.
                return nil
            default:
                continue
            }
        }
        return utf8Count
    }

    private func authorizeKeyboardAction(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        focusGeneration: UInt64
    ) -> (focus: AuthorizedFocus?, rejection: MacRemoteInputRejection?) {
        guard allowRemoteControl else {
            return (nil, .disabled)
        }
        guard matchingSession(
            screenRequestID: screenRequestID,
            inputSessionID: inputSessionID
        ) != nil else {
            return (nil, .staleSession)
        }
        guard hasCurrentPermissions() else {
            revokeState()
            return (nil, .permissionRequired)
        }
        guard let focus = authorizedFocus, focus.generation == focusGeneration else {
            return (nil, .focusChanged)
        }
        return (focus, nil)
    }

    private func rejectKeyboardAction(_ reason: MacRemoteInputRejection) -> MacRemoteInputResult {
        authorizedFocus = nil
        return .rejected(reason)
    }

    private func matchingSession(
        screenRequestID: UInt64,
        inputSessionID: UUID
    ) -> ActiveSession? {
        guard let activeSession,
              activeSession.screenRequestID == screenRequestID,
              activeSession.inputSessionID == inputSessionID else {
            return nil
        }
        return activeSession
    }

    private func hasCurrentPermissions() -> Bool {
        system.permissionStatus(promptIfNeeded: false).isAuthorized
    }

    private func validDisplayBounds(for displayID: UInt32) -> CGRect? {
        guard let bounds = system.displayBounds(for: displayID),
              !bounds.isNull,
              !bounds.isInfinite,
              bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0 else {
            return nil
        }
        return bounds
    }

    private func editableAncestor(from hitElement: MacRemoteAccessibilityElement) -> EditableElement? {
        var current: MacRemoteAccessibilityElement? = hitElement
        var visited: [MacRemoteAccessibilityElement] = []

        for _ in 0..<Self.maximumEditableAncestorDepth {
            guard let element = current else { break }
            if visited.contains(where: { system.elementsEqual($0, element) }) {
                break
            }
            visited.append(element)

            // A secure field is a hard traversal boundary. Returning nil here, rather than
            // merely treating the field itself as non-editable, prevents a secure descendant
            // from falling through to an otherwise editable container above it.
            if system.subrole(of: element) == "AXSecureTextField" {
                return nil
            }

            if let editable = editableElement(exactly: element) {
                return editable
            }
            current = system.parent(of: element)
        }
        return nil
    }

    private func editableElement(exactly element: MacRemoteAccessibilityElement) -> EditableElement? {
        // Some first-party controls (including TextEdit's AXTextArea) omit AXEnabled even though
        // AXValue is settable. Only an explicit false is a disabled-control signal; editability
        // still requires an approved role + settable value, or AXEditable == true below.
        guard system.isEnabled(element) != false else {
            return nil
        }

        let roleIsEditable = system.role(of: element)
            .map(Self.editableRoles.contains) == true
            && system.isValueSettable(element)
        guard roleIsEditable || system.isEditable(element) == true else { return nil }

        return EditableElement(element: element)
    }

    private func waitForFocusedEditableElement(
        matching expected: MacRemoteAccessibilityElement
    ) -> EditableElement? {
        let start = clock.now()
        let deadline = start + Self.maximumFocusWait

        // The attempt cap prevents a faulty injected clock from causing an
        // unbounded wait; the elapsed-time check enforces the 50 ms boundary.
        for attempt in 0...10 {
            if let focused = system.focusedElement(),
               let editable = editableAncestor(from: focused),
               system.elementsEqual(editable.element, expected) {
                return editable
            }

            let now = clock.now()
            guard attempt < 10, now < deadline else { break }
            clock.sleep(for: min(Self.focusPollInterval, deadline - now))
        }
        return nil
    }

    private func verifyFocusedElement(_ focus: AuthorizedFocus) -> Bool {
        guard let currentlyFocused = system.focusedElement(),
              let editable = editableAncestor(from: currentlyFocused),
              system.elementsEqual(editable.element, focus.element) else {
            return false
        }
        return true
    }

    private func resetRateLimits(now: TimeInterval) {
        tapBucket.reset(at: now)
        keyBucket.reset(at: now)
        textBucket.reset(at: now)
    }

    private func revokeState() {
        activeSession = nil
        authorizedFocus = nil
        nextFocusGeneration = 0
        resetRateLimits(now: clock.now())
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static let editableRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox"
    ]
}

private struct ActiveSession: Sendable {
    let displayID: UInt32
    let screenRequestID: UInt64
    let inputSessionID: UUID
}

private struct AuthorizedFocus: Sendable {
    let element: MacRemoteAccessibilityElement
    let generation: UInt64
}

private struct EditableElement {
    let element: MacRemoteAccessibilityElement
}

enum MacRemoteInputCoordinateMapper {
    static func globalPoint(_ point: MacRemoteNormalizedPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(bounds.maxX.nextDown, bounds.minX + (bounds.width * point.x)),
            y: min(bounds.maxY.nextDown, bounds.minY + (bounds.height * point.y))
        )
    }
}

enum MacRemoteInputDragPath {
    static let draggedEventCount = 6

    static func points(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        (1...draggedEventCount).map { step in
            let progress = CGFloat(step) / CGFloat(draggedEventCount)
            return CGPoint(
                x: start.x + ((end.x - start.x) * progress),
                y: start.y + ((end.y - start.y) * progress)
            )
        }
    }
}

private struct TokenBucket {
    let capacity: Double
    let refillPerSecond: Double
    private(set) var tokens: Double
    private(set) var lastRefill: TimeInterval

    init(capacity: Double, refillPerSecond: Double, now: TimeInterval) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.tokens = capacity
        self.lastRefill = now
    }

    mutating func reset(at now: TimeInterval) {
        tokens = capacity
        lastRefill = now
    }

    mutating func consume(_ cost: Double, at now: TimeInterval) -> Bool {
        if now.isFinite, now > lastRefill {
            tokens = min(capacity, tokens + ((now - lastRefill) * refillPerSecond))
            lastRefill = now
        }

        guard cost > 0, cost <= tokens else { return false }
        tokens -= cost
        return true
    }
}

protocol MacRemoteInputClock: Sendable {
    func now() -> TimeInterval
    func sleep(for interval: TimeInterval)
}

private struct SystemMacRemoteInputClock: MacRemoteInputClock {
    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func sleep(for interval: TimeInterval) {
        guard interval > 0 else { return }
        Thread.sleep(forTimeInterval: interval)
    }
}

final class MacRemoteAccessibilityElement: @unchecked Sendable {
    fileprivate let rawValue: AnyObject

    init(rawValue: AnyObject) {
        self.rawValue = rawValue
    }
}

protocol MacRemoteInputSystem: Sendable {
    func permissionStatus(promptIfNeeded: Bool) -> MacRemoteInputPermissionStatus
    func displayBounds(for displayID: UInt32) -> CGRect?
    func isPhysicalPrimaryButtonPressed() -> Bool

    func element(at point: CGPoint) -> MacRemoteAccessibilityElement?
    func parent(of element: MacRemoteAccessibilityElement) -> MacRemoteAccessibilityElement?
    func role(of element: MacRemoteAccessibilityElement) -> String?
    func subrole(of element: MacRemoteAccessibilityElement) -> String?
    func isEnabled(_ element: MacRemoteAccessibilityElement) -> Bool?
    func isEditable(_ element: MacRemoteAccessibilityElement) -> Bool?
    func isValueSettable(_ element: MacRemoteAccessibilityElement) -> Bool
    func focusedElement() -> MacRemoteAccessibilityElement?
    func elementsEqual(
        _ lhs: MacRemoteAccessibilityElement,
        _ rhs: MacRemoteAccessibilityElement
    ) -> Bool

    func postMouseClick(at point: CGPoint) -> Bool
    func postPrimaryDrag(from start: CGPoint, to end: CGPoint) -> Bool
    func postUnicodeText(_ text: String) -> Bool
    func postKey(_ key: MacRemoteInputKey) -> Bool
}

private struct CoreGraphicsMacRemoteInputSystem: MacRemoteInputSystem {
    func permissionStatus(promptIfNeeded: Bool) -> MacRemoteInputPermissionStatus {
        let accessibilityTrusted: Bool
        if promptIfNeeded {
            // The exported constant's value is stable and documented. Using its
            // literal avoids Swift 6 treating the C global as mutable shared state.
            let options = ["AXTrustedCheckOptionPrompt": true]
                as CFDictionary
            accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        } else {
            accessibilityTrusted = AXIsProcessTrusted()
        }

        let postEventAllowed = promptIfNeeded
            ? CGRequestPostEventAccess()
            : CGPreflightPostEventAccess()

        return MacRemoteInputPermissionStatus(
            accessibilityTrusted: accessibilityTrusted,
            postEventAllowed: postEventAllowed
        )
    }

    func displayBounds(for displayID: UInt32) -> CGRect? {
        guard CGDisplayIsActive(displayID) != 0 else { return nil }
        return CGDisplayBounds(displayID)
    }

    func isPhysicalPrimaryButtonPressed() -> Bool {
        CGEventSource.buttonState(.hidSystemState, button: .left)
    }

    func element(at point: CGPoint) -> MacRemoteAccessibilityElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &value
        ) == .success, let value else {
            return nil
        }
        return MacRemoteAccessibilityElement(rawValue: value)
    }

    func parent(of element: MacRemoteAccessibilityElement) -> MacRemoteAccessibilityElement? {
        copyElementAttribute(kAXParentAttribute as CFString, from: element)
    }

    func role(of element: MacRemoteAccessibilityElement) -> String? {
        copyAttribute(kAXRoleAttribute as CFString, from: element) as? String
    }

    func subrole(of element: MacRemoteAccessibilityElement) -> String? {
        copyAttribute(kAXSubroleAttribute as CFString, from: element) as? String
    }

    func isEnabled(_ element: MacRemoteAccessibilityElement) -> Bool? {
        (copyAttribute(kAXEnabledAttribute as CFString, from: element) as? NSNumber)?.boolValue
    }

    func isEditable(_ element: MacRemoteAccessibilityElement) -> Bool? {
        (copyAttribute(kAXIsEditableAttribute as CFString, from: element) as? NSNumber)?.boolValue
    }

    func isValueSettable(_ element: MacRemoteAccessibilityElement) -> Bool {
        var settable = DarwinBoolean(false)
        let axElement = element.rawValue as! AXUIElement
        guard AXUIElementIsAttributeSettable(
            axElement,
            kAXValueAttribute as CFString,
            &settable
        ) == .success else {
            return false
        }
        return settable.boolValue
    }

    func focusedElement() -> MacRemoteAccessibilityElement? {
        let systemWide = MacRemoteAccessibilityElement(rawValue: AXUIElementCreateSystemWide())
        return copyElementAttribute(kAXFocusedUIElementAttribute as CFString, from: systemWide)
    }

    func elementsEqual(
        _ lhs: MacRemoteAccessibilityElement,
        _ rhs: MacRemoteAccessibilityElement
    ) -> Bool {
        CFEqual(lhs.rawValue, rhs.rawValue)
    }

    func postMouseClick(at point: CGPoint) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseDown,
                  mouseCursorPosition: point,
                  mouseButton: .left
              ),
              let up = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseUp,
                  mouseCursorPosition: point,
                  mouseButton: .left
              ) else {
            return false
        }

        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    func postPrimaryDrag(from start: CGPoint, to end: CGPoint) -> Bool {
        // All fallible construction happens before the first irreversible post,
        // so a construction failure can never leave the primary button held.
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseDown,
                  mouseCursorPosition: start,
                  mouseButton: .left
              ),
              let up = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseUp,
                  mouseCursorPosition: end,
                  mouseButton: .left
              ) else {
            return false
        }

        var draggedEvents: [CGEvent] = []
        draggedEvents.reserveCapacity(MacRemoteInputDragPath.draggedEventCount)
        for point in MacRemoteInputDragPath.points(from: start, to: end) {
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else {
                return false
            }
            draggedEvents.append(event)
        }

        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.flags = []
        up.flags = []
        for event in draggedEvents {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.flags = []
        }

        down.post(tap: .cghidEventTap)
        for event in draggedEvents {
            event.post(tap: .cghidEventTap)
        }
        up.post(tap: .cghidEventTap)
        return true
    }

    func postUnicodeText(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }

        var utf16 = Array(text.utf16)
        utf16.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: baseAddress
            )
            up.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: baseAddress
            )
        }
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    func postKey(_ key: MacRemoteInputKey) -> Bool {
        let virtualKey: CGKeyCode = switch key {
        case .backspace:
            CGKeyCode(kVK_Delete)
        case .returnKey:
            CGKeyCode(kVK_Return)
        }

        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: virtualKey,
                  keyDown: true
              ),
              let up = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: virtualKey,
                  keyDown: false
              ) else {
            return false
        }
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func copyElementAttribute(
        _ attribute: CFString,
        from element: MacRemoteAccessibilityElement
    ) -> MacRemoteAccessibilityElement? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return MacRemoteAccessibilityElement(rawValue: value as AnyObject)
    }

    private func copyAttribute(
        _ attribute: CFString,
        from element: MacRemoteAccessibilityElement
    ) -> CFTypeRef? {
        let axElement = element.rawValue as! AXUIElement
        AXUIElementSetMessagingTimeout(axElement, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, attribute, &value) == .success else {
            return nil
        }
        return value
    }
}
