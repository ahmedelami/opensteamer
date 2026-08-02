import CoreMedia
import Foundation
import ScreenCaptureKit

/// Owns the ScreenCaptureKit stream used by file-backed system-audio capture.
///
/// ScreenCaptureKit invokes each audio callback on the downstream processor's exact
/// serial ownership queue. The processor consumes the non-Sendable sample buffer
/// synchronously, so no CoreMedia object crosses a second concurrency boundary.
final class ScreenCaptureAudioSource: NSObject {
    private let displayID: UInt32?
    private let logger: Logger
    private var stream: SCStream?
    private var output: StreamOutput?

    init(displayID: UInt32?, logger: Logger) {
        self.displayID = displayID
        self.logger = logger
    }

    /// Selects a display, installs the audio output, and begins asynchronous capture.
    func start(consumer: SampleBufferConsumer) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display = try selectDisplay(from: content.displays)
        logger.info("Selected display \(display.displayID) (\(display.width)x\(display.height))")

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        // A minimal video surface satisfies SCStream while avoiding needless video work.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let registration = Self.makeOutputRegistration(consumer: consumer)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(
            registration.output,
            type: .audio,
            sampleHandlerQueue: registration.sampleHandlerQueue
        )
        output = registration.output
        self.stream = stream

        logger.info("Starting ScreenCaptureKit capture")
        try await stream.startCapture()
    }

    /// Stops the active stream and releases objects that retain its callback consumer.
    func stop() async throws {
        guard let stream else { return }
        logger.info("Stopping ScreenCaptureKit capture")
        try await stream.stopCapture()
        self.stream = nil
        output = nil
    }

    /// Builds the production registration without introducing an intermediate queue.
    static func makeOutputRegistration(
        consumer: SampleBufferConsumer
    ) -> StreamOutputRegistration {
        StreamOutputRegistration(
            output: StreamOutput(consumer: consumer),
            sampleHandlerQueue: consumer.sampleHandlerQueue
        )
    }

    /// Applies explicit display selection and reports configuration errors early.
    private func selectDisplay(from displays: [SCDisplay]) throws -> SCDisplay {
        guard !displays.isEmpty else {
            throw CaptureError.noDisplays
        }

        if let displayID {
            guard let display = displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.displayNotFound(displayID)
            }
            return display
        }

        return displays[0]
    }
}
