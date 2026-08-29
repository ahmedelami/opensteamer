import CoreGraphics
import WebRTCTransport

/// One bounded, integer framebuffer-pixel scroll delta ready for the wire protocol.
struct RemoteScrollPixelDelta: Equatable {
    let x: Int32
    let y: Int32
}

/// Converts incremental movement in viewer points into framebuffer pixels without dropping the
/// fractional part of each callback. UIKit's positive-y direction is intentionally preserved:
/// an upward finger movement remains a negative wheel delta at the Mac injection boundary.
struct RemoteScrollDeltaAccumulator: Equatable {
    private let horizontalScale: Double
    private let verticalScale: Double
    private(set) var pendingPixelDelta = CGSize.zero

    init?(containerSize: CGSize, videoSize: CGSize) {
        guard let visibleRect = AspectFitCoordinateMapper.visibleVideoRect(
            containerSize: containerSize,
            videoSize: videoSize
        ) else {
            return nil
        }

        let horizontalScale = Double(videoSize.width / visibleRect.width)
        let verticalScale = Double(videoSize.height / visibleRect.height)
        guard horizontalScale.isFinite,
              verticalScale.isFinite,
              horizontalScale > 0,
              verticalScale > 0 else {
            return nil
        }

        self.horizontalScale = horizontalScale
        self.verticalScale = verticalScale
    }

    /// Returns false without changing the accumulator when a native callback is non-finite or
    /// would overflow the bounded arithmetic used by a later protocol packet.
    @discardableResult
    mutating func append(viewDelta: CGSize) -> Bool {
        guard viewDelta.width.isFinite,
              viewDelta.height.isFinite else {
            return false
        }

        let nextX = Double(pendingPixelDelta.width)
            + (Double(viewDelta.width) * horizontalScale)
        let nextY = Double(pendingPixelDelta.height)
            + (Double(viewDelta.height) * verticalScale)
        guard nextX.isFinite, nextY.isFinite else { return false }

        pendingPixelDelta = CGSize(width: CGFloat(nextX), height: CGFloat(nextY))
        return true
    }

    /// Removes at most one protocol-sized packet. Ordinary display-cadence flushes retain
    /// subpixel remainders; the terminal flush rounds the final aggregate once.
    mutating func takeNextPacket(finalizing: Bool) -> RemoteScrollPixelDelta? {
        let roundedX = roundedComponent(
            Double(pendingPixelDelta.width),
            finalizing: finalizing
        )
        let roundedY = roundedComponent(
            Double(pendingPixelDelta.height),
            finalizing: finalizing
        )
        let limit = Double(WebRTCInputAction.maximumScrollDeltaMagnitude)
        let emittedX = Int32(min(max(roundedX, -limit), limit))
        let emittedY = Int32(min(max(roundedY, -limit), limit))
        guard emittedX != 0 || emittedY != 0 else { return nil }

        pendingPixelDelta.width -= CGFloat(emittedX)
        pendingPixelDelta.height -= CGFloat(emittedY)
        return RemoteScrollPixelDelta(x: emittedX, y: emittedY)
    }

    func hasPacket(finalizing: Bool) -> Bool {
        roundedComponent(
            Double(pendingPixelDelta.width),
            finalizing: finalizing
        ) != 0 || roundedComponent(
            Double(pendingPixelDelta.height),
            finalizing: finalizing
        ) != 0
    }

    private func roundedComponent(_ value: Double, finalizing: Bool) -> Double {
        finalizing ? value.rounded() : value.rounded(.towardZero)
    }
}
