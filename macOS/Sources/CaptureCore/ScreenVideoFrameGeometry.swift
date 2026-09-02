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

    /// Converts a global logical AX window rectangle into the encoded frame's unit square.
    /// The content rectangle is measured in capture-surface pixels, while `displayBounds` and the
    /// AX rectangle are logical global points; this is the single intentional conversion boundary.
    public func frameNormalizedRect(
        forGlobalRect globalRect: CGRect,
        in displayBounds: CGRect
    ) -> CGRect? {
        guard Self.isFinitePositiveRect(globalRect),
              Self.isFinitePositiveRect(displayBounds),
              Self.contains(globalRect, in: displayBounds, tolerance: 0.5) else {
            return nil
        }

        let contentNormalizedRect = CGRect(
            x: (globalRect.minX - displayBounds.minX) / displayBounds.width,
            y: (globalRect.minY - displayBounds.minY) / displayBounds.height,
            width: globalRect.width / displayBounds.width,
            height: globalRect.height / displayBounds.height
        )
        let surfaceRect = CGRect(
            x: contentRect.minX + (contentNormalizedRect.minX * contentRect.width),
            y: contentRect.minY + (contentNormalizedRect.minY * contentRect.height),
            width: contentNormalizedRect.width * contentRect.width,
            height: contentNormalizedRect.height * contentRect.height
        )
        return Self.boundedUnitRect(
            CGRect(
                x: surfaceRect.minX / CGFloat(surfaceWidth),
                y: surfaceRect.minY / CGFloat(surfaceHeight),
                width: surfaceRect.width / CGFloat(surfaceWidth),
                height: surfaceRect.height / CGFloat(surfaceHeight)
            )
        )
    }

    /// Converts an encoded-frame normalized rectangle back into global logical AX coordinates.
    /// Rectangles touching ScreenCaptureKit letterbox pixels are rejected rather than projected.
    public func globalRect(
        forFrameNormalizedRect frameNormalizedRect: CGRect,
        in displayBounds: CGRect
    ) -> CGRect? {
        guard let frameNormalizedRect = Self.boundedUnitRect(frameNormalizedRect),
              Self.isFinitePositiveRect(displayBounds) else {
            return nil
        }
        let surfaceRect = CGRect(
            x: frameNormalizedRect.minX * CGFloat(surfaceWidth),
            y: frameNormalizedRect.minY * CGFloat(surfaceHeight),
            width: frameNormalizedRect.width * CGFloat(surfaceWidth),
            height: frameNormalizedRect.height * CGFloat(surfaceHeight)
        )
        guard Self.contains(surfaceRect, in: contentRect, tolerance: 0.5) else {
            return nil
        }
        let contentNormalizedRect = CGRect(
            x: (surfaceRect.minX - contentRect.minX) / contentRect.width,
            y: (surfaceRect.minY - contentRect.minY) / contentRect.height,
            width: surfaceRect.width / contentRect.width,
            height: surfaceRect.height / contentRect.height
        )
        let globalRect = CGRect(
            x: displayBounds.minX + (contentNormalizedRect.minX * displayBounds.width),
            y: displayBounds.minY + (contentNormalizedRect.minY * displayBounds.height),
            width: contentNormalizedRect.width * displayBounds.width,
            height: contentNormalizedRect.height * displayBounds.height
        )
        guard Self.isFinitePositiveRect(globalRect),
              Self.contains(globalRect, in: displayBounds, tolerance: 0.5) else {
            return nil
        }
        return globalRect
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

    private static func boundedUnitRect(_ rect: CGRect) -> CGRect? {
        guard isFinitePositiveRect(rect) else { return nil }
        let tolerance: CGFloat = 1e-9
        guard rect.minX >= -tolerance,
              rect.minY >= -tolerance,
              rect.maxX <= 1 + tolerance,
              rect.maxY <= 1 + tolerance else {
            return nil
        }
        let minX = min(1, max(0, rect.minX))
        let minY = min(1, max(0, rect.minY))
        let maxX = min(1, max(0, rect.maxX))
        let maxY = min(1, max(0, rect.maxY))
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func isFinitePositiveRect(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    private static func contains(
        _ inner: CGRect,
        in outer: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        inner.minX >= outer.minX - tolerance
            && inner.minY >= outer.minY - tolerance
            && inner.maxX <= outer.maxX + tolerance
            && inner.maxY <= outer.maxY + tolerance
    }
}

/// Distinguishes trustworthy geometry, benign attachment absence, and contradictory metadata.
///
/// ScreenCaptureKit's geometry attachments are optional. A settled frame that omits them supplies
/// no new evidence and may preserve an already-proven transform; a present but malformed value is
/// unsafe evidence and must instead enter bounded fail-closed recovery.
public enum ScreenVideoFrameGeometryObservation: Equatable, Sendable {
    case valid(ScreenVideoFrameGeometry)
    case absent
    case invalid

    public var geometry: ScreenVideoFrameGeometry? {
        guard case .valid(let geometry) = self else { return nil }
        return geometry
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
        _ observation: ScreenVideoFrameGeometryObservation
    ) -> Action {
        guard !requestIssued else { return .dropFrame }
        switch observation {
        case .absent:
            // A missing attachment after a changed frame cannot prove that the old capture
            // format became valid again. Keep the candidate count and withhold the uncertain
            // frame until a concrete full-frame geometry clears it or renegotiation completes.
            return consecutiveChangedFrames > 0 ? .dropFrame : .forwardFrame

        case .invalid:
            // Present-but-invalid metadata is contradictory evidence, not ordinary absence.
            // Withhold it immediately and use the same bounded frame/deadline recovery as a
            // concrete changed format so an invalid stream cannot silently run forever.
            consecutiveChangedFrames += 1
            guard consecutiveChangedFrames >= Self.requiredConsecutiveChangedFrames else {
                return .dropFrame
            }
            requestIssued = true
            return .renegotiate

        case .valid(let geometry):
            return observeValidGeometry(geometry)
        }
    }

    /// Compatibility entry point for consumers that do not distinguish absent from invalid.
    public mutating func observe(
        _ geometry: ScreenVideoFrameGeometry?
    ) -> Action {
        observe(geometry.map(ScreenVideoFrameGeometryObservation.valid) ?? .absent)
    }

    private mutating func observeValidGeometry(
        _ geometry: ScreenVideoFrameGeometry
    ) -> Action {
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
