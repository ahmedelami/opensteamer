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

/// Logical and framebuffer dimensions read from one authoritative display-mode snapshot.
public struct ScreenVideoDisplayModeSnapshot: Equatable, Sendable {
    public let logicalDimensions: ScreenVideoPixelDimensions
    public let pixelDimensions: ScreenVideoPixelDimensions

    public init(
        logicalDimensions: ScreenVideoPixelDimensions,
        pixelDimensions: ScreenVideoPixelDimensions
    ) {
        self.logicalDimensions = logicalDimensions
        self.pixelDimensions = pixelDimensions
    }
}

/// Resolves a display mode without prescribing whether the caller uses its current process or a
/// fresh helper process. The worldwide host uses a fresh process because the virtual-display
/// owner's CoreGraphics connection can retain an older mode after Display Settings changes it.
public typealias ScreenVideoDisplayModeSnapshotProvider =
    @Sendable (UInt32) async throws -> ScreenVideoDisplayModeSnapshot

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

    /// Resolves the requested source framebuffer. Ordinary displays preserve the established
    /// logical-size behavior. OpenSteamer-owned displays use Core Graphics' current framebuffer
    /// pixels after proving that ScreenCaptureKit still identifies the same logical display; the
    /// service separately proves the first delivered surface before publishing this format.
    static func sourceDimensions(
        vendorID: UInt32,
        productID: UInt32,
        logicalDimensions: ScreenVideoPixelDimensions,
        filterContentWidth: Double,
        filterContentHeight: Double,
        pointPixelScale: Double,
        coreGraphicsLogicalDimensions: ScreenVideoPixelDimensions,
        coreGraphicsPixelDimensions: ScreenVideoPixelDimensions
    ) -> ScreenVideoPixelDimensions? {
        guard dimensionKind(vendorID: vendorID, productID: productID) == .framebufferPixels else {
            return logicalDimensions
        }

        guard logicalDimensions.width >= 2,
              logicalDimensions.height >= 2,
              logicalDimensions.width <= 32_768,
              logicalDimensions.height <= 32_768,
              filterContentWidth.isFinite,
              filterContentHeight.isFinite,
              pointPixelScale.isFinite,
              (1 ... 4).contains(pointPixelScale),
              coreGraphicsLogicalDimensions.width >= 2,
              coreGraphicsLogicalDimensions.height >= 2,
              coreGraphicsPixelDimensions.width >= 2,
              coreGraphicsPixelDimensions.height >= 2,
              coreGraphicsPixelDimensions.width <= 32_768,
              coreGraphicsPixelDimensions.height <= 32_768,
              logicalDimensions == coreGraphicsLogicalDimensions,
              abs(filterContentWidth - Double(logicalDimensions.width)) <= 0.5,
              abs(filterContentHeight - Double(logicalDimensions.height)) <= 0.5 else {
            return nil
        }

        return coreGraphicsPixelDimensions
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
