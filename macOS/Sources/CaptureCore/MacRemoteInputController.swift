import ApplicationServices
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Streaming

/// A display-relative point received from a remote viewer.
///
/// Coordinates use the captured image's top-left origin and must be in `0...1`.
/// Core Graphics display bounds use that same global orientation, including negative
/// origins on displays arranged to the left or above the primary display.
public struct MacRemoteNormalizedPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    /// Creates a point in the captured display's normalized coordinate space.
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// Whether both finite coordinates fall inside the closed unit square.
    var isValid: Bool {
        x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
    }
}

/// Decoded viewer-frame dimensions captured with one remote pointer intent.
/// Exact pixels and ratio may be WebRTC-adapted; their bounded shape remains a transition fence.
public struct MacRemoteInputVideoSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    var isValid: Bool {
        (2 ... 32_768).contains(width) && (2 ... 32_768).contains(height)
    }
}

/// Snapshot of the macOS grants needed to synthesize and target remote input.
public struct MacRemoteInputPermissionStatus: Equatable, Sendable {
    public let accessibilityTrusted: Bool
    public let postEventAllowed: Bool

    /// Creates a permission snapshot from the two independent system checks.
    public init(accessibilityTrusted: Bool, postEventAllowed: Bool) {
        self.accessibilityTrusted = accessibilityTrusted
        self.postEventAllowed = postEventAllowed
    }

    /// `true` only when Accessibility inspection and event posting are both allowed.
    public var isAuthorized: Bool {
        accessibilityTrusted && postEventAllowed
    }
}

/// Outcome of binding remote input to a specific screen-sharing session.
public enum MacRemoteInputArmResult: Equatable, Sendable {
    case armed
    case disabled
    case permissionRequired(MacRemoteInputPermissionStatus)
    case displayUnavailable
}

/// Keyboard-focus capability returned to the iPhone after a pointer action.
public enum MacRemoteInputFocus: Equatable, Sendable {
    case none
    case editable(generation: UInt64, secure: Bool)
}

/// Small, explicitly allowed set of non-text keyboard commands.
public enum MacRemoteInputKey: Equatable, Sendable {
    case backspace
    case returnKey
}

/// Stable rejection reasons safe to expose across the remote-control protocol.
public enum MacRemoteInputRejection: Equatable, Sendable {
    case disabled
    case permissionRequired
    case staleSession
    case screenFormatChanging
    case invalidPoint
    case invalidScrollDelta
    case invalidText
    case rateLimited
    case displayUnavailable
    case focusChanged
    case primaryButtonInUse
    case injectionFailed
    case windowUnavailable
    case windowResizeFailed
    case windowResizeUncertain
}

/// Result of one authorized remote input request.
public enum MacRemoteInputResult: Equatable, Sendable {
    case accepted(MacRemoteInputFocus)
    case rejected(MacRemoteInputRejection)
}

/// Internal geometry-fence reason retained only for privacy-safe host diagnostics.
///
/// The wire protocol intentionally continues exposing the single stable
/// `screenFormatChanging` rejection so older clients remain decode-compatible.
public enum MacRemoteInputScreenFormatReason: String, Equatable, Sendable {
    case viewerSizeMissing
    case frameGeometryUnavailableOrUnstable
    case displayGeometryIncompatible
    case viewerAspectMismatch
}

/// Structural state captured atomically with a `screenFormatChanging` rejection.
/// No pointer coordinates, display names, or session identifiers are retained.
public struct MacRemoteInputScreenFormatDiagnostic: Equatable, Sendable {
    public let reason: MacRemoteInputScreenFormatReason
    public let viewerVideoSize: MacRemoteInputVideoSize?
    public let frameSurfaceWidth: Int?
    public let frameSurfaceHeight: Int?
    public let stableGeometryAvailable: Bool
    public let candidateGeometryAvailable: Bool
    public let candidateAgeMilliseconds: UInt64?
    public let viewerAspectRelativeDifference: Double?

    public init(
        reason: MacRemoteInputScreenFormatReason,
        viewerVideoSize: MacRemoteInputVideoSize?,
        frameSurfaceWidth: Int?,
        frameSurfaceHeight: Int?,
        stableGeometryAvailable: Bool,
        candidateGeometryAvailable: Bool,
        candidateAgeMilliseconds: UInt64?,
        viewerAspectRelativeDifference: Double?
    ) {
        self.reason = reason
        self.viewerVideoSize = viewerVideoSize
        self.frameSurfaceWidth = frameSurfaceWidth
        self.frameSurfaceHeight = frameSurfaceHeight
        self.stableGeometryAvailable = stableGeometryAvailable
        self.candidateGeometryAvailable = candidateGeometryAvailable
        self.candidateAgeMilliseconds = candidateAgeMilliseconds
        self.viewerAspectRelativeDifference = viewerAspectRelativeDifference
    }
}

/// Local controller result with an optional non-sensitive format diagnostic.
public struct MacRemoteInputDiagnosedResult: Equatable, Sendable {
    public let result: MacRemoteInputResult
    public let screenFormatDiagnostic: MacRemoteInputScreenFormatDiagnostic?

    public init(
        result: MacRemoteInputResult,
        screenFormatDiagnostic: MacRemoteInputScreenFormatDiagnostic?
    ) {
        self.result = result
        self.screenFormatDiagnostic = screenFormatDiagnostic
    }
}

/// Opaque focused-window authority and its rectangle in the exact encoded video frame.
public struct MacRemoteWindowResizeTarget: Equatable, Sendable {
    public let generation: UUID
    public let normalizedFrame: CGRect

    public init(generation: UUID, normalizedFrame: CGRect) {
        self.generation = generation
        self.normalizedFrame = normalizedFrame
    }
}

/// Semantic operation that produced a current focused-window target.
public enum MacRemoteWindowResizeFeedbackKind: Equatable, Sendable {
    case targetAcquired
    case windowSelected
    case resizeCommitted
}

/// Content-free target feedback produced by a focused-window operation.
public struct MacRemoteWindowResizeFeedback: Equatable, Sendable {
    public let kind: MacRemoteWindowResizeFeedbackKind
    public let target: MacRemoteWindowResizeTarget
    /// Present only for a successful commit, identifying the one-shot target that was consumed.
    public let committedTargetGeneration: UUID?

    public init(
        kind: MacRemoteWindowResizeFeedbackKind,
        target: MacRemoteWindowResizeTarget,
        committedTargetGeneration: UUID? = nil
    ) {
        self.kind = kind
        self.target = target
        self.committedTargetGeneration = committedTargetGeneration
    }
}

/// Focused-window result with optional target and format-fence evidence.
public struct MacRemoteWindowResizeDiagnosedResult: Equatable, Sendable {
    public let result: MacRemoteInputResult
    public let windowResizeFeedback: MacRemoteWindowResizeFeedback?
    /// Exact post-operation focus proof used even when the resize itself was rejected.
    public let verifiedFocus: MacRemoteInputFocus?
    public let screenFormatDiagnostic: MacRemoteInputScreenFormatDiagnostic?

    public init(
        result: MacRemoteInputResult,
        windowResizeFeedback: MacRemoteWindowResizeFeedback? = nil,
        verifiedFocus: MacRemoteInputFocus? = nil,
        screenFormatDiagnostic: MacRemoteInputScreenFormatDiagnostic? = nil
    ) {
        self.result = result
        self.windowResizeFeedback = windowResizeFeedback
        self.verifiedFocus = verifiedFocus
        self.screenFormatDiagnostic = screenFormatDiagnostic
    }
}

/// Serializes and authorizes remote input for one active screen-sharing session.
///
/// The controller is disabled unless the host explicitly opts in. Each action must
/// match both the active Show request and its fresh input-session UUID. Keyboard
/// authorization is narrower still: it is granted only after the same editable AX
/// element that was hit-tested before a click becomes focused after that click.
/// The controller lock owns session identity, focus grants, and all token buckets;
/// no remote action can interleave between its final authorization check and posting.
public final class MacRemoteInputController: @unchecked Sendable {
    private static let focusPollInterval: TimeInterval = 0.005
    private static let maximumFocusWait: TimeInterval = 0.050
    private static let maximumEditableAncestorDepth = 12
    private static let minimumFrameGeometryStability: TimeInterval = 0.750
    private static let maximumScrollDeltaMagnitude: Int32 = 4_096
    private static let maximumWindowAncestorDepth = 24
    private static let maximumWindowResizeGenerationsPerSession = 65_536
    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    private let allowRemoteControl: Bool
    private let system: any MacRemoteInputSystem
    private let clock: any MacRemoteInputClock
    private let makeWindowResizeGeneration: @Sendable () -> UUID
    private let lock = NSLock()

    private var isPermanentlyInvalidated = false
    private var activeSession: ActiveSession?
    private var screenVideoFrameGeometry: ScreenVideoFrameGeometry?
    private var candidateScreenVideoFrameGeometry: ScreenVideoFrameGeometry?
    private var candidateScreenVideoFrameGeometrySince: TimeInterval?
    private var authorizedFocus: AuthorizedFocus?
    private var authorizedWindowResizeTarget: AuthorizedWindowResizeTarget?
    private var issuedWindowResizeGenerations: Set<UUID> = []
    private var nextFocusGeneration: UInt64 = 0

    private var tapBucket: TokenBucket
    private var scrollBucket: TokenBucket
    private var keyBucket: TokenBucket
    private var textBucket: TokenBucket
    private var windowResizeBucket: TokenBucket
    private var scrollDeltaConversionState: ScrollDeltaConversionState?

    /// Creates a controller backed by macOS Accessibility and Core Graphics APIs.
    public init(allowRemoteControl: Bool) {
        let clock = SystemMacRemoteInputClock()
        self.allowRemoteControl = allowRemoteControl
        self.system = CoreGraphicsMacRemoteInputSystem()
        self.clock = clock
        self.makeWindowResizeGeneration = { UUID() }
        let now = clock.now()
        self.tapBucket = TokenBucket(capacity: 12, refillPerSecond: 8, now: now)
        self.scrollBucket = TokenBucket(capacity: 8, refillPerSecond: 60, now: now)
        self.keyBucket = TokenBucket(capacity: 40, refillPerSecond: 25, now: now)
        self.textBucket = TokenBucket(capacity: 4_096, refillPerSecond: 2_048, now: now)
        self.windowResizeBucket = TokenBucket(capacity: 8, refillPerSecond: 4, now: now)
    }

    /// Test-only dependency initializer for deterministic clocks and system behavior.
    init(
        allowRemoteControl: Bool,
        system: any MacRemoteInputSystem,
        clock: any MacRemoteInputClock,
        makeWindowResizeGeneration: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.allowRemoteControl = allowRemoteControl
        self.system = system
        self.clock = clock
        self.makeWindowResizeGeneration = makeWindowResizeGeneration
        let now = clock.now()
        self.tapBucket = TokenBucket(capacity: 12, refillPerSecond: 8, now: now)
        self.scrollBucket = TokenBucket(capacity: 8, refillPerSecond: 60, now: now)
        self.keyBucket = TokenBucket(capacity: 40, refillPerSecond: 25, now: now)
        self.textBucket = TokenBucket(capacity: 4_096, refillPerSecond: 2_048, now: now)
        self.windowResizeBucket = TokenBucket(capacity: 8, refillPerSecond: 4, now: now)
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
        inputSessionID: UUID,
        authoritativeDisplayBounds: CGRect? = nil
    ) -> MacRemoteInputArmResult {
        withLock {
            armLocked(
                displayID: displayID,
                screenRequestID: screenRequestID,
                inputSessionID: inputSessionID,
                authoritativeDisplayBounds: authoritativeDisplayBounds
            )
        }
    }

    /// Revokes old state and establishes one session after permissions and display checks.
    private func armLocked(
        displayID: UInt32,
        screenRequestID: UInt64,
        inputSessionID: UUID,
        authoritativeDisplayBounds: CGRect?
    ) -> MacRemoteInputArmResult {
        guard !isPermanentlyInvalidated else {
            return .disabled
        }

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
        let validatedAuthoritativeBounds: CGRect?
        if let authoritativeDisplayBounds {
            guard let bounds = Self.validatedDisplayBounds(authoritativeDisplayBounds) else {
                return .displayUnavailable
            }
            validatedAuthoritativeBounds = bounds
        } else {
            validatedAuthoritativeBounds = nil
        }

        activeSession = ActiveSession(
            displayID: displayID,
            screenRequestID: screenRequestID,
            inputSessionID: inputSessionID,
            authoritativeDisplayBounds: validatedAuthoritativeBounds
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

    /// Replaces stale in-process Core Graphics dimensions with the fresh bounds proven by the
    /// capture generation. A changed mapping closes the frame gate until matching geometry has
    /// remained stable, while the same authenticated Show/input capability stays valid.
    public func updateAuthoritativeDisplayBounds(
        _ bounds: CGRect?,
        for displayID: UInt32
    ) {
        withLock {
            guard var session = activeSession,
                  session.displayID == displayID else {
                return
            }
            let validatedBounds: CGRect?
            if let bounds {
                guard let validBounds = Self.validatedDisplayBounds(bounds) else {
                    clearScreenVideoFrameGeometry()
                    revokeState()
                    return
                }
                validatedBounds = validBounds
            } else {
                validatedBounds = nil
            }
            guard session.authoritativeDisplayBounds != validatedBounds else {
                return
            }
            session.authoritativeDisplayBounds = validatedBounds
            activeSession = session
            authorizedFocus = nil
            authorizedWindowResizeTarget = nil
            clearScreenVideoFrameGeometry()
        }
    }

    /// Observes the geometry of a complete frame that has entered WebRTC.
    ///
    /// A new transform closes input for a bounded propagation interval. Passing nil closes the
    /// gate while capture is stopped or geometry cannot be proven.
    public func updateScreenVideoFrameGeometry(_ geometry: ScreenVideoFrameGeometry?) {
        withLock {
            guard let geometry else {
                clearScreenVideoFrameGeometry()
                return
            }

            if let target = authorizedWindowResizeTarget,
               !target.frameGeometry.hasSameInputTransform(as: geometry) {
                authorizedWindowResizeTarget = nil
            }

            let now = clock.now()
            guard let candidateScreenVideoFrameGeometry,
                  candidateScreenVideoFrameGeometry.hasSameInputTransform(as: geometry),
                  let candidateScreenVideoFrameGeometrySince else {
                screenVideoFrameGeometry = nil
                candidateScreenVideoFrameGeometry = geometry
                self.candidateScreenVideoFrameGeometrySince = now
                return
            }

            if now - candidateScreenVideoFrameGeometrySince
                >= Self.minimumFrameGeometryStability {
                screenVideoFrameGeometry = geometry
            }
        }
    }

    /// Permanently disables this controller and revokes every active authorization.
    ///
    /// Unlike `revoke()`, invalidation is terminal: the controller cannot be armed
    /// again and every subsequent input request remains fail closed.
    public func invalidate() {
        withLock {
            isPermanentlyInvalidated = true
            clearScreenVideoFrameGeometry()
            revokeState()
        }
    }

    // MARK: - Pointer actions

    /// Posts one primary click and optionally grants keyboard focus to its editable target.
    public func handleTap(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        normalizedPoint: MacRemoteNormalizedPoint,
        viewerVideoSize: MacRemoteInputVideoSize? = nil
    ) -> MacRemoteInputResult {
        handleTapWithDiagnostics(
            screenRequestID: screenRequestID,
            inputSessionID: inputSessionID,
            normalizedPoint: normalizedPoint,
            viewerVideoSize: viewerVideoSize
        ).result
    }

    /// Posts one primary click and captures the exact local format fence that rejected it.
    public func handleTapWithDiagnostics(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        normalizedPoint: MacRemoteNormalizedPoint,
        viewerVideoSize: MacRemoteInputVideoSize? = nil
    ) -> MacRemoteInputDiagnosedResult {
        withLock {
            var screenFormatDiagnostic: MacRemoteInputScreenFormatDiagnostic?
            let result = handleTapLocked(
                screenRequestID: screenRequestID,
                inputSessionID: inputSessionID,
                normalizedPoint: normalizedPoint,
                viewerVideoSize: viewerVideoSize,
                screenFormatDiagnostic: &screenFormatDiagnostic
            )
            return MacRemoteInputDiagnosedResult(
                result: result,
                screenFormatDiagnostic: screenFormatDiagnostic
            )
        }
    }

    /// Performs the complete tap authorization and injection transaction under `lock`.
    private func handleTapLocked(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        normalizedPoint: MacRemoteNormalizedPoint,
        viewerVideoSize: MacRemoteInputVideoSize?,
        screenFormatDiagnostic: inout MacRemoteInputScreenFormatDiagnostic?
    ) -> MacRemoteInputResult {
        // Every tap invalidates the prior keyboard grant, even when this tap is
        // malformed or rate-limited.
        authorizedFocus = nil

        guard !isPermanentlyInvalidated, allowRemoteControl else {
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
        guard let viewerVideoSize else {
            screenFormatDiagnostic = makeScreenFormatDiagnostic(
                reason: .viewerSizeMissing,
                viewerVideoSize: nil,
                frameGeometry: screenVideoFrameGeometry
                    ?? candidateScreenVideoFrameGeometry,
                viewerAspectRelativeDifference: nil
            )
            return .rejected(.screenFormatChanging)
        }
        guard viewerVideoSize.isValid else {
            return .rejected(.invalidPoint)
        }
        guard hasCurrentPermissions() else {
            revokeState()
            return .rejected(.permissionRequired)
        }
        guard let liveDisplayBounds = validDisplayBounds(for: session.displayID) else {
            revokeState()
            return .rejected(.displayUnavailable)
        }
        let displayBounds = session.authoritativeDisplayBounds ?? liveDisplayBounds
        let frameGeometry: ScreenVideoFrameGeometry
        switch currentScreenVideoFrameGeometryResolution(compatibleWith: displayBounds) {
        case .unavailable:
            screenFormatDiagnostic = makeScreenFormatDiagnostic(
                reason: .frameGeometryUnavailableOrUnstable,
                viewerVideoSize: viewerVideoSize,
                frameGeometry: candidateScreenVideoFrameGeometry,
                viewerAspectRelativeDifference: nil
            )
            return .rejected(.screenFormatChanging)
        case .displayIncompatible(let geometry):
            screenFormatDiagnostic = makeScreenFormatDiagnostic(
                reason: .displayGeometryIncompatible,
                viewerVideoSize: viewerVideoSize,
                frameGeometry: geometry,
                viewerAspectRelativeDifference: nil
            )
            return .rejected(.screenFormatChanging)
        case .available(let geometry):
            frameGeometry = geometry
        }
        let viewerAspectComparison = Self.viewerVideoAspectComparison(
            viewerVideoSize,
            frameGeometry: frameGeometry
        )
        guard viewerAspectComparison.matches else {
            screenFormatDiagnostic = makeScreenFormatDiagnostic(
                reason: .viewerAspectMismatch,
                viewerVideoSize: viewerVideoSize,
                frameGeometry: frameGeometry,
                viewerAspectRelativeDifference:
                    viewerAspectComparison.relativeDifference
            )
            return .rejected(.screenFormatChanging)
        }
        guard let contentNormalizedPoint = mappedContentPoint(
            normalizedPoint,
            frameGeometry: frameGeometry,
            clampToContent: false
        ) else {
            return .rejected(.invalidPoint)
        }
        guard tapBucket.consume(1, at: clock.now()) else {
            return .rejected(.rateLimited)
        }

        let globalPoint = MacRemoteInputCoordinateMapper.globalPoint(
            contentNormalizedPoint,
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
        end: MacRemoteNormalizedPoint,
        viewerVideoSize: MacRemoteInputVideoSize? = nil
    ) -> MacRemoteInputResult {
        handlePrimaryDragWithDiagnostics(
            screenRequestID: screenRequestID,
            inputSessionID: inputSessionID,
            start: start,
            end: end,
            viewerVideoSize: viewerVideoSize
        ).result
    }

    /// Performs one drag and captures the exact local format fence that rejected it.
    public func handlePrimaryDragWithDiagnostics(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        start: MacRemoteNormalizedPoint,
        end: MacRemoteNormalizedPoint,
        viewerVideoSize: MacRemoteInputVideoSize? = nil
    ) -> MacRemoteInputDiagnosedResult {
        withLock {
            var screenFormatDiagnostic: MacRemoteInputScreenFormatDiagnostic?
            let result = handlePrimaryDragLocked(
                screenRequestID: screenRequestID,
                inputSessionID: inputSessionID,
                start: start,
                end: end,
                viewerVideoSize: viewerVideoSize,
                screenFormatDiagnostic: &screenFormatDiagnostic
            )
            return MacRemoteInputDiagnosedResult(
                result: result,
                screenFormatDiagnostic: screenFormatDiagnostic
            )
        }
    }

    /// Performs an atomic drag transaction under the controller lock.
    private func handlePrimaryDragLocked(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        start: MacRemoteNormalizedPoint,
        end: MacRemoteNormalizedPoint,
        viewerVideoSize: MacRemoteInputVideoSize?,
        screenFormatDiagnostic: inout MacRemoteInputScreenFormatDiagnostic?
    ) -> MacRemoteInputResult {
        // Any pointer action invalidates the prior keyboard grant, including a
        // malformed, stale, denied, or rate-limited drag.
        authorizedFocus = nil

        guard !isPermanentlyInvalidated, allowRemoteControl else {
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
        guard let viewerVideoSize else {
            screenFormatDiagnostic = makeScreenFormatDiagnostic(
                reason: .viewerSizeMissing,
                viewerVideoSize: nil,
                frameGeometry: screenVideoFrameGeometry
                    ?? candidateScreenVideoFrameGeometry,
                viewerAspectRelativeDifference: nil
            )
            return .rejected(.screenFormatChanging)
        }
        guard viewerVideoSize.isValid else {
            return .rejected(.invalidPoint)
        }
        guard hasCurrentPermissions() else {
            revokeState()
            return .rejected(.permissionRequired)
        }
        guard let liveDisplayBounds = validDisplayBounds(for: session.displayID) else {
            revokeState()
            return .rejected(.displayUnavailable)
        }
        let displayBounds = session.authoritativeDisplayBounds ?? liveDisplayBounds
        let frameGeometry: ScreenVideoFrameGeometry
        switch currentScreenVideoFrameGeometryResolution(compatibleWith: displayBounds) {
        case .unavailable:
            screenFormatDiagnostic = makeScreenFormatDiagnostic(
                reason: .frameGeometryUnavailableOrUnstable,
                viewerVideoSize: viewerVideoSize,
                frameGeometry: candidateScreenVideoFrameGeometry,
                viewerAspectRelativeDifference: nil
            )
            return .rejected(.screenFormatChanging)
        case .displayIncompatible(let geometry):
            screenFormatDiagnostic = makeScreenFormatDiagnostic(
                reason: .displayGeometryIncompatible,
                viewerVideoSize: viewerVideoSize,
                frameGeometry: geometry,
                viewerAspectRelativeDifference: nil
            )
            return .rejected(.screenFormatChanging)
        case .available(let geometry):
            frameGeometry = geometry
        }
        let viewerAspectComparison = Self.viewerVideoAspectComparison(
            viewerVideoSize,
            frameGeometry: frameGeometry
        )
        guard viewerAspectComparison.matches else {
            screenFormatDiagnostic = makeScreenFormatDiagnostic(
                reason: .viewerAspectMismatch,
                viewerVideoSize: viewerVideoSize,
                frameGeometry: frameGeometry,
                viewerAspectRelativeDifference:
                    viewerAspectComparison.relativeDifference
            )
            return .rejected(.screenFormatChanging)
        }
        guard let contentStart = mappedContentPoint(
            start,
            frameGeometry: frameGeometry,
            clampToContent: false
        ), let contentEnd = mappedContentPoint(
            end,
            frameGeometry: frameGeometry,
            clampToContent: true
        ) else {
            return .rejected(.invalidPoint)
        }
        guard !system.isPhysicalPrimaryButtonPressed() else {
            return .rejected(.primaryButtonInUse)
        }
        // Taps and atomic drags share one pointer-action budget so alternating
        // action kinds cannot bypass the host's documented click rate limit.
        guard tapBucket.consume(1, at: clock.now()) else {
            return .rejected(.rateLimited)
        }

        let globalStart = MacRemoteInputCoordinateMapper.globalPoint(
            contentStart,
            in: displayBounds
        )
        let globalEnd = MacRemoteInputCoordinateMapper.globalPoint(
            contentEnd,
            in: displayBounds
        )
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

    /// Posts one stateless pixel scroll at the initial remote touch anchor.
    public func handleScroll(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        anchor: MacRemoteNormalizedPoint,
        deltaX: Int32,
        deltaY: Int32,
        viewerVideoSize: MacRemoteInputVideoSize? = nil
    ) -> MacRemoteInputResult {
        handleScrollWithDiagnostics(
            screenRequestID: screenRequestID,
            inputSessionID: inputSessionID,
            anchor: anchor,
            deltaX: deltaX,
            deltaY: deltaY,
            viewerVideoSize: viewerVideoSize
        ).result
    }

    /// Posts one scroll and captures the exact local format fence that rejected it.
    public func handleScrollWithDiagnostics(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        anchor: MacRemoteNormalizedPoint,
        deltaX: Int32,
        deltaY: Int32,
        viewerVideoSize: MacRemoteInputVideoSize? = nil
    ) -> MacRemoteInputDiagnosedResult {
        withLock {
            var screenFormatDiagnostic: MacRemoteInputScreenFormatDiagnostic?
            let result = handleScrollLocked(
                screenRequestID: screenRequestID,
                inputSessionID: inputSessionID,
                anchor: anchor,
                deltaX: deltaX,
                deltaY: deltaY,
                viewerVideoSize: viewerVideoSize,
                screenFormatDiagnostic: &screenFormatDiagnostic
            )
            return MacRemoteInputDiagnosedResult(
                result: result,
                screenFormatDiagnostic: screenFormatDiagnostic
            )
        }
    }

    /// Performs the complete scroll authorization and injection transaction under `lock`.
    private func handleScrollLocked(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        anchor: MacRemoteNormalizedPoint,
        deltaX: Int32,
        deltaY: Int32,
        viewerVideoSize: MacRemoteInputVideoSize?,
        screenFormatDiagnostic: inout MacRemoteInputScreenFormatDiagnostic?
    ) -> MacRemoteInputResult {
        // Scrolling never grants keyboard authority, and any pointer intent retires a prior grant.
        authorizedFocus = nil

        guard !isPermanentlyInvalidated, allowRemoteControl else {
            return .rejected(.disabled)
        }
        guard let session = matchingSession(
            screenRequestID: screenRequestID,
            inputSessionID: inputSessionID
        ) else {
            return .rejected(.staleSession)
        }
        guard anchor.isValid else {
            return .rejected(.invalidPoint)
        }
        guard Self.isValidScrollDelta(deltaX: deltaX, deltaY: deltaY) else {
            return .rejected(.invalidScrollDelta)
        }
        guard let viewerVideoSize else {
            screenFormatDiagnostic = makeScreenFormatDiagnostic(
                reason: .viewerSizeMissing,
                viewerVideoSize: nil,
                frameGeometry: screenVideoFrameGeometry
                    ?? candidateScreenVideoFrameGeometry,
                viewerAspectRelativeDifference: nil
            )
            return .rejected(.screenFormatChanging)
        }
        guard viewerVideoSize.isValid else {
            return .rejected(.invalidPoint)
        }
        guard hasCurrentPermissions() else {
            revokeState()
            return .rejected(.permissionRequired)
        }
        guard let liveDisplayBounds = validDisplayBounds(for: session.displayID) else {
            revokeState()
            return .rejected(.displayUnavailable)
        }
        let displayBounds = session.authoritativeDisplayBounds ?? liveDisplayBounds
        let frameGeometry: ScreenVideoFrameGeometry
        switch currentScreenVideoFrameGeometryResolution(compatibleWith: displayBounds) {
        case .unavailable:
            screenFormatDiagnostic = makeScreenFormatDiagnostic(
                reason: .frameGeometryUnavailableOrUnstable,
                viewerVideoSize: viewerVideoSize,
                frameGeometry: candidateScreenVideoFrameGeometry,
                viewerAspectRelativeDifference: nil
            )
            return .rejected(.screenFormatChanging)
        case .displayIncompatible(let geometry):
            screenFormatDiagnostic = makeScreenFormatDiagnostic(
                reason: .displayGeometryIncompatible,
                viewerVideoSize: viewerVideoSize,
                frameGeometry: geometry,
                viewerAspectRelativeDifference: nil
            )
            return .rejected(.screenFormatChanging)
        case .available(let geometry):
            frameGeometry = geometry
        }
        let viewerAspectComparison = Self.viewerVideoAspectComparison(
            viewerVideoSize,
            frameGeometry: frameGeometry
        )
        guard viewerAspectComparison.matches else {
            screenFormatDiagnostic = makeScreenFormatDiagnostic(
                reason: .viewerAspectMismatch,
                viewerVideoSize: viewerVideoSize,
                frameGeometry: frameGeometry,
                viewerAspectRelativeDifference: viewerAspectComparison.relativeDifference
            )
            return .rejected(.screenFormatChanging)
        }
        guard let contentAnchor = mappedContentPoint(
            anchor,
            frameGeometry: frameGeometry,
            clampToContent: false
        ) else {
            return .rejected(.invalidPoint)
        }
        guard scrollBucket.consume(1, at: clock.now()) else {
            return .rejected(.rateLimited)
        }

        let globalAnchor = MacRemoteInputCoordinateMapper.globalPoint(
            contentAnchor,
            in: displayBounds
        )
        guard let preparedDelta = prepareLogicalScrollDelta(
            screenRequestID: screenRequestID,
            inputSessionID: inputSessionID,
            viewerVideoSize: viewerVideoSize,
            frameGeometry: frameGeometry,
            displayBounds: displayBounds,
            deltaX: deltaX,
            deltaY: deltaY
        ) else {
            return .rejected(.invalidScrollDelta)
        }
        guard preparedDelta.x != 0 || preparedDelta.y != 0 else {
            scrollDeltaConversionState = preparedDelta.nextState
            return .accepted(.none)
        }
        guard system.postScroll(
            at: globalAnchor,
            deltaX: preparedDelta.x,
            deltaY: preparedDelta.y
        ) else {
            return .rejected(.injectionFailed)
        }
        scrollDeltaConversionState = preparedDelta.nextState
        return .accepted(.none)
    }

    /// Mirrors the wire bound at the native injection boundary without depending on transport code.
    private static func isValidScrollDelta(deltaX: Int32, deltaY: Int32) -> Bool {
        guard deltaX != 0 || deltaY != 0 else { return false }
        return abs(Int64(deltaX)) <= Int64(maximumScrollDeltaMagnitude)
            && abs(Int64(deltaY)) <= Int64(maximumScrollDeltaMagnitude)
    }

    /// Converts decoded viewer-frame pixels into the logical content units consumed by AppKit.
    ///
    /// The viewer may receive either a 1x frame, a HiDPI framebuffer, or an independently adapted
    /// WebRTC frame. The captured content rectangle identifies what fraction of the source surface
    /// represents the live logical display. Fractional logical units carry across otherwise
    /// stateless packets so repeated sub-point deltas retain their total without remote gesture or
    /// mouse-button state.
    private func prepareLogicalScrollDelta(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        viewerVideoSize: MacRemoteInputVideoSize,
        frameGeometry: ScreenVideoFrameGeometry,
        displayBounds: CGRect,
        deltaX: Int32,
        deltaY: Int32
    ) -> PreparedLogicalScrollDelta? {
        let surfaceWidth = Double(frameGeometry.surfaceWidth)
        let surfaceHeight = Double(frameGeometry.surfaceHeight)
        let viewerWidth = Double(viewerVideoSize.width)
        let viewerHeight = Double(viewerVideoSize.height)
        let viewerContentWidth = Double(frameGeometry.contentRect.width)
            * viewerWidth / surfaceWidth
        let viewerContentHeight = Double(frameGeometry.contentRect.height)
            * viewerHeight / surfaceHeight
        guard viewerContentWidth.isFinite,
              viewerContentHeight.isFinite,
              viewerContentWidth > 0,
              viewerContentHeight > 0 else {
            return nil
        }

        let horizontalScale = Double(displayBounds.width) / viewerContentWidth
        let verticalScale = Double(displayBounds.height) / viewerContentHeight
        guard horizontalScale.isFinite,
              verticalScale.isFinite,
              horizontalScale > 0,
              verticalScale > 0 else {
            return nil
        }

        let candidateBinding = ScrollDeltaConversionBinding(
            screenRequestID: screenRequestID,
            inputSessionID: inputSessionID,
            viewerVideoSize: viewerVideoSize,
            frameGeometry: frameGeometry,
            logicalDisplaySize: displayBounds.size,
            horizontalScale: horizontalScale,
            verticalScale: verticalScale
        )
        var nextState: ScrollDeltaConversionState
        if let current = scrollDeltaConversionState,
           current.binding.matches(candidateBinding) {
            nextState = current
        } else {
            nextState = ScrollDeltaConversionState(
                binding: candidateBinding,
                horizontalRemainder: 0,
                verticalRemainder: 0
            )
        }

        let unroundedX = Double(deltaX) * nextState.binding.horizontalScale
            + nextState.horizontalRemainder
        let unroundedY = Double(deltaY) * nextState.binding.verticalScale
            + nextState.verticalRemainder
        guard unroundedX.isFinite, unroundedY.isFinite else { return nil }

        let roundedX = Self.integralScrollComponent(unroundedX)
        let roundedY = Self.integralScrollComponent(unroundedY)
        let nativeLimit = Double(Self.maximumScrollDeltaMagnitude)
        guard abs(roundedX) <= nativeLimit,
              abs(roundedY) <= nativeLimit else {
            return nil
        }

        let emittedX = Int32(roundedX)
        let emittedY = Int32(roundedY)
        nextState.horizontalRemainder = unroundedX - roundedX
        nextState.verticalRemainder = unroundedY - roundedY
        return PreparedLogicalScrollDelta(
            x: emittedX,
            y: emittedY,
            nextState: nextState
        )
    }

    /// Truncation delays a sub-point event until enough accepted motion accumulates. Snap values
    /// already within floating-point noise of an integer so exact mode ratios do not lose a unit.
    private static func integralScrollComponent(_ value: Double) -> Double {
        let nearest = value.rounded()
        let tolerance = 1e-9 * max(1, abs(value))
        if abs(value - nearest) <= tolerance {
            return nearest
        }
        return value.rounded(.towardZero)
    }

    // MARK: - Focused-window resize

    /// Acquires the exact currently focused standard window without changing system focus.
    public func requestFocusedWindowResizeTarget(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        viewerVideoSize: MacRemoteInputVideoSize?
    ) -> MacRemoteWindowResizeDiagnosedResult {
        withLock {
            // A semantic reacquisition supersedes any previously issued resize authority.
            authorizedWindowResizeTarget = nil
            let resolution = windowResizeContextLocked(
                screenRequestID: screenRequestID,
                inputSessionID: inputSessionID,
                viewerVideoSize: viewerVideoSize
            )
            guard case .available(let context) = resolution else {
                return diagnosedWindowResizeRejection(resolution)
            }
            let preservedFocus = currentlyAuthorizedFocusIfValid()
            guard windowResizeBucket.consume(1, at: clock.now()) else {
                return .init(
                    result: .rejected(.rateLimited),
                    verifiedFocus: focusResult(preserving: preservedFocus)
                )
            }

            guard let window = system.focusedWindow() else {
                authorizedWindowResizeTarget = nil
                return .init(
                    result: .rejected(.windowUnavailable),
                    verifiedFocus: focusResult(preserving: preservedFocus),
                    screenFormatDiagnostic: nil
                )
            }
            return installWindowResizeTarget(
                for: window,
                kind: .targetAcquired,
                context: context,
                preservedFocus: preservedFocus
            )
        }
    }

    /// Selects only the top-level standard window at a video point, without clicking its controls.
    public func selectWindowForResize(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        normalizedPoint: MacRemoteNormalizedPoint,
        viewerVideoSize: MacRemoteInputVideoSize?
    ) -> MacRemoteWindowResizeDiagnosedResult {
        withLock {
            // A selection attempt always retires the old target, including malformed taps.
            authorizedWindowResizeTarget = nil
            guard normalizedPoint.isValid else {
                return .init(result: .rejected(.invalidPoint))
            }
            let resolution = windowResizeContextLocked(
                screenRequestID: screenRequestID,
                inputSessionID: inputSessionID,
                viewerVideoSize: viewerVideoSize
            )
            guard case .available(let context) = resolution else {
                return diagnosedWindowResizeRejection(resolution)
            }
            guard let contentPoint = mappedContentPoint(
                normalizedPoint,
                frameGeometry: context.frameGeometry,
                clampToContent: false
            ) else {
                return .init(result: .rejected(.invalidPoint))
            }
            let preservedFocus = currentlyAuthorizedFocusIfValid()
            guard windowResizeBucket.consume(1, at: clock.now()) else {
                return .init(
                    result: .rejected(.rateLimited),
                    verifiedFocus: focusResult(preserving: preservedFocus)
                )
            }

            let globalPoint = MacRemoteInputCoordinateMapper.globalPoint(
                contentPoint,
                in: context.displayBounds
            )
            guard let hitElement = system.element(at: globalPoint),
                  let window = windowAncestor(from: hitElement),
                  validatedResizableWindowFrame(window, in: context.displayBounds) != nil,
                  system.focusWindow(window),
                  waitForFocusedWindow(matching: window) else {
                return .init(
                    result: .rejected(.windowUnavailable),
                    verifiedFocus: focusResult(preserving: preservedFocus)
                )
            }
            return installWindowResizeTarget(
                for: window,
                kind: .windowSelected,
                context: context,
                preservedFocus: preservedFocus
            )
        }
    }

    /// Applies one bounded AX size/position transaction to the exact bound target generation.
    public func commitFocusedWindowResize(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        targetGeneration: UUID,
        start: MacRemoteNormalizedPoint,
        end: MacRemoteNormalizedPoint,
        viewerVideoSize: MacRemoteInputVideoSize?
    ) -> MacRemoteWindowResizeDiagnosedResult {
        withLock {
            guard targetGeneration != Self.zeroUUID,
                  start.isValid, end.isValid else {
                authorizedWindowResizeTarget = nil
                return .init(result: .rejected(.invalidPoint))
            }
            let resolution = windowResizeContextLocked(
                screenRequestID: screenRequestID,
                inputSessionID: inputSessionID,
                viewerVideoSize: viewerVideoSize
            )
            guard case .available(let context) = resolution else {
                authorizedWindowResizeTarget = nil
                return diagnosedWindowResizeRejection(resolution)
            }
            guard let target = authorizedWindowResizeTarget,
                  target.generation == targetGeneration,
                  target.screenRequestID == screenRequestID,
                  target.inputSessionID == inputSessionID,
                  target.viewerVideoSize == context.viewerVideoSize,
                  target.frameGeometry.hasSameInputTransform(as: context.frameGeometry),
                  MacRemoteWindowResizeGeometry.approximatelyEqual(
                      target.displayBounds,
                      context.displayBounds
                  ),
                  let focusedWindow = system.focusedWindow(),
                  system.elementsEqual(focusedWindow, target.element),
                  let currentFrame = validatedResizableWindowFrame(
                      target.element,
                      in: context.displayBounds
                  ),
                  MacRemoteWindowResizeGeometry.approximatelyEqual(
                      currentFrame,
                      target.originalFrame
                  ),
                  let contentStart = mappedContentPoint(
                      start,
                      frameGeometry: context.frameGeometry,
                      clampToContent: false
                  ),
                  let contentEnd = mappedContentPoint(
                      end,
                      frameGeometry: context.frameGeometry,
                      clampToContent: true
                  ) else {
                authorizedWindowResizeTarget = nil
                let preservedFocus = currentlyAuthorizedFocusIfValid()
                return .init(
                    result: .rejected(.windowUnavailable),
                    verifiedFocus: focusResult(preserving: preservedFocus)
                )
            }

            let preservedFocus = currentlyAuthorizedFocusIfValid()

            let globalStart = MacRemoteInputCoordinateMapper.globalPoint(
                contentStart,
                in: context.displayBounds
            )
            let globalEnd = MacRemoteInputCoordinateMapper.globalPoint(
                contentEnd,
                in: context.displayBounds
            )
            guard let proposal = MacRemoteWindowResizeGeometry.proposedFrame(
                original: target.originalFrame,
                start: globalStart,
                end: globalEnd,
                displayBounds: context.displayBounds
            ) else {
                authorizedWindowResizeTarget = nil
                return .init(
                    result: .rejected(.invalidPoint),
                    verifiedFocus: focusResult(preserving: preservedFocus)
                )
            }
            guard windowResizeBucket.consume(1, at: clock.now()) else {
                authorizedWindowResizeTarget = nil
                return .init(
                    result: .rejected(.rateLimited),
                    verifiedFocus: focusResult(preserving: preservedFocus)
                )
            }
            guard !system.isPhysicalPrimaryButtonPressed() else {
                authorizedWindowResizeTarget = nil
                return .init(
                    result: .rejected(.primaryButtonInUse),
                    verifiedFocus: focusResult(preserving: preservedFocus)
                )
            }
            guard let successorGeneration = freshWindowResizeGeneration(
                excluding: target.generation
            ) else {
                revokeState()
                return .init(
                    result: .rejected(.staleSession)
                )
            }

            // The AX/TCC/display world is not serialized by this controller's lock. Re-resolve
            // every external and controller-owned authorization fact after all proposal, rate-limit,
            // physical-button, and successor-generation work, immediately before the first AX
            // write. A focus, frame, permission, display, capture transform, viewer shape, session,
            // or one-shot target drift therefore retires the target without any system mutation.
            let finalResolution = windowResizeContextLocked(
                screenRequestID: screenRequestID,
                inputSessionID: inputSessionID,
                viewerVideoSize: viewerVideoSize
            )
            guard case .available(let finalContext) = finalResolution else {
                authorizedWindowResizeTarget = nil
                return diagnosedWindowResizeRejection(finalResolution)
            }
            guard let finalTarget = authorizedWindowResizeTarget,
                  finalTarget.generation == targetGeneration,
                  finalTarget.generation == target.generation,
                  finalTarget.screenRequestID == screenRequestID,
                  finalTarget.inputSessionID == inputSessionID,
                  finalTarget.viewerVideoSize == finalContext.viewerVideoSize,
                  finalTarget.viewerVideoSize == target.viewerVideoSize,
                  finalTarget.frameGeometry.hasSameInputTransform(
                      as: finalContext.frameGeometry
                  ),
                  finalTarget.frameGeometry.hasSameInputTransform(
                      as: target.frameGeometry
                  ),
                  MacRemoteWindowResizeGeometry.approximatelyEqual(
                      finalTarget.displayBounds,
                      finalContext.displayBounds
                  ),
                  MacRemoteWindowResizeGeometry.approximatelyEqual(
                      finalTarget.displayBounds,
                      target.displayBounds
                  ),
                  let finalFocusedWindow = system.focusedWindow(),
                  system.elementsEqual(finalFocusedWindow, finalTarget.element),
                  system.elementsEqual(finalTarget.element, target.element),
                  let finalFrame = validatedResizableWindowFrame(
                      finalTarget.element,
                      in: finalContext.displayBounds
                  ),
                  MacRemoteWindowResizeGeometry.approximatelyEqual(
                      finalFrame,
                      finalTarget.originalFrame
                  ),
                  MacRemoteWindowResizeGeometry.approximatelyEqual(
                      finalFrame,
                      target.originalFrame
                  ) else {
                authorizedWindowResizeTarget = nil
                return .init(
                    result: .rejected(.windowUnavailable),
                    verifiedFocus: focusResult(preserving: preservedFocus)
                )
            }

            authorizedWindowResizeTarget = nil
            switch performWindowResizeTransaction(
                window: finalTarget.element,
                originalFrame: finalTarget.originalFrame,
                proposedFrame: proposal.frame,
                corner: proposal.corner,
                displayBounds: finalContext.displayBounds
            ) {
            case .committed(let finalFrame):
                guard let stillFocused = system.focusedWindow(),
                      system.elementsEqual(stillFocused, finalTarget.element),
                      let normalizedFrame = finalContext.frameGeometry.frameNormalizedRect(
                          forGlobalRect: finalFrame,
                          in: finalContext.displayBounds
                      ) else {
                    return rejectCommittedResizeAfterRollback(
                        window: finalTarget.element,
                        originalFrame: finalTarget.originalFrame,
                        preservedFocus: preservedFocus
                    )
                }
                return installCommittedWindowResizeTarget(
                    window: finalTarget.element,
                    generation: successorGeneration,
                    consumedGeneration: finalTarget.generation,
                    finalFrame: finalFrame,
                    normalizedFrame: normalizedFrame,
                    context: finalContext,
                    preservedFocus: preservedFocus
                )

            case .failedWithProvenRollback:
                return .init(
                    result: .rejected(.windowResizeFailed),
                    verifiedFocus: focusResult(preserving: preservedFocus),
                    screenFormatDiagnostic: nil
                )

            case .restorationUncertain:
                authorizedFocus = nil
                return .init(
                    result: .rejected(.windowResizeUncertain),
                    screenFormatDiagnostic: nil
                )
            }
        }
    }

    private func windowResizeContextLocked(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        viewerVideoSize: MacRemoteInputVideoSize?
    ) -> MacRemoteWindowResizeContextResolution {
        guard !isPermanentlyInvalidated, allowRemoteControl else {
            return .rejected(.disabled, diagnostic: nil)
        }
        guard let session = matchingSession(
            screenRequestID: screenRequestID,
            inputSessionID: inputSessionID
        ) else {
            return .rejected(.staleSession, diagnostic: nil)
        }
        guard let viewerVideoSize else {
            return .rejected(
                .screenFormatChanging,
                diagnostic: makeScreenFormatDiagnostic(
                    reason: .viewerSizeMissing,
                    viewerVideoSize: nil,
                    frameGeometry: screenVideoFrameGeometry
                        ?? candidateScreenVideoFrameGeometry,
                    viewerAspectRelativeDifference: nil
                )
            )
        }
        guard viewerVideoSize.isValid else {
            return .rejected(.invalidPoint, diagnostic: nil)
        }
        guard hasCurrentPermissions() else {
            revokeState()
            return .rejected(.permissionRequired, diagnostic: nil)
        }
        guard let liveDisplayBounds = validDisplayBounds(for: session.displayID) else {
            revokeState()
            return .rejected(.displayUnavailable, diagnostic: nil)
        }
        let displayBounds = session.authoritativeDisplayBounds ?? liveDisplayBounds
        let frameGeometry: ScreenVideoFrameGeometry
        switch currentScreenVideoFrameGeometryResolution(compatibleWith: displayBounds) {
        case .unavailable:
            return .rejected(
                .screenFormatChanging,
                diagnostic: makeScreenFormatDiagnostic(
                    reason: .frameGeometryUnavailableOrUnstable,
                    viewerVideoSize: viewerVideoSize,
                    frameGeometry: candidateScreenVideoFrameGeometry,
                    viewerAspectRelativeDifference: nil
                )
            )
        case .displayIncompatible(let geometry):
            return .rejected(
                .screenFormatChanging,
                diagnostic: makeScreenFormatDiagnostic(
                    reason: .displayGeometryIncompatible,
                    viewerVideoSize: viewerVideoSize,
                    frameGeometry: geometry,
                    viewerAspectRelativeDifference: nil
                )
            )
        case .available(let geometry):
            frameGeometry = geometry
        }
        let comparison = Self.viewerVideoAspectComparison(
            viewerVideoSize,
            frameGeometry: frameGeometry
        )
        guard comparison.matches else {
            return .rejected(
                .screenFormatChanging,
                diagnostic: makeScreenFormatDiagnostic(
                    reason: .viewerAspectMismatch,
                    viewerVideoSize: viewerVideoSize,
                    frameGeometry: frameGeometry,
                    viewerAspectRelativeDifference: comparison.relativeDifference
                )
            )
        }
        return .available(
            MacRemoteWindowResizeContext(
                session: session,
                displayBounds: displayBounds,
                frameGeometry: frameGeometry,
                viewerVideoSize: viewerVideoSize
            )
        )
    }

    private func diagnosedWindowResizeRejection(
        _ resolution: MacRemoteWindowResizeContextResolution
    ) -> MacRemoteWindowResizeDiagnosedResult {
        switch resolution {
        case .available:
            return .init(result: .rejected(.windowUnavailable))
        case .rejected(let rejection, let diagnostic):
            let verifiedFocus: MacRemoteInputFocus?
            if rejection == .screenFormatChanging {
                verifiedFocus = focusResult(
                    preserving: currentlyAuthorizedFocusIfValid()
                )
            } else {
                verifiedFocus = nil
            }
            return .init(
                result: .rejected(rejection),
                verifiedFocus: verifiedFocus,
                screenFormatDiagnostic: diagnostic
            )
        }
    }

    private func installWindowResizeTarget(
        for window: MacRemoteAccessibilityElement,
        kind: MacRemoteWindowResizeFeedbackKind,
        context: MacRemoteWindowResizeContext,
        preservedFocus: AuthorizedFocus?
    ) -> MacRemoteWindowResizeDiagnosedResult {
        guard let focusedWindow = system.focusedWindow(),
              system.elementsEqual(focusedWindow, window),
              let frame = validatedResizableWindowFrame(
                  window,
                  in: context.displayBounds
              ),
              let normalizedFrame = context.frameGeometry.frameNormalizedRect(
                  forGlobalRect: frame,
                  in: context.displayBounds
              ) else {
            authorizedWindowResizeTarget = nil
            return .init(
                result: .rejected(.windowUnavailable),
                verifiedFocus: focusResult(preserving: preservedFocus),
                screenFormatDiagnostic: nil
            )
        }
        guard let generation = freshWindowResizeGeneration(excluding: nil) else {
            revokeState()
            return .init(result: .rejected(.staleSession))
        }

        authorizedWindowResizeTarget = AuthorizedWindowResizeTarget(
            element: window,
            generation: generation,
            originalFrame: frame,
            displayBounds: context.displayBounds,
            frameGeometry: context.frameGeometry,
            viewerVideoSize: context.viewerVideoSize,
            screenRequestID: context.session.screenRequestID,
            inputSessionID: context.session.inputSessionID
        )
        return MacRemoteWindowResizeDiagnosedResult(
            result: .accepted(focusResult(preserving: preservedFocus)),
            windowResizeFeedback: MacRemoteWindowResizeFeedback(
                kind: kind,
                target: MacRemoteWindowResizeTarget(
                    generation: generation,
                    normalizedFrame: normalizedFrame
                )
            ),
            verifiedFocus: nil
        )
    }

    /// Publishes only the already-read, validated AX truth from the successful transaction.
    private func installCommittedWindowResizeTarget(
        window: MacRemoteAccessibilityElement,
        generation: UUID,
        consumedGeneration: UUID,
        finalFrame: CGRect,
        normalizedFrame: CGRect,
        context: MacRemoteWindowResizeContext,
        preservedFocus: AuthorizedFocus?
    ) -> MacRemoteWindowResizeDiagnosedResult {
        authorizedWindowResizeTarget = AuthorizedWindowResizeTarget(
            element: window,
            generation: generation,
            originalFrame: finalFrame,
            displayBounds: context.displayBounds,
            frameGeometry: context.frameGeometry,
            viewerVideoSize: context.viewerVideoSize,
            screenRequestID: context.session.screenRequestID,
            inputSessionID: context.session.inputSessionID
        )
        return MacRemoteWindowResizeDiagnosedResult(
            result: .accepted(focusResult(preserving: preservedFocus)),
            windowResizeFeedback: MacRemoteWindowResizeFeedback(
                kind: .resizeCommitted,
                target: MacRemoteWindowResizeTarget(
                    generation: generation,
                    normalizedFrame: normalizedFrame
                ),
                committedTargetGeneration: consumedGeneration
            )
        )
    }

    /// A resize is not rejected after mutation unless the original frame is restored or the
    /// outcome is escalated to terminal uncertainty.
    private func rejectCommittedResizeAfterRollback(
        window: MacRemoteAccessibilityElement,
        originalFrame: CGRect,
        preservedFocus: AuthorizedFocus?
    ) -> MacRemoteWindowResizeDiagnosedResult {
        authorizedWindowResizeTarget = nil
        if rollbackWindowFrame(window, to: originalFrame) {
            return .init(
                result: .rejected(.windowResizeFailed),
                verifiedFocus: focusResult(preserving: preservedFocus)
            )
        }
        authorizedFocus = nil
        return .init(result: .rejected(.windowResizeUncertain))
    }

    /// Bounds a broken generator and never reissues authority within one input session.
    private func freshWindowResizeGeneration(excluding consumed: UUID?) -> UUID? {
        guard issuedWindowResizeGenerations.count
                < Self.maximumWindowResizeGenerationsPerSession else {
            return nil
        }
        for _ in 0..<16 {
            let candidate = makeWindowResizeGeneration()
            if candidate != Self.zeroUUID,
               candidate != consumed,
               issuedWindowResizeGenerations.insert(candidate).inserted {
                return candidate
            }
        }
        return nil
    }

    private func validatedResizableWindowFrame(
        _ window: MacRemoteAccessibilityElement,
        in displayBounds: CGRect
    ) -> CGRect? {
        guard let frame = system.windowFrame(window),
              isResizableWindow(window, with: frame, in: displayBounds) else {
            return nil
        }
        return frame
    }

    /// Validates one exact AX readback so a second frame read cannot race the transaction proof.
    private func isResizableWindow(
        _ window: MacRemoteAccessibilityElement,
        with frame: CGRect,
        in displayBounds: CGRect
    ) -> Bool {
        system.role(of: window) == "AXWindow"
            && system.subrole(of: window) == "AXStandardWindow"
            && system.isEnabled(window) == true
            && system.isWindowMinimized(window) == false
            && system.isWindowFullScreen(window) == false
            && system.isWindowModal(window) == false
            && system.isWindowPositionSettable(window)
            && system.isWindowSizeSettable(window)
            && MacRemoteWindowResizeGeometry.contains(
                frame,
                in: displayBounds,
                tolerance: 0.5
            )
            && !Self.isFullscreenLike(frame, in: displayBounds)
    }

    private static func isFullscreenLike(_ frame: CGRect, in displayBounds: CGRect) -> Bool {
        let tolerance: CGFloat = 2
        return abs(frame.minX - displayBounds.minX) <= tolerance
            && abs(frame.minY - displayBounds.minY) <= tolerance
            && abs(frame.maxX - displayBounds.maxX) <= tolerance
            && abs(frame.maxY - displayBounds.maxY) <= tolerance
    }

    private func windowAncestor(
        from hitElement: MacRemoteAccessibilityElement
    ) -> MacRemoteAccessibilityElement? {
        var current: MacRemoteAccessibilityElement? = hitElement
        var visited: [MacRemoteAccessibilityElement] = []
        for _ in 0..<Self.maximumWindowAncestorDepth {
            guard let element = current else { break }
            if visited.contains(where: { system.elementsEqual($0, element) }) {
                break
            }
            visited.append(element)
            if system.role(of: element) == "AXWindow" {
                return element
            }
            current = system.parent(of: element)
        }
        return nil
    }

    private func waitForFocusedWindow(
        matching expected: MacRemoteAccessibilityElement
    ) -> Bool {
        let deadline = clock.now() + Self.maximumFocusWait
        for attempt in 0...10 {
            if let focused = system.focusedWindow(), system.elementsEqual(focused, expected) {
                return true
            }
            let now = clock.now()
            guard attempt < 10, now < deadline else { break }
            clock.sleep(for: min(Self.focusPollInterval, deadline - now))
        }
        return false
    }

    private func currentlyAuthorizedFocusIfValid() -> AuthorizedFocus? {
        guard let authorizedFocus else { return nil }
        guard verifyFocusedElement(authorizedFocus) else {
            self.authorizedFocus = nil
            return nil
        }
        return authorizedFocus
    }

    private func focusResult(preserving focus: AuthorizedFocus?) -> MacRemoteInputFocus {
        guard let focus, verifyFocusedElement(focus) else {
            if let focus, authorizedFocus?.generation == focus.generation {
                authorizedFocus = nil
            }
            return .none
        }
        authorizedFocus = focus
        return .editable(generation: focus.generation, secure: false)
    }

    private enum WindowResizeTransactionResult {
        case committed(CGRect)
        case failedWithProvenRollback
        case restorationUncertain
    }

    private func performWindowResizeTransaction(
        window: MacRemoteAccessibilityElement,
        originalFrame: CGRect,
        proposedFrame: CGRect,
        corner: MacRemoteWindowResizeCorner,
        displayBounds: CGRect
    ) -> WindowResizeTransactionResult {
        guard system.setWindowSize(proposedFrame.size, for: window),
              let constrainedFrame = system.windowFrame(window),
              let anchoredOrigin = MacRemoteWindowResizeGeometry.anchoredOrigin(
                  for: constrainedFrame.size,
                  original: originalFrame,
                  corner: corner
              ) else {
            return rollbackWindowFrame(window, to: originalFrame)
                ? .failedWithProvenRollback
                : .restorationUncertain
        }

        let constrainedCandidate = CGRect(
            origin: anchoredOrigin,
            size: constrainedFrame.size
        )
        guard MacRemoteWindowResizeGeometry.contains(
            constrainedCandidate,
            in: displayBounds,
            tolerance: 0.5
        ) else {
            return rollbackWindowFrame(window, to: originalFrame)
                ? .failedWithProvenRollback
                : .restorationUncertain
        }

        if !MacRemoteWindowResizeGeometry.approximatelyEqual(
            constrainedFrame.origin,
            anchoredOrigin
        ), !system.setWindowPosition(anchoredOrigin, for: window) {
            return rollbackWindowFrame(window, to: originalFrame)
                ? .failedWithProvenRollback
                : .restorationUncertain
        }

        guard let finalFrame = system.windowFrame(window),
              isResizableWindow(
                  window,
                  with: finalFrame,
                  in: displayBounds
              ),
              MacRemoteWindowResizeGeometry.preservesOppositeCorner(
                  finalFrame,
                  from: originalFrame,
                  corner: corner
              ) else {
            return rollbackWindowFrame(window, to: originalFrame)
                ? .failedWithProvenRollback
                : .restorationUncertain
        }
        return .committed(finalFrame)
    }

    private func rollbackWindowFrame(
        _ window: MacRemoteAccessibilityElement,
        to originalFrame: CGRect
    ) -> Bool {
        _ = system.setWindowSize(originalFrame.size, for: window)
        _ = system.setWindowPosition(originalFrame.origin, for: window)
        guard let restored = system.windowFrame(window) else { return false }
        return MacRemoteWindowResizeGeometry.approximatelyEqual(restored, originalFrame)
    }

    // MARK: - Keyboard actions

    /// Inserts bounded Unicode text into the exact focus generation granted by a tap.
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

    /// Revalidates session, permissions, focus, and rate limit before text injection.
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

    /// Posts one allowed key into the exact focus generation granted by a tap.
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

    /// Revalidates session, permissions, focus, and rate limit before key injection.
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

    /// Validates protocol text limits and rejects control/function-key scalars.
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

    // MARK: - Authorization helpers

    /// Resolves the current focus grant after fail-closed session and TCC checks.
    private func authorizeKeyboardAction(
        screenRequestID: UInt64,
        inputSessionID: UUID,
        focusGeneration: UInt64
    ) -> (focus: AuthorizedFocus?, rejection: MacRemoteInputRejection?) {
        guard !isPermanentlyInvalidated, allowRemoteControl else {
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

    /// Invalidates keyboard authority on every rejection to require a fresh pointer grant.
    private func rejectKeyboardAction(_ reason: MacRemoteInputRejection) -> MacRemoteInputResult {
        authorizedFocus = nil
        return .rejected(reason)
    }

    /// Matches both public request identity and the unguessable per-session UUID.
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

    private enum ScreenVideoFrameGeometryResolution {
        case unavailable
        case displayIncompatible(ScreenVideoFrameGeometry)
        case available(ScreenVideoFrameGeometry)
    }

    private struct ViewerVideoAspectComparison {
        let relativeDifference: Double
        let tolerance: Double

        var matches: Bool {
            relativeDifference <= tolerance
        }
    }

    /// Promotes a stable frame transform and classifies the exact geometry fence atomically.
    private func currentScreenVideoFrameGeometryResolution(
        compatibleWith displayBounds: CGRect
    ) -> ScreenVideoFrameGeometryResolution {
        if screenVideoFrameGeometry == nil,
           let candidateScreenVideoFrameGeometry,
           let candidateScreenVideoFrameGeometrySince,
           clock.now() - candidateScreenVideoFrameGeometrySince
            >= Self.minimumFrameGeometryStability {
            screenVideoFrameGeometry = candidateScreenVideoFrameGeometry
        }
        guard let screenVideoFrameGeometry else {
            return .unavailable
        }
        guard screenVideoFrameGeometry.hasCompatibleAspectRatio(with: displayBounds) else {
            return .displayIncompatible(screenVideoFrameGeometry)
        }
        return .available(screenVideoFrameGeometry)
    }

    /// Accepts WebRTC's bounded alignment/crop rounding while rejecting a delayed frame from a
    /// materially different display shape. Exact aspect equality is unsafe because adaptation
    /// can round each output edge independently.
    private static func viewerVideoAspectComparison(
        _ viewerVideoSize: MacRemoteInputVideoSize,
        frameGeometry: ScreenVideoFrameGeometry
    ) -> ViewerVideoAspectComparison {
        let viewerAspect = Double(viewerVideoSize.width) / Double(viewerVideoSize.height)
        let frameAspect = Double(frameGeometry.surfaceWidth)
            / Double(frameGeometry.surfaceHeight)
        let relativeDifference = abs(viewerAspect - frameAspect)
            / max(viewerAspect, frameAspect)
        // WebRTC aligns encoded edges to even pixels. Bound the resulting aspect error by two
        // pixels on each smaller edge, capped so an implausibly tiny wire size cannot weaken the
        // transition fence for the supported display modes.
        let alignmentTolerance = min(
            0.02,
            2 / Double(min(viewerVideoSize.width, viewerVideoSize.height))
                + 2 / Double(min(frameGeometry.surfaceWidth, frameGeometry.surfaceHeight))
        )
        return ViewerVideoAspectComparison(
            relativeDifference: relativeDifference,
            tolerance: alignmentTolerance
        )
    }

    /// Snapshots only bounded structural state while the controller lock still owns the result.
    private func makeScreenFormatDiagnostic(
        reason: MacRemoteInputScreenFormatReason,
        viewerVideoSize: MacRemoteInputVideoSize?,
        frameGeometry: ScreenVideoFrameGeometry?,
        viewerAspectRelativeDifference: Double?
    ) -> MacRemoteInputScreenFormatDiagnostic {
        let candidateAgeMilliseconds = candidateScreenVideoFrameGeometrySince.map { since in
            let milliseconds = max(0, (clock.now() - since) * 1_000)
            // Keep telemetry bounded even if a custom or suspended clock jumps far forward.
            return UInt64(min(milliseconds, 86_400_000).rounded(.down))
        }
        return MacRemoteInputScreenFormatDiagnostic(
            reason: reason,
            viewerVideoSize: viewerVideoSize,
            frameSurfaceWidth: frameGeometry?.surfaceWidth,
            frameSurfaceHeight: frameGeometry?.surfaceHeight,
            stableGeometryAvailable: screenVideoFrameGeometry != nil,
            candidateGeometryAvailable: candidateScreenVideoFrameGeometry != nil,
            candidateAgeMilliseconds: candidateAgeMilliseconds,
            viewerAspectRelativeDifference: viewerAspectRelativeDifference
        )
    }

    /// Removes ScreenCaptureKit's inner content inset before mapping into live display bounds.
    private func mappedContentPoint(
        _ frameNormalizedPoint: MacRemoteNormalizedPoint,
        frameGeometry: ScreenVideoFrameGeometry,
        clampToContent: Bool
    ) -> MacRemoteNormalizedPoint? {
        let point = CGPoint(x: frameNormalizedPoint.x, y: frameNormalizedPoint.y)
        let mapped = clampToContent
            ? frameGeometry.clampedContentNormalizedPoint(for: point)
            : frameGeometry.contentNormalizedPoint(for: point)
        guard let mapped else { return nil }
        return MacRemoteNormalizedPoint(
            x: Double(mapped.x),
            y: Double(mapped.y)
        )
    }

    private func clearScreenVideoFrameGeometry() {
        screenVideoFrameGeometry = nil
        candidateScreenVideoFrameGeometry = nil
        candidateScreenVideoFrameGeometrySince = nil
        scrollDeltaConversionState = nil
        authorizedWindowResizeTarget = nil
    }

    private func hasCurrentPermissions() -> Bool {
        system.permissionStatus(promptIfNeeded: false).isAuthorized
    }

    /// Rejects inactive or geometrically unusable display bounds.
    private func validDisplayBounds(for displayID: UInt32) -> CGRect? {
        Self.validatedDisplayBounds(system.displayBounds(for: displayID))
    }

    private static func validatedDisplayBounds(_ bounds: CGRect?) -> CGRect? {
        guard let bounds,
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

    /// Walks a bounded, cycle-safe AX ancestry to find an allowed editable target.
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

    /// Applies the role, enabled-state, and writable-value editability policy.
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

    /// Gives AppKit a bounded 50 ms window to move focus after pointer injection.
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

    /// Confirms the previously authorized AX object still owns editable focus.
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
        scrollBucket.reset(at: now)
        keyBucket.reset(at: now)
        textBucket.reset(at: now)
        windowResizeBucket.reset(at: now)
    }

    /// Clears all authority and refills buckets for the next explicitly armed session.
    private func revokeState() {
        activeSession = nil
        authorizedFocus = nil
        authorizedWindowResizeTarget = nil
        issuedWindowResizeGenerations.removeAll(keepingCapacity: false)
        nextFocusGeneration = 0
        scrollDeltaConversionState = nil
        resetRateLimits(now: clock.now())
    }

    /// Serializes a complete authorization-and-post transaction.
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

/// Exact screen and input identities to which the controller is currently bound.
private struct ActiveSession: Sendable {
    let displayID: UInt32
    let screenRequestID: UInt64
    let inputSessionID: UUID
    var authoritativeDisplayBounds: CGRect?
}

/// Stable conversion identity for fractional logical scroll carry.
private struct ScrollDeltaConversionBinding: Sendable {
    let screenRequestID: UInt64
    let inputSessionID: UUID
    let viewerVideoSize: MacRemoteInputVideoSize
    let frameGeometry: ScreenVideoFrameGeometry
    let logicalDisplaySize: CGSize
    let horizontalScale: Double
    let verticalScale: Double

    /// ScreenCaptureKit metadata can jitter by a subpixel without changing the input transform.
    /// Retain the original scale/remainder across that benign variation, but reset for every
    /// session, decoded-size, logical-size, or material frame-transform transition.
    func matches(_ other: ScrollDeltaConversionBinding) -> Bool {
        screenRequestID == other.screenRequestID
            && inputSessionID == other.inputSessionID
            && viewerVideoSize == other.viewerVideoSize
            && logicalDisplaySize == other.logicalDisplaySize
            && frameGeometry.hasSameInputTransform(as: other.frameGeometry)
    }
}

/// Numeric quantization carry only; this owns no remote gesture or mouse-button lifecycle.
private struct ScrollDeltaConversionState: Sendable {
    let binding: ScrollDeltaConversionBinding
    var horizontalRemainder: Double
    var verticalRemainder: Double
}

/// One converted event plus the state committed only after that packet is accepted locally.
private struct PreparedLogicalScrollDelta: Sendable {
    let x: Int32
    let y: Int32
    let nextState: ScrollDeltaConversionState
}

/// AX element and monotonic generation authorized by the most recent pointer action.
private struct AuthorizedFocus: Sendable {
    let element: MacRemoteAccessibilityElement
    let generation: UInt64
}

/// Exact AX and geometry identity authorized by the most recent target acquisition.
private struct AuthorizedWindowResizeTarget: Sendable {
    let element: MacRemoteAccessibilityElement
    let generation: UUID
    let originalFrame: CGRect
    let displayBounds: CGRect
    let frameGeometry: ScreenVideoFrameGeometry
    let viewerVideoSize: MacRemoteInputVideoSize
    let screenRequestID: UInt64
    let inputSessionID: UUID
}

private struct MacRemoteWindowResizeContext: Sendable {
    let session: ActiveSession
    let displayBounds: CGRect
    let frameGeometry: ScreenVideoFrameGeometry
    let viewerVideoSize: MacRemoteInputVideoSize
}

private enum MacRemoteWindowResizeContextResolution {
    case available(MacRemoteWindowResizeContext)
    case rejected(
        MacRemoteInputRejection,
        diagnostic: MacRemoteInputScreenFormatDiagnostic?
    )
}

typealias MacRemoteWindowResizeCorner = FocusedWindowResizeCorner

/// Pure opposite-corner resize calculations shared by the AX transaction and deterministic tests.
enum MacRemoteWindowResizeGeometry {
    static func proposedFrame(
        original: CGRect,
        start: CGPoint,
        end: CGPoint,
        displayBounds: CGRect
    ) -> (corner: MacRemoteWindowResizeCorner, frame: CGRect)? {
        guard let minimumSize = FocusedWindowResizeGeometry.minimumRetainedSize(
            for: original
        ) else { return nil }
        guard let proposal = FocusedWindowResizeGeometry.proposedFrame(
            original: original,
            start: start,
            end: end,
            bounds: displayBounds,
            minimumSize: minimumSize
        ) else { return nil }
        return (proposal.corner, proposal.frame)
    }

    static func anchoredOrigin(
        for actualSize: CGSize,
        original: CGRect,
        corner: MacRemoteWindowResizeCorner
    ) -> CGPoint? {
        guard actualSize.width.isFinite, actualSize.height.isFinite,
              actualSize.width > 0, actualSize.height > 0 else {
            return nil
        }
        let x: CGFloat = switch corner {
        case .topLeft, .bottomLeft:
            original.maxX - actualSize.width
        case .topRight, .bottomRight:
            original.minX
        }
        let y: CGFloat = switch corner {
        case .topLeft, .topRight:
            original.maxY - actualSize.height
        case .bottomLeft, .bottomRight:
            original.minY
        }
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    static func preservesOppositeCorner(
        _ frame: CGRect,
        from original: CGRect,
        corner: MacRemoteWindowResizeCorner,
        tolerance: CGFloat = 1
    ) -> Bool {
        switch corner {
        case .topLeft:
            abs(frame.maxX - original.maxX) <= tolerance
                && abs(frame.maxY - original.maxY) <= tolerance
        case .topRight:
            abs(frame.minX - original.minX) <= tolerance
                && abs(frame.maxY - original.maxY) <= tolerance
        case .bottomLeft:
            abs(frame.maxX - original.maxX) <= tolerance
                && abs(frame.minY - original.minY) <= tolerance
        case .bottomRight:
            abs(frame.minX - original.minX) <= tolerance
                && abs(frame.minY - original.minY) <= tolerance
        }
    }

    static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    static func approximatelyEqual(
        _ lhs: CGPoint,
        _ rhs: CGPoint,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance
    }

    static func isFinitePositiveRect(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    static func contains(
        _ rect: CGRect,
        in bounds: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        rect.minX >= bounds.minX - tolerance
            && rect.minY >= bounds.minY - tolerance
            && rect.maxX <= bounds.maxX + tolerance
            && rect.maxY <= bounds.maxY + tolerance
    }

    private static func contains(
        _ point: CGPoint,
        in frame: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        point.x >= frame.minX - tolerance
            && point.x <= frame.maxX + tolerance
            && point.y >= frame.minY - tolerance
            && point.y <= frame.maxY + tolerance
    }
}

/// Validated accessibility element that may receive keyboard input.
private struct EditableElement {
    let element: MacRemoteAccessibilityElement
}

/// Maps iPhone-relative coordinates into the selected Core Graphics display bounds.
enum MacRemoteInputCoordinateMapper {
    /// Converts a validated normalized point while keeping exact `1.0` inside the display.
    static func globalPoint(_ point: MacRemoteNormalizedPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(bounds.maxX.nextDown, bounds.minX + (bounds.width * point.x)),
            y: min(bounds.maxY.nextDown, bounds.minY + (bounds.height * point.y))
        )
    }
}

/// Produces a short, deterministic interpolation path for atomic primary-button drags.
enum MacRemoteInputDragPath {
    static let draggedEventCount = 6

    /// Returns intermediate points including the requested end coordinate.
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

/// Monotonic token bucket used to bound pointer, scroll, key, and text injection rates.
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

    /// Refills for elapsed uptime and atomically charges `cost` when capacity allows.
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

/// Injectable monotonic time and bounded sleeping used by focus polling and rate limits.
protocol MacRemoteInputClock: Sendable {
    func now() -> TimeInterval
    func sleep(for interval: TimeInterval)
}

/// Production clock based on system uptime, which is unaffected by wall-clock changes.
private struct SystemMacRemoteInputClock: MacRemoteInputClock {
    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func sleep(for interval: TimeInterval) {
        guard interval > 0 else { return }
        Thread.sleep(forTimeInterval: interval)
    }
}

/// Sendable identity wrapper around an immutable Accessibility object reference.
final class MacRemoteAccessibilityElement: @unchecked Sendable {
    fileprivate let rawValue: AnyObject

    init(rawValue: AnyObject) {
        self.rawValue = rawValue
    }
}

/// Narrow system boundary for permission, AX inspection, and synthetic event posting.
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
    func focusedWindow() -> MacRemoteAccessibilityElement?
    func isWindowPositionSettable(_ window: MacRemoteAccessibilityElement) -> Bool
    func isWindowSizeSettable(_ window: MacRemoteAccessibilityElement) -> Bool
    func windowFrame(_ window: MacRemoteAccessibilityElement) -> CGRect?
    func isWindowMinimized(_ window: MacRemoteAccessibilityElement) -> Bool?
    func isWindowFullScreen(_ window: MacRemoteAccessibilityElement) -> Bool?
    func isWindowModal(_ window: MacRemoteAccessibilityElement) -> Bool?
    func focusWindow(_ window: MacRemoteAccessibilityElement) -> Bool
    func setWindowSize(_ size: CGSize, for window: MacRemoteAccessibilityElement) -> Bool
    func setWindowPosition(_ position: CGPoint, for window: MacRemoteAccessibilityElement) -> Bool
    func elementsEqual(
        _ lhs: MacRemoteAccessibilityElement,
        _ rhs: MacRemoteAccessibilityElement
    ) -> Bool

    func postMouseClick(at point: CGPoint) -> Bool
    func postPrimaryDrag(from start: CGPoint, to end: CGPoint) -> Bool
    func postScroll(at point: CGPoint, deltaX: Int32, deltaY: Int32) -> Bool
    func postUnicodeText(_ text: String) -> Bool
    func postKey(_ key: MacRemoteInputKey) -> Bool
}

/// Production implementation backed by Accessibility and Core Graphics event APIs.
private struct CoreGraphicsMacRemoteInputSystem: MacRemoteInputSystem {
    /// Checks or requests only the permissions required by the implemented operations.
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

    func focusedWindow() -> MacRemoteAccessibilityElement? {
        let systemWide = MacRemoteAccessibilityElement(rawValue: AXUIElementCreateSystemWide())
        guard let application = copyElementAttribute(
            kAXFocusedApplicationAttribute as CFString,
            from: systemWide
        ) else {
            return nil
        }
        return copyElementAttribute(kAXFocusedWindowAttribute as CFString, from: application)
    }

    func isWindowPositionSettable(_ window: MacRemoteAccessibilityElement) -> Bool {
        isAttributeSettable(kAXPositionAttribute as CFString, on: window)
    }

    func isWindowSizeSettable(_ window: MacRemoteAccessibilityElement) -> Bool {
        isAttributeSettable(kAXSizeAttribute as CFString, on: window)
    }

    func windowFrame(_ window: MacRemoteAccessibilityElement) -> CGRect? {
        guard let position = copyPointAttribute(kAXPositionAttribute as CFString, from: window),
              let size = copySizeAttribute(kAXSizeAttribute as CFString, from: window),
              size.width > 0, size.height > 0 else {
            return nil
        }
        let frame = CGRect(origin: position, size: size)
        return MacRemoteWindowResizeGeometry.isFinitePositiveRect(frame) ? frame : nil
    }

    func isWindowMinimized(_ window: MacRemoteAccessibilityElement) -> Bool? {
        copyBooleanAttribute(kAXMinimizedAttribute as CFString, from: window)
    }

    func isWindowFullScreen(_ window: MacRemoteAccessibilityElement) -> Bool? {
        // `AXFullScreen` is public AX API but is not exported as a Swift SDK constant.
        copyBooleanAttribute("AXFullScreen" as CFString, from: window)
    }

    func isWindowModal(_ window: MacRemoteAccessibilityElement) -> Bool? {
        copyBooleanAttribute(kAXModalAttribute as CFString, from: window)
    }

    func focusWindow(_ window: MacRemoteAccessibilityElement) -> Bool {
        let axWindow = window.rawValue as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(axWindow, &pid) == .success,
              let application = NSRunningApplication(processIdentifier: pid),
              application.activate(options: []) else {
            return false
        }
        guard AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString) == .success else {
            return false
        }
        if isAttributeSettable(kAXMainAttribute as CFString, on: window) {
            guard AXUIElementSetAttributeValue(
                axWindow,
                kAXMainAttribute as CFString,
                kCFBooleanTrue
            ) == .success else {
                return false
            }
        }
        if isAttributeSettable(kAXFocusedAttribute as CFString, on: window) {
            guard AXUIElementSetAttributeValue(
                axWindow,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            ) == .success else {
                return false
            }
        }
        return true
    }

    func setWindowSize(_ size: CGSize, for window: MacRemoteAccessibilityElement) -> Bool {
        var size = size
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              let value = AXValueCreate(.cgSize, &size) else {
            return false
        }
        return AXUIElementSetAttributeValue(
            window.rawValue as! AXUIElement,
            kAXSizeAttribute as CFString,
            value
        ) == .success
    }

    func setWindowPosition(_ position: CGPoint, for window: MacRemoteAccessibilityElement) -> Bool {
        var position = position
        guard position.x.isFinite, position.y.isFinite,
              let value = AXValueCreate(.cgPoint, &position) else {
            return false
        }
        return AXUIElementSetAttributeValue(
            window.rawValue as! AXUIElement,
            kAXPositionAttribute as CFString,
            value
        ) == .success
    }

    func elementsEqual(
        _ lhs: MacRemoteAccessibilityElement,
        _ rhs: MacRemoteAccessibilityElement
    ) -> Bool {
        CFEqual(lhs.rawValue, rhs.rawValue)
    }

    /// Constructs both halves before posting a balanced primary click.
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

    /// Constructs the complete event sequence before posting a balanced drag.
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

    /// Posts one location-targeted smooth scroll without synthesizing mouse-button state.
    func postScroll(at point: CGPoint, deltaX: Int32, deltaY: Int32) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(
                  scrollWheelEvent2Source: source,
                  units: .pixel,
                  wheelCount: 2,
                  wheel1: deltaY,
                  wheel2: deltaX,
                  wheel3: 0
              ) else {
            return false
        }
        event.location = point
        event.flags = []
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Posts prevalidated UTF-16 text as a balanced keyboard event pair.
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

    /// Maps the protocol's allowlisted keys to balanced virtual-key events.
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

    private func isAttributeSettable(
        _ attribute: CFString,
        on element: MacRemoteAccessibilityElement
    ) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element.rawValue as! AXUIElement,
            attribute,
            &settable
        ) == .success else {
            return false
        }
        return settable.boolValue
    }

    private func copyBooleanAttribute(
        _ attribute: CFString,
        from element: MacRemoteAccessibilityElement
    ) -> Bool? {
        (copyAttribute(attribute, from: element) as? NSNumber)?.boolValue
    }

    private func copyPointAttribute(
        _ attribute: CFString,
        from element: MacRemoteAccessibilityElement
    ) -> CGPoint? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point),
              point.x.isFinite, point.y.isFinite else {
            return nil
        }
        return point
    }

    private func copySizeAttribute(
        _ attribute: CFString,
        from element: MacRemoteAccessibilityElement
    ) -> CGSize? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size),
              size.width.isFinite, size.height.isFinite else {
            return nil
        }
        return size
    }

    /// Reads one AX attribute with a bounded messaging timeout to avoid host stalls.
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
