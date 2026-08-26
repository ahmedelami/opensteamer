import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Dimensions and cadence negotiated for one display capture.
public struct ScreenVideoCaptureFormat: Sendable, Equatable {
    public let displayID: UInt32
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int
    /// Present for an OpenSteamer-owned display whose Core Graphics logical-to-pixel scale must
    /// be proved again by the first ScreenCaptureKit frame.
    public let expectedScaleFactor: Double?
    /// Expected scaling from the selected Core Graphics framebuffer into the configured surface.
    public let expectedContentScale: Double?
}

private struct ScreenVideoActiveSourceFormat {
    let dimensions: ScreenVideoPixelDimensions
    let expectedScaleFactor: Double?
}

/// Receives complete display frames and unexpected native stream failures.
public protocol ScreenVideoSampleConsumer: AnyObject, Sendable {
    /// Accepts one complete, image-backed screen sample on the capture queue.
    func consumeScreenVideoSample(_ sampleBuffer: CMSampleBuffer)
    /// Accepts the same sample together with its validated output-surface content geometry.
    /// Consumers that do not map remote input can keep the original sample-only implementation.
    func consumeScreenVideoSample(
        _ sampleBuffer: CMSampleBuffer,
        frameGeometry: ScreenVideoFrameGeometry?
    )
    /// Accepts the same sample while preserving absent-versus-invalid attachment semantics.
    func consumeScreenVideoSample(
        _ sampleBuffer: CMSampleBuffer,
        frameGeometryObservation: ScreenVideoFrameGeometryObservation
    )
    /// Reports that Core Graphics is about to reconfigure this source's display.
    func screenVideoCaptureSourceDisplayConfigurationWillChange(
        _ source: ScreenVideoCaptureSource
    )
    /// Reports that Core Graphics has settled a display reconfiguration for this source.
    func screenVideoCaptureSourceDisplayModeDidChange(
        _ source: ScreenVideoCaptureSource
    )
    /// Reports a stream stop that did not originate from normal session teardown.
    func screenVideoCaptureSource(
        _ source: ScreenVideoCaptureSource,
        didStopWithErrorDescription errorDescription: String
    )
}

public extension ScreenVideoSampleConsumer {
    func consumeScreenVideoSample(
        _ sampleBuffer: CMSampleBuffer,
        frameGeometryObservation: ScreenVideoFrameGeometryObservation
    ) {
        consumeScreenVideoSample(
            sampleBuffer,
            frameGeometry: frameGeometryObservation.geometry
        )
    }

    func consumeScreenVideoSample(
        _ sampleBuffer: CMSampleBuffer,
        frameGeometry _: ScreenVideoFrameGeometry?
    ) {
        consumeScreenVideoSample(sampleBuffer)
    }

    func screenVideoCaptureSourceDisplayModeDidChange(
        _: ScreenVideoCaptureSource
    ) {}

    func screenVideoCaptureSourceDisplayConfigurationWillChange(
        _: ScreenVideoCaptureSource
    ) {}
}

/// Bounds one native screen-capture lifecycle call without changing its error semantics.
///
/// The watchdog is supplied by the executable only while it owns the private virtual display.
/// A normal or promptly failed native call cancels and drains that watchdog before returning.
enum ScreenCaptureLifecycleWatchdog {
    static func perform<T>(
        makeWatchdog: @Sendable () -> Task<Void, Never>?,
        operation: () async throws -> T
    ) async throws -> T {
        let watchdog = makeWatchdog()
        do {
            let result = try await operation()
            watchdog?.cancel()
            await watchdog?.value
            return result
        } catch {
            watchdog?.cancel()
            await watchdog?.value
            throw error
        }
    }
}

/// Owns a video-only ScreenCaptureKit stream for the selected display.
///
/// `stateLock` protects stream identity and start/stop cancellation across Swift
/// concurrency and ScreenCaptureKit delegate callbacks. It is never held across an
/// `await`; framework samples are delivered on the dedicated `sampleQueue`.
public final class ScreenVideoCaptureSource: @unchecked Sendable {
    private enum SampleDeliveryPhase {
        case closed
        case opening
        case open
    }

    private let displayID: UInt32?
    private let displayRequirement: ScreenVideoDisplayRequirement?
    private let maximumWidth: Int
    private let framesPerSecond: Int
    private let consumer: ScreenVideoSampleConsumer
    private let displayModeSnapshotProvider: ScreenVideoDisplayModeSnapshotProvider
    private let makeStopWatchdog: @Sendable () -> Task<Void, Never>?
    private let logger: Logger
    private let sampleQueue = DispatchQueue(label: "opensteamer.ScreenVideoCapture")
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var output: ScreenVideoStreamOutput?
    private var displayModeObserver: ScreenVideoDisplayModeObserver?
    private var activeDisplayID: UInt32?
    private var sampleDeliveryPhase = SampleDeliveryPhase.closed
    private var displayModeChangedWhileOpeningDelivery = false
    private var isStarting = false
    private var cancellationRequested = false
    private var isStopping = false
    private var startCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private lazy var streamDelegate = ScreenVideoStreamDelegate { [weak self] stream, message in
        self?.handleUnexpectedStop(of: stream, errorDescription: message)
    }

    /// Creates a source with an aspect-preserving width cap and target cadence.
    public init(
        displayID: UInt32?,
        displayRequirement: ScreenVideoDisplayRequirement? = nil,
        maximumWidth: Int,
        framesPerSecond: Int,
        consumer: ScreenVideoSampleConsumer,
        displayModeSnapshotProvider: ScreenVideoDisplayModeSnapshotProvider? = nil,
        makeStopWatchdog: @escaping @Sendable () -> Task<Void, Never>? = { nil },
        logger: Logger
    ) {
        self.displayID = displayID
        self.displayRequirement = displayRequirement
        self.maximumWidth = maximumWidth
        self.framesPerSecond = framesPerSecond
        self.consumer = consumer
        self.displayModeSnapshotProvider = displayModeSnapshotProvider ?? { displayID in
            guard let mode = CGDisplayCopyDisplayMode(displayID) else {
                throw ScreenVideoCaptureError.displayModeUnavailable(displayID)
            }
            return ScreenVideoDisplayModeSnapshot(
                logicalDimensions: ScreenVideoPixelDimensions(
                    width: mode.width,
                    height: mode.height
                ),
                pixelDimensions: ScreenVideoPixelDimensions(
                    width: mode.pixelWidth,
                    height: mode.pixelHeight
                )
            )
        }
        self.makeStopWatchdog = makeStopWatchdog
        self.logger = logger
    }

    // MARK: - Capture lifecycle

    /// Resolves the display, installs a video output, and starts native capture.
    ///
    /// A concurrent `stop()` latches cancellation and prevents a partially started
    /// stream from becoming visible to the rest of the session.
    public func start() async throws -> ScreenVideoCaptureFormat {
        try await ScreenCaptureLifecycleWatchdog.perform(
            makeWatchdog: makeStopWatchdog,
            operation: {
                try await self.startWithoutStartupWatchdog()
            }
        )
    }

    /// Opens sample delivery only after the owning transport has installed its new format.
    /// The latest image-backed startup frame is replayed synchronously before live callbacks.
    public func beginSampleDelivery() throws {
        let resources = try stateLock.withLock { () -> (
            ScreenVideoStreamOutput,
            ScreenVideoDisplayModeObserver,
            UInt32
        ) in
            guard let output,
                  let displayModeObserver,
                  let activeDisplayID,
                  stream != nil,
                  !isStarting,
                  !isStopping,
                  !cancellationRequested else {
                throw ScreenVideoCaptureError.startCancelled
            }
            if sampleDeliveryPhase == .open {
                return (output, displayModeObserver, activeDisplayID)
            }
            guard sampleDeliveryPhase == .closed else {
                throw ScreenVideoCaptureError.alreadyRunning
            }
            sampleDeliveryPhase = .opening
            displayModeChangedWhileOpeningDelivery = false
            return (output, displayModeObserver, activeDisplayID)
        }

        guard resources.1.activate(), resources.1.commitActivation() else {
            throw ScreenVideoCaptureError.displayModeChangedDuringStart(resources.2)
        }

        let deliveryError = stateLock.withLock { () -> ScreenVideoCaptureError? in
            guard stream != nil,
                  self.output === resources.0,
                  self.displayModeObserver === resources.1,
                  activeDisplayID == resources.2,
                  !isStopping,
                  !cancellationRequested else {
                return .startCancelled
            }
            guard !displayModeChangedWhileOpeningDelivery else {
                return .displayModeChangedDuringStart(resources.2)
            }
            sampleDeliveryPhase = .open
            return nil
        }
        if let deliveryError {
            throw deliveryError
        }
        guard resources.0.beginDelivery() else {
            throw ScreenVideoCaptureError.startCancelled
        }
    }

    /// Runs one complete startup transaction under the caller's already-armed watchdog.
    private func startWithoutStartupWatchdog() async throws -> ScreenVideoCaptureFormat {
        guard stateLock.withLock({ () -> Bool in
            guard self.stream == nil, !isStarting, !isStopping else { return false }
            isStarting = true
            activeDisplayID = nil
            sampleDeliveryPhase = .closed
            displayModeChangedWhileOpeningDelivery = false
            cancellationRequested = false
            return true
        }) else {
            throw ScreenVideoCaptureError.alreadyRunning
        }
        defer { finishStarting() }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            try ensureStartWasNotCancelled()
            let display = try selectDisplay(from: content.displays)
            try validateDisplayRequirement(for: display.displayID)
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let sourceFormat = try await activeSourceFormat(for: display, filter: filter)
            let dimensions = try ScreenVideoOutputPolicy.outputDimensions(
                source: sourceFormat.dimensions,
                maximumWidth: maximumWidth
            )
            let format = ScreenVideoCaptureFormat(
                displayID: display.displayID,
                width: dimensions.width,
                height: dimensions.height,
                framesPerSecond: framesPerSecond,
                expectedScaleFactor: sourceFormat.expectedScaleFactor,
                expectedContentScale: sourceFormat.expectedScaleFactor.map { _ in
                    Double(dimensions.width) / Double(sourceFormat.dimensions.width)
                }
            )
            let displayModeObserver = try ScreenVideoDisplayModeObserver(
                displayID: display.displayID,
                willReconfigure: { [weak self] in
                    self?.handleDisplayConfigurationWillChange()
                }
            ) { [weak self] in
                self?.handleDisplayModeChange()
            }

            let configuration = SCStreamConfiguration()
            configuration.width = format.width
            configuration.height = format.height
            configuration.minimumFrameInterval = CMTime(
                value: 1,
                timescale: CMTimeScale(framesPerSecond)
            )
            // A short native queue absorbs jitter without adding visible interaction lag.
            configuration.queueDepth = 3
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
            configuration.colorSpaceName = CGColorSpace.itur_709
            configuration.showsCursor = true
            configuration.capturesAudio = false
            configuration.preservesAspectRatio = true
            configuration.captureResolution = .best

            let output = ScreenVideoStreamOutput(consumer: consumer)
            let stream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: streamDelegate
            )
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
            let installed = stateLock.withLock { () -> Bool in
                guard !cancellationRequested else {
                    return false
                }
                self.output = output
                self.stream = stream
                return true
            }
            guard installed else {
                output.revoke()
                try? stream.removeStreamOutput(output, type: .screen)
                throw ScreenVideoCaptureError.startCancelled
            }

            logger.info(
                "Starting screen video capture from display \(display.displayID) " +
                "at \(format.width)x\(format.height)@\(format.framesPerSecond)"
            )
            do {
                try ensureStartWasNotCancelled()
                try await stream.startCapture()
            } catch {
                try await recoverFromFailedStart(
                    stream: stream,
                    output: output,
                    startError: error
                )
            }

            do {
                try ensureStartWasNotCancelled()
                try validateDisplayRequirement(for: display.displayID)
                let postStartContent = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                let postStartDisplay = try selectDisplay(from: postStartContent.displays)
                guard postStartDisplay.displayID == display.displayID else {
                    throw ScreenVideoCaptureError.displayModeChangedDuringStart(display.displayID)
                }
                try validateDisplayRequirement(for: postStartDisplay.displayID)
                let postStartFilter = SCContentFilter(
                    display: postStartDisplay,
                    excludingWindows: []
                )
                let postStartSourceFormat = try await activeSourceFormat(
                    for: postStartDisplay,
                    filter: postStartFilter
                )
                guard ScreenVideoSourceDimensionPolicy.isStableAcrossStart(
                    before: sourceFormat.dimensions,
                    after: postStartSourceFormat.dimensions
                ), sourceFormat.expectedScaleFactor == postStartSourceFormat.expectedScaleFactor else {
                    throw ScreenVideoCaptureError.displayModeChangedDuringStart(
                        display.displayID
                    )
                }

                let observerInstalled = stateLock.withLock { () -> Bool in
                    guard !cancellationRequested,
                          self.stream === stream,
                          self.displayModeObserver == nil else {
                        return false
                    }
                    self.displayModeObserver = displayModeObserver
                    self.activeDisplayID = display.displayID
                    return true
                }
                guard observerInstalled else {
                    _ = displayModeObserver.stop()
                    throw ScreenVideoCaptureError.startCancelled
                }
            } catch {
                let validationError = error
                let ownsStop = stateLock.withLock { () -> Bool in
                    guard self.stream === stream, !isStopping else { return false }
                    isStopping = true
                    return true
                }
                if ownsStop {
                    do {
                        try await self.stopOwnedStreamWithoutWatchdog(
                            stream,
                            output: output
                        )
                    } catch {
                        // Keep the only native teardown handle attached after a failed stop so
                        // an explicit stop() can retry it.
                        throw error
                    }
                }
                throw validationError
            }

            let cancelledAfterStart = stateLock.withLock { () -> Bool in
                cancellationRequested || self.stream !== stream
            }
            guard !cancelledAfterStart else {
                // A concurrent stop owns teardown and is waiting for startup to leave this
                // method. Retain native ownership so it can stop the exact stream once.
                throw ScreenVideoCaptureError.startCancelled
            }
            return format
        } catch {
            throw error
        }
    }

    /// Stops the currently owned native stream exactly once.
    ///
    /// A stop requested during startup latches cancellation and waits for startup to finish.
    /// A concurrent stop joins the owning native stop, then retries only if that owner retained
    /// the stream after failure. No caller can report success while teardown remains in flight.
    public func stop() async throws {
        let ownsStop = stateLock.withLock { () -> Bool in
            cancellationRequested = true
            guard !isStopping else { return false }
            isStopping = true
            return true
        }
        guard ownsStop else {
            await waitForStopToFinish()
            return try await stop()
        }

        try await ScreenCaptureLifecycleWatchdog.perform(
            makeWatchdog: makeStopWatchdog,
            operation: {
                await self.waitForStartToFinish()
                let ownedStream = self.stateLock.withLock {
                    self.stream.map { ($0, self.output) }
                }
                guard let (stream, output) = ownedStream else {
                    self.finishStopping()
                    return
                }
                try await self.stopOwnedStreamWithoutWatchdog(stream, output: output)
            }
        )
    }

    /// Revokes sample delivery, then releases native ownership only after stop confirmation.
    /// The owning caller must already have armed its full-attempt watchdog.
    private func stopOwnedStreamWithoutWatchdog(
        _ stream: SCStream,
        output: ScreenVideoStreamOutput?
    ) async throws {
        logger.info("Stopping screen video capture")
        let displayModeObserver = stateLock.withLock { () -> ScreenVideoDisplayModeObserver? in
            guard self.stream === stream else { return nil }
            let observer = self.displayModeObserver
            self.displayModeObserver = nil
            sampleDeliveryPhase = .closed
            displayModeChangedWhileOpeningDelivery = false
            return observer
        }
        if case .removalFailed(let error) = displayModeObserver?.stop() {
            logger.error(
                "Could not remove the inert display-mode observer: " +
                "Core Graphics error \(error.rawValue)"
            )
        }
        let outputWasRemoved: Bool
        if let output {
            output.revoke()
            do {
                try stream.removeStreamOutput(output, type: .screen)
                outputWasRemoved = true
                stateLock.withLock {
                    if self.stream === stream, self.output === output {
                        self.output = nil
                    }
                }
            } catch {
                outputWasRemoved = false
            }
        } else {
            outputWasRemoved = true
        }

        defer { finishStopping() }
        do {
            try await stream.stopCapture()
        } catch {
            // Keep the SCStream and any output registration that could not be revoked. Clearing
            // `isStopping` in the defer makes this exact stream retryable.
            throw error
        }

        stateLock.withLock {
            if self.stream === stream {
                self.stream = nil
                self.output = nil
                activeDisplayID = nil
            }
        }
        if !outputWasRemoved, let output {
            try? stream.removeStreamOutput(output, type: .screen)
        }
    }

    /// Treats a prompt native start error as a potentially partial start. Two teardown attempts
    /// are permitted while the enclosing startup watchdog remains armed; repeated failure keeps
    /// the exact stream attached for the service-level stop/quarantine path.
    private func recoverFromFailedStart(
        stream: SCStream,
        output: ScreenVideoStreamOutput,
        startError: Error
    ) async throws -> Never {
        var stopFailureDescriptions: [String] = []
        for _ in 0..<2 {
            let ownsStop = stateLock.withLock { () -> Bool in
                guard self.stream === stream, !isStopping else { return false }
                isStopping = true
                return true
            }
            guard ownsStop else {
                // A concurrent stop already owns the installed stream and will run as soon as
                // this startup transaction leaves its `defer`.
                throw startError
            }

            var didStop = false
            do {
                try await stopOwnedStreamWithoutWatchdog(stream, output: output)
                didStop = true
            } catch {
                if stateLock.withLock({ self.stream == nil }) {
                    throw startError
                }
                stopFailureDescriptions.append(error.localizedDescription)
            }
            if didStop {
                throw startError
            }
        }
        throw ScreenVideoCaptureError.nativeStopUnconfirmed(
            stopFailureDescriptions.joined(separator: "; ")
        )
    }

    /// Suspends a stop owner until startup can no longer install a native stream.
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

    /// Joins the exact in-progress native stop without issuing a duplicate framework call.
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

    /// Clears start ownership and resumes every waiting stop owner outside the lock.
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

    /// Releases stop ownership so a retained stream can be retried after failure.
    private func finishStopping() {
        let waiters = stateLock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isStopping = false
            let waiters = stopCompletionWaiters
            stopCompletionWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    /// Checks the cancellation latch after asynchronous startup boundaries.
    private func ensureStartWasNotCancelled() throws {
        guard stateLock.withLock({ !cancellationRequested }) else {
            throw ScreenVideoCaptureError.startCancelled
        }
    }

    /// Reports only a failure belonging to the current, non-stopping stream.
    private func handleUnexpectedStop(of stoppedStream: SCStream, errorDescription: String) {
        let transition = stateLock.withLock { () -> (
            Bool,
            ScreenVideoStreamOutput?,
            ScreenVideoDisplayModeObserver?
        ) in
            guard !isStopping, stream === stoppedStream else {
                return (false, nil, nil)
            }
            let retiredOutput = output
            let retiredDisplayModeObserver = displayModeObserver
            stream = nil
            output = nil
            displayModeObserver = nil
            activeDisplayID = nil
            sampleDeliveryPhase = .closed
            displayModeChangedWhileOpeningDelivery = false
            return (true, retiredOutput, retiredDisplayModeObserver)
        }
        transition.1?.revoke()
        _ = transition.2?.stop()
        guard transition.0 else { return }
        consumer.screenVideoCaptureSource(
            self,
            didStopWithErrorDescription: errorDescription
        )
    }

    /// Delivers only a pre-configuration event belonging to the current open source generation.
    private func handleDisplayConfigurationWillChange() {
        let shouldNotify = stateLock.withLock {
            guard stream != nil,
                  displayModeObserver != nil,
                  !isStopping,
                  !cancellationRequested else {
                return false
            }
            if sampleDeliveryPhase == .opening {
                displayModeChangedWhileOpeningDelivery = true
                return false
            }
            return sampleDeliveryPhase == .open
        }
        guard shouldNotify else { return }
        consumer.screenVideoCaptureSourceDisplayConfigurationWillChange(self)
    }

    /// Delivers only a settled event belonging to this source's current, non-stopping stream.
    private func handleDisplayModeChange() {
        let shouldNotify = stateLock.withLock {
            guard stream != nil,
                  displayModeObserver != nil,
                  !isStopping,
                  !cancellationRequested else {
                return false
            }
            if sampleDeliveryPhase == .opening {
                displayModeChangedWhileOpeningDelivery = true
                return false
            }
            return sampleDeliveryPhase == .open
        }
        guard shouldNotify else { return }
        consumer.screenVideoCaptureSourceDisplayModeDidChange(self)
    }

    /// Resolves an explicit display or prefers the current main display.
    private func selectDisplay(from displays: [SCDisplay]) throws -> SCDisplay {
        guard !displays.isEmpty else {
            throw ScreenVideoCaptureError.noDisplays
        }

        if let displayID {
            guard let display = displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenVideoCaptureError.displayNotFound(displayID)
            }
            return display
        }

        return displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? displays[0]
    }

    /// Re-proves an owned display's identity and topology around every native capture start.
    private func validateDisplayRequirement(for selectedDisplayID: UInt32) throws {
        guard let displayRequirement else { return }
        guard displayID == selectedDisplayID else {
            throw ScreenVideoCaptureError.displayIdentityMismatch(selectedDisplayID)
        }

        // Two slots are sufficient to disprove the required sole-display topology and avoid a
        // count/allocation race if a physical display appears during this snapshot.
        var onlineDisplayIDs = [CGDirectDisplayID](
            repeating: kCGNullDirectDisplay,
            count: 2
        )
        var onlineDisplayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(
            UInt32(onlineDisplayIDs.count),
            &onlineDisplayIDs,
            &onlineDisplayCount
        ) == .success else {
            throw ScreenVideoCaptureError.displayIdentityMismatch(selectedDisplayID)
        }
        onlineDisplayIDs.removeSubrange(
            min(Int(onlineDisplayCount), onlineDisplayIDs.count)..<onlineDisplayIDs.count
        )

        let snapshot = ScreenVideoDisplaySnapshot(
            displayID: selectedDisplayID,
            vendorID: CGDisplayVendorNumber(selectedDisplayID),
            productID: CGDisplayModelNumber(selectedDisplayID),
            serialNumber: CGDisplaySerialNumber(selectedDisplayID),
            isOnline: CGDisplayIsOnline(selectedDisplayID) != 0,
            isActive: CGDisplayIsActive(selectedDisplayID) != 0,
            mainDisplayID: CGMainDisplayID(),
            onlineDisplayIDs: onlineDisplayIDs
        )
        guard ScreenVideoDisplayRequirementPolicy.isSatisfied(
            displayRequirement,
            by: snapshot
        ) else {
            throw ScreenVideoCaptureError.displayIdentityMismatch(selectedDisplayID)
        }
    }

    /// Preserves ScreenCaptureKit's established logical sizing for ordinary displays while
    /// OpenSteamer virtual displays stream the active Retina framebuffer at full resolution.
    private func activeSourceFormat(
        for display: SCDisplay,
        filter: SCContentFilter
    ) async throws -> ScreenVideoActiveSourceFormat {
        let vendorID = CGDisplayVendorNumber(display.displayID)
        let productID = CGDisplayModelNumber(display.displayID)
        guard ScreenVideoSourceDimensionPolicy.dimensionKind(
            vendorID: vendorID,
            productID: productID
        ) == .framebufferPixels else {
            return ScreenVideoActiveSourceFormat(
                dimensions: ScreenVideoPixelDimensions(
                    width: display.width,
                    height: display.height
                ),
                expectedScaleFactor: nil
            )
        }
        let mode = try await displayModeSnapshotProvider(display.displayID)
        guard mode.logicalDimensions.width >= 2,
              mode.logicalDimensions.height >= 2,
              mode.pixelDimensions.width >= 2,
              mode.pixelDimensions.height >= 2 else {
            throw ScreenVideoCaptureError.displayModeUnavailable(display.displayID)
        }
        let sourceDimensions = ScreenVideoSourceDimensionPolicy.sourceDimensions(
            vendorID: vendorID,
            productID: productID,
            logicalDimensions: ScreenVideoPixelDimensions(
                width: display.width,
                height: display.height
            ),
            filterContentWidth: Double(filter.contentRect.width),
            filterContentHeight: Double(filter.contentRect.height),
            pointPixelScale: Double(filter.pointPixelScale),
            coreGraphicsLogicalDimensions: mode.logicalDimensions,
            coreGraphicsPixelDimensions: mode.pixelDimensions
        )
        guard let sourceDimensions else {
            // The logical display identity itself is unsettled. The service can tolerate stale
            // ScreenCaptureKit scale metadata, but never a disagreement about which display or
            // logical canvas is being captured.
            throw ScreenVideoCaptureError.displayModeChangedDuringStart(display.displayID)
        }
        let horizontalScale = Double(mode.pixelDimensions.width)
            / Double(mode.logicalDimensions.width)
        let verticalScale = Double(mode.pixelDimensions.height)
            / Double(mode.logicalDimensions.height)
        guard (1 ... 4).contains(horizontalScale),
              abs(horizontalScale - verticalScale) <= 0.005 else {
            throw ScreenVideoCaptureError.displayModeChangedDuringStart(display.displayID)
        }
        return ScreenVideoActiveSourceFormat(
            dimensions: sourceDimensions,
            expectedScaleFactor: horizontalScale
        )
    }
}

/// Bridges ScreenCaptureKit's delegate callback to a Sendable error closure.
private final class ScreenVideoStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let didStop: @Sendable (SCStream, String) -> Void

    init(didStop: @escaping @Sendable (SCStream, String) -> Void) {
        self.didStop = didStop
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        didStop(stream, error.localizedDescription)
    }
}

/// Pure startup-frame state used to replay exactly one fresh image after transport installation.
struct ScreenVideoInitialFrameDeliveryState: Equatable, Sendable {
    enum FrameAction: Equatable, Sendable {
        case storeLatest
        case forward
        case drop
    }

    enum BeginAction: Equatable, Sendable {
        case open
        case replayLatest
        case reject
    }

    private var deliveryIsOpen = false
    private var hasPendingFrame = false
    private var isRevoked = false

    mutating func receiveFrame() -> FrameAction {
        guard !isRevoked else { return .drop }
        guard !deliveryIsOpen else { return .forward }
        hasPendingFrame = true
        return .storeLatest
    }

    mutating func beginDelivery() -> BeginAction {
        guard !isRevoked else { return .reject }
        deliveryIsOpen = true
        guard hasPendingFrame else { return .open }
        hasPendingFrame = false
        return .replayLatest
    }

    mutating func revoke() {
        deliveryIsOpen = false
        hasPendingFrame = false
        isRevoked = true
    }
}

enum ScreenVideoFrameStatusPolicy {
    static func admitsImageFrame(_ status: SCFrameStatus) -> Bool {
        status == .started || status == .complete
    }
}

/// Retains the latest image-backed ScreenCaptureKit frame until the transport format is installed.
final class ScreenVideoStreamOutput: NSObject, SCStreamOutput {
    private struct PendingFrame {
        let sampleBuffer: CMSampleBuffer
        let geometryObservation: ScreenVideoFrameGeometryObservation
    }

    private let consumer: ScreenVideoSampleConsumer
    private let lock = NSLock()
    private var deliveryState = ScreenVideoInitialFrameDeliveryState()
    private var pendingFrame: PendingFrame?

    init(consumer: ScreenVideoSampleConsumer) {
        self.consumer = consumer
    }

    /// Permanently closes this capture generation and waits for an admitted callback to return.
    func revoke() {
        lock.withLock {
            deliveryState.revoke()
            pendingFrame = nil
        }
    }

    /// Replays the newest startup image, then forwards future frames in callback order.
    func beginDelivery() -> Bool {
        lock.withLock {
            switch deliveryState.beginDelivery() {
            case .reject:
                return false
            case .open:
                return true
            case .replayLatest:
                guard let pendingFrame else { return false }
                self.pendingFrame = nil
                consumer.consumeScreenVideoSample(
                    pendingFrame.sampleBuffer,
                    frameGeometryObservation: pendingFrame.geometryObservation
                )
                return true
            }
        }
    }

    /// Accepts image-backed first/complete frames; idle and other non-image statuses are ignored.
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        consumeScreenSample(sampleBuffer)
    }

    /// Handles one native screen sample after the callback's output-type gate.
    func consumeScreenSample(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let statusRawValue = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue),
              ScreenVideoFrameStatusPolicy.admitsImageFrame(status) else {
            return
        }
        let geometryObservation = Self.frameGeometryObservation(
            pixelBuffer: pixelBuffer,
            attachments: attachments[0]
        )
        lock.withLock {
            switch deliveryState.receiveFrame() {
            case .storeLatest:
                pendingFrame = PendingFrame(
                    sampleBuffer: sampleBuffer,
                    geometryObservation: geometryObservation
                )
            case .forward:
                consumer.consumeScreenVideoSample(
                    sampleBuffer,
                    frameGeometryObservation: geometryObservation
                )
            case .drop:
                break
            }
        }
    }

    /// Parses Apple's optional geometry while distinguishing absence from unsafe present values.
    private static func frameGeometryObservation(
        pixelBuffer: CVPixelBuffer,
        attachments: [SCStreamFrameInfo: Any]
    ) -> ScreenVideoFrameGeometryObservation {
        let contentRect: CGRect?
        if let contentRectValue = attachments[.contentRect] {
            guard let contentRectDictionary = contentRectValue as? NSDictionary,
                  let parsedContentRect = CGRect(
                      dictionaryRepresentation: contentRectDictionary as CFDictionary
                  ),
                  parsedContentRect.origin.x.isFinite,
                  parsedContentRect.origin.y.isFinite,
                  parsedContentRect.width.isFinite,
                  parsedContentRect.height.isFinite,
                  parsedContentRect.width > 0,
                  parsedContentRect.height > 0 else {
                return .invalid
            }
            contentRect = parsedContentRect
        } else {
            contentRect = nil
        }

        let contentScale: CGFloat?
        if let contentScaleValue = attachments[.contentScale] {
            guard let contentScaleNumber = contentScaleValue as? NSNumber else {
                return .invalid
            }
            let parsedContentScale = CGFloat(truncating: contentScaleNumber)
            guard parsedContentScale.isFinite, parsedContentScale > 0 else {
                return .invalid
            }
            contentScale = parsedContentScale
        } else {
            contentScale = nil
        }

        let scaleFactor: CGFloat?
        if let scaleFactorValue = attachments[.scaleFactor] {
            guard let scaleFactorNumber = scaleFactorValue as? NSNumber else {
                return .invalid
            }
            let parsedScaleFactor = CGFloat(truncating: scaleFactorNumber)
            guard parsedScaleFactor.isFinite,
                  (1 ... 4).contains(parsedScaleFactor) else {
                return .invalid
            }
            scaleFactor = parsedScaleFactor
        } else {
            scaleFactor = nil
        }

        if let contentRect {
            // `contentScale` does not affect the input rectangle, and one is the minimum supported
            // scale factor. Even with another attachment missing, reject any present rectangle
            // that the available evidence already proves cannot describe this pixel surface.
            guard ScreenVideoFrameGeometry(
                surfaceWidth: CVPixelBufferGetWidth(pixelBuffer),
                surfaceHeight: CVPixelBufferGetHeight(pixelBuffer),
                contentRect: contentRect,
                contentScale: contentScale ?? 1,
                scaleFactor: scaleFactor ?? 1
            ) != nil else {
                return .invalid
            }
        }

        guard let contentRect, let contentScale, let scaleFactor else {
            return .absent
        }
        guard let geometry = ScreenVideoFrameGeometry(
            surfaceWidth: CVPixelBufferGetWidth(pixelBuffer),
            surfaceHeight: CVPixelBufferGetHeight(pixelBuffer),
            contentRect: contentRect,
            contentScale: contentScale,
            scaleFactor: scaleFactor
        ) else {
            return .invalid
        }
        return .valid(geometry)
    }
}

/// Display-selection and lifecycle failures from screen capture.
public enum ScreenVideoCaptureError: LocalizedError {
    case noDisplays
    case displayNotFound(UInt32)
    case displayModeUnavailable(UInt32)
    case displayModeChangedDuringStart(UInt32)
    case displayIdentityMismatch(UInt32)
    case alreadyRunning
    case startCancelled
    case nativeStopUnconfirmed(String)

    /// A user-facing diagnostic for host status and logs.
    public var errorDescription: String? {
        switch self {
        case .noDisplays:
            "ScreenCaptureKit did not report any displays"
        case .displayNotFound(let displayID):
            "ScreenCaptureKit did not find display \(displayID)"
        case .displayModeUnavailable(let displayID):
            "ScreenCaptureKit did not report valid active pixel geometry for display \(displayID)"
        case .displayModeChangedDuringStart(let displayID):
            "Display \(displayID) changed resolution while screen capture was starting"
        case .displayIdentityMismatch(let displayID):
            "Display \(displayID) no longer matches the required identity and topology"
        case .alreadyRunning:
            "Screen video capture is already running"
        case .startCancelled:
            "Screen video capture was cancelled before startup completed"
        case .nativeStopUnconfirmed(let description):
            "Screen video capture did not confirm native shutdown: \(description)"
        }
    }
}
