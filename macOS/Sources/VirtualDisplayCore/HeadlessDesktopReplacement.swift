import CoreGraphics
import Foundation

struct RestoredDesktopSnapshot: Equatable, Sendable {
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32
    let logicalWidth: UInt32
    let logicalHeight: UInt32
    let pixelWidth: UInt32
    let pixelHeight: UInt32
    let isMain: Bool
    let isActive: Bool
}

/// The exact display identity and desktop mapping a fresh verifier must observe after teardown.
public struct RestoredDesktopExpectation: Equatable, Sendable {
    public let retiredVendorID: UInt32
    public let retiredProductID: UInt32
    public let retiredSerialNumber: UInt32
    public let logicalWidth: UInt32
    public let logicalHeight: UInt32
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32

    public init?(
        retiredVendorID: UInt32,
        retiredProductID: UInt32,
        retiredSerialNumber: UInt32,
        logicalWidth: UInt32,
        logicalHeight: UInt32,
        pixelWidth: UInt32,
        pixelHeight: UInt32
    ) {
        guard retiredVendorID > 0, retiredProductID > 0, retiredSerialNumber > 0,
            logicalWidth > 0, logicalHeight > 0, pixelWidth > 0, pixelHeight > 0
        else {
            return nil
        }
        self.retiredVendorID = retiredVendorID
        self.retiredProductID = retiredProductID
        self.retiredSerialNumber = retiredSerialNumber
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public init(afterRetiring configuration: VirtualDisplayConfiguration) {
        let expected = configuration.requiredResolvedModes[0]
        retiredVendorID = configuration.vendorID
        retiredProductID = configuration.productID
        retiredSerialNumber = configuration.serialNumber
        logicalWidth = expected.logicalWidth
        logicalHeight = expected.logicalHeight
        pixelWidth = expected.pixelWidth
        pixelHeight = expected.pixelHeight
    }
}

enum RestoredDesktopPolicy {
    private static let openSteamerVendorID: UInt32 = 0x6F73
    private static let openSteamerProductIDs: Set<UInt32> = [0x1717, 0x1718]

    static func accepts(
        _ displays: [RestoredDesktopSnapshot],
        expectation: RestoredDesktopExpectation,
        appleHeadlessVendorID: UInt32,
        appleHeadlessProductID: UInt32
    ) -> Bool {
        guard !displays.isEmpty,
            displays.filter(\.isMain).count == 1,
            let main = displays.first(where: \.isMain),
            main.isActive,
            !displays.contains(where: {
                $0.vendorID == expectation.retiredVendorID
                    && $0.productID == expectation.retiredProductID
                    && $0.serialNumber == expectation.retiredSerialNumber
            }),
            !displays.contains(where: {
                $0.vendorID == openSteamerVendorID
                    && openSteamerProductIDs.contains($0.productID)
            })
        else {
            return false
        }

        guard main.vendorID == appleHeadlessVendorID,
            main.productID == appleHeadlessProductID
        else {
            // A physical display may be connected during the session. Its active main desktop is
            // safe once the retired OpenSteamer identity is absent, even though the placeholder
            // will legitimately remain suppressed.
            return true
        }
        guard displays.count == 1 else {
            return false
        }
        return main.logicalWidth == expectation.logicalWidth
            && main.logicalHeight == expectation.logicalHeight
            && main.pixelWidth == expectation.pixelWidth
            && main.pixelHeight == expectation.pixelHeight
    }

    static func accepts(
        _ displays: [RestoredDesktopSnapshot],
        retiredConfiguration: VirtualDisplayConfiguration,
        appleHeadlessVendorID: UInt32,
        appleHeadlessProductID: UInt32
    ) -> Bool {
        accepts(
            displays,
            expectation: .init(afterRetiring: retiredConfiguration),
            appleHeadlessVendorID: appleHeadlessVendorID,
            appleHeadlessProductID: appleHeadlessProductID
        )
    }
}

public enum HeadlessDesktopReplacement {
    static let appleHeadlessVendorID: UInt32 = 0x756E_6B6E  // "unkn"
    static let appleHeadlessProductID: UInt32 = 0x7669_7274  // "virt"

    /// Proves WindowServer has restored the sole Apple headless placeholder after the owned
    /// virtual display retires. Identity, online/active state, and main-display topology must all
    /// agree before another host process may acquire the exclusive runtime lock.
    static func restorationIsConfirmed(
        afterRetiring configuration: VirtualDisplayConfiguration
    ) -> Bool {
        restorationIsConfirmed(
            expectation: .init(afterRetiring: configuration)
        )
    }

    static func restorationIsConfirmed(
        expectation: RestoredDesktopExpectation
    ) -> Bool {
        var onlineDisplays = [CGDirectDisplayID](
            repeating: kCGNullDirectDisplay,
            count: 16
        )
        var onlineDisplayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(
            UInt32(onlineDisplays.count),
            &onlineDisplays,
            &onlineDisplayCount
        ) == .success,
            onlineDisplayCount > 0,
            onlineDisplayCount < UInt32(onlineDisplays.count)
        else {
            return false
        }
        let mainDisplayID = CGMainDisplayID()
        let snapshots = onlineDisplays.prefix(Int(onlineDisplayCount)).compactMap {
            displayID -> RestoredDesktopSnapshot? in
            guard displayID != kCGNullDirectDisplay,
                CGDisplayIsOnline(displayID) == 1
            else {
                return nil
            }
            let bounds = CGDisplayBounds(displayID)
            guard let logicalWidth = UInt32(exactly: bounds.width),
                let logicalHeight = UInt32(exactly: bounds.height),
                let pixelWidth = UInt32(exactly: CGDisplayPixelsWide(displayID)),
                let pixelHeight = UInt32(exactly: CGDisplayPixelsHigh(displayID))
            else {
                return nil
            }
            return RestoredDesktopSnapshot(
                vendorID: CGDisplayVendorNumber(displayID),
                productID: CGDisplayModelNumber(displayID),
                serialNumber: CGDisplaySerialNumber(displayID),
                logicalWidth: logicalWidth,
                logicalHeight: logicalHeight,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                isMain: displayID == mainDisplayID,
                isActive: CGDisplayIsActive(displayID) == 1
            )
        }
        guard snapshots.count == Int(onlineDisplayCount) else { return false }
        return RestoredDesktopPolicy.accepts(
            snapshots,
            expectation: expectation,
            appleHeadlessVendorID: appleHeadlessVendorID,
            appleHeadlessProductID: appleHeadlessProductID
        )
    }

    /// Bounded synchronous polling matches the private runtime's offline proof and keeps close()
    /// usable from process teardown without introducing an unstructured asynchronous owner.
    public static func waitUntilRestored(
        afterRetiring configuration: VirtualDisplayConfiguration
    ) -> Bool {
        waitUntilRestored(
            maximumAttempts: 60,
            isRestored: {
                restorationIsConfirmed(afterRetiring: configuration)
            },
            sleeper: { Thread.sleep(forTimeInterval: 0.05) }
        )
    }

    /// Uses a fresh process's CoreGraphics connection to prove the restored desktop. The longer
    /// bound covers process launch plus WindowServer settlement without weakening the predicate.
    public static func waitUntilRestored(
        expectation: RestoredDesktopExpectation
    ) -> Bool {
        waitUntilRestored(
            maximumAttempts: 200,
            isRestored: {
                restorationIsConfirmed(expectation: expectation)
            },
            sleeper: { Thread.sleep(forTimeInterval: 0.05) }
        )
    }

    static func waitUntilRestored(
        maximumAttempts: Int,
        isRestored: () -> Bool,
        sleeper: () -> Void
    ) -> Bool {
        guard maximumAttempts > 0 else { return false }
        for attempt in 0..<maximumAttempts {
            if isRestored() { return true }
            if attempt + 1 < maximumAttempts {
                sleeper()
            }
        }
        return false
    }

    public static func configurationIfNeeded(
        displayID: CGDirectDisplayID = CGMainDisplayID()
    ) throws -> VirtualDisplayConfiguration? {
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
        var onlineDisplayCount: UInt32 = 0
        guard
            CGGetOnlineDisplayList(
                UInt32(onlineDisplays.count),
                &onlineDisplays,
                &onlineDisplayCount
            ) == .success
        else {
            throw HeadlessDesktopReplacementError.displayEnumerationFailed
        }
        guard onlineDisplayCount == 1,
            onlineDisplays[0] == displayID,
            CGMainDisplayID() == displayID
        else {
            return nil
        }
        let bounds = CGDisplayBounds(displayID)
        return try makeConfiguration(
            vendorID: CGDisplayVendorNumber(displayID),
            productID: CGDisplayModelNumber(displayID),
            logicalWidth: Int(bounds.width),
            logicalHeight: Int(bounds.height),
            pixelWidth: CGDisplayPixelsWide(displayID),
            pixelHeight: CGDisplayPixelsHigh(displayID)
        )
    }

    static func makeConfiguration(
        vendorID: UInt32,
        productID: UInt32,
        logicalWidth: Int,
        logicalHeight: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws -> VirtualDisplayConfiguration? {
        guard vendorID == appleHeadlessVendorID,
            productID == appleHeadlessProductID
        else {
            return nil
        }
        guard logicalWidth > 0, logicalHeight > 0,
            pixelWidth > 0, pixelHeight > 0,
            pixelWidth.isMultiple(of: logicalWidth),
            pixelHeight.isMultiple(of: logicalHeight)
        else {
            throw HeadlessDesktopReplacementError.unsupportedDisplayMode
        }

        let horizontalScale = pixelWidth / logicalWidth
        let verticalScale = pixelHeight / logicalHeight
        guard horizontalScale == verticalScale, (1...4).contains(horizontalScale),
            UInt32(exactly: logicalWidth) != nil,
            UInt32(exactly: logicalHeight) != nil,
            UInt32(exactly: pixelWidth) != nil,
            UInt32(exactly: pixelHeight) != nil
        else {
            throw HeadlessDesktopReplacementError.unsupportedDisplayMode
        }
        guard let currentLogicalWidth = UInt32(exactly: logicalWidth),
            let currentLogicalHeight = UInt32(exactly: logicalHeight),
            let currentPixelWidth = UInt32(exactly: pixelWidth),
            let currentPixelHeight = UInt32(exactly: pixelHeight)
        else {
            throw HeadlessDesktopReplacementError.unsupportedDisplayMode
        }
        let maximumWidth = max(currentPixelWidth, 1_206)
        let maximumHeight = max(currentPixelHeight, 2_622)
        let fractions: [(numerator: UInt32, denominator: UInt32)] = [
            (1, 1),
            (5, 6),
            (3, 4),
            (2, 3),
            (1, 2),
        ]
        var modes: [VirtualDisplayMode] = [
            .init(
                logicalWidth: currentPixelWidth,
                logicalHeight: currentPixelHeight
            ),
            .init(logicalWidth: 1_206, logicalHeight: 2_622),
            .init(logicalWidth: 1_080, logicalHeight: 2_340),
            .init(logicalWidth: 1_080, logicalHeight: 1_920),
            .init(logicalWidth: 828, logicalHeight: 1_792),
            .init(logicalWidth: 750, logicalHeight: 1_334),
        ]
        modes = modes.filter {
            $0.logicalWidth <= maximumWidth && $0.logicalHeight <= maximumHeight
        }
        var seen = Set<VirtualDisplayMode>()
        modes = modes.filter { seen.insert($0).inserted }
        for fraction in fractions {
            guard
                let width = UInt32(
                    exactly: UInt64(pixelWidth) * UInt64(fraction.numerator)
                        / UInt64(fraction.denominator)
                ),
                let height = UInt32(
                    exactly: UInt64(pixelHeight) * UInt64(fraction.numerator)
                        / UInt64(fraction.denominator)
                )
            else {
                throw HeadlessDesktopReplacementError.unsupportedDisplayMode
            }
            let mode = VirtualDisplayMode(logicalWidth: width, logicalHeight: height)
            if width > 0, height > 0, seen.insert(mode).inserted {
                modes.append(mode)
            }
        }

        var requiredResolvedModes: [VirtualDisplayResolvedMode] = [
            .init(
                logicalWidth: currentLogicalWidth,
                logicalHeight: currentLogicalHeight,
                pixelWidth: currentPixelWidth,
                pixelHeight: currentPixelHeight
            ),
            .init(
                logicalWidth: 603,
                logicalHeight: 1_311,
                pixelWidth: 1_206,
                pixelHeight: 2_622
            ),
            .init(
                logicalWidth: 540,
                logicalHeight: 1_170,
                pixelWidth: 1_080,
                pixelHeight: 2_340
            ),
            .init(
                logicalWidth: 540,
                logicalHeight: 960,
                pixelWidth: 1_080,
                pixelHeight: 1_920
            ),
            .init(
                logicalWidth: 414,
                logicalHeight: 896,
                pixelWidth: 828,
                pixelHeight: 1_792
            ),
            .init(
                // macOS 26 does not synthesize a 375-point-wide HiDPI mode for this
                // framebuffer, but it does expose the exact iPhone pixel canvas at 1x.
                // Require the mode WindowServer actually publishes so one unsupported
                // optional scale cannot reject the complete adjustable display.
                logicalWidth: 750,
                logicalHeight: 1_334,
                pixelWidth: 750,
                pixelHeight: 1_334
            ),
        ]
        requiredResolvedModes = requiredResolvedModes.filter {
            $0.pixelWidth <= maximumWidth && $0.pixelHeight <= maximumHeight
        }
        var seenResolvedModes = Set<VirtualDisplayResolvedMode>()
        requiredResolvedModes = requiredResolvedModes.filter {
            seenResolvedModes.insert($0).inserted
        }

        let pixelsPerInch = 220.0
        return try VirtualDisplayConfiguration(
            name: "opensteamer Display",
            vendorID: 0x6F73,
            productID: 0x1718,
            serialNumber: 0x0001,
            maximumWidth: maximumWidth,
            maximumHeight: maximumHeight,
            physicalWidthMillimeters: Double(maximumWidth) / pixelsPerInch * 25.4,
            physicalHeightMillimeters: Double(maximumHeight) / pixelsPerInch * 25.4,
            displaySettingsHiDPI: 1,
            modes: modes,
            requiredResolvedModes: requiredResolvedModes
        )
    }
}

public enum HeadlessDesktopReplacementError: LocalizedError, Equatable {
    case displayEnumerationFailed
    case unsupportedDisplayMode

    public var errorDescription: String? {
        switch self {
        case .displayEnumerationFailed:
            "macOS could not enumerate the current display topology"
        case .unsupportedDisplayMode:
            "The current headless desktop mode cannot be preserved safely"
        }
    }
}
