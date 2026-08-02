import CoreMedia
import Foundation
import ScreenCaptureKit

/// Queue-bound consumer used directly by ScreenCaptureKit's audio callback.
///
/// `sampleHandlerQueue` is the consumer's state-ownership queue. ScreenCaptureKit
/// must invoke `consume(_:)` on that exact queue, and the consumer must finish using
/// the non-Sendable `CMSampleBuffer` before the callback returns.
protocol SampleBufferConsumer: AnyObject {
    var sampleHandlerQueue: DispatchQueue { get }
    func consume(_ sampleBuffer: CMSampleBuffer)
}

/// Couples an `SCStreamOutput` with the exact queue that owns its consumer.
struct StreamOutputRegistration {
    let output: StreamOutput
    let sampleHandlerQueue: DispatchQueue
}

/// Filters an `SCStream` down to audio and synchronously invokes its queue owner.
final class StreamOutput: NSObject, SCStreamOutput {
    private let consumer: SampleBufferConsumer

    init(consumer: SampleBufferConsumer) {
        self.consumer = consumer
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        handle(sampleBuffer, outputType: outputType)
    }

    /// Internal callback seam used by deterministic queue/lifetime tests.
    func handle(_ sampleBuffer: CMSampleBuffer, outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        consumer.consume(sampleBuffer)
    }
}
