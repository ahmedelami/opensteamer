import AudioToolbox
import CoreAudio
import Foundation

final class BlackHoleInputAudioSource: @unchecked Sendable {
    private let logger: Logger
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
    }

    func start(consumer: StreamingAudioProcessor) throws {
        self.consumer = consumer

        let route = try Self.prepareBlackHoleRoute(logger: logger)
        let name = route.name
        var description = Self.makeQueueFormat(sampleRate: sampleRate, channels: UInt32(channelCount))
        format = StreamAudioFormat(description)

        logger.info(
            "Starting default-input AudioQueue capture from \(name): " +
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
    }

    func stop() {
        guard let audioQueue else { return }
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

    private static func prepareBlackHoleRoute(logger: Logger) throws -> AudioRoute {
        let devices = try allDevices()
        let routes = devices.map {
            AudioRoute(
                deviceID: $0,
                name: deviceName($0) ?? "unknown",
                uid: deviceUID($0)
            )
        }
        guard let route = routes.first(where: { $0.isBlackHole }) else {
            let names = routes.map(\.name).sorted().joined(separator: ", ")
            throw CaptureError.audioDeviceNotFound("BlackHole 2ch is required. Available devices: \(names)")
        }

        try setDefaultDevice(route.deviceID, selector: kAudioHardwarePropertyDefaultOutputDevice, label: "default output")
        try setDefaultDevice(route.deviceID, selector: kAudioHardwarePropertyDefaultSystemOutputDevice, label: "system output")
        try setDefaultDevice(route.deviceID, selector: kAudioHardwarePropertyDefaultInputDevice, label: "default input")

        logger.info("Routed Mac default output, system output, and input to \(route.name)")
        return route
    }

    private static func allDevices() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )
        guard status == noErr else {
            throw CaptureError.audioDeviceConfiguration("read device-list size", status)
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var devices = Array(repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &devices
        )
        guard status == noErr else {
            throw CaptureError.audioDeviceConfiguration("read device list", status)
        }
        return devices.filter { $0 != kAudioObjectUnknown }
    }

    private static func setDefaultDevice(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        label: String
    ) throws {
        var deviceID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )
        guard status == noErr else {
            throw CaptureError.audioDeviceConfiguration("set \(label)", status)
        }
    }

    private static func defaultInputDevice() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw CaptureError.audioBufferListFailure(status)
        }
        return deviceID
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioObjectPropertyName)
    }

    private static func deviceUID(_ deviceID: AudioDeviceID) -> CFString? {
        guard let value = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) else { return nil }
        return value as CFString
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String
    }
}

private struct AudioRoute {
    let deviceID: AudioDeviceID
    let name: String
    let uid: CFString?

    var isBlackHole: Bool {
        name.localizedCaseInsensitiveContains("BlackHole") ||
            ((uid as String?)?.localizedCaseInsensitiveContains("BlackHole") ?? false)
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
