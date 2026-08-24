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
    /// Reports a stream stop that did not originate from normal session teardown.
    func screenVideoCaptureSource(
        _ source: ScreenVideoCaptureSource,
        didStopWithErrorDescription errorDescription: String
    )
}

public extension ScreenVideoSampleConsumer {
    func consumeScreenVideoSample(
        _ sampleBuffer: CMSampleBuffer,
        frameGeometry _: ScreenVideoFrameGeometry?
    ) {
        consumeScreenVideoSample(sampleBuffer)
    }
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
    private let displayID: UInt32?
    private let displayRequirement: ScreenVideoDisplayRequirement?
    private let maximumWidth: Int
    private let framesPerSecond: Int
    private let consumer: ScreenVideoSampleConsumer
    private let makeStopWatchdog: @Sendable () -> Task<Void, Never>?
    private let logger: Logger
    private let sampleQueue = DispatchQueue(label: "opensteamer.ScreenVideoCapture")
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var output: ScreenVideoStreamOutput?
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
        makeStopWatchdog: @escaping @Sendable () -> Task<Void, Never>? = { nil },
        logger: Logger
    ) {
        self.displayID = displayID
        self.displayRequirement = displayRequirement
        self.maximumWidth = maximumWidth
        self.framesPerSecond = framesPerSecond
        self.consumer = consumer
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

    /// Runs one complete startup transaction under the caller's already-armed watchdog.
    private func startWithoutStartupWatchdog() async throws -> ScreenVideoCaptureFormat {
        guard stateLock.withLock({ () -> Bool in
            guard self.stream == nil, !isStarting, !isStopping else { return false }
            isStarting = true
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
            let sourceDimensions = try activeSourceDimensions(for: display)
            let dimensions = try ScreenVideoOutputPolicy.outputDimensions(
                source: sourceDimensions,
                maximumWidth: maximumWidth
            )
            let format = ScreenVideoCaptureFormat(
                displayID: display.displayID,
                width: dimensions.width,
                height: dimensions.height,
                framesPerSecond: framesPerSecond
            )

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

            let filter = SCContentFilter(display: display, excludingWindows: [])
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
                let postStartSourceDimensions = try activeSourceDimensions(for: display)
                guard ScreenVideoSourceDimensionPolicy.isStableAcrossStart(
                    before: sourceDimensions,
                    after: postStartSourceDimensions
                ) else {
                    throw ScreenVideoCaptureError.displayModeChangedDuringStart(
                        display.displayID
                    )
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
        let transition = stateLock.withLock { () -> (Bool, ScreenVideoStreamOutput?) in
            guard !isStopping, stream === stoppedStream else { return (false, nil) }
            let retiredOutput = output
            stream = nil
            output = nil
            return (true, retiredOutput)
        }
        transition.1?.revoke()
        guard transition.0 else { return }
        consumer.screenVideoCaptureSource(
            self,
            didStopWithErrorDescription: errorDescription
        )
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
    private func activeSourceDimensions(
        for display: SCDisplay
    ) throws -> ScreenVideoPixelDimensions {
        let dimensionKind = ScreenVideoSourceDimensionPolicy.dimensionKind(
            vendorID: CGDisplayVendorNumber(display.displayID),
            productID: CGDisplayModelNumber(display.displayID)
        )
        guard dimensionKind == .framebufferPixels else {
            return ScreenVideoPixelDimensions(width: display.width, height: display.height)
        }

        guard let mode = CGDisplayCopyDisplayMode(display.displayID),
              mode.pixelWidth >= 2, mode.pixelHeight >= 2 else {
            throw ScreenVideoCaptureError.displayModeUnavailable(display.displayID)
        }
        return ScreenVideoPixelDimensions(
            width: mode.pixelWidth,
            height: mode.pixelHeight
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

/// Rejects incomplete ScreenCaptureKit frames before invoking the session consumer.
private final class ScreenVideoStreamOutput: NSObject, SCStreamOutput {
    private let consumer: ScreenVideoSampleConsumer
    private let lock = NSLock()
    private var isForwarding = true

    init(consumer: ScreenVideoSampleConsumer) {
        self.consumer = consumer
    }

    /// Permanently closes this capture generation and waits for an admitted callback to return.
    func revoke() {
        lock.withLock { isForwarding = false }
    }

    /// Forwards only ready screen samples whose frame status is `.complete`.
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let statusRawValue = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRawValue) == .complete else {
            return
        }
        lock.withLock {
            guard isForwarding else { return }
            consumer.consumeScreenVideoSample(
                sampleBuffer,
                frameGeometry: Self.frameGeometry(
                    pixelBuffer: pixelBuffer,
                    attachments: attachments[0]
                )
            )
        }
    }

    /// Parses Apple's per-frame geometry without trusting missing, malformed, or out-of-surface
    /// attachment values. A nil result keeps media flowing but forces remote input to fail closed.
    private static func frameGeometry(
        pixelBuffer: CVPixelBuffer,
        attachments: [SCStreamFrameInfo: Any]
    ) -> ScreenVideoFrameGeometry? {
        guard let contentRectDictionary = attachments[.contentRect] as? NSDictionary,
              let contentRect = CGRect(
                  dictionaryRepresentation: contentRectDictionary as CFDictionary
              ),
              let contentScaleNumber = attachments[.contentScale] as? NSNumber,
              let scaleFactorNumber = attachments[.scaleFactor] as? NSNumber else {
            return nil
        }
        let contentScale = CGFloat(truncating: contentScaleNumber)
        let scaleFactor = CGFloat(truncating: scaleFactorNumber)
        return ScreenVideoFrameGeometry(
            surfaceWidth: CVPixelBufferGetWidth(pixelBuffer),
            surfaceHeight: CVPixelBufferGetHeight(pixelBuffer),
            contentRect: contentRect,
            contentScale: contentScale,
            scaleFactor: scaleFactor
        )
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
            "CoreGraphics did not report an active pixel mode for display \(displayID)"
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
