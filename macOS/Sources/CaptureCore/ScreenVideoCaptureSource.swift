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
    /// Reports a stream stop that did not originate from normal session teardown.
    func screenVideoCaptureSource(
        _ source: ScreenVideoCaptureSource,
        didStopWithErrorDescription errorDescription: String
    )
}

/// Owns a video-only ScreenCaptureKit stream for the selected display.
///
/// `stateLock` protects stream identity and start/stop cancellation across Swift
/// concurrency and ScreenCaptureKit delegate callbacks. It is never held across an
/// `await`; framework samples are delivered on the dedicated `sampleQueue`.
public final class ScreenVideoCaptureSource: @unchecked Sendable {
    private let displayID: UInt32?
    private let maximumWidth: Int
    private let framesPerSecond: Int
    private let consumer: ScreenVideoSampleConsumer
    private let logger: Logger
    private let sampleQueue = DispatchQueue(label: "MacCaptureVerifier.ScreenVideoCapture")
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var output: ScreenVideoStreamOutput?
    private var isStarting = false
    private var cancellationRequested = false
    private var isStopping = false
    private lazy var streamDelegate = ScreenVideoStreamDelegate { [weak self] stream, message in
        self?.handleUnexpectedStop(of: stream, errorDescription: message)
    }

    /// Creates a source with an aspect-preserving width cap and target cadence.
    public init(
        displayID: UInt32?,
        maximumWidth: Int,
        framesPerSecond: Int,
        consumer: ScreenVideoSampleConsumer,
        logger: Logger
    ) {
        self.displayID = displayID
        self.maximumWidth = maximumWidth
        self.framesPerSecond = framesPerSecond
        self.consumer = consumer
        self.logger = logger
    }

    // MARK: - Capture lifecycle

    /// Resolves the display, installs a video output, and starts native capture.
    ///
    /// A concurrent `stop()` latches cancellation and prevents a partially started
    /// stream from becoming visible to the rest of the session.
    public func start() async throws -> ScreenVideoCaptureFormat {
        guard stateLock.withLock({ () -> Bool in
            guard self.stream == nil, !isStarting else { return false }
            isStarting = true
            cancellationRequested = false
            isStopping = false
            return true
        }) else {
            throw ScreenVideoCaptureError.alreadyRunning
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            try ensureStartWasNotCancelled()
            let display = try selectDisplay(from: content.displays)
            let dimensions = outputDimensions(for: display)
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
                    isStarting = false
                    return false
                }
                self.output = output
                self.stream = stream
                return true
            }
            guard installed else {
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
                stateLock.withLock {
                    if self.stream === stream {
                        self.stream = nil
                        self.output = nil
                    }
                    isStarting = false
                }
                try? stream.removeStreamOutput(output, type: .screen)
                throw error
            }

            let cancelledAfterStart = stateLock.withLock { () -> Bool in
                isStarting = false
                return cancellationRequested || self.stream !== stream
            }
            guard !cancelledAfterStart else {
                try? await stream.stopCapture()
                stateLock.withLock {
                    if self.stream === stream {
                        self.stream = nil
                        self.output = nil
                    }
                }
                try? stream.removeStreamOutput(output, type: .screen)
                throw ScreenVideoCaptureError.startCancelled
            }
            return format
        } catch {
            stateLock.withLock {
                isStarting = false
            }
            throw error
        }
    }

    /// Detaches and stops the currently owned stream; repeated calls are harmless.
    public func stop() async throws {
        let stopped = stateLock.withLock { () -> (SCStream, ScreenVideoStreamOutput?)? in
            cancellationRequested = true
            isStopping = true
            guard let stream else { return nil }
            let output = self.output
            self.stream = nil
            self.output = nil
            return (stream, output)
        }
        guard let (stream, output) = stopped else { return }
        logger.info("Stopping screen video capture")
        defer {
            if let output {
                try? stream.removeStreamOutput(output, type: .screen)
            }
        }
        try await stream.stopCapture()
    }

    /// Checks the cancellation latch after asynchronous startup boundaries.
    private func ensureStartWasNotCancelled() throws {
        guard stateLock.withLock({ !cancellationRequested }) else {
            throw ScreenVideoCaptureError.startCancelled
        }
    }

    /// Reports only a failure belonging to the current, non-stopping stream.
    private func handleUnexpectedStop(of stoppedStream: SCStream, errorDescription: String) {
        let shouldReport = stateLock.withLock { () -> Bool in
            guard !isStopping, stream === stoppedStream else { return false }
            stream = nil
            output = nil
            isStarting = false
            return true
        }
        guard shouldReport else { return }
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

    /// Scales within the width cap and rounds both dimensions down for H.264 chroma planes.
    private func outputDimensions(for display: SCDisplay) -> (width: Int, height: Int) {
        let cappedWidth = min(display.width, maximumWidth)
        let width = max(2, cappedWidth - cappedWidth % 2)
        let scaledHeight = Int(
            (Double(display.height) * Double(width) / Double(display.width)).rounded()
        )
        let height = max(2, scaledHeight - scaledHeight % 2)
        return (width, height)
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

    init(consumer: ScreenVideoSampleConsumer) {
        self.consumer = consumer
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
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let statusRawValue = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRawValue) == .complete else {
            return
        }
        consumer.consumeScreenVideoSample(sampleBuffer)
    }
}

/// Display-selection and lifecycle failures from screen capture.
public enum ScreenVideoCaptureError: LocalizedError {
    case noDisplays
    case displayNotFound(UInt32)
    case alreadyRunning
    case startCancelled

    /// A user-facing diagnostic for host status and logs.
    public var errorDescription: String? {
        switch self {
        case .noDisplays:
            "ScreenCaptureKit did not report any displays"
        case .displayNotFound(let displayID):
            "ScreenCaptureKit did not find display \(displayID)"
        case .alreadyRunning:
            "Screen video capture is already running"
        case .startCancelled:
            "Screen video capture was cancelled before startup completed"
        }
    }
}
