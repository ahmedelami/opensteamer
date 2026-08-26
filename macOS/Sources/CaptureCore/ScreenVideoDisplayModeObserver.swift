import CoreGraphics
import Foundation

/// Reports the begin and settled boundaries of one display's Core Graphics reconfiguration.
///
/// Registration happens during initialization, but delivery remains closed until `activate()`.
/// Capture startup can therefore install the callback before starting ScreenCaptureKit, validate
/// that the display mode stayed stable, and only then arm live reconfiguration delivery. `stop()`
/// is permanent and idempotent after successful callback removal.
public final class ScreenVideoDisplayModeObserver: @unchecked Sendable {
    public typealias Observer = @Sendable () -> Void

    private let operations: any ScreenVideoDisplayModeObservingOperations
    private let callbackGate: ScreenVideoDisplayModeCallbackGate
    private let registrationLock = NSLock()
    private var retainedCallbackContext: UnsafeMutableRawPointer?
    private var stopRequested = false

    /// Registers an initially inactive callback for `displayID`.
    public convenience init(
        displayID: CGDirectDisplayID,
        willReconfigure: @escaping Observer = {},
        observer: @escaping Observer
    ) throws {
        try self.init(
            displayID: displayID,
            operations: SystemScreenVideoDisplayModeObservingOperations(),
            willReconfigure: willReconfigure,
            observer: observer
        )
    }

    init(
        displayID: CGDirectDisplayID,
        operations: any ScreenVideoDisplayModeObservingOperations,
        willReconfigure: @escaping Observer = {},
        observer: @escaping Observer
    ) throws {
        self.operations = operations
        callbackGate = ScreenVideoDisplayModeCallbackGate(
            displayID: displayID,
            willReconfigure: willReconfigure,
            observer: observer
        )

        // Core Graphics does not retain userInfo. Give the registration its own strong reference
        // so a failed removal can retain an inert context instead of leaving a dangling pointer.
        let context = Unmanaged.passRetained(callbackGate).toOpaque()
        let registrationError = operations.register(
            callback: screenVideoDisplayModeReconfigurationCallback,
            userInfo: context
        )
        guard registrationError == .success else {
            Unmanaged<ScreenVideoDisplayModeCallbackGate>.fromOpaque(context).release()
            throw ScreenVideoDisplayModeObserverError.registrationFailed(registrationError)
        }
        retainedCallbackContext = context
    }

    deinit {
        _ = stop()
    }

    /// Arms a provisional delivery generation after capture validates its selected display mode.
    ///
    /// Repeated activation is harmless. Activation is rejected if any target-display
    /// configuration began after registration but before this fence, or after a stop request.
    @discardableResult
    public func activate() -> Bool {
        registrationLock.withLock {
            guard retainedCallbackContext != nil, !stopRequested else { return false }
            return callbackGate.activate()
        }
    }

    /// Commits live callback delivery after the owner has installed every downstream format gate.
    /// A display configuration admitted between `activate()` and this call rejects the commit.
    @discardableResult
    public func commitActivation() -> Bool {
        registrationLock.withLock {
            guard retainedCallbackContext != nil, !stopRequested else { return false }
            return callbackGate.commitActivation()
        }
    }

    /// Permanently closes delivery and removes the exact Core Graphics registration.
    ///
    /// A failed removal leaves the separately retained callback context installed but inert. A
    /// later call retries the same callback/user-info identity without reopening delivery.
    @discardableResult
    public func stop() -> ScreenVideoDisplayModeObserverStopResult {
        registrationLock.withLock {
            stopRequested = true
            callbackGate.stop()
            guard let context = retainedCallbackContext else { return .stopped }

            let removalError = operations.remove(
                callback: screenVideoDisplayModeReconfigurationCallback,
                userInfo: context
            )
            guard removalError == .success else {
                return .removalFailed(removalError)
            }

            retainedCallbackContext = nil
            Unmanaged<ScreenVideoDisplayModeCallbackGate>.fromOpaque(context).release()
            return .stopped
        }
    }
}

/// Callback registration failures that prevent authoritative mode observation.
public enum ScreenVideoDisplayModeObserverError: LocalizedError, Equatable, Sendable {
    case registrationFailed(CGError)

    public var errorDescription: String? {
        switch self {
        case .registrationFailed(let error):
            "Could not register the display-mode observer (Core Graphics error \(error.rawValue))"
        }
    }
}

/// Result of closing one display-mode callback registration.
public enum ScreenVideoDisplayModeObserverStopResult: Equatable, Sendable {
    case stopped
    case removalFailed(CGError)
}

/// Injectable Core Graphics boundary used by deterministic lifecycle tests.
protocol ScreenVideoDisplayModeObservingOperations: Sendable {
    func register(
        callback: CGDisplayReconfigurationCallBack?,
        userInfo: UnsafeMutableRawPointer?
    ) -> CGError

    func remove(
        callback: CGDisplayReconfigurationCallBack?,
        userInfo: UnsafeMutableRawPointer?
    ) -> CGError
}

private struct SystemScreenVideoDisplayModeObservingOperations:
    ScreenVideoDisplayModeObservingOperations
{
    func register(
        callback: CGDisplayReconfigurationCallBack?,
        userInfo: UnsafeMutableRawPointer?
    ) -> CGError {
        CGDisplayRegisterReconfigurationCallback(callback, userInfo)
    }

    func remove(
        callback: CGDisplayReconfigurationCallBack?,
        userInfo: UnsafeMutableRawPointer?
    ) -> CGError {
        CGDisplayRemoveReconfigurationCallback(callback, userInfo)
    }
}

/// Lock-serialized activation, event classification, and notification for the C callback context.
private final class ScreenVideoDisplayModeCallbackGate: @unchecked Sendable {
    private enum Delivery {
        case willReconfigure
        case didSettle
    }

    private let displayID: CGDirectDisplayID
    private let willReconfigure: ScreenVideoDisplayModeObserver.Observer
    private let observer: ScreenVideoDisplayModeObserver.Observer
    private let lock = NSLock()
    private enum ActivationPhase {
        case inactive
        case provisional
        case active
        case stopped
    }
    private var activationPhase = ActivationPhase.inactive
    private var isStopped = false
    private var configurationBeganBeforeCommit = false
    private var configurationSettledBeforeCommit = false
    private var activeConfigurationIsInProgress = false
    private var deliveredForCurrentConfiguration = false

    init(
        displayID: CGDirectDisplayID,
        willReconfigure: @escaping ScreenVideoDisplayModeObserver.Observer,
        observer: @escaping ScreenVideoDisplayModeObserver.Observer
    ) {
        self.displayID = displayID
        self.willReconfigure = willReconfigure
        self.observer = observer
    }

    func activate() -> Bool {
        lock.withLock {
            guard !isStopped,
                  !configurationBeganBeforeCommit,
                  !configurationSettledBeforeCommit else {
                return false
            }
            if activationPhase == .inactive {
                activationPhase = .provisional
            }
            return true
        }
    }

    func commitActivation() -> Bool {
        lock.withLock {
            guard !isStopped,
                  !configurationBeganBeforeCommit,
                  !configurationSettledBeforeCommit else {
                return false
            }
            switch activationPhase {
            case .provisional:
                activationPhase = .active
                return true
            case .active:
                return true
            case .inactive, .stopped:
                return false
            }
        }
    }

    func stop() {
        lock.withLock {
            activationPhase = .stopped
            isStopped = true
        }
    }

    /// Emits once before and once after each target-display configuration while active.
    ///
    /// Apple's begin callback cannot say what the transaction will change, so it closes consumers
    /// immediately. The first target post callback settles that fence after Core Graphics state is
    /// current, regardless of which post-configuration flags it carries.
    func consume(
        displayID eventDisplayID: CGDirectDisplayID,
        flags: CGDisplayChangeSummaryFlags
    ) {
        let delivery = lock.withLock { () -> Delivery? in
            guard eventDisplayID == displayID else { return nil }
            if flags.contains(.beginConfigurationFlag) {
                deliveredForCurrentConfiguration = false
                if activationPhase == .inactive || activationPhase == .provisional {
                    configurationBeganBeforeCommit = true
                }
                guard activationPhase == .active,
                      !isStopped,
                      !activeConfigurationIsInProgress else {
                    return nil
                }
                activeConfigurationIsInProgress = true
                return .willReconfigure
            }
            guard !isStopped,
                  !deliveredForCurrentConfiguration else {
                return nil
            }
            deliveredForCurrentConfiguration = true
            activeConfigurationIsInProgress = false
            switch activationPhase {
            case .inactive, .provisional:
                configurationSettledBeforeCommit = true
                return nil
            case .active:
                return .didSettle
            case .stopped:
                return nil
            }
        }
        switch delivery {
        case .willReconfigure:
            willReconfigure()
        case .didSettle:
            observer()
        case nil:
            break
        }
    }
}

private let screenVideoDisplayModeReconfigurationCallback:
    CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
        guard let userInfo else { return }
        let callbackGate = Unmanaged<ScreenVideoDisplayModeCallbackGate>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        callbackGate.consume(displayID: displayID, flags: flags)
    }
