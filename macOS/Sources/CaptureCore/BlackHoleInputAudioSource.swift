import AudioToolbox
import Foundation

/// Captures stereo float PCM from the BlackHole loopback device with Audio Queue Services.
///
/// The host calls `start` and `stop` as a single-owner lifecycle. Audio Queue invokes
/// `handleInput` on its callback thread; each callback copies the device buffer before
/// returning, so downstream work never retains Audio Queue memory.
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
    // Twenty milliseconds at 48 kHz balances interactive latency and callback overhead.
    private let framesPerBuffer: UInt32 = 960

    /// Creates a source and the route manager that will pin BlackHole as the active route.
    init(logger: Logger) {
        self.logger = logger
        self.routeManager = BlackHoleRouteManager(logger: logger)
    }

    /// Prepares routing, allocates the fixed buffer pool, and starts input callbacks.
    ///
    /// Any partial-start failure is rolled back through `stop()` before being rethrown.
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

            // The queue never owns this context; the source outlives it until `stop()`.
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
            try Self.setQueueDevice(queue, route: route)

            let byteCount = framesPerBuffer * UInt32(channelCount) * UInt32(MemoryLayout<Float>.size)
            // A small rotating pool lets Core Audio fill one buffer while another is handled.
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
            let captureUID = Self.currentQueueDeviceUID(queue) ?? route.uid
            let health = try routeManager.health(captureDeviceUID: captureUID)
            guard health.isHealthy else {
                throw CaptureError.audioRouteUnhealthy(health.render())
            }
            logger.info("\n\(health.render())")
        } catch {
            stop()
            throw error
        }
    }

    /// Stops callbacks synchronously, frees every queue-owned buffer, and drops the consumer.
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

    /// Copies and forwards one Audio Queue buffer, then always returns it to the pool.
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

    /// Derives a monotonic media timestamp from captured frame position, not wall time.
    private func nextTimestamp(frameCount: Int, sampleRate: Double) -> UInt64 {
        let position = framePosition
        framePosition += UInt64(max(frameCount, 0))
        guard sampleRate > 0 else { return 0 }
        return UInt64(Double(position) * 1_000_000_000 / sampleRate)
    }

    /// Describes the native packed-float format requested from Audio Queue Services.
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

    /// Pins the queue to the stable device UID instead of relying only on defaults.
    private static func setQueueDevice(_ queue: AudioQueueRef, route: AudioRoute) throws {
        guard let uid = route.uid else {
            throw CaptureError.audioRouteUnhealthy("BlackHole route has no stable CoreAudio UID")
        }
        var deviceUID = uid as CFString
        let status = withUnsafePointer(to: &deviceUID) { pointer in
            AudioQueueSetProperty(
                queue,
                kAudioQueueProperty_CurrentDevice,
                pointer,
                UInt32(MemoryLayout<CFString>.size)
            )
        }
        guard status == noErr else {
            throw CaptureError.audioDeviceConfiguration("set AudioQueue capture device", status)
        }
    }

    /// Reads back the queue's effective device for post-start route verification.
    private static func currentQueueDeviceUID(_ queue: AudioQueueRef) -> String? {
        var deviceUID: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &deviceUID) { pointer in
            AudioQueueGetProperty(
                queue,
                kAudioQueueProperty_CurrentDevice,
                pointer,
                &size
            )
        }
        let uid = deviceUID as String
        guard status == noErr, size > 0, !uid.isEmpty else { return nil }
        return uid
    }
}

/// C callback trampoline; `inUserData` is the unretained source supplied at queue creation.
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
