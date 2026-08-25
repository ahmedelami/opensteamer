import Foundation

/// Source dimensions used to configure ScreenCaptureKit output.
public struct ScreenVideoPixelDimensions: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Immutable identity and topology requirements for a display selected by numeric ID.
///
/// WindowServer may recycle display IDs after a virtual display terminates. Callers that own a
/// display pass this requirement so every capture start proves the ID still names that display.
public struct ScreenVideoDisplayRequirement: Equatable, Sendable {
    public let vendorID: UInt32
    public let productID: UInt32
    public let serialNumber: UInt32
    public let requiresSoleMainDisplay: Bool

    public init(
        vendorID: UInt32,
        productID: UInt32,
        serialNumber: UInt32,
        requiresSoleMainDisplay: Bool
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.requiresSoleMainDisplay = requiresSoleMainDisplay
    }
}

/// Read-only CoreGraphics facts used to reject a stale or recycled display ID.
struct ScreenVideoDisplaySnapshot: Equatable, Sendable {
    let displayID: UInt32
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32
    let isOnline: Bool
    let isActive: Bool
    let mainDisplayID: UInt32
    let onlineDisplayIDs: [UInt32]
}

enum ScreenVideoDisplayRequirementPolicy {
    static func isSatisfied(
        _ requirement: ScreenVideoDisplayRequirement,
        by snapshot: ScreenVideoDisplaySnapshot
    ) -> Bool {
        guard snapshot.isOnline,
            snapshot.isActive,
            snapshot.vendorID == requirement.vendorID,
            snapshot.productID == requirement.productID,
            snapshot.serialNumber == requirement.serialNumber
        else {
            return false
        }
        guard requirement.requiresSoleMainDisplay else { return true }
        return snapshot.mainDisplayID == snapshot.displayID
            && snapshot.onlineDisplayIDs == [snapshot.displayID]
    }
}

/// Chooses which display dimensions preserve established capture behavior.
enum ScreenVideoSourceDimensionKind: Equatable, Sendable {
    case logical
    case framebufferPixels
}

/// Restricts framebuffer-pixel capture to OpenSteamer-owned virtual displays.
enum ScreenVideoSourceDimensionPolicy {
    private static let openSteamerVendorID: UInt32 = 0x6F73
    private static let openSteamerProductIDs: Set<UInt32> = [0x1717, 0x1718]

    static func dimensionKind(vendorID: UInt32, productID: UInt32) -> ScreenVideoSourceDimensionKind
    {
        guard vendorID == openSteamerVendorID,
            openSteamerProductIDs.contains(productID)
        else {
            return .logical
        }
        return .framebufferPixels
    }

    /// Resolves the source framebuffer from the same ScreenCaptureKit filter snapshot that will
    /// configure the stream. Ordinary displays preserve the established logical-size behavior;
    /// OpenSteamer-owned displays use the filter's documented pixel-to-point scale.
    static func sourceDimensions(
        vendorID: UInt32,
        productID: UInt32,
        logicalDimensions: ScreenVideoPixelDimensions,
        filterContentWidth: Double,
        filterContentHeight: Double,
        pointPixelScale: Double
    ) -> ScreenVideoPixelDimensions? {
        guard dimensionKind(vendorID: vendorID, productID: productID) == .framebufferPixels else {
            return logicalDimensions
        }

        guard logicalDimensions.width >= 2,
              logicalDimensions.height >= 2,
              filterContentWidth.isFinite,
              filterContentHeight.isFinite,
              pointPixelScale.isFinite,
              (1 ... 4).contains(pointPixelScale),
              abs(filterContentWidth - Double(logicalDimensions.width)) <= 0.5,
              abs(filterContentHeight - Double(logicalDimensions.height)) <= 0.5 else {
            return nil
        }

        let pixelWidth = (filterContentWidth * pointPixelScale).rounded()
        let pixelHeight = (filterContentHeight * pointPixelScale).rounded()
        guard pixelWidth.isFinite,
              pixelHeight.isFinite,
              let width = Int(exactly: pixelWidth),
              let height = Int(exactly: pixelHeight),
              width >= 2,
              height >= 2 else {
            return nil
        }
        return ScreenVideoPixelDimensions(width: width, height: height)
    }

    /// A Show transaction may publish its encoder format only if the framebuffer stayed fixed
    /// throughout native SCStream startup.
    static func isStableAcrossStart(
        before: ScreenVideoPixelDimensions,
        after: ScreenVideoPixelDimensions
    ) -> Bool {
        before == after
    }
}

/// Converts selected display dimensions into even, aspect-preserving encoder dimensions.
public enum ScreenVideoOutputPolicy {
    public static func outputDimensions(
        source: ScreenVideoPixelDimensions,
        maximumWidth: Int
    ) throws -> ScreenVideoPixelDimensions {
        guard source.width >= 2, source.height >= 2, maximumWidth >= 2 else {
            throw ScreenVideoOutputPolicyError.invalidDimensions
        }

        let cappedWidth = min(source.width, maximumWidth)
        let width = cappedWidth - cappedWidth % 2
        let scaledHeight = Int(
            (Double(source.height) * Double(width) / Double(source.width)).rounded()
        )
        let height = max(2, scaledHeight - scaledHeight % 2)
        return ScreenVideoPixelDimensions(width: width, height: height)
    }
}

public enum ScreenVideoOutputPolicyError: LocalizedError, Equatable {
    case invalidDimensions

    public var errorDescription: String? {
        "Screen video source and maximum dimensions must be at least two pixels"
    }
}
