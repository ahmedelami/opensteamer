import CoreGraphics
import Foundation

/// Per-frame ScreenCaptureKit geometry needed to map viewer input onto captured content.
///
/// ScreenCaptureKit reports `contentRect` in points within the output surface and `scaleFactor`
/// as its point-to-pixel conversion. This type normalizes that rectangle into surface pixels. It
/// can be smaller than the surface after a display mode changes while an existing stream keeps
/// its startup canvas. Keeping that inset makes remote input relative to the pixels the viewer
/// actually sees rather than to an obsolete fixed output size.
public struct ScreenVideoFrameGeometry: Equatable, Sendable {
    public let surfaceWidth: Int
    public let surfaceHeight: Int
    public let contentRect: CGRect
    public let contentScale: CGFloat
    public let scaleFactor: CGFloat

    /// Whether ScreenCaptureKit is fitting the current display inside an obsolete output surface.
    /// A half-pixel difference at any surface edge is treated as framework rounding, not an inset.
    public var requiresCaptureFormatRenegotiation: Bool {
        let edgeTolerance: CGFloat = 0.5
        return abs(contentRect.minX) > edgeTolerance
            || abs(contentRect.minY) > edgeTolerance
            || abs(CGFloat(surfaceWidth) - contentRect.maxX) > edgeTolerance
            || abs(CGFloat(surfaceHeight) - contentRect.maxY) > edgeTolerance
    }

    public init?(
        surfaceWidth: Int,
        surfaceHeight: Int,
        contentRect: CGRect,
        contentScale: CGFloat,
        scaleFactor: CGFloat
    ) {
        guard surfaceWidth >= 2,
              surfaceHeight >= 2,
              contentRect.origin.x.isFinite,
              contentRect.origin.y.isFinite,
              contentRect.width.isFinite,
              contentRect.height.isFinite,
              contentRect.width > 0,
              contentRect.height > 0,
              contentScale.isFinite,
              contentScale > 0,
              scaleFactor.isFinite,
              (1 ... 4).contains(scaleFactor) else {
            return nil
        }

        let contentRectInPixels = CGRect(
            x: contentRect.origin.x * scaleFactor,
            y: contentRect.origin.y * scaleFactor,
            width: contentRect.width * scaleFactor,
            height: contentRect.height * scaleFactor
        )
        guard contentRectInPixels.origin.x.isFinite,
              contentRectInPixels.origin.y.isFinite,
              contentRectInPixels.width.isFinite,
              contentRectInPixels.height.isFinite else {
            return nil
        }

        let surfaceBounds = CGRect(
            x: 0,
            y: 0,
            width: surfaceWidth,
            height: surfaceHeight
        )
        // ScreenCaptureKit can report fractional edges. Permit at most half a surface pixel of
        // rounding, then retain only the real surface intersection.
        let edgeTolerance: CGFloat = 0.5
        guard contentRectInPixels.minX >= surfaceBounds.minX - edgeTolerance,
              contentRectInPixels.minY >= surfaceBounds.minY - edgeTolerance,
              contentRectInPixels.maxX <= surfaceBounds.maxX + edgeTolerance,
              contentRectInPixels.maxY <= surfaceBounds.maxY + edgeTolerance else {
            return nil
        }
        let boundedContentRect = contentRectInPixels.intersection(surfaceBounds)
        guard !boundedContentRect.isNull,
              boundedContentRect.width > 0,
              boundedContentRect.height > 0 else {
            return nil
        }

        self.surfaceWidth = surfaceWidth
        self.surfaceHeight = surfaceHeight
        self.contentRect = boundedContentRect
        self.contentScale = contentScale
        self.scaleFactor = scaleFactor
    }

    /// Whether two frames use the same input transform, allowing subpixel metadata jitter.
    func hasSameInputTransform(as other: ScreenVideoFrameGeometry) -> Bool {
        guard surfaceWidth == other.surfaceWidth,
              surfaceHeight == other.surfaceHeight else {
            return false
        }
        let tolerance: CGFloat = 0.5
        return abs(contentRect.minX - other.contentRect.minX) <= tolerance
            && abs(contentRect.minY - other.contentRect.minY) <= tolerance
            && abs(contentRect.width - other.contentRect.width) <= tolerance
            && abs(contentRect.height - other.contentRect.height) <= tolerance
    }

    /// Converts a point normalized over the encoded frame into the captured content's unit
    /// square. Taps in ScreenCaptureKit's internal letterbox or pillarbox are rejected.
    func contentNormalizedPoint(for frameNormalizedPoint: CGPoint) -> CGPoint? {
        map(frameNormalizedPoint, clampingToContent: false)
    }

    /// Converts an already-active drag endpoint, clamping it to the nearest captured edge.
    func clampedContentNormalizedPoint(for frameNormalizedPoint: CGPoint) -> CGPoint? {
        map(frameNormalizedPoint, clampingToContent: true)
    }

    /// Proves that this frame's captured content still describes the live display bounds.
    func hasCompatibleAspectRatio(with displayBounds: CGRect) -> Bool {
        guard displayBounds.width.isFinite,
              displayBounds.height.isFinite,
              displayBounds.width > 0,
              displayBounds.height > 0 else {
            return false
        }
        let contentAspect = contentRect.width / contentRect.height
        let displayAspect = displayBounds.width / displayBounds.height
        let relativeError = abs(contentAspect - displayAspect) / displayAspect
        // One-pixel rounding in an inset content rect is expected; a stale cross-aspect frame is
        // far outside this half-percent boundary and therefore fails closed during transitions.
        return relativeError <= 0.005
    }

    private func map(
        _ frameNormalizedPoint: CGPoint,
        clampingToContent: Bool
    ) -> CGPoint? {
        guard frameNormalizedPoint.x.isFinite,
              frameNormalizedPoint.y.isFinite,
              (0 ... 1).contains(frameNormalizedPoint.x),
              (0 ... 1).contains(frameNormalizedPoint.y) else {
            return nil
        }

        var surfacePoint = CGPoint(
            x: CGFloat(surfaceWidth) * frameNormalizedPoint.x,
            y: CGFloat(surfaceHeight) * frameNormalizedPoint.y
        )
        if clampingToContent {
            surfacePoint.x = min(max(surfacePoint.x, contentRect.minX), contentRect.maxX)
            surfacePoint.y = min(max(surfacePoint.y, contentRect.minY), contentRect.maxY)
        } else {
            guard surfacePoint.x >= contentRect.minX,
                  surfacePoint.x <= contentRect.maxX,
                  surfacePoint.y >= contentRect.minY,
                  surfacePoint.y <= contentRect.maxY else {
                return nil
            }
        }

        let normalized = CGPoint(
            x: (surfacePoint.x - contentRect.minX) / contentRect.width,
            y: (surfacePoint.y - contentRect.minY) / contentRect.height
        )
        guard normalized.x.isFinite,
              normalized.y.isFinite,
              (0 ... 1).contains(normalized.x),
              (0 ... 1).contains(normalized.y) else {
            return nil
        }
        return normalized
    }
}

/// Debounces ScreenCaptureKit's per-frame geometry before a service rebuilds its native stream.
/// Changed frames are withheld immediately, but one transient metadata sample cannot churn capture.
public struct ScreenVideoFormatRenegotiationDetector: Sendable {
    public enum Action: Equatable, Sendable {
        case forwardFrame
        case dropFrame
        case renegotiate
    }

    public static let requiredConsecutiveChangedFrames = 3
    public static let fallbackDelay: TimeInterval = 0.5

    private var consecutiveChangedFrames = 0
    private var requestIssued = false
    private var baselineGeometry: ScreenVideoFrameGeometry?

    public init() {}

    public mutating func observe(
        _ geometry: ScreenVideoFrameGeometry?
    ) -> Action {
        guard !requestIssued else { return .dropFrame }
        guard let geometry else {
            // A missing attachment after a changed frame cannot prove that the old capture
            // format became valid again. Keep the candidate count and withhold the uncertain
            // frame until a concrete full-frame geometry clears it or renegotiation completes.
            return consecutiveChangedFrames > 0 ? .dropFrame : .forwardFrame
        }

        if baselineGeometry == nil,
           !geometry.requiresCaptureFormatRenegotiation {
            baselineGeometry = geometry
            consecutiveChangedFrames = 0
            return .forwardFrame
        }

        let formatChanged = geometry.requiresCaptureFormatRenegotiation
            || baselineGeometry.map { !geometry.hasSameCaptureFormat(as: $0) } == true
        guard formatChanged else {
            consecutiveChangedFrames = 0
            return .forwardFrame
        }

        consecutiveChangedFrames += 1
        guard consecutiveChangedFrames >= Self.requiredConsecutiveChangedFrames else {
            return .dropFrame
        }
        requestIssued = true
        return .renegotiate
    }

    /// True while changed geometry is withholding frames but has not yet reached the
    /// consecutive-frame threshold. A caller can use this to arm a wall-clock fallback for
    /// streams that become idle before ScreenCaptureKit supplies another complete frame.
    public var hasPendingFormatChange: Bool {
        consecutiveChangedFrames > 0 && !requestIssued
    }

    /// Latches the same one-shot renegotiation request as the frame-count threshold once a
    /// caller-owned fallback deadline expires. Concrete compatible geometry clears the pending
    /// candidate, so a recovered transient cannot be promoted by an obsolete deadline.
    @discardableResult
    public mutating func requestRenegotiationAfterFallbackDeadline() -> Bool {
        guard hasPendingFormatChange else { return false }
        requestIssued = true
        return true
    }

    public mutating func reset() {
        consecutiveChangedFrames = 0
        requestIssued = false
        baselineGeometry = nil
    }
}

private extension ScreenVideoFrameGeometry {
    /// Surface dimensions and ScreenCaptureKit scale metadata together distinguish a same-aspect
    /// resolution change from harmless subpixel content-rectangle jitter.
    func hasSameCaptureFormat(as other: ScreenVideoFrameGeometry) -> Bool {
        let scaleTolerance: CGFloat = 0.005
        return surfaceWidth == other.surfaceWidth
            && surfaceHeight == other.surfaceHeight
            && abs(contentScale - other.contentScale) <= scaleTolerance
            && abs(scaleFactor - other.scaleFactor) <= scaleTolerance
    }
}
