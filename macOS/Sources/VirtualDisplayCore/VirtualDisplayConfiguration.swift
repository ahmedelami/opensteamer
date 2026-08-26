import Foundation

/// A mode passed to the private virtual-display settings object.
public struct VirtualDisplayMode: Equatable, Hashable, Sendable {
    public let logicalWidth: UInt32
    public let logicalHeight: UInt32
    public let refreshRate: Double

    public init(
        logicalWidth: UInt32,
        logicalHeight: UInt32,
        refreshRate: Double = 60
    ) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.refreshRate = refreshRate
    }
}

/// A logical-to-framebuffer mapping that must actually appear after registration.
public struct VirtualDisplayResolvedMode: Equatable, Hashable, Sendable {
    public let logicalWidth: UInt32
    public let logicalHeight: UInt32
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32
    public let refreshRate: Double

    public init(
        logicalWidth: UInt32,
        logicalHeight: UInt32,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        refreshRate: Double = 60
    ) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
    }
}

public struct VirtualDisplayConfiguration: Equatable, Sendable {
    public let name: String
    public let vendorID: UInt32
    public let productID: UInt32
    public let serialNumber: UInt32
    public let maximumWidth: UInt32
    public let maximumHeight: UInt32
    public let physicalWidthMillimeters: Double
    public let physicalHeightMillimeters: Double
    public let displaySettingsHiDPI: UInt32
    public let modes: [VirtualDisplayMode]
    public let requiredResolvedModes: [VirtualDisplayResolvedMode]
    /// The underlying desktop mapping expected after this owned virtual display retires.
    /// It can be larger than the virtual display's framebuffer limits.
    public let restoredDesktopMode: VirtualDisplayResolvedMode?

    public init(
        name: String,
        vendorID: UInt32,
        productID: UInt32,
        serialNumber: UInt32,
        maximumWidth: UInt32,
        maximumHeight: UInt32,
        physicalWidthMillimeters: Double,
        physicalHeightMillimeters: Double,
        displaySettingsHiDPI: UInt32,
        modes: [VirtualDisplayMode],
        requiredResolvedModes: [VirtualDisplayResolvedMode],
        restoredDesktopMode: VirtualDisplayResolvedMode? = nil
    ) throws {
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.physicalWidthMillimeters = physicalWidthMillimeters
        self.physicalHeightMillimeters = physicalHeightMillimeters
        self.displaySettingsHiDPI = displaySettingsHiDPI
        self.modes = modes
        self.requiredResolvedModes = requiredResolvedModes
        self.restoredDesktopMode = restoredDesktopMode
        try validate()
    }

    /// Direct 2x phone canvas retained for diagnostics and a future workspace mode.
    public static let iPhone17Pro: Self = {
        let modes = [
            VirtualDisplayMode(logicalWidth: 603, logicalHeight: 1_311),
            .init(logicalWidth: 540, logicalHeight: 1_170),
            .init(logicalWidth: 540, logicalHeight: 960),
            .init(logicalWidth: 414, logicalHeight: 896),
            .init(logicalWidth: 375, logicalHeight: 667),
        ]
        let resolvedModes = modes.map {
            VirtualDisplayResolvedMode(
                logicalWidth: $0.logicalWidth,
                logicalHeight: $0.logicalHeight,
                pixelWidth: $0.logicalWidth * 2,
                pixelHeight: $0.logicalHeight * 2,
                refreshRate: $0.refreshRate
            )
        }
        do {
            return try Self(
                name: "opensteamer Phone Display",
                vendorID: 0x6F73,
                productID: 0x1717,
                serialNumber: 0x0001,
                maximumWidth: 1_206,
                maximumHeight: 2_622,
                // Approximately 220 PPI. Literal iPhone density can make WindowServer reject it.
                physicalWidthMillimeters: 139.2,
                physicalHeightMillimeters: 302.7,
                displaySettingsHiDPI: 2,
                modes: modes,
                requiredResolvedModes: resolvedModes
            )
        } catch {
            preconditionFailure("Invalid built-in iPhone 17 Pro display preset: \(error)")
        }
    }()

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VirtualDisplayConfigurationError.emptyName
        }
        guard !name.utf8.contains(0) else {
            throw VirtualDisplayConfigurationError.invalidName
        }
        guard vendorID > 0, productID > 0, serialNumber > 0 else {
            throw VirtualDisplayConfigurationError.invalidIdentity
        }
        guard maximumWidth > 0, maximumHeight > 0 else {
            throw VirtualDisplayConfigurationError.invalidMaximumDimensions
        }
        guard physicalWidthMillimeters.isFinite, physicalWidthMillimeters > 0,
            physicalHeightMillimeters.isFinite, physicalHeightMillimeters > 0
        else {
            throw VirtualDisplayConfigurationError.invalidPhysicalDimensions
        }
        guard displaySettingsHiDPI > 0, displaySettingsHiDPI <= 4 else {
            throw VirtualDisplayConfigurationError.invalidDisplaySettingsHiDPI
        }
        guard !modes.isEmpty else {
            throw VirtualDisplayConfigurationError.emptyModes
        }
        guard !requiredResolvedModes.isEmpty else {
            throw VirtualDisplayConfigurationError.emptyResolvedModes
        }

        var uniqueModes = Set<VirtualDisplayMode>()
        for mode in modes {
            guard mode.logicalWidth > 0, mode.logicalHeight > 0,
                mode.logicalWidth <= maximumWidth,
                mode.logicalHeight <= maximumHeight
            else {
                throw VirtualDisplayConfigurationError.invalidModeDimensions
            }
            guard Self.validRefreshRate(mode.refreshRate) else {
                throw VirtualDisplayConfigurationError.invalidRefreshRate
            }
            guard uniqueModes.insert(mode).inserted else {
                throw VirtualDisplayConfigurationError.duplicateMode
            }
        }

        var uniqueResolvedModes = Set<VirtualDisplayResolvedMode>()
        for mode in requiredResolvedModes {
            guard mode.logicalWidth > 0, mode.logicalHeight > 0,
                mode.pixelWidth > 0, mode.pixelHeight > 0,
                mode.pixelWidth <= maximumWidth,
                mode.pixelHeight <= maximumHeight
            else {
                throw VirtualDisplayConfigurationError.invalidResolvedModeDimensions
            }
            guard Self.validRefreshRate(mode.refreshRate) else {
                throw VirtualDisplayConfigurationError.invalidRefreshRate
            }
            guard uniqueResolvedModes.insert(mode).inserted else {
                throw VirtualDisplayConfigurationError.duplicateResolvedMode
            }
        }

        if let restoredDesktopMode {
            guard restoredDesktopMode.logicalWidth > 0,
                restoredDesktopMode.logicalHeight > 0,
                restoredDesktopMode.pixelWidth > 0,
                restoredDesktopMode.pixelHeight > 0
            else {
                throw VirtualDisplayConfigurationError.invalidResolvedModeDimensions
            }
            guard Self.validRefreshRate(restoredDesktopMode.refreshRate) else {
                throw VirtualDisplayConfigurationError.invalidRefreshRate
            }
        }
    }

    private static func validRefreshRate(_ value: Double) -> Bool {
        value.isFinite && value > 0 && value <= 240
    }
}

public enum VirtualDisplayConfigurationError: LocalizedError, Equatable {
    case emptyName
    case invalidName
    case invalidIdentity
    case invalidMaximumDimensions
    case invalidPhysicalDimensions
    case invalidDisplaySettingsHiDPI
    case emptyModes
    case emptyResolvedModes
    case invalidModeDimensions
    case invalidResolvedModeDimensions
    case invalidRefreshRate
    case duplicateMode
    case duplicateResolvedMode

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            "Virtual display name is empty"
        case .invalidName:
            "Virtual display name contains an unsupported null byte"
        case .invalidIdentity:
            "Virtual display identity values must be nonzero"
        case .invalidMaximumDimensions:
            "Virtual display maximum dimensions must be positive"
        case .invalidPhysicalDimensions:
            "Virtual display physical dimensions must be finite and positive"
        case .invalidDisplaySettingsHiDPI:
            "Virtual display private HiDPI setting must be between 1 and 4"
        case .emptyModes:
            "Virtual display must advertise at least one mode"
        case .emptyResolvedModes:
            "Virtual display must require at least one resolved mode"
        case .invalidModeDimensions:
            "Virtual display advertised mode dimensions must fit inside its maximum size"
        case .invalidResolvedModeDimensions:
            "Virtual display resolved framebuffer dimensions must fit inside its maximum size"
        case .invalidRefreshRate:
            "Virtual display refresh rate must be between 0 and 240 Hz"
        case .duplicateMode:
            "Virtual display advertised modes must be unique"
        case .duplicateResolvedMode:
            "Virtual display resolved modes must be unique"
        }
    }
}
