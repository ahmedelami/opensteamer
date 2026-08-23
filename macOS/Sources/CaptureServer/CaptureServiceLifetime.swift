import CaptureCore
import Foundation
import Server

/// Native media-stop proof collected before process-level resources may be released.
struct CaptureServiceShutdownConfirmation: Sendable, Equatable {
    let lanScreenCaptureIsConfirmed: Bool
    let worldwideNativeCaptureIsConfirmed: Bool

    static let confirmed = CaptureServiceShutdownConfirmation(
        lanScreenCaptureIsConfirmed: true,
        worldwideNativeCaptureIsConfirmed: true
    )

    var allNativeCapturesAreConfirmed: Bool {
        lanScreenCaptureIsConfirmed && worldwideNativeCaptureIsConfirmed
    }
}

/// Keeps the owned virtual display alive until every possibly display-backed native capture has
/// confirmed shutdown. A fatal process exit is the only safe release boundary after uncertainty.
enum CaptureServerFatalExitPolicy {
    static func mayRemoveVirtualDisplay(
        shutdownConfirmation: CaptureServiceShutdownConfirmation,
        lanAudioStopIsConfirmed: Bool
    ) -> Bool {
        shutdownConfirmation.allNativeCapturesAreConfirmed
            && lanAudioStopIsConfirmed
    }
}

/// Owns fail-closed service references while virtual-display supervision is active.
///
/// Invalidation closes synchronous transport/input gates before launching async native teardown,
/// so a slow ScreenCaptureKit stop cannot keep forwarding or remote input authorized.
final class CaptureServiceLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private let validityProbe: @Sendable () -> Bool
    private let teardownDidBegin: @Sendable () -> Void
    private var invalidated = false
    private var server: TCPServer?
    private var screenService: ScreenVideoService?
    private var worldwideCoordinator: WorldwideHostCoordinator?
    private var remoteInputController: MacRemoteInputController?
    private var teardownTask: Task<CaptureServiceShutdownConfirmation, Never>?

    init(
        validityProbe: @escaping @Sendable () -> Bool = { true },
        teardownDidBegin: @escaping @Sendable () -> Void = {}
    ) {
        self.validityProbe = validityProbe
        self.teardownDidBegin = teardownDidBegin
    }

    var isValid: Bool {
        lock.withLock { () -> Bool in
            guard !invalidated else { return false }
            guard validityProbe() else {
                invalidateLocked()
                return false
            }
            return true
        }
    }

    /// Cheap admission latch for realtime media callbacks.
    ///
    /// Full WindowServer identity checks stay on the monitor and actor/startup boundaries. The
    /// realtime callback takes this lock only long enough to observe terminal invalidation, then
    /// releases it before calling WebRTC so audio and video never serialize on native capture.
    var allowsCallbackEntry: Bool {
        lock.withLock { !invalidated }
    }

    func installAndStart(server: TCPServer) throws {
        try whileValid {
            self.server = server
            do {
                try server.start()
            } catch {
                self.server = nil
                throw error
            }
        }
    }

    func installAndStart(screenService: ScreenVideoService) throws {
        try whileValid {
            self.screenService = screenService
            do {
                try screenService.start()
            } catch {
                self.screenService = nil
                throw error
            }
        }
    }

    func install(
        worldwideCoordinator: WorldwideHostCoordinator,
        remoteInputController: MacRemoteInputController
    ) throws {
        try whileValid {
            self.worldwideCoordinator = worldwideCoordinator
            self.remoteInputController = remoteInputController
        }
    }

    func requireValid() throws {
        try whileValid {}
        try Task.checkCancellation()
    }

    /// Idempotently closes every synchronous gate and starts async dependency teardown.
    func invalidate() {
        lock.withLock {
            invalidateLocked()
        }
    }

    @discardableResult
    func shutdown() async -> CaptureServiceShutdownConfirmation {
        invalidate()
        let task = lock.withLock { teardownTask }
        guard let task else { return .confirmed }
        return await task.value
    }

    private static func stopWorldwideCoordinator(
        _ coordinator: WorldwideHostCoordinator?
    ) async -> Bool {
        guard let coordinator else { return true }
        return await coordinator.stop()
    }

    private static func stopLANScreenService(
        _ screenService: ScreenVideoService?,
        afterRevoking lifecycleTask: Task<Void, Never>?
    ) async -> Bool {
        guard let screenService else { return true }
        return await screenService.finishStop(afterRevoking: lifecycleTask)
    }

    private func whileValid(_ body: () throws -> Void) throws {
        try lock.withLock {
            do {
                guard !invalidated, validityProbe() else {
                    throw VirtualDisplayLifetimeError.displayInvalid
                }
                try body()
            } catch let error as VirtualDisplayLifetimeError {
                invalidateLocked()
                throw error
            }
        }
    }

    /// Transitions callback admission and publishes the one teardown task while `lock` is held.
    /// This removes the gap in which owner invalidity was known but a realtime callback or a
    /// second installer could still enter before asynchronous teardown ownership existed.
    private func invalidateLocked() {
        guard !invalidated else { return }
        teardownDidBegin()
        invalidated = true

        remoteInputController?.invalidate()
        server?.stop()
        let screenLifecycleTask = screenService?.revoke()

        let coordinator = worldwideCoordinator
        let screenService = screenService
        teardownTask = Task {
            async let worldwideConfirmation = Self.stopWorldwideCoordinator(coordinator)
            async let lanConfirmation = Self.stopLANScreenService(
                screenService,
                afterRevoking: screenLifecycleTask
            )
            let confirmations = await (lanConfirmation, worldwideConfirmation)
            return CaptureServiceShutdownConfirmation(
                lanScreenCaptureIsConfirmed: confirmations.0,
                worldwideNativeCaptureIsConfirmed: confirmations.1
            )
        }
    }
}
