import CoreGraphics

/// Converts a tap in an aspect-fit renderer into the normalized coordinates of its video.
/// Letterbox taps are deliberately rejected instead of being clamped onto a screen edge.
enum AspectFitCoordinateMapper {
    static func visibleVideoRect(
        containerSize: CGSize,
        videoSize: CGSize
    ) -> CGRect? {
        guard containerSize.isFiniteAndPositive,
              videoSize.isFiniteAndPositive else {
            return nil
        }

        let scale = min(
            containerSize.width / videoSize.width,
            containerSize.height / videoSize.height
        )
        guard scale.isFinite, scale > 0 else { return nil }

        let fittedSize = CGSize(
            width: videoSize.width * scale,
            height: videoSize.height * scale
        )
        guard fittedSize.isFiniteAndPositive else { return nil }

        return CGRect(
            x: (containerSize.width - fittedSize.width) / 2,
            y: (containerSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    static func normalizedPoint(
        for location: CGPoint,
        containerSize: CGSize,
        videoSize: CGSize
    ) -> CGPoint? {
        guard location.x.isFinite,
              location.y.isFinite,
              let visibleRect = visibleVideoRect(
                containerSize: containerSize,
                videoSize: videoSize
              ),
              location.x >= visibleRect.minX,
              location.x <= visibleRect.maxX,
              location.y >= visibleRect.minY,
              location.y <= visibleRect.maxY else {
            return nil
        }

        let normalized = CGPoint(
            x: (location.x - visibleRect.minX) / visibleRect.width,
            y: (location.y - visibleRect.minY) / visibleRect.height
        )
        guard normalized.x.isFinite,
              normalized.y.isFinite,
              (0...1).contains(normalized.x),
              (0...1).contains(normalized.y) else {
            return nil
        }
        return normalized
    }

    /// Maps an active drag to the nearest video edge after its origin has already
    /// been accepted inside the visible image.
    static func clampedNormalizedPoint(
        for location: CGPoint,
        containerSize: CGSize,
        videoSize: CGSize
    ) -> CGPoint? {
        guard location.x.isFinite,
              location.y.isFinite,
              let visibleRect = visibleVideoRect(
                containerSize: containerSize,
                videoSize: videoSize
              ) else {
            return nil
        }

        let clampedLocation = CGPoint(
            x: min(max(location.x, visibleRect.minX), visibleRect.maxX),
            y: min(max(location.y, visibleRect.minY), visibleRect.maxY)
        )
        return normalizedPoint(
            for: clampedLocation,
            containerSize: containerSize,
            videoSize: videoSize
        )
    }
}

private extension CGSize {
    var isFiniteAndPositive: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
