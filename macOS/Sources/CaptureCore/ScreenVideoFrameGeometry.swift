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
