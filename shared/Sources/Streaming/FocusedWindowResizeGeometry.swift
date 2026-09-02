import CoreGraphics
import Foundation

/// The original-frame corner selected from a drag start. Coordinates use the shared video/UI
/// convention: x grows rightward and y grows downward.
public enum FocusedWindowResizeCorner: CaseIterable, Equatable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

/// A canonical positive frame and the corner whose edge motion produced it.
public struct FocusedWindowResizeProposal: Equatable, Sendable {
    public let corner: FocusedWindowResizeCorner
    public let frame: CGRect

    public init(corner: FocusedWindowResizeCorner, frame: CGRect) {
        self.corner = corner
        self.frame = frame
    }

    public static func == (
        lhs: FocusedWindowResizeProposal,
        rhs: FocusedWindowResizeProposal
    ) -> Bool {
        lhs.corner == rhs.corner
            && lhs.frame.origin.x == rhs.frame.origin.x
            && lhs.frame.origin.y == rhs.frame.origin.y
            && lhs.frame.size.width == rhs.frame.size.width
            && lhs.frame.size.height == rhs.frame.size.height
    }
}

/// Pure resize math shared by viewer preview and authoritative host commit.
///
/// Callers map the original frame and both drag points into the same coordinate space. The drag
/// start selects a corner by the original frame's midlines; exact x/y ties choose right/bottom.
/// The drag delta then moves that original edge while the opposite corner remains fixed. A start
/// inset from the visible edge therefore never makes the window snap to the finger.
public enum FocusedWindowResizeGeometry {
    /// Keeps the preview and host proposal affine-equivalent without exposing display scale.
    /// Each axis may shrink to one quarter of its originally authorized extent; applications
    /// remain free to enforce a larger native minimum during the authoritative AX readback.
    public static let minimumRetainedFraction: CGFloat = 0.25

    public static func minimumRetainedSize(for original: CGRect) -> CGSize? {
        guard isFinitePositiveRect(original) else { return nil }
        return CGSize(
            width: original.width * minimumRetainedFraction,
            height: original.height * minimumRetainedFraction
        )
    }

    public static func corner(
        for start: CGPoint,
        in frame: CGRect,
        containmentTolerance: CGFloat = 0.5
    ) -> FocusedWindowResizeCorner? {
        guard isFinitePositiveRect(frame),
              isFinite(start),
              isValidTolerance(containmentTolerance),
              contains(start, in: frame, tolerance: containmentTolerance) else {
            return nil
        }

        switch (start.x < frame.midX, start.y < frame.midY) {
        case (true, true): return .topLeft
        case (false, true): return .topRight
        case (true, false): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }

    /// Applies the drag delta to the selected original edges, clamps them to `bounds` and
    /// `minimumSize`, and returns a finite positive canonical frame. The minimum on each axis is
    /// capped at the original size so a resize gesture never enlarges an already smaller window.
    public static func proposedFrame(
        original: CGRect,
        start: CGPoint,
        end: CGPoint,
        bounds: CGRect,
        minimumSize: CGSize,
        containmentTolerance: CGFloat = 0.5
    ) -> FocusedWindowResizeProposal? {
        guard let corner = corner(
            for: start,
            in: original,
            containmentTolerance: containmentTolerance
        ),
        isFinite(end),
        isFinitePositiveRect(bounds),
        isFiniteNonnegativeSize(minimumSize),
        contains(original, in: bounds, tolerance: containmentTolerance) else {
            return nil
        }

        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        guard deltaX.isFinite, deltaY.isFinite else { return nil }

        let minimumWidth = min(minimumSize.width, original.width)
        let minimumHeight = min(minimumSize.height, original.height)

        let minX: CGFloat
        let maxX: CGFloat
        switch corner {
        case .topLeft, .bottomLeft:
            minX = min(
                original.maxX - minimumWidth,
                max(bounds.minX, original.minX + deltaX)
            )
            maxX = original.maxX
        case .topRight, .bottomRight:
            minX = original.minX
            maxX = max(
                original.minX + minimumWidth,
                min(bounds.maxX, original.maxX + deltaX)
            )
        }

        let minY: CGFloat
        let maxY: CGFloat
        switch corner {
        case .topLeft, .topRight:
            minY = min(
                original.maxY - minimumHeight,
                max(bounds.minY, original.minY + deltaY)
            )
            maxY = original.maxY
        case .bottomLeft, .bottomRight:
            minY = original.minY
            maxY = max(
                original.minY + minimumHeight,
                min(bounds.maxY, original.maxY + deltaY)
            )
        }

        let frame = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        guard isFinitePositiveRect(frame),
              frame == frame.standardized,
              contains(frame, in: bounds, tolerance: containmentTolerance) else {
            return nil
        }
        return FocusedWindowResizeProposal(corner: corner, frame: frame)
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func isFiniteNonnegativeSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
            && size.width >= 0 && size.height >= 0
    }

    private static func isFinitePositiveRect(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    private static func isValidTolerance(_ tolerance: CGFloat) -> Bool {
        tolerance.isFinite && tolerance >= 0
    }

    private static func contains(
        _ point: CGPoint,
        in rect: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        point.x >= rect.minX - tolerance
            && point.y >= rect.minY - tolerance
            && point.x <= rect.maxX + tolerance
            && point.y <= rect.maxY + tolerance
    }

    private static func contains(
        _ rect: CGRect,
        in bounds: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        rect.minX >= bounds.minX - tolerance
            && rect.minY >= bounds.minY - tolerance
            && rect.maxX <= bounds.maxX + tolerance
            && rect.maxY <= bounds.maxY + tolerance
    }
}
