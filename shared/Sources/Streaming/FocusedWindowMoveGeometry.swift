import Foundation

/// The gesture's displacement translates the selected window, regardless of where it began.
public enum FocusedWindowMoveGeometry {
    /// The retained top strip keeps the title bar reachable, while the horizontal intersection
    /// leaves enough of that strip visible to grab the window again on any display size.
    public static let minimumVisibleTopBandFraction: CGFloat = 0.03
    public static let minimumVisibleHorizontalGripFraction: CGFloat = 0.05
    public static let maximumWindowSpanInDisplays: CGFloat = 64

    public static func proposedFrame(
        original: CGRect,
        start: CGPoint,
        end: CGPoint,
        displayBounds: CGRect,
        allowsRecoverableOffscreen: Bool = false
    ) -> CGRect? {
        let values = [original.minX, original.minY, original.width, original.height,
                      start.x, start.y, end.x, end.y,
                      displayBounds.minX, displayBounds.minY, displayBounds.width, displayBounds.height]
        guard values.allSatisfy(\.isFinite),
              original.size.width > 0, original.size.height > 0,
              displayBounds.size.width > 0, displayBounds.size.height > 0,
              allowsRecoverableOffscreen
                ? isRecoverable(original, in: displayBounds)
                : isFullyContained(original, in: displayBounds),
              start.x >= displayBounds.minX, start.x <= displayBounds.maxX,
              start.y >= displayBounds.minY, start.y <= displayBounds.maxY else { return nil }
        let x = original.minX + end.x - start.x
        let y = original.minY + end.y - start.y
        guard x.isFinite, y.isFinite else { return nil }
        let limits = allowsRecoverableOffscreen
            ? recoverableOriginLimits(for: original.size, in: displayBounds)
            : fullyContainedOriginLimits(for: original.size, in: displayBounds)
        guard let limits else { return nil }
        return CGRect(
            origin: CGPoint(
                x: min(max(x, limits.minX), limits.maxX),
                y: min(max(y, limits.minY), limits.maxY)
            ),
            size: original.size
        )
    }

    public static func isRecoverable(
        _ frame: CGRect,
        in displayBounds: CGRect,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        let values = [frame.minX, frame.minY, frame.width, frame.height,
                      displayBounds.minX, displayBounds.minY,
                      displayBounds.width, displayBounds.height, tolerance]
        guard values.allSatisfy(\.isFinite), frame.width > 0, frame.height > 0,
              displayBounds.width > 0, displayBounds.height > 0,
              frame.width <= displayBounds.width * maximumWindowSpanInDisplays,
              frame.height <= displayBounds.height * maximumWindowSpanInDisplays,
              tolerance >= 0,
              let limits = recoverableOriginLimits(for: frame.size, in: displayBounds) else {
            return false
        }
        return frame.minX >= limits.minX - tolerance
            && frame.minX <= limits.maxX + tolerance
            && frame.minY >= limits.minY - tolerance
            && frame.minY <= limits.maxY + tolerance
    }

    private static func isFullyContained(_ frame: CGRect, in bounds: CGRect) -> Bool {
        guard fullyContainedOriginLimits(for: frame.size, in: bounds) != nil else { return false }
        return frame.minX >= bounds.minX && frame.minY >= bounds.minY
            && frame.maxX <= bounds.maxX && frame.maxY <= bounds.maxY
    }

    private static func fullyContainedOriginLimits(
        for size: CGSize,
        in bounds: CGRect
    ) -> (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat)? {
        guard size.width <= bounds.width, size.height <= bounds.height else { return nil }
        return (bounds.minX, bounds.maxX - size.width, bounds.minY, bounds.maxY - size.height)
    }

    private static func recoverableOriginLimits(
        for size: CGSize,
        in bounds: CGRect
    ) -> (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat)? {
        let gripWidth = min(size.width, bounds.width * minimumVisibleHorizontalGripFraction)
        let topBandHeight = min(size.height, bounds.height * minimumVisibleTopBandFraction)
        guard gripWidth.isFinite, topBandHeight.isFinite,
              gripWidth > 0, topBandHeight > 0 else { return nil }
        return (
            bounds.minX - size.width + gripWidth,
            bounds.maxX - gripWidth,
            bounds.minY,
            bounds.maxY - topBandHeight
        )
    }
}
