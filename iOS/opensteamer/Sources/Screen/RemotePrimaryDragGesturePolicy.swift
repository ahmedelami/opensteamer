import CoreGraphics

/// Normalized endpoints for a single primary-button drag on the remote display.
struct RemotePrimaryDragEndpoints: Equatable {
    let start: CGPoint
    let end: CGPoint
}

/// Validates an iPhone drag and translates it into aspect-fit Mac display coordinates.
/// The gesture must start inside visible video, but its end is clamped to the video edge so an
/// already-started remote drag can complete naturally after the finger crosses letterboxing.
enum RemotePrimaryDragGesturePolicy {
    static let minimumMovement: CGFloat = 3

    static func normalizedEndpoints(
        startLocation: CGPoint,
        endLocation: CGPoint,
        containerSize: CGSize,
        videoSize: CGSize
    ) -> RemotePrimaryDragEndpoints? {
        guard startLocation.x.isFinite,
              startLocation.y.isFinite,
              endLocation.x.isFinite,
              endLocation.y.isFinite,
              hypot(
                endLocation.x - startLocation.x,
                endLocation.y - startLocation.y
              ) >= minimumMovement,
              let start = AspectFitCoordinateMapper.normalizedPoint(
                for: startLocation,
                containerSize: containerSize,
                videoSize: videoSize
              ),
              let end = AspectFitCoordinateMapper.clampedNormalizedPoint(
                for: endLocation,
                containerSize: containerSize,
                videoSize: videoSize
              ) else {
            return nil
        }

        return RemotePrimaryDragEndpoints(start: start, end: end)
    }
}
