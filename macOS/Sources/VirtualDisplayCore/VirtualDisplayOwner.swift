import CoreGraphics
import Foundation
import VirtualDisplayPrivate

public final class VirtualDisplayOwner: @unchecked Sendable {
    public let displayID: CGDirectDisplayID
    public let configuration: VirtualDisplayConfiguration

    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var teardownResult: Bool?
    private var teardownIsInProgress = false

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
        let unreleasedHandle = lock.withLock { () -> OpaquePointer? in
            defer { handle = nil }
            return handle
        }
        OpensteamerVirtualDisplayDestroy(unreleasedHandle)
    }

    /// Releases the display exactly once, then delegates restored-topology proof to a verifier.
    /// The executable supplies a fresh-process verifier because the owning CoreGraphics
    /// connection can retain the retired display in its own topology snapshot.
    @discardableResult
    public func close(
        using restorationVerifier: (RestoredDesktopExpectation) -> Bool
    ) -> Bool {
        enum CloseAction {
            case resolved(Bool)
            case verify(OpaquePointer?)
            case verificationInProgress
        }
        let action = lock.withLock { () -> CloseAction in
            if let teardownResult {
                return .resolved(teardownResult)
            }
            guard !teardownIsInProgress else {
                return .verificationInProgress
            }
            teardownIsInProgress = true
            let retiredHandle = handle
            handle = nil
            return .verify(retiredHandle)
        }
        switch action {
        case .resolved(let result):
            return result
        case .verificationInProgress:
            return false
        case .verify(let retiredHandle):
            OpensteamerVirtualDisplayDestroy(retiredHandle)
            let result = restorationVerifier(
                RestoredDesktopExpectation(afterRetiring: configuration)
            )
            lock.withLock {
                // Cache only proof. A bounded miss remains fail-closed for this caller, while the
                // enclosing fatal-cleanup path may make one final fresh-process attempt after
                // WindowServer has had additional time to settle.
                teardownResult = result ? true : nil
                teardownIsInProgress = false
            }
            return result
        }
    }

    @discardableResult
    public func close() -> Bool {
        close(using: { expectation in
            HeadlessDesktopReplacement.waitUntilRestored(
                expectation: expectation
            )
        })
    }

    @discardableResult
    public func invalidate(
        using restorationVerifier: (RestoredDesktopExpectation) -> Bool
    ) -> Bool {
        close(using: restorationVerifier)
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
