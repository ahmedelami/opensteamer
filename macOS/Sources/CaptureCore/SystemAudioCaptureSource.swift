import AppKit
import AudioToolbox
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Negotiated format of the standalone native system-audio stream.
public struct SystemAudioCaptureFormat: Sendable, Equatable {
    public static let requiredSampleRate = 48_000
    public static let requiredChannelCount = 2

    public let displayID: UInt32
    public let sampleRate: Int
    public let channelCount: Int

    /// Creates the fixed format expected by the WebRTC audio pipeline.
    public init(displayID: UInt32) {
        self.displayID = displayID
        sampleRate = Self.requiredSampleRate
        channelCount = Self.requiredChannelCount
    }
}

/// Native identity of the viewer challenge under which a FaceTime duplex observation was sampled.
/// The random call epoch remains stable across nonce rotations for the same CallKit membership.
public struct SystemAudioMacFaceTimeActivityChallenge: Sendable, Equatable {
    public let sequence: UInt64
    public let nonce: UUID
    public let callEpochNonce: UUID

    public init(
        sequence: UInt64,
        nonce: UUID,
        callEpochNonce: UUID
    ) {
        self.sequence = sequence
        self.nonce = nonce
        self.callEpochNonce = callEpochNonce
    }
}

/// Privacy-minimal result of the native FaceTime epoch binder. A nonnil binding ID means an
/// authoritative zero baseline was followed by one exact duplex process for this challenge's call
/// epoch. Process identity never leaves CaptureCore.
public struct SystemAudioMacFaceTimeActivityObservation: Sendable, Equatable {
    public let challenge: SystemAudioMacFaceTimeActivityChallenge?
    public let observationSequence: UInt64
    public let causalBindingID: UUID?

    public init(
        challenge: SystemAudioMacFaceTimeActivityChallenge?,
        observationSequence: UInt64,
        causalBindingID: UUID?
    ) {
        self.challenge = challenge
        self.observationSequence = observationSequence
        self.causalBindingID = causalBindingID
    }

    public var isCausallyBoundActive: Bool {
        causalBindingID != nil
    }
}

/// Receives validated system-audio samples and terminal stream failures.
public protocol SystemAudioSampleConsumer: AnyObject, Sendable {
    /// Accepts one ready audio buffer on the source's sample queue.
    func consumeSystemAudioSample(_ sampleBuffer: CMSampleBuffer)
    /// Accepts one borrowed Core Audio callback buffer synchronously. The consumer must not retain
    /// the list or any contained data pointer after this method returns.
    func consumeSystemAudioFrames(
        _ audioBufferList: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription,
        frameCount: UInt32,
        presentationTime: CMTime
    )
    /// Reports a native stream stop that was not initiated by normal host shutdown.
    func systemAudioCaptureSource(
        _ source: SystemAudioCaptureSource,
        didStopWithErrorDescription errorDescription: String
    )
    /// Delivers an immediate activity transition and one fresh heartbeat per second while the
    /// exact Mac FaceTime audio process remains duplex. No process or participant identity leaves
    /// the host.
    func systemAudioCaptureSource(
        _ source: SystemAudioCaptureSource,
        didObserveMacFaceTimeActivity observation:
            SystemAudioMacFaceTimeActivityObservation
    )
}

/// Captures the Mac's mixed system output independently from screen-video visibility.
///
/// `stateLock` owns native stream identity and the start/stop state machine. It is
/// never held across `await`; continuations let concurrent stop calls wait without
/// blocking a native capture callback or cooperative executor thread.
public final class SystemAudioCaptureSource: @unchecked Sendable {
    private let displayID: UInt32?
    private let consumer: SystemAudioSampleConsumer
    private let logger: Logger
    private lazy var processTapSource =
        CoreAudioProcessTapSystemAudioSource(
            consumer: consumer,
            logger: logger,
            faceTimeDuplexActivityHandler: {
                [weak self] observation in
                self?.handleMacFaceTimeActivity(observation)
            }
        )
    private let sampleQueue = DispatchQueue(label: "opensteamer.SystemAudioCapture")
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var output: SystemAudioStreamOutput?
    private var processTapIsActive = false
    private var activeDisplayID: UInt32?
    private var feedbackRefreshGeneration: UInt64 = 0
    private var workspaceNotificationTokens: [NSObjectProtocol] = []
    private var isStarting = false
    private var cancellationRequested = false
    private var isStopping = false
    private var startCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private lazy var streamDelegate = SystemAudioStreamDelegate { [weak self] stream, message in
        self?.handleUnexpectedStop(of: stream, errorDescription: message)
    }

    /// Creates a source and begins observing iPhone Mirroring process changes.
    ///
    /// The observer keeps that application's audio excluded, preventing the remote
    /// stream from recapturing its own iPhone playback and forming a feedback loop.
    public init(
        displayID: UInt32?,
        consumer: SystemAudioSampleConsumer,
        logger: Logger
    ) {
        self.displayID = displayID
        self.consumer = consumer
        self.logger = logger
        installWorkspaceObservers()
    }

    deinit {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for token in workspaceNotificationTokens {
            notificationCenter.removeObserver(token)
        }
    }

    // MARK: - Capture lifecycle

    /// Starts one system-audio stream and returns its fixed receiver format.
    ///
    /// Concurrent starts fail with `alreadyRunning`. A stop requested during any
    /// suspension point wins and causes startup to fail with `startCancelled`.
    public func start() async throws -> SystemAudioCaptureFormat {
        guard stateLock.withLock({ () -> Bool in
            guard stream == nil,
                  !processTapIsActive,
                  !isStarting,
                  !isStopping else {
                return false
            }
            isStarting = true
            cancellationRequested = false
            return true
        }) else {
            throw SystemAudioCaptureError.alreadyRunning
        }
        defer { finishStarting() }

        if #available(macOS 14.2, *) {
            var didStartProcessTap = false
            do {
                try ensureStartWasNotCancelled()
                _ = try processTapSource.start()
                didStartProcessTap = true
                try ensureStartWasNotCancelled()
                let selectedDisplayID = displayID ?? CGMainDisplayID()
                let installed = stateLock.withLock { () -> Bool in
                    guard !cancellationRequested,
                          !processTapIsActive else {
                        return false
                    }
                    processTapIsActive = true
                    activeDisplayID = selectedDisplayID
                    feedbackRefreshGeneration &+= 1
                    return true
                }
                guard installed else {
                    throw SystemAudioCaptureError.startCancelled
                }
                return SystemAudioCaptureFormat(
                    displayID: selectedDisplayID
                )
            } catch {
                if didStartProcessTap {
                    stateLock.withLock {
                        processTapIsActive = false
                        activeDisplayID = nil
                        feedbackRefreshGeneration &+= 1
                    }
                    try? processTapSource.stop()
                }
                stateLock.withLock {
                    activeDisplayID = nil
                }
                throw error
            }
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            try ensureStartWasNotCancelled()
            let display = try selectDisplay(from: content.displays)
            let format = SystemAudioCaptureFormat(displayID: display.displayID)

            let configuration = SystemAudioCaptureConfiguration.make()

            let excludedApplications = SystemAudioApplicationExclusionPolicy.excludedApplications(
                from: content.applications,
                bundleIdentifier: \.bundleIdentifier
            )
            if excludedApplications.isEmpty {
                logger.info("System audio feedback exclusion found no iPhone Mirroring process")
            } else {
                let processIDs = excludedApplications.map { String($0.processID) }.joined(
                    separator: ","
                )
                logger.info(
                    "System audio feedback exclusion active for iPhone Mirroring "
                        + "processes=\(processIDs)"
                )
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
            let output = SystemAudioStreamOutput(consumer: consumer)
            let stream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: streamDelegate
            )
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)

            let installed = stateLock.withLock { () -> Bool in
                guard !cancellationRequested else { return false }
                self.output = output
                self.stream = stream
                activeDisplayID = format.displayID
                return true
            }
            guard installed else {
                try? stream.removeStreamOutput(output, type: .audio)
                throw SystemAudioCaptureError.startCancelled
            }

            logger.info(
                "Starting system audio capture from display \(display.displayID) at " +
                "\(format.sampleRate) Hz, \(format.channelCount) channels"
            )
            do {
                try ensureStartWasNotCancelled()
                try await stream.startCapture()
            } catch {
                let ownsCleanup = stateLock.withLock { () -> Bool in
                    if self.stream === stream {
                        self.stream = nil
                        self.output = nil
                        activeDisplayID = nil
                        return true
                    }
                    return false
                }
                if ownsCleanup {
                    try? stream.removeStreamOutput(output, type: .audio)
                }
                throw error
            }

            let cancelledAfterStart = stateLock.withLock {
                cancellationRequested || self.stream !== stream
            }
            guard !cancelledAfterStart else {
                // A concurrent stop owns an installed stream. An unexpected delegate stop has
                // already detached it. Never race either path with a second native stop here.
                throw SystemAudioCaptureError.startCancelled
            }
            await refreshFeedbackExclusion(
                for: stream,
                displayID: format.displayID,
                generation: stateLock.withLock { feedbackRefreshGeneration }
            )
            let cancelledAfterRefresh = stateLock.withLock {
                cancellationRequested || self.stream !== stream
            }
            guard !cancelledAfterRefresh else {
                throw SystemAudioCaptureError.startCancelled
            }
            return format
        } catch {
            throw error
        }
    }

    /// Stops the native stream exactly once and releases its output registration.
    ///
    /// Concurrent callers join the in-progress stop and observe completion rather
    /// than issuing multiple `SCStream.stopCapture()` calls.
    public func stop() async throws {
        let ownsStop = stateLock.withLock { () -> Bool in
            cancellationRequested = true
            guard !isStopping else { return false }
            isStopping = true
            return true
        }
        guard ownsStop else {
            await waitForStopToFinish()
            return
        }

        await waitForStartToFinish()
        if #available(macOS 14.2, *) {
            let shouldStopProcessTap = stateLock.withLock { () -> Bool in
                guard processTapIsActive else { return false }
                processTapIsActive = false
                activeDisplayID = nil
                feedbackRefreshGeneration &+= 1
                return true
            }
            defer { finishStopping() }
            if shouldStopProcessTap {
                try processTapSource.stop()
            }
            return
        }
        let stopped = stateLock.withLock { () -> (SCStream, SystemAudioStreamOutput?)? in
            guard let stream else { return nil }
            let output = self.output
            self.stream = nil
            self.output = nil
            activeDisplayID = nil
            feedbackRefreshGeneration &+= 1
            return (stream, output)
        }
        guard let (stream, output) = stopped else {
            finishStopping()
            return
        }
        logger.info("Stopping system audio capture")
        defer {
            if let output {
                try? stream.removeStreamOutput(output, type: .audio)
            }
            finishStopping()
        }
        try await stream.stopCapture()
    }

    /// Suspends a stop caller until the current startup path reaches its defer.
    private func waitForStartToFinish() async {
        await withCheckedContinuation { continuation in
            let shouldResume = stateLock.withLock { () -> Bool in
                guard isStarting else { return true }
                startCompletionWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    /// Clears start ownership and resumes every stop waiter outside the lock.
    private func finishStarting() {
        let waiters = stateLock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard isStarting else { return [] }
            isStarting = false
            let waiters = startCompletionWaiters
            startCompletionWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    /// Suspends a non-owning stop caller until the native stop completes.
    private func waitForStopToFinish() async {
        await withCheckedContinuation { continuation in
            let shouldResume = stateLock.withLock { () -> Bool in
                guard isStopping else { return true }
                stopCompletionWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    /// Clears stop ownership and resumes all callers waiting for idempotent shutdown.
    private func finishStopping() {
        let waiters = stateLock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard isStopping else { return [] }
            isStopping = false
            let waiters = stopCompletionWaiters
            stopCompletionWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    /// Checks the lock-protected cancellation latch after asynchronous startup work.
    private func ensureStartWasNotCancelled() throws {
        guard stateLock.withLock({ !cancellationRequested }) else {
            throw SystemAudioCaptureError.startCancelled
        }
    }

    /// Detaches only the currently owned stream before reporting a native failure.
    private func handleUnexpectedStop(of stoppedStream: SCStream, errorDescription: String) {
        let shouldReport = stateLock.withLock { () -> Bool in
            guard !isStopping, stream === stoppedStream else { return false }
            stream = nil
            output = nil
            activeDisplayID = nil
            feedbackRefreshGeneration &+= 1
            return true
        }
        guard shouldReport else { return }
        consumer.systemAudioCaptureSource(
            self,
            didStopWithErrorDescription: errorDescription
        )
    }

    /// Publishes evidence only while this wrapper still owns the live process-tap backend.
    private func handleMacFaceTimeActivity(
        _ observation: SystemAudioMacFaceTimeActivityObservation
    ) {
        guard stateLock.withLock({
            processTapIsActive && !isStopping
        }) else {
            return
        }
        consumer.systemAudioCaptureSource(
            self,
            didObserveMacFaceTimeActivity: observation
        )
    }

    /// Installs a viewer challenge only on the live process-tap backend. The backend serializes a
    /// fresh native scan after the full challenge installation and stamps its result before
    /// returning it.
    @discardableResult
    public func installMacFaceTimeActivityChallenge(
        _ challenge: SystemAudioMacFaceTimeActivityChallenge
    ) -> Bool {
        guard stateLock.withLock({
            processTapIsActive && !isStopping
        }) else {
            return false
        }
        processTapSource.installFaceTimeActivityChallenge(challenge)
        return true
    }

    /// Resolves an explicit display or prefers the current main display.
    private func selectDisplay(from displays: [SCDisplay]) throws -> SCDisplay {
        guard !displays.isEmpty else {
            throw SystemAudioCaptureError.noDisplays
        }

        if let displayID {
            guard let display = displays.first(where: { $0.displayID == displayID }) else {
                throw SystemAudioCaptureError.displayNotFound(displayID)
            }
            return display
        }

        return displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? displays[0]
    }

    // MARK: - Feedback exclusion

    /// Observes only launches and terminations that can change the exclusion filter.
    private func installWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceNotificationTokens = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ].map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let application = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey
                ] as? NSRunningApplication else {
                    return
                }
                self?.applicationLifecycleChanged(
                    bundleIdentifier: application.bundleIdentifier
                )
            }
        }
    }

    /// Starts a generation-tagged refresh when iPhone Mirroring changes lifecycle.
    private func applicationLifecycleChanged(bundleIdentifier: String?) {
        guard SystemAudioApplicationExclusionPolicy.requiresFilterRefresh(
            bundleIdentifier: bundleIdentifier
        ) else {
            return
        }
        if #available(macOS 14.2, *) {
            let processTapGeneration = stateLock.withLock { () -> UInt64? in
                guard processTapIsActive, !isStopping else { return nil }
                feedbackRefreshGeneration &+= 1
                return feedbackRefreshGeneration
            }
            if let processTapGeneration {
                sampleQueue.async { [weak self] in
                    self?.refreshProcessTapExclusion(
                        generation: processTapGeneration
                    )
                }
                return
            }
        }

        let refresh = stateLock.withLock { () -> (SCStream, UInt32, UInt64)? in
            guard let stream, let activeDisplayID, !isStopping else { return nil }
            feedbackRefreshGeneration &+= 1
            return (stream, activeDisplayID, feedbackRefreshGeneration)
        }
        guard let (stream, displayID, generation) = refresh else { return }
        Task { [weak self] in
            await self?.refreshFeedbackExclusion(
                for: stream,
                displayID: displayID,
                generation: generation
            )
        }
    }

    /// Applies a PID refresh only while the same process-tap generation remains active.
    @available(macOS 14.2, *)
    private func refreshProcessTapExclusion(generation: UInt64) {
        let isCurrent = stateLock.withLock {
            processTapIsActive
                && feedbackRefreshGeneration == generation
                && !isStopping
        }
        guard isCurrent else { return }

        do {
            try processTapSource.refreshExcludedProcesses()
        } catch {
            let shouldReport = stateLock.withLock {
                processTapIsActive
                    && feedbackRefreshGeneration == generation
                    && !isStopping
            }
            if shouldReport {
                logger.error(
                    "System audio process-tap exclusion refresh failed: "
                        + error.localizedDescription
                )
            }
        }
    }

    /// Updates the live filter only if its stream and refresh generation remain current.
    ///
    /// A stale asynchronous refresh is discarded, preventing an older application
    /// snapshot from overwriting a newer filter or touching a replacement stream.
    private func refreshFeedbackExclusion(
        for expectedStream: SCStream,
        displayID: UInt32,
        generation: UInt64
    ) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let display = content.displays.first(where: {
                $0.displayID == displayID
            }) else {
                throw SystemAudioCaptureError.displayNotFound(displayID)
            }
            let excludedApplications = SystemAudioApplicationExclusionPolicy.excludedApplications(
                from: content.applications,
                bundleIdentifier: \.bundleIdentifier
            )
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
            let isCurrent = stateLock.withLock {
                stream === expectedStream
                    && activeDisplayID == displayID
                    && feedbackRefreshGeneration == generation
                    && !isStopping
            }
            guard isCurrent else { return }

            try await expectedStream.updateContentFilter(filter)

            let processIDs = excludedApplications.map { String($0.processID) }
                .joined(separator: ",")
            logger.info(
                processIDs.isEmpty
                    ? "System audio feedback exclusion refreshed with no iPhone Mirroring process"
                    : "System audio feedback exclusion refreshed for iPhone Mirroring "
                        + "processes=\(processIDs)"
            )
        } catch {
            let isCurrent = stateLock.withLock {
                stream === expectedStream
                    && activeDisplayID == displayID
                    && feedbackRefreshGeneration == generation
                    && !isStopping
            }
            if isCurrent {
                logger.error(
                    "System audio feedback exclusion refresh failed: "
                        + error.localizedDescription
                )
            }
        }
    }
}

/// Identifies applications whose playback must not be recaptured as system audio.
enum SystemAudioApplicationExclusionPolicy {
    static let iPhoneMirroringBundleIdentifier = "com.apple.ScreenContinuity"
    static let captureServerBundleIdentifier =
        "com.elamin.AudioStreamer.CaptureServer"

    /// Stable bundle identities excluded by the global Core Audio tap. The explicit production
    /// host identity keeps tests and command-line wrappers from accidentally replacing it.
    static func excludedBundleIdentifiers(
        currentBundleIdentifier: String?
    ) -> [String] {
        var identifiers = Set([
            iPhoneMirroringBundleIdentifier,
            captureServerBundleIdentifier,
        ])
        if let currentBundleIdentifier,
           !currentBundleIdentifier.isEmpty {
            identifiers.insert(currentBundleIdentifier)
        }
        return identifiers.sorted()
    }

    /// Filters generic shareable-application values by bundle identifier.
    static func excludedApplications<Application>(
        from applications: [Application],
        bundleIdentifier: (Application) -> String?
    ) -> [Application] {
        applications.filter {
            bundleIdentifier($0) == iPhoneMirroringBundleIdentifier
        }
    }

    /// Determines whether an application lifecycle event affects the live filter.
    static func requiresFilterRefresh(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == iPhoneMirroringBundleIdentifier
    }
}

/// Builds the fixed, audio-focused ScreenCaptureKit configuration.
enum SystemAudioCaptureConfiguration {
    /// Returns a fresh configuration suitable for 48 kHz stereo system audio.
    static func make() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = SystemAudioCaptureFormat.requiredSampleRate
        configuration.channelCount = SystemAudioCaptureFormat.requiredChannelCount
        // No screen output is installed, but ScreenCaptureKit still requires valid dimensions.
        configuration.width = 2
        configuration.height = 2
        // Keep the unused video side of the stream on a normal cadence; an artificially slow
        // frame interval must never become a source of audio batching or added latency.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        return configuration
    }
}

/// Bridges ScreenCaptureKit's delegate callback to a Sendable failure closure.
private final class SystemAudioStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let didStop: @Sendable (SCStream, String) -> Void

    init(didStop: @escaping @Sendable (SCStream, String) -> Void) {
        self.didStop = didStop
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        didStop(stream, error.localizedDescription)
    }
}

/// Validates audio callbacks before forwarding them to the session consumer.
private final class SystemAudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let consumer: SystemAudioSampleConsumer

    init(consumer: SystemAudioSampleConsumer) {
        self.consumer = consumer
    }

    /// Drops non-audio, invalid, empty, or format-less buffers at the framework boundary.
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              CMSampleBufferGetFormatDescription(sampleBuffer) != nil else {
            return
        }
        consumer.consumeSystemAudioSample(sampleBuffer)
    }
}

/// Lifecycle and display-selection failures specific to system-audio capture.
public enum SystemAudioCaptureError: LocalizedError {
    case noDisplays
    case displayNotFound(UInt32)
    case alreadyRunning
    case startCancelled

    /// A user-facing explanation suitable for host status and diagnostics.
    public var errorDescription: String? {
        switch self {
        case .noDisplays:
            "ScreenCaptureKit did not report any displays for system audio capture"
        case .displayNotFound(let displayID):
            "ScreenCaptureKit did not find display \(displayID) for system audio capture"
        case .alreadyRunning:
            "System audio capture is already running"
        case .startCancelled:
            "System audio capture was cancelled before startup completed"
        }
    }
}
