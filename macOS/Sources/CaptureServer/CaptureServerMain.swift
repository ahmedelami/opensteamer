import CaptureCore
import Darwin
import Foundation
import RemoteSessionCore
import Server
import VirtualDisplayCore

/// Process entry point that composes trusted-LAN capture and the secure worldwide host.
///
/// Startup proceeds from exclusive process ownership through listeners and coordinators;
/// teardown runs in reverse so no capture callback or WebSocket outlives its dependency.
@main
struct CaptureServerMain {
    /// Parses configuration, starts enabled services, and exits nonzero on any fatal failure.
    static func main() async {
        var virtualDisplayOwner: VirtualDisplayOwner?
        var activeServiceLifetime: CaptureServiceLifetime?
        var activeVirtualDisplayLifetimeTask: Task<Void, Never>?
        var activeVirtualDisplayTeardownDeadline: VirtualDisplayTeardownDeadline?
        var activeProcessCleanupDeadline: VirtualDisplayTeardownDeadline?
        var attemptedVirtualDisplayConfiguration: VirtualDisplayConfiguration?
        var worldwideHostProcessLock: WorldwideHostProcessLock?
        var activeTerminationSignalMonitor: ProcessTerminationSignalMonitor?
        do {
            let options = try CaptureServerOptions.parse(CommandLine.arguments)
            if options.showHelp {
                print(CaptureServerOptions.usage)
                return
            }

            let logger = ConsoleLogger(verbose: options.verbose)
            if options.listDisplays {
                try await ShareableContentLister(logger: logger).printDisplays()
                return
            }

            if options.verifyRouting {
                let health = try BlackHoleRouteVerifier.verifyCurrentRoute()
                print(health.render())
                if !health.isHealthy {
                    exit(2)
                }
                return
            }

            // The shared lock is also required by the display-only LAN mode: WindowServer must
            // never be mutated while an installed worldwide host owns this runtime namespace.
            if options.requiresExclusiveHostProcessLock {
                worldwideHostProcessLock = try WorldwideHostProcessLock.acquire()
            } else {
                worldwideHostProcessLock = nil
            }

            let virtualDisplayTeardownDeadline: VirtualDisplayTeardownDeadline?
            if options.virtualPhoneDisplayEnabled {
                let deadline = VirtualDisplayTeardownDeadline {
                    fputs(
                        "error: adjustable display lifecycle exceeded its grace period; exiting\n",
                        stderr
                    )
                    exit(1)
                }
                virtualDisplayTeardownDeadline = deadline
                activeVirtualDisplayTeardownDeadline = deadline
            } else {
                virtualDisplayTeardownDeadline = nil
            }

            let terminationMonitorIsRequired = ProcessTerminationSignalPolicy.requiresMonitor(
                virtualDisplayEnabled: options.virtualPhoneDisplayEnabled,
                worldwideEnabled: options.worldwideEnabled
            )
            let processCleanupDeadline: VirtualDisplayTeardownDeadline?
            if ProcessTerminationSignalPolicy.requiresIndependentFallback(
                virtualDisplayEnabled: options.virtualPhoneDisplayEnabled,
                worldwideEnabled: options.worldwideEnabled
            ) {
                let deadline = VirtualDisplayTeardownDeadline(
                    gracePeriod: VirtualDisplayTeardownBudgets.nonVirtualProcessCleanup
                ) {
                    fputs(
                        "error: process cleanup exceeded its grace period; exiting\n",
                        stderr
                    )
                    exit(1)
                }
                processCleanupDeadline = deadline
                activeProcessCleanupDeadline = deadline
            } else {
                processCleanupDeadline = nil
            }
            let terminalCleanupDeadline =
                virtualDisplayTeardownDeadline ?? processCleanupDeadline

            // Install before virtual-display creation and all listener/coordinator startup. The
            // signal is retained synchronously even while a private/native call cannot cancel.
            if terminationMonitorIsRequired {
                activeTerminationSignalMonitor = ProcessTerminationSignalMonitor { _ in
                    terminalCleanupDeadline?.arm()
                }
            }
            try activeTerminationSignalMonitor?.throwIfSignaled()

            let serviceLifetime: CaptureServiceLifetime
            let virtualDisplayLifetimeTask: Task<Void, Never>?
            let virtualDisplayInvalidationEvents: AsyncStream<Void>?
            if let teardownDeadline = virtualDisplayTeardownDeadline {
                guard let configuration = try HeadlessDesktopReplacement.configurationIfNeeded()
                else {
                    throw CaptureServerMainError.virtualDisplayRequiresHeadlessDesktop
                }
                attemptedVirtualDisplayConfiguration = configuration
                try activeTerminationSignalMonitor?.throwIfSignaled()
                // Native creation has several intentional sequential WindowServer settling
                // windows totaling roughly 27 seconds, so creation owns a separate budget.
                let initializationWatchdog = teardownDeadline.makeInitializationWatchdog()
                let owner: VirtualDisplayOwner
                do {
                    owner = try VirtualDisplayOwner(configuration: configuration)
                    initializationWatchdog.cancel()
                    await initializationWatchdog.value
                } catch {
                    initializationWatchdog.cancel()
                    await initializationWatchdog.value
                    throw error
                }
                virtualDisplayOwner = owner
                try activeTerminationSignalMonitor?.throwIfSignaled()

                serviceLifetime = CaptureServiceLifetime(
                    validityProbe: { owner.isAlive },
                    teardownDidBegin: { teardownDeadline.arm() }
                )
                activeServiceLifetime = serviceLifetime
                let invalidationSignal = VirtualDisplayInvalidationSignal()
                virtualDisplayLifetimeTask = VirtualDisplayLifetimeSupervisor.start(
                    monitor: VirtualDisplayLifetimeMonitor.live(
                        isValid: { owner.isAlive }
                    ),
                    onInvalidation: {
                        teardownDeadline.arm()
                        serviceLifetime.invalidate()
                        invalidationSignal.signal()
                    }
                )
                activeVirtualDisplayLifetimeTask = virtualDisplayLifetimeTask
                virtualDisplayInvalidationEvents = invalidationSignal.events

                // Supervision is already active here: a wedged ScreenCaptureKit snapshot cannot
                // leave a drifted replacement display or the exclusive host lock unbounded.
                try await runUntilProcessTermination(
                    terminationSignals: activeTerminationSignalMonitor?.events
                ) {
                    try await VirtualDisplayShareabilityGate.live.waitUntilReady(
                        displayID: owner.displayID,
                        vendorID: configuration.vendorID,
                        productID: configuration.productID,
                        displayIsAlive: { owner.isAlive }
                    )
                }
                try activeTerminationSignalMonitor?.throwIfSignaled()
                logger.info(
                    "Created \(configuration.name) as display \(owner.displayID) with " +
                        "\(configuration.requiredResolvedModes.count) verified mappings"
                )
            } else {
                serviceLifetime = CaptureServiceLifetime(
                    teardownDidBegin: { processCleanupDeadline?.arm() }
                )
                activeServiceLifetime = serviceLifetime
                virtualDisplayLifetimeTask = nil
                virtualDisplayInvalidationEvents = nil
            }

            let displaySelection = CaptureDisplaySelection(
                explicitDisplayID: options.displayID,
                virtualDisplayID: virtualDisplayOwner?.displayID
            )
            let screenDisplayRequirement = virtualDisplayOwner.map { owner in
                ScreenVideoDisplayRequirement(
                    vendorID: owner.configuration.vendorID,
                    productID: owner.configuration.productID,
                    serialNumber: owner.configuration.serialNumber,
                    requiresSoleMainDisplay: true
                )
            }
            let server: TCPServer?
            if options.lanEnabled {
                try activeTerminationSignalMonitor?.throwIfSignaled()
                let lanServer = try TCPServer(
                    host: options.host,
                    port: options.port,
                    bonjourName: options.bonjourName,
                    authToken: options.authToken,
                    logger: logger
                )
                try serviceLifetime.installAndStart(server: lanServer)
                try activeTerminationSignalMonitor?.throwIfSignaled()
                try serviceLifetime.requireValid()
                server = lanServer
            } else {
                server = nil
                logger.info("Legacy LAN audio and screen listeners are disabled")
            }

            let screenService: ScreenVideoService?
            if options.lanEnabled, options.screenEnabled {
                if options.authToken == nil {
                    logger.info(
                        "SECURITY: screen video is unauthenticated and plaintext; " +
                        "use only on a trusted LAN or set MCAP_TOKEN"
                    )
                }
                let service = try ScreenVideoService(
                    host: options.host,
                    port: options.screenPort,
                    bonjourName: options.bonjourName,
                    authToken: options.authToken,
                    displayID: displaySelection.screenDisplayID,
                    displayRequirement: screenDisplayRequirement,
                    maximumWidth: options.screenMaximumWidth,
                    framesPerSecond: options.screenFramesPerSecond,
                    bitrate: options.screenBitrate,
                    makeCaptureStopWatchdog: {
                        virtualDisplayTeardownDeadline?.makeNativeCaptureWatchdog()
                    },
                    logger: logger
                )
                try serviceLifetime.installAndStart(screenService: service)
                try activeTerminationSignalMonitor?.throwIfSignaled()
                try serviceLifetime.requireValid()
                screenService = service
            } else {
                screenService = nil
            }

            let worldwideHostCoordinator: WorldwideHostCoordinator?
            if options.worldwideEnabled,
               let rendezvousURL = options.rendezvousURL,
               let worldwideHostProcessLock {
                let remoteInputController = MacRemoteInputController(
                    allowRemoteControl: options.allowRemoteControl
                )
                if options.allowRemoteControl {
                    let permission = remoteInputController.permissionStatus(promptIfNeeded: true)
                    if permission.isAuthorized {
                        logger.info("Worldwide remote input is enabled")
                    } else {
                        logger.info(
                            "Worldwide remote input was requested but remains view-only until " +
                            "Accessibility and event-posting permissions are granted"
                        )
                    }
                }
                let coordinator = WorldwideHostCoordinator(
                    endpoint: rendezvousURL,
                    forceRelay: options.forceRelay,
                    screenDisplayID: displaySelection.screenDisplayID,
                    screenDisplayRequirement: screenDisplayRequirement,
                    systemAudioDisplayID: displaySelection.systemAudioDisplayID,
                    maximumWidth: options.screenMaximumWidth,
                    framesPerSecond: options.screenFramesPerSecond,
                    maximumVideoBitrate: Int(options.screenBitrate),
                    remoteInputController: remoteInputController,
                    captureLifetime: virtualDisplayOwner == nil ? nil : serviceLifetime,
                    iPhoneMicrophoneForwardingPolicy:
                        options.iPhoneMicrophoneForwardingPolicy,
                    store: WorldwidePairingStore(
                        dataStore: WorldwideKeychainDataStore()
                    ),
                    availabilityMarkerProcessIdentifier:
                        ProcessInfo.processInfo.processIdentifier,
                    availabilityMarkerGenerationNonce:
                        worldwideHostProcessLock.generationNonce,
                    connectionTelemetry: LocalConnectionTelemetryJournal.applicationSupport(
                        component: "mac-host"
                    ),
                    teardownDidBegin: {
                        terminalCleanupDeadline?.arm()
                    },
                    makeMediaServiceTeardownWatchdog: {
                        virtualDisplayTeardownDeadline?.makeMediaServiceWatchdog()
                    },
                    makeNativeCaptureWatchdog: {
                        virtualDisplayTeardownDeadline?.makeNativeCaptureWatchdog()
                    },
                    logger: logger
                )
                try serviceLifetime.install(
                    worldwideCoordinator: coordinator,
                    remoteInputController: remoteInputController
                )
                try activeTerminationSignalMonitor?.throwIfSignaled()
                let resetWorldwidePairing = options.resetWorldwidePairing
                let startResult = try await runUntilProcessTermination(
                    terminationSignals: activeTerminationSignalMonitor?.events
                ) {
                    try await coordinator.start(resetPairing: resetWorldwidePairing)
                }
                try activeTerminationSignalMonitor?.throwIfSignaled()
                try serviceLifetime.requireValid()
                worldwideHostCoordinator = coordinator

                switch startResult {
                case .invitation(let invitationCode):
                    // This is the sole intentional presentation of the pairing capability.
                    // Routine diagnostics must never repeat it or include derived channels.
                    print("")
                    print("Worldwide one-time pairing code")
                    print("-------------------------------")
                    print(invitationCode)
                    print("Enter this code on the iPhone before it expires.")
                    print("")
                    fflush(stdout)
                case .paired:
                    logger.info("Worldwide host is available for the paired iPhone")
                }
            } else {
                worldwideHostCoordinator = nil
            }

            let monitor: Task<Void, Never>?
            if let server {
                monitor = Task {
                    await monitorServer(server: server, screenService: screenService, logger: logger)
                }
            } else {
                monitor = nil
            }

            let terminationSignalMonitor = activeTerminationSignalMonitor
            let report: StreamingCaptureReport?
            do {
                try terminationSignalMonitor?.throwIfSignaled()
                report = try await runUntilVirtualDisplayInvalidation(
                    events: virtualDisplayInvalidationEvents
                ) {
                    if let server {
                        if let worldwideHostCoordinator {
                            let duration = options.duration
                            let displayID = options.displayID
                            let captureMode = options.captureMode
                            return try await runCoexistingLANAndWorldwide(
                                coordinator: worldwideHostCoordinator,
                                terminationSignals: terminationSignalMonitor?.events
                            ) {
                                try await StreamingCaptureManager(
                                    duration: duration,
                                    displayID: displayID,
                                    captureMode: captureMode,
                                    sink: server,
                                    teardownDidBegin: {
                                        terminalCleanupDeadline?.arm()
                                    },
                                    makeCaptureStopWatchdog: {
                                        virtualDisplayTeardownDeadline?.makeNativeCaptureWatchdog()
                                    },
                                    logger: logger
                                ).run()
                            }
                        } else {
                            return try await runUntilProcessTermination(
                                terminationSignals: terminationSignalMonitor?.events
                            ) {
                                try await StreamingCaptureManager(
                                    duration: options.duration,
                                    displayID: options.displayID,
                                    captureMode: options.captureMode,
                                    sink: server,
                                    teardownDidBegin: {
                                        terminalCleanupDeadline?.arm()
                                    },
                                    makeCaptureStopWatchdog: {
                                        virtualDisplayTeardownDeadline?
                                            .makeNativeCaptureWatchdog()
                                    },
                                    logger: logger
                                ).run()
                            }
                        }
                    } else if let worldwideHostCoordinator,
                              let terminationSignalMonitor {
                        try await waitForWorldwideHost(
                            worldwideHostCoordinator,
                            duration: options.duration,
                            terminationSignals: terminationSignalMonitor.events
                        )
                        return nil
                    } else {
                        throw CaptureServerMainError.noEnabledService
                    }
                }
                try terminationSignalMonitor?.throwIfSignaled()
                try serviceLifetime.requireValid()
            } catch {
                monitor?.cancel()
                activeVirtualDisplayTeardownDeadline?.arm()
                activeProcessCleanupDeadline?.arm()
                let shutdownConfirmation = await serviceLifetime.shutdown()
                guard shutdownConfirmation.allNativeCapturesAreConfirmed else {
                    if StreamingCaptureManager.hasUnconfirmedNativeScreenCaptureStop(error) {
                        throw error
                    }
                    throw CaptureServerMainError.nativeCaptureTeardownUnconfirmed
                }
                throw error
            }
            monitor?.cancel()
            activeVirtualDisplayTeardownDeadline?.arm()
            activeProcessCleanupDeadline?.arm()
            let shutdownConfirmation = await serviceLifetime.shutdown()
            guard shutdownConfirmation.allNativeCapturesAreConfirmed else {
                throw CaptureServerMainError.nativeCaptureTeardownUnconfirmed
            }
            if let report, let server {
                print(report.render())
                let snapshot = server.snapshot()
                print("")
                print("Server report")
                print("-------------")
                print("Connected clients: \(snapshot.connectedClients)")
                print("Reconnects: \(snapshot.reconnects)")
                print("Packets sent: \(snapshot.packetsSent)")
                print("Bytes sent: \(snapshot.bytesSent)")
            }
            if let screenService {
                let screenSnapshot = screenService.snapshot()
                print("")
                print("Screen video report")
                print("-------------------")
                print("Connected viewers: \(screenSnapshot.connectedClients)")
                print("Viewer reconnects: \(screenSnapshot.reconnects)")
                print("Frames sent: \(screenSnapshot.framesSent)")
                print("Bytes sent: \(screenSnapshot.bytesSent)")
            }
            virtualDisplayLifetimeTask?.cancel()
            await virtualDisplayLifetimeTask?.value
            guard virtualDisplayOwner?.close() != false else {
                throw CaptureServerMainError.virtualDisplayTeardownTimedOut
            }
            await activeVirtualDisplayTeardownDeadline?.cancel()
            activeVirtualDisplayTeardownDeadline = nil
            await activeProcessCleanupDeadline?.cancel()
            activeProcessCleanupDeadline = nil
            if let signalNumber = activeTerminationSignalMonitor?
                .cancelAndReturnPendingSignal() {
                activeTerminationSignalMonitor = nil
                throw ProcessTerminationRequest(signalNumber: signalNumber)
            }
            activeTerminationSignalMonitor = nil
            worldwideHostProcessLock?.release()
            worldwideHostProcessLock = nil
        } catch {
            var requestedSignalNumber =
                (error as? ProcessTerminationRequest)?.signalNumber
            activeVirtualDisplayTeardownDeadline?.arm()
            activeProcessCleanupDeadline?.arm()
            let shutdownConfirmation: CaptureServiceShutdownConfirmation
            if let activeServiceLifetime {
                shutdownConfirmation = await activeServiceLifetime.shutdown()
            } else {
                shutdownConfirmation = .confirmed
            }
            let lanAudioStopIsConfirmed =
                !StreamingCaptureManager.hasUnconfirmedNativeScreenCaptureStop(error)
            let mayRemoveVirtualDisplay = CaptureServerFatalExitPolicy
                .mayRemoveVirtualDisplay(
                    shutdownConfirmation: shutdownConfirmation,
                    lanAudioStopIsConfirmed: lanAudioStopIsConfirmed
                )
            var virtualDisplayRemovalIsConfirmed = false
            if mayRemoveVirtualDisplay {
                activeVirtualDisplayLifetimeTask?.cancel()
                await activeVirtualDisplayLifetimeTask?.value
                if let virtualDisplayOwner {
                    virtualDisplayRemovalIsConfirmed = virtualDisplayOwner.close()
                } else if let attemptedVirtualDisplayConfiguration {
                    // A private initializer may create and reject a display before Swift receives
                    // an owner. Prove restoration independently before treating nil as harmless.
                    virtualDisplayRemovalIsConfirmed =
                        HeadlessDesktopReplacement.waitUntilRestored(
                            afterRetiring: attemptedVirtualDisplayConfiguration
                        )
                } else {
                    virtualDisplayRemovalIsConfirmed = true
                }
                if virtualDisplayRemovalIsConfirmed {
                    await activeVirtualDisplayTeardownDeadline?.cancel()
                    activeVirtualDisplayTeardownDeadline = nil
                } else {
                    fputs("error: virtual display teardown timed out\n", stderr)
                }
            } else {
                fputs("error: native capture teardown remained unconfirmed\n", stderr)
            }
            let fullCleanupIsConfirmed = mayRemoveVirtualDisplay
                && virtualDisplayRemovalIsConfirmed
            if fullCleanupIsConfirmed {
                await activeProcessCleanupDeadline?.cancel()
                activeProcessCleanupDeadline = nil
            }
            if ProcessTerminationSignalPolicy.mayRestoreDefaultHandling(
                fullCleanupIsConfirmed: fullCleanupIsConfirmed
            ) {
                let bufferedSignalNumber = activeTerminationSignalMonitor?
                    .cancelAndReturnPendingSignal()
                requestedSignalNumber = requestedSignalNumber ?? bufferedSignalNumber
                activeTerminationSignalMonitor = nil
            }
            if let requestedSignalNumber, fullCleanupIsConfirmed {
                withExtendedLifetime(worldwideHostProcessLock) {
                    Darwin.signal(requestedSignalNumber, SIG_DFL)
                    Darwin.raise(requestedSignalNumber)
                    Darwin._exit(128 + requestedSignalNumber)
                }
            }
            fputs("error: \(error.localizedDescription)\n", stderr)
            // Every fatal path deliberately keeps the exclusive lock descriptor open until
            // process exit. This also covers a private-runtime initializer that created a display
            // but could not prove its rejected instance retired before throwing.
            withExtendedLifetime(error) {
                withExtendedLifetime(worldwideHostProcessLock) {
                    withExtendedLifetime(activeServiceLifetime) {
                        withExtendedLifetime(virtualDisplayOwner) {
                            withExtendedLifetime(activeTerminationSignalMonitor) {
                                withExtendedLifetime(activeProcessCleanupDeadline) {
                                    exit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Races cancellable startup/LAN work against the monitor installed before display creation.
    /// Every child is drained so cancellation cannot hide an owner-bearing native-stop error.
    static func runUntilProcessTermination<Output: Sendable>(
        terminationSignals: AsyncStream<Int32>?,
        operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        guard let terminationSignals else {
            return try await operation()
        }
        return try await withThrowingTaskGroup(
            of: ProcessTerminationSupervisedRunOutcome<Output>.self
        ) { group in
            group.addTask {
                do {
                    return .operationFinished(try await operation())
                } catch {
                    return .operationFailed(.init(error))
                }
            }
            group.addTask {
                for await signalNumber in terminationSignals {
                    guard !Task.isCancelled else {
                        return .terminationMonitorEnded
                    }
                    return .terminationSignal(signalNumber)
                }
                return .terminationMonitorEnded
            }

            guard let firstOutcome = try await group.next() else {
                throw CaptureServerMainError.terminationSignalMonitorEnded
            }
            group.cancelAll()
            var outcomes = [firstOutcome]
            while let outcome = try await group.next() {
                outcomes.append(outcome)
            }
            if let retainedStopError = outcomes.compactMap(\.error).first(where: {
                StreamingCaptureManager.hasUnconfirmedNativeScreenCaptureStop($0)
            }) {
                throw retainedStopError
            }
            if let signalNumber = outcomes.compactMap(\.signalNumber).first {
                throw ProcessTerminationRequest(signalNumber: signalNumber)
            }

            switch firstOutcome {
            case .operationFinished(let output):
                return output
            case .operationFailed(let error):
                throw error.underlying
            case .terminationSignal(let signalNumber):
                throw ProcessTerminationRequest(signalNumber: signalNumber)
            case .terminationMonitorEnded:
                throw CaptureServerMainError.terminationSignalMonitorEnded
            }
        }
    }

    /// Races an indefinite service loop against the owned display's buffered failure signal.
    static func runUntilVirtualDisplayInvalidation(
        events: AsyncStream<Void>?,
        operation: @escaping @Sendable () async throws -> StreamingCaptureReport?
    ) async throws -> StreamingCaptureReport? {
        guard let events else { return try await operation() }
        return try await withThrowingTaskGroup(
            of: VirtualDisplaySupervisedRunOutcome.self
        ) { group in
            group.addTask {
                do {
                    return .operationFinished(try await operation())
                } catch {
                    return .operationFailed(.init(error))
                }
            }
            group.addTask {
                for await _ in events {
                    return .displayInvalid
                }
                return .displayInvalid
            }
            guard let firstOutcome = try await group.next() else {
                throw VirtualDisplayLifetimeError.displayInvalid
            }
            group.cancelAll()
            var outcomes = [firstOutcome]
            while let outcome = try await group.next() {
                outcomes.append(outcome)
            }
            if let retainedStopError = outcomes.compactMap(\.error).first(where: {
                StreamingCaptureManager.hasUnconfirmedNativeScreenCaptureStop($0)
            }) {
                throw retainedStopError
            }

            switch firstOutcome {
            case .operationFinished(let report):
                return report
            case .operationFailed(let error):
                throw error.underlying
            case .displayInvalid:
                throw VirtualDisplayLifetimeError.displayInvalid
            }
        }
    }

    /// Races legacy LAN capture against the supervised worldwide host. If worldwide availability
    /// terminates first, the LAN task is cancelled and the error reaches `main`, allowing launchd
    /// to replace the otherwise-live process instead of leaving half of coexistence mode wedged.
    static func runCoexistingLANAndWorldwide(
        coordinator: WorldwideHostCoordinator,
        terminationSignals: AsyncStream<Int32>? = nil,
        runLAN: @escaping @Sendable () async throws -> StreamingCaptureReport
    ) async throws -> StreamingCaptureReport {
        try await withThrowingTaskGroup(of: CoexistenceOutcome.self) { group in
            group.addTask {
                do {
                    return .lanFinished(try await runLAN())
                } catch {
                    return .lanFailed(.init(error))
                }
            }
            if let terminationSignals {
                group.addTask {
                    for await signalNumber in terminationSignals {
                        guard !Task.isCancelled else {
                            return .terminationMonitorEnded
                        }
                        return .terminationSignal(signalNumber)
                    }
                    return .terminationMonitorEnded
                }
            }
            group.addTask {
                do {
                    for try await _ in coordinator.completion {}
                    return .worldwideEnded
                } catch {
                    return .worldwideFailed(.init(error))
                }
            }
            guard let firstOutcome = try await group.next() else {
                throw CaptureServerMainError.worldwideHostEndedDuringLAN
            }
            group.cancelAll()
            var outcomes = [firstOutcome]
            while let outcome = try await group.next() {
                outcomes.append(outcome)
            }
            if let retainedStopError = outcomes.compactMap(\.error).first(where: {
                StreamingCaptureManager.hasUnconfirmedNativeScreenCaptureStop($0)
            }) {
                throw retainedStopError
            }

            switch firstOutcome {
            case .lanFinished(let report):
                return report
            case .lanFailed(let error), .worldwideFailed(let error):
                throw error.underlying
            case .worldwideEnded:
                throw CaptureServerMainError.worldwideHostEndedDuringLAN
            case .terminationSignal(let signalNumber):
                throw ProcessTerminationRequest(signalNumber: signalNumber)
            case .terminationMonitorEnded:
                throw CaptureServerMainError.terminationSignalMonitorEnded
            }
        }
    }

    /// Races coordinator failure, process termination, and an optional bounded duration.
    private static func waitForWorldwideHost(
        _ coordinator: WorldwideHostCoordinator,
        duration: TimeInterval?,
        terminationSignals: AsyncStream<Int32>
    ) async throws {
        try await withThrowingTaskGroup(of: WorldwideHostWaitOutcome.self) { group in
            group.addTask {
                for try await _ in coordinator.completion {
                    return .coordinatorEnded
                }
                return .coordinatorEnded
            }
            group.addTask {
                for await signalNumber in terminationSignals {
                    try Task.checkCancellation()
                    return .terminationSignal(signalNumber)
                }
                return .terminationMonitorEnded
            }
            if let duration {
                group.addTask {
                    try await Task.sleep(for: .seconds(duration))
                    return .durationElapsed
                }
            }

            guard let outcome = try await group.next() else {
                throw CaptureServerMainError.terminationSignalMonitorEnded
            }
            group.cancelAll()
            switch outcome {
            case .terminationSignal(let signalNumber):
                throw ProcessTerminationRequest(signalNumber: signalNumber)
            case .terminationMonitorEnded:
                throw CaptureServerMainError.terminationSignalMonitorEnded
            case .coordinatorEnded, .durationElapsed:
                return
            }
        }
    }

    /// Emits periodic transport snapshots until the enclosing server task is cancelled.
    private static func monitorServer(
        server: TCPServer,
        screenService: ScreenVideoService?,
        logger: Logger
    ) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let snapshot = server.snapshot()
                logger.info(
                    "clients=\(snapshot.connectedClients) " +
                    "queued=\(snapshot.queuedPackets) " +
                    "packetsSent=\(snapshot.packetsSent) " +
                    "bytesSent=\(snapshot.bytesSent) " +
                    "reconnects=\(snapshot.reconnects)"
                )
                if let screenService {
                    let video = screenService.snapshot()
                    logger.info(
                        "screenClients=\(video.connectedClients) " +
                        "screenQueued=\(video.queuedPackets) " +
                        "screenFrames=\(video.framesSent) " +
                        "screenBytes=\(video.bytesSent) " +
                        "screenAwaitingAck=\(video.framesAwaitingAcknowledgement)"
                    )
                }
            } catch {
                return
            }
        }
    }
}

/// First terminal condition observed while running worldwide-only mode.
private enum WorldwideHostWaitOutcome: Equatable {
    case coordinatorEnded
    case durationElapsed
    case terminationSignal(Int32)
    case terminationMonitorEnded
}

/// Competing result when trusted-LAN and worldwide modes share a process.
private enum CoexistenceOutcome: Sendable {
    case lanFinished(StreamingCaptureReport)
    case lanFailed(UncheckedSendableCaptureError)
    case worldwideEnded
    case worldwideFailed(UncheckedSendableCaptureError)
    case terminationSignal(Int32)
    case terminationMonitorEnded

    var error: (any Error)? {
        switch self {
        case .lanFailed(let error), .worldwideFailed(let error):
            error.underlying
        case .lanFinished, .worldwideEnded, .terminationSignal,
             .terminationMonitorEnded:
            nil
        }
    }
}

/// Competing terminal conditions while startup or a LAN-only run owns mutable display state.
private enum ProcessTerminationSupervisedRunOutcome<Output: Sendable>: Sendable {
    case operationFinished(Output)
    case operationFailed(UncheckedSendableCaptureError)
    case terminationSignal(Int32)
    case terminationMonitorEnded

    var error: (any Error)? {
        if case .operationFailed(let error) = self {
            error.underlying
        } else {
            nil
        }
    }

    var signalNumber: Int32? {
        if case .terminationSignal(let signalNumber) = self {
            signalNumber
        } else {
            nil
        }
    }
}

/// Competing terminal condition for a long-running service with an owned virtual display.
private enum VirtualDisplaySupervisedRunOutcome: Sendable {
    case operationFinished(StreamingCaptureReport?)
    case operationFailed(UncheckedSendableCaptureError)
    case displayInvalid

    var error: (any Error)? {
        if case .operationFailed(let error) = self {
            error.underlying
        } else {
            nil
        }
    }
}

/// Task-group errors stay on the same actor/process and are inspected only after every child has
/// been drained. The unchecked wrapper prevents an existential `Error` from weakening Sendable
/// checking on the result enums while retaining the exact owner-bearing error instance.
private struct UncheckedSendableCaptureError: @unchecked Sendable {
    let underlying: any Error

    init(_ underlying: any Error) {
        self.underlying = underlying
    }
}

/// Carries a Unix termination request through full native/display cleanup before Main re-raises it.
struct ProcessTerminationRequest: LocalizedError, Sendable {
    let signalNumber: Int32

    var errorDescription: String? {
        "Process termination signal \(signalNumber) requested orderly shutdown."
    }
}

/// Fatal service-composition failures handled by the process entry point.
private enum CaptureServerMainError: LocalizedError {
    case noEnabledService
    case nativeCaptureTeardownUnconfirmed
    case virtualDisplayRequiresHeadlessDesktop
    case virtualDisplayTeardownTimedOut
    case worldwideHostEndedDuringLAN
    case terminationSignalMonitorEnded

    var errorDescription: String? {
        switch self {
        case .noEnabledService:
            "No capture service is enabled."
        case .nativeCaptureTeardownUnconfirmed:
            "Native capture did not confirm shutdown before process teardown."
        case .virtualDisplayRequiresHeadlessDesktop:
            "The adjustable display currently requires the sole Apple headless desktop."
        case .virtualDisplayTeardownTimedOut:
            "The adjustable display did not leave WindowServer before the teardown timeout."
        case .worldwideHostEndedDuringLAN:
            "Worldwide availability ended while the LAN capture service was still running."
        case .terminationSignalMonitorEnded:
            "The process termination signal monitor ended unexpectedly."
        }
    }
}
