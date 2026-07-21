import CoreMedia
import Foundation
import ScreenCaptureKit

/// Queue-bound consumer used to move ScreenCaptureKit samples into processing.
protocol SampleBufferConsumer: AnyObject {
    func enqueue(_ sampleBuffer: CMSampleBuffer)
}

/// Filters an `SCStream` down to audio and forwards buffers to its owner.
///
/// ScreenCaptureKit owns the callback thread; the consumer must establish any
/// stronger serialization or lifetime guarantees it needs.
final class StreamOutput: NSObject, SCStreamOutput {
    private let consumer: SampleBufferConsumer

    init(consumer: SampleBufferConsumer) {
        self.consumer = consumer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        consumer.enqueue(sampleBuffer)
    }
}
