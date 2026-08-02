import AudioToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit
import Streaming
import XCTest
@testable import CaptureCore

/// Locks down ScreenCaptureKit configuration, callback ownership, and audio processing behavior.
final class SystemAudioCaptureSourceTests: XCTestCase {
    func testProductionConfigurationRequestsFortyEightKilohertzStereoAudioOnly() {
        let configuration = SystemAudioCaptureConfiguration.make()

        XCTAssertTrue(configuration.capturesAudio)
        XCTAssertTrue(configuration.excludesCurrentProcessAudio)
        XCTAssertEqual(configuration.sampleRate, 48_000)
        XCTAssertEqual(configuration.channelCount, 2)
        // ScreenCaptureKit still requires nonzero video dimensions even though this source
        // consumes only its audio output, so production uses the smallest practical surface.
        XCTAssertEqual(configuration.width, 2)
        XCTAssertEqual(configuration.height, 2)
    }

    func testPublishedFormatCannotDriftFromCaptureConfiguration() {
        let format = SystemAudioCaptureFormat(displayID: 73)
        let configuration = SystemAudioCaptureConfiguration.make()

        XCTAssertEqual(format.displayID, 73)
        XCTAssertEqual(format.sampleRate, configuration.sampleRate)
        XCTAssertEqual(format.channelCount, configuration.channelCount)
    }

    func testCaptureErrorsDistinguishConcurrentStartFromCancellation() {
        XCTAssertNotEqual(
            SystemAudioCaptureError.alreadyRunning.localizedDescription,
            SystemAudioCaptureError.startCancelled.localizedDescription
        )
        XCTAssertTrue(
            SystemAudioCaptureError.displayNotFound(9).localizedDescription.contains("9")
        )
    }

    func testFeedbackExclusionSelectsOnlyExactIPhoneMirroringBundle() {
        let bundleIdentifiers: [String?] = [
            "com.apple.ScreenContinuity",
            "com.spotify.client",
            "COM.APPLE.SCREENCONTINUITY",
            "com.apple.ScreenContinuity.helper",
            nil,
            "com.apple.ScreenContinuity"
        ]

        let excluded = SystemAudioApplicationExclusionPolicy.excludedApplications(
            from: bundleIdentifiers,
            bundleIdentifier: { $0 }
        )

        XCTAssertEqual(excluded, [
            "com.apple.ScreenContinuity",
            "com.apple.ScreenContinuity"
        ])
    }

    func testOnlyIPhoneMirroringLifecycleEventsRefreshTheAudioFilter() {
        XCTAssertTrue(
            SystemAudioApplicationExclusionPolicy.requiresFilterRefresh(
                bundleIdentifier: "com.apple.ScreenContinuity"
            )
        )
        XCTAssertFalse(
            SystemAudioApplicationExclusionPolicy.requiresFilterRefresh(
                bundleIdentifier: "com.apple.ScreenContinuity.helper"
            )
        )
        XCTAssertFalse(
            SystemAudioApplicationExclusionPolicy.requiresFilterRefresh(
                bundleIdentifier: nil
            )
        )
    }

    func testScreenCaptureRegistrationUsesExactConsumerQueueAndSynchronousCallback() throws {
        let consumer = QueueProbeConsumer()
        let registration = ScreenCaptureAudioSource.makeOutputRegistration(consumer: consumer)

        XCTAssertTrue(registration.sampleHandlerQueue === consumer.sampleHandlerQueue)
        try registration.sampleHandlerQueue.sync {
            let sampleBuffer = try makeStereoFloatSampleBuffer(
                frames: [[0.25, -0.25], [0.5, -0.5]],
                presentationTime: .zero
            )
            registration.output.handle(sampleBuffer, outputType: .audio)
            // This assertion runs before the ScreenCaptureKit callback would return. A second
            // async handoff in StreamOutput would leave the count at zero here.
            XCTAssertEqual(consumer.consumeCount, 1)

            registration.output.handle(sampleBuffer, outputType: .screen)
            XCTAssertEqual(consumer.consumeCount, 1)
        }
    }

    func testFileProcessorConsumesSynchronouslyAndFinishesWithExactMetrics() throws {
        let outputURL = temporaryURL(name: "processor.wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let processor = AudioProcessor(outputURL: outputURL, logger: SilentLogger())

        try processor.sampleHandlerQueue.sync {
            let first = try makeStereoFloatSampleBuffer(
                frames: [[0.25, -0.25], [0.5, -0.5]],
                presentationTime: .zero
            )
            processor.consume(first)
            let firstSize = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber
            ).intValue
            XCTAssertGreaterThan(firstSize, 44)

            let second = try makeStereoFloatSampleBuffer(
                frames: [[-1, 1], [0, 0]],
                presentationTime: CMTime(value: 2, timescale: 48_000)
            )
            processor.consume(second)
            let secondSize = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber
            ).intValue
            XCTAssertGreaterThan(secondSize, firstSize)
        }

        let snapshot = processor.latestSnapshot()
        XCTAssertEqual(snapshot.callbackStatistics.count, 2)
        XCTAssertEqual(snapshot.framesWritten, 4)
        XCTAssertEqual(try XCTUnwrap(snapshot.latestMetrics).peak, 1, accuracy: 0.000_001)

        let summary = try processor.finish()
        XCTAssertEqual(summary.callbackStatistics.count, 2)
        XCTAssertEqual(summary.framesWritten, 4)
        XCTAssertEqual(summary.bytesWritten, 16)
        XCTAssertEqual(summary.streamFormat?.sampleRate, 48_000)
        XCTAssertEqual(summary.streamFormat?.channelCount, 2)
        XCTAssertEqual(try XCTUnwrap(summary.metricSummary.maximumPeak), 1, accuracy: 0.000_001)
    }

    func testStreamingSampleBufferIsFramedBeforeCallbackReturns() throws {
        let sink = RecordingPCMSink()
        let processor = StreamingAudioProcessor(sink: sink, logger: SilentLogger())
        let queueKey = DispatchSpecificKey<UInt8>()
        processor.sampleHandlerQueue.setSpecific(key: queueKey, value: 1)
        sink.expect(queueKey: queueKey)

        try processor.sampleHandlerQueue.sync {
            let sampleBuffer = try makeStereoFloatSampleBuffer(
                frames: [[0.25, -0.25], [0.5, -0.5]],
                presentationTime: CMTime(value: 96, timescale: 48_000)
            )
            processor.consume(sampleBuffer)
            // The sink must already contain the packet while the callback is still active.
            XCTAssertEqual(sink.snapshot().packets.count, 1)
        }

        let summary = try processor.finish()
        XCTAssertEqual(summary.callbackStatistics.count, 1)
        XCTAssertEqual(summary.framesStreamed, 2)
        XCTAssertEqual(summary.bytesStreamed, 8)
        XCTAssertEqual(summary.packetsStreamed, 1)

        let snapshot = sink.snapshot()
        XCTAssertEqual(snapshot.headers.count, 1)
        XCTAssertEqual(snapshot.headers[0].sampleRate, 48_000)
        XCTAssertEqual(snapshot.headers[0].channels, 2)
        XCTAssertEqual(snapshot.packets.map(\.sequence), [0])
        XCTAssertEqual(snapshot.packets.map(\.timestamp), [2_000_000])
        XCTAssertEqual(snapshot.packets.map(\.frameCount), [2])
        XCTAssertEqual(snapshot.offExpectedQueueCalls, 0)
    }

    func testBlackHolePCMEnqueueCapturesArrivalBeforeProcessingBacklog() throws {
        let sink = RecordingPCMSink()
        let queueKey = DispatchSpecificKey<UInt8>()
        let callbackClock = ManualCallbackArrivalClock(queueKey: queueKey)
        let processor = StreamingAudioProcessor(
            sink: sink,
            logger: SilentLogger(),
            callbackTimeProvider: {
                callbackClock.now()
            }
        )
        processor.sampleHandlerQueue.setSpecific(key: queueKey, value: 1)
        sink.expect(queueKey: queueKey)
        let format = makeStereoFloatFormat()
        let backlogEntered = DispatchSemaphore(value: 0)
        let releaseBacklog = DispatchSemaphore(value: 0)

        processor.sampleHandlerQueue.async {
            backlogEntered.signal()
            releaseBacklog.wait()
        }
        XCTAssertEqual(
            backlogEntered.wait(timeout: .now() + .seconds(1)),
            .success
        )

        let arrivalTimes: [UInt64] = [
            1_000_000,
            11_000_000,
            31_000_000,
        ]
        for (index, arrivalTime) in arrivalTimes.enumerated() {
            callbackClock.set(arrivalTime)
            let pcm = PCMBuffer(
                samples: [Float(index) / 64, -Float(index) / 64, 0.25, -0.25],
                frameCount: 2,
                channels: 2,
                format: format
            )
            processor.enqueue(
                pcm,
                presentationTimestampNanoseconds: UInt64(index) * 1_000_000
            )
        }
        callbackClock.set(1_000_000_000)
        releaseBacklog.signal()

        let summary = try processor.finish()
        XCTAssertEqual(summary.callbackStatistics.count, 3)
        XCTAssertEqual(summary.framesStreamed, 6)
        XCTAssertEqual(summary.bytesStreamed, 24)
        XCTAssertEqual(summary.packetsStreamed, 3)
        XCTAssertEqual(
            try XCTUnwrap(summary.callbackStatistics.minimumInterval),
            0.01,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(summary.callbackStatistics.maximumInterval),
            0.02,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            summary.callbackStatistics.averageInterval,
            0.015,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            callbackClock.processorQueueReadCount,
            0,
            "Arrival sampling must happen at enqueue, not after the serial processing backlog drains."
        )

        let snapshot = sink.snapshot()
        XCTAssertEqual(snapshot.headers.count, 1)
        XCTAssertEqual(snapshot.packets.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(snapshot.offExpectedQueueCalls, 0)
    }

    func testConcurrentBlackHolePCMEnqueueLinearizesArrivalWithoutUnderflow()
        throws {
        let sink = RecordingPCMSink()
        let queueKey = DispatchSpecificKey<UInt8>()
        let callbackClock =
            RegressingConcurrentCallbackArrivalClock(
                queueKey: queueKey
            )
        let processor = StreamingAudioProcessor(
            sink: sink,
            logger: SilentLogger(),
            callbackTimeProvider: {
                callbackClock.now()
            }
        )
        processor.sampleHandlerQueue.setSpecific(key: queueKey, value: 1)
        sink.expect(queueKey: queueKey)
        let format = makeStereoFloatFormat()
        let packetCount = 32

        DispatchQueue.concurrentPerform(iterations: packetCount) { index in
            let pcm = PCMBuffer(
                samples: [Float(index) / 64, -Float(index) / 64, 0.25, -0.25],
                frameCount: 2,
                channels: 2,
                format: format
            )
            processor.enqueue(
                pcm,
                presentationTimestampNanoseconds: UInt64(index) * 1_000_000
            )
        }

        let summary = try processor.finish()
        XCTAssertEqual(summary.callbackStatistics.count, packetCount)
        XCTAssertEqual(summary.framesStreamed, Int64(packetCount * 2))
        XCTAssertEqual(summary.bytesStreamed, Int64(packetCount * 8))
        XCTAssertEqual(summary.packetsStreamed, Int64(packetCount))
        XCTAssertEqual(
            try XCTUnwrap(summary.callbackStatistics.minimumInterval),
            0,
            accuracy: 0.000_001,
            "A regressing injected sample is clamped instead of subtracting UInt64 values out of order."
        )
        XCTAssertEqual(
            try XCTUnwrap(summary.callbackStatistics.maximumInterval),
            0.01,
            accuracy: 0.000_001
        )
        XCTAssertEqual(callbackClock.readCount, packetCount)
        XCTAssertEqual(
            callbackClock.processorQueueReadCount,
            0,
            "Concurrent arrivals must be timestamped before queue submission."
        )

        let snapshot = sink.snapshot()
        XCTAssertEqual(snapshot.headers.count, 1)
        XCTAssertEqual(snapshot.packets.count, packetCount)
        XCTAssertEqual(snapshot.packets.map(\.sequence), Array(0..<UInt32(packetCount)))
        XCTAssertEqual(
            Set(snapshot.packets.map(\.timestamp)),
            Set((0..<packetCount).map { UInt64($0) * 1_000_000 })
        )
        XCTAssertTrue(snapshot.packets.allSatisfy {
            $0.frameCount == 2 && $0.byteCount == 8
        })
        XCTAssertEqual(snapshot.offExpectedQueueCalls, 0)
    }

    private func temporaryURL(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-\(UUID().uuidString)-\(name)")
    }
}

private final class QueueProbeConsumer: SampleBufferConsumer {
    let sampleHandlerQueue = DispatchQueue(label: "opensteamer.tests.QueueProbeConsumer")
    private(set) var consumeCount = 0

    func consume(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(sampleHandlerQueue))
        XCTAssertTrue(sampleBuffer.isValid)
        consumeCount += 1
    }
}

private struct SilentLogger: Logger {
    func info(_: String) {}
    func debug(_: String) {}
    func error(_: String) {}
}

private final class ManualCallbackArrivalClock: @unchecked Sendable {
    private let queueKey: DispatchSpecificKey<UInt8>
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var processorQueueReadCountStorage = 0

    init(queueKey: DispatchSpecificKey<UInt8>) {
        self.queueKey = queueKey
    }

    func set(_ value: UInt64) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if DispatchQueue.getSpecific(key: queueKey) == 1 {
            processorQueueReadCountStorage += 1
        }
        return value
    }

    var processorQueueReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return processorQueueReadCountStorage
    }
}

private final class RegressingConcurrentCallbackArrivalClock:
    @unchecked Sendable
{
    private let queueKey: DispatchSpecificKey<UInt8>
    private let lock = NSLock()
    private var readCountStorage = 0
    private var processorQueueReadCountStorage = 0

    init(queueKey: DispatchSpecificKey<UInt8>) {
        self.queueKey = queueKey
    }

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if DispatchQueue.getSpecific(key: queueKey) == 1 {
            processorQueueReadCountStorage += 1
        }
        let index = readCountStorage
        readCountStorage += 1
        switch index {
        case 0:
            return 2_000_000
        case 1:
            return 1_000_000
        default:
            return 2_000_000
                + UInt64(index - 1) * 10_000_000
        }
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCountStorage
    }

    var processorQueueReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return processorQueueReadCountStorage
    }
}

private final class RecordingPCMSink: PCMFrameSink, @unchecked Sendable {
    struct Packet: Equatable {
        let sequence: UInt32
        let timestamp: UInt64
        let frameCount: UInt32
        let byteCount: Int
    }

    struct Snapshot {
        let headers: [PCMStreamHeader]
        let packets: [Packet]
        let offExpectedQueueCalls: Int
    }

    private let lock = NSLock()
    private var expectedQueueKey: DispatchSpecificKey<UInt8>?
    private var headers: [PCMStreamHeader] = []
    private var packets: [Packet] = []
    private var offExpectedQueueCalls = 0

    func expect(queueKey: DispatchSpecificKey<UInt8>) {
        lock.lock()
        expectedQueueKey = queueKey
        lock.unlock()
    }

    func configureStream(_ header: PCMStreamHeader) {
        lock.lock()
        recordQueueExpectation()
        headers.append(header)
        lock.unlock()
    }

    func sendPCMFrame(metadata: PCMPacketMetadata, pcmBytes: Data) {
        lock.lock()
        recordQueueExpectation()
        packets.append(
            Packet(
                sequence: metadata.sequence,
                timestamp: metadata.presentationTimestampNanoseconds,
                frameCount: metadata.frameCount,
                byteCount: pcmBytes.count
            )
        )
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            headers: headers,
            packets: packets,
            offExpectedQueueCalls: offExpectedQueueCalls
        )
    }

    private func recordQueueExpectation() {
        guard let expectedQueueKey,
              DispatchQueue.getSpecific(key: expectedQueueKey) == 1 else {
            offExpectedQueueCalls += 1
            return
        }
    }
}

private func makeStereoFloatFormat() -> StreamAudioFormat {
    let description = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8,
        mFramesPerPacket: 1,
        mBytesPerFrame: 8,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    return StreamAudioFormat(description)
}

private func makeStereoFloatSampleBuffer(
    frames: [[Float]],
    presentationTime: CMTime
) throws -> CMSampleBuffer {
    guard !frames.isEmpty, frames.allSatisfy({ $0.count == 2 }) else {
        throw SampleBufferFixtureError.invalidFrames
    }
    let samples = frames.flatMap { $0 }
    let byteCount = samples.count * MemoryLayout<Float>.size

    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: byteCount,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    guard status == kCMBlockBufferNoErr, let blockBuffer else {
        throw SampleBufferFixtureError.blockBuffer(status)
    }
    status = samples.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else {
            return kCMBlockBufferBadLengthParameterErr
        }
        return CMBlockBufferReplaceDataBytes(
            with: baseAddress,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
    }
    guard status == kCMBlockBufferNoErr else {
        throw SampleBufferFixtureError.blockBuffer(status)
    }

    var description = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8,
        mFramesPerPacket: 1,
        mBytesPerFrame: 8,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    status = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &description,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )
    guard status == noErr, let formatDescription else {
        throw SampleBufferFixtureError.formatDescription(status)
    }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: presentationTime,
        decodeTimeStamp: .invalid
    )
    var sampleSize = 8
    var sampleBuffer: CMSampleBuffer?
    status = CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: frames.count,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else {
        throw SampleBufferFixtureError.sampleBuffer(status)
    }
    return sampleBuffer
}

private enum SampleBufferFixtureError: Error {
    case invalidFrames
    case blockBuffer(OSStatus)
    case formatDescription(OSStatus)
    case sampleBuffer(OSStatus)
}
