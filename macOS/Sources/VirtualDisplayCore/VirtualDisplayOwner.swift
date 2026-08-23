import CoreGraphics
import Foundation
import VirtualDisplayPrivate

public final class VirtualDisplayOwner: @unchecked Sendable {
    public let displayID: CGDirectDisplayID
    public let configuration: VirtualDisplayConfiguration

    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var teardownIsConfirmed = false

    public static var runtimeIsAvailable: Bool {
        OpensteamerVirtualDisplayRuntimeIsAvailable()
    }

    public var isAlive: Bool {
        lock.withLock {
            guard OpensteamerVirtualDisplayIsAlive(handle),
                CGDisplayVendorNumber(displayID) == configuration.vendorID,
                CGDisplayModelNumber(displayID) == configuration.productID,
                CGDisplaySerialNumber(displayID) == configuration.serialNumber,
                CGMainDisplayID() == displayID
            else {
                return false
            }

            var onlineDisplayIDs = [CGDirectDisplayID](
                repeating: kCGNullDirectDisplay,
                count: 2
            )
            var onlineDisplayCount: UInt32 = 0
            guard
                CGGetOnlineDisplayList(
                    UInt32(onlineDisplayIDs.count),
                    &onlineDisplayIDs,
                    &onlineDisplayCount
                ) == .success,
                onlineDisplayCount == 1,
                onlineDisplayIDs[0] == displayID
            else {
                return false
            }
            return true
        }
    }

    public init(configuration: VirtualDisplayConfiguration) throws {
        try configuration.validate()
        guard Self.runtimeIsAvailable else {
            throw VirtualDisplayRuntimeError.runtimeUnavailable
        }

        let nativeModes = configuration.modes.map {
            OpensteamerVirtualDisplayMode(
                logicalWidth: $0.logicalWidth,
                logicalHeight: $0.logicalHeight,
                refreshRate: $0.refreshRate
            )
        }
        let requiredResolvedModes = configuration.requiredResolvedModes.map {
            OpensteamerVirtualDisplayResolvedMode(
                logicalWidth: $0.logicalWidth,
                logicalHeight: $0.logicalHeight,
                pixelWidth: $0.pixelWidth,
                pixelHeight: $0.pixelHeight,
                refreshRate: $0.refreshRate
            )
        }
        var resolvedDisplayID = kCGNullDirectDisplay
        var status = OpensteamerVirtualDisplayStatus(
            OpensteamerVirtualDisplayStatusSuccess
        )
        let createdHandle = configuration.name.withCString { name in
            nativeModes.withUnsafeBufferPointer { buffer in
                requiredResolvedModes.withUnsafeBufferPointer { resolvedBuffer in
                    OpensteamerVirtualDisplayCreate(
                        name,
                        configuration.vendorID,
                        configuration.productID,
                        configuration.serialNumber,
                        configuration.maximumWidth,
                        configuration.maximumHeight,
                        configuration.physicalWidthMillimeters,
                        configuration.physicalHeightMillimeters,
                        configuration.displaySettingsHiDPI,
                        buffer.baseAddress!,
                        buffer.count,
                        resolvedBuffer.baseAddress!,
                        resolvedBuffer.count,
                        &resolvedDisplayID,
                        &status
                    )
                }
            }
        }
        guard let createdHandle,
            status
                == OpensteamerVirtualDisplayStatus(
                    OpensteamerVirtualDisplayStatusSuccess
                ),
            resolvedDisplayID != kCGNullDirectDisplay
        else {
            throw VirtualDisplayRuntimeError.creationFailed(status: status)
        }

        self.configuration = configuration
        displayID = resolvedDisplayID
        handle = createdHandle
    }

    deinit {
        close()
    }

    /// Releases the display, proves its ID is offline, then proves the sole Apple headless
    /// placeholder has returned before allowing the process lock to be released.
    @discardableResult
    public func close() -> Bool {
        enum CloseAction {
            case alreadyConfirmed
            case destroy(OpaquePointer)
            case retryOfflineProof
        }
        let action = lock.withLock { () -> CloseAction in
            if teardownIsConfirmed {
                return .alreadyConfirmed
            }
            guard let retiredHandle = handle else {
                return .retryOfflineProof
            }
            handle = nil
            return .destroy(retiredHandle)
        }
        let didConfirmOffline: Bool
        switch action {
        case .alreadyConfirmed:
            return true
        case .destroy(let retiredHandle):
            didConfirmOffline = OpensteamerVirtualDisplayDestroy(retiredHandle)
        case .retryOfflineProof:
            didConfirmOffline = OpensteamerVirtualDisplayWaitUntilOffline(displayID)
        }
        let didConfirmRestoration = didConfirmOffline
            && HeadlessDesktopReplacement.waitUntilRestored(
                afterRetiring: configuration
            )
        if didConfirmRestoration {
            lock.withLock { teardownIsConfirmed = true }
        }
        return didConfirmRestoration
    }

    @discardableResult
    public func invalidate() -> Bool {
        close()
    }
}

public enum VirtualDisplayRuntimeError: LocalizedError, Equatable {
    case runtimeUnavailable
    case creationFailed(status: OpensteamerVirtualDisplayStatus)

    public var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            "This macOS version does not provide the virtual-display runtime"
        case .creationFailed(let status):
            "macOS rejected the virtual display (status \(status))"
        }
    }
}
