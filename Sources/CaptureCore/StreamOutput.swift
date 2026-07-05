import CoreMedia
import Foundation
import ScreenCaptureKit

protocol SampleBufferConsumer: AnyObject {
    func enqueue(_ sampleBuffer: CMSampleBuffer)
}

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
