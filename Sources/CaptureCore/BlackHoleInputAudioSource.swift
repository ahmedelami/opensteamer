import AudioToolbox
import Foundation

final class BlackHoleInputAudioSource: @unchecked Sendable {
    private let logger: Logger
    private let routeManager: BlackHoleRouteManager
    private var consumer: StreamingAudioProcessor?
    private var audioQueue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef] = []
    private var format: StreamAudioFormat?
    private var framePosition: UInt64 = 0
    private let channelCount = 2
    private let sampleRate = 48_000.0
    private let framesPerBuffer: UInt32 = 960

    init(logger: Logger) {
        self.logger = logger
        self.routeManager = BlackHoleRouteManager(logger: logger)
    }

    func start(consumer: StreamingAudioProcessor) throws {
        self.consumer = consumer

        do {
            let route = try routeManager.prepareRoute()
            try routeManager.startMonitoring(expectedRoute: route)

            var description = Self.makeQueueFormat(sampleRate: sampleRate, channels: UInt32(channelCount))
            format = StreamAudioFormat(description)

            logger.info(
                "Starting default-input AudioQueue capture from \(route.name): " +
                "\(description.mSampleRate) Hz, \(description.mChannelsPerFrame) channels, " +
                "float=true, interleaved=true, bits=32"
            )

            let context = Unmanaged.passUnretained(self).toOpaque()
            var queue: AudioQueueRef?
            var status = AudioQueueNewInput(
                &description,
                audioQueueInputCallback,
                context,
                nil,
                nil,
                0,
                &queue
            )
            guard status == noErr, let queue else {
                throw CaptureError.audioBufferListFailure(status)
            }
            audioQueue = queue

            let byteCount = framesPerBuffer * UInt32(channelCount) * UInt32(MemoryLayout<Float>.size)
            for _ in 0..<3 {
                var buffer: AudioQueueBufferRef?
                status = AudioQueueAllocateBuffer(queue, byteCount, &buffer)
                guard status == noErr, let buffer else {
                    throw CaptureError.audioBufferListFailure(status)
                }
                buffers.append(buffer)
                status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
                guard status == noErr else {
                    throw CaptureError.audioBufferListFailure(status)
                }
            }

            status = AudioQueueStart(queue, nil)
            guard status == noErr else {
                throw CaptureError.audioBufferListFailure(status)
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        routeManager.stopMonitoring()
        guard let audioQueue else {
            consumer = nil
            return
        }
        AudioQueueStop(audioQueue, true)
        for buffer in buffers {
            AudioQueueFreeBuffer(audioQueue, buffer)
        }
        buffers.removeAll()
        AudioQueueDispose(audioQueue, true)
        self.audioQueue = nil
        consumer = nil
    }

    fileprivate func handleInput(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        defer {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }

        guard let consumer, let format else { return }
        let byteCount = Int(buffer.pointee.mAudioDataByteSize)
        guard byteCount >= MemoryLayout<Float>.size * channelCount else { return }

        let sampleCount = byteCount / MemoryLayout<Float>.size
        let frameCount = sampleCount / channelCount
        guard frameCount > 0 else { return }

        let data = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        let samples = Array(UnsafeBufferPointer(start: data, count: sampleCount))
        let pcm = PCMBuffer(samples: samples, frameCount: frameCount, channels: channelCount, format: format)
        let timestamp = nextTimestamp(frameCount: frameCount, sampleRate: format.sampleRate)
        consumer.enqueue(pcm, presentationTimestampNanoseconds: timestamp)
    }

    private func nextTimestamp(frameCount: Int, sampleRate: Double) -> UInt64 {
        let position = framePosition
        framePosition += UInt64(max(frameCount, 0))
        guard sampleRate > 0 else { return 0 }
        return UInt64(Double(position) * 1_000_000_000 / sampleRate)
    }

    private static func makeQueueFormat(sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size) * channels
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
    }
}

private func audioQueueInputCallback(
    _ inUserData: UnsafeMutableRawPointer?,
    _ inAQ: AudioQueueRef,
    _ inBuffer: AudioQueueBufferRef,
    _ inStartTime: UnsafePointer<AudioTimeStamp>,
    _ inNumPackets: UInt32,
    _ inPacketDesc: UnsafePointer<AudioStreamPacketDescription>?
) {
    guard let inUserData else { return }
    let source = Unmanaged<BlackHoleInputAudioSource>.fromOpaque(inUserData).takeUnretainedValue()
    source.handleInput(queue: inAQ, buffer: inBuffer)
}
