import CoreMedia
import Foundation
import ScreenCaptureKit

final class ScreenCaptureAudioSource: NSObject {
    private let displayID: UInt32?
    private let logger: Logger
    private var stream: SCStream?
    private var output: StreamOutput?
    private let sampleQueue = DispatchQueue(label: "MacCaptureVerifier.ScreenCaptureKit")

    init(displayID: UInt32?, logger: Logger) {
        self.displayID = displayID
        self.logger = logger
    }

    func start(consumer: SampleBufferConsumer) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display = try selectDisplay(from: content.displays)
        logger.info("Selected display \(display.displayID) (\(display.width)x\(display.height))")

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let output = StreamOutput(consumer: consumer)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
        self.output = output
        self.stream = stream

        logger.info("Starting ScreenCaptureKit capture")
        try await stream.startCapture()
    }

    func stop() async throws {
        guard let stream else { return }
        logger.info("Stopping ScreenCaptureKit capture")
        try await stream.stopCapture()
        self.stream = nil
        self.output = nil
    }

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
