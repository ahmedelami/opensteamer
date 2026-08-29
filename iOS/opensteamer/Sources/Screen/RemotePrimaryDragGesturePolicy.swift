import CoreGraphics

struct RemoteScrollSample: Equatable {
    let anchor: CGPoint
    let deltaX: Double
    let deltaY: Double
}

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

/// Classifies a one-finger remote pointer gesture and converts live movement into bounded,
/// resolution-independent scroll samples. Time arms primary drag; movement owns scrolling.
enum RemotePointerGesturePolicy {
    static let movementThreshold: CGFloat = 12
    static let holdDuration: Duration = .milliseconds(350)
    static let maximumNormalizedDelta = 1.0

    static func exceededMovementThreshold(
        from startLocation: CGPoint,
        to location: CGPoint
    ) -> Bool {
        guard startLocation.x.isFinite,
              startLocation.y.isFinite,
              location.x.isFinite,
              location.y.isFinite else {
            return false
        }
        return hypot(
            location.x - startLocation.x,
            location.y - startLocation.y
        ) >= movementThreshold
    }

    static func normalizedScrollSample(
        anchorLocation: CGPoint,
        previousLocation: CGPoint,
        location: CGPoint,
        containerSize: CGSize,
        videoSize: CGSize
    ) -> RemoteScrollSample? {
        guard let anchor = AspectFitCoordinateMapper.normalizedPoint(
                  for: anchorLocation,
                  containerSize: containerSize,
                  videoSize: videoSize
              ),
              let visibleRect = AspectFitCoordinateMapper.visibleVideoRect(
                  containerSize: containerSize,
                  videoSize: videoSize
              ),
              previousLocation.x.isFinite,
              previousLocation.y.isFinite,
              location.x.isFinite,
              location.y.isFinite else {
            return nil
        }

        let rawDeltaX = Double((location.x - previousLocation.x) / visibleRect.width)
        let rawDeltaY = Double((location.y - previousLocation.y) / visibleRect.height)
        guard rawDeltaX.isFinite,
              rawDeltaY.isFinite,
              rawDeltaX != 0 || rawDeltaY != 0 else {
            return nil
        }

        return RemoteScrollSample(
            anchor: anchor,
            deltaX: min(max(rawDeltaX, -maximumNormalizedDelta), maximumNormalizedDelta),
            deltaY: min(max(rawDeltaY, -maximumNormalizedDelta), maximumNormalizedDelta)
        )
    }
}
