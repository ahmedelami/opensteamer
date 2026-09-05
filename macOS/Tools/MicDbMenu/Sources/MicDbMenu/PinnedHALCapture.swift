import AudioToolbox
import CoreAudio
import Foundation
import MicDbMenuCore

/// Input-only AUHAL. CurrentDevice is explicit before initialization; no default
/// selector is ever written, and no virtual/unknown device is started.
final class PinnedHALCapture: MeterCapture {
    // A failed disposal is terminal for this utility process. Retaining one context
    // keeps any undrained native callback valid without allowing further captures.
    private static var failedDisposalContext: CallbackContext?
    private let target: InputIdentity
    private let accumulator: LevelAccumulator
    private let generation: UUID
    private var unit: AudioUnit?
    private var context: CallbackContext?
    private var initialized = false
    private var started = false

    init(target: InputIdentity, accumulator: LevelAccumulator, generation: UUID) throws {
        self.target = target; self.accumulator = accumulator; self.generation = generation
        guard Self.failedDisposalContext == nil else {
            throw AudioFailure.unavailable("Capture teardown failed; relaunch the meter before retrying")
        }
        guard target.permitsCapture, try CoreAudioInput.identity(target.id) == target else {
            throw AudioFailure.unavailable("Physical input could not be verified")
        }
        do {
            var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0, componentFlagsMask: 0)
            guard let component = AudioComponentFindNext(nil, &description) else {
                throw AudioFailure.unavailable("Input capture unavailable")
            }
            try requireAudio(AudioComponentInstanceNew(component, &unit), "Create physical capture")
            guard let unit else { throw AudioFailure.unavailable("Missing physical capture") }
            let context = CallbackContext(unit: unit, target: target, accumulator: accumulator, generation: generation)
            self.context = context
            var enabled: UInt32 = 1
            var disabled: UInt32 = 0
            try set(kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, element: 1, value: &enabled)
            try set(kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, element: 0, value: &disabled)
            var device = target.id
            try set(kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, element: 0, value: &device)
            try verifyTarget()
            var format = AudioStreamBasicDescription(mSampleRate: target.sampleRate,
                mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4 * target.channels, mFramesPerPacket: 1,
                mBytesPerFrame: 4 * target.channels, mChannelsPerFrame: target.channels,
                mBitsPerChannel: 32, mReserved: 0)
            try set(kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Output, element: 1, value: &format)
            try verifyFormat()
            var maximumFrames: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            try requireAudio(AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global, 0, &maximumFrames, &size), "Read capture buffer bound")
            guard (1...16_384).contains(maximumFrames), size == MemoryLayout<UInt32>.size else {
                throw AudioFailure.unavailable("Unsupported capture buffer bound")
            }
            context.maximumFrames = maximumFrames
            context.samples = .allocate(capacity: Int(maximumFrames * target.channels))
            var callback = AURenderCallbackStruct(inputProc: { refcon, flags, timestamp, _, frames, _ in
                Unmanaged<CallbackContext>.fromOpaque(refcon).takeUnretainedValue()
                    .receive(flags: flags, timestamp: timestamp, frames: frames)
            }, inputProcRefCon: Unmanaged.passUnretained(context).toOpaque())
            try set(kAudioOutputUnitProperty_SetInputCallback, scope: kAudioUnitScope_Global, element: 0, value: &callback)
        } catch {
            guard stop() else { throw CaptureController.CaptureError.teardownFailed }
            throw error
        }
    }

    private func set<T>(_ property: AudioUnitPropertyID, scope: AudioUnitScope,
                        element: AudioUnitElement, value: inout T) throws {
        guard let unit else { throw AudioFailure.unavailable("Capture closed") }
        try withUnsafePointer(to: &value) {
            try requireAudio(AudioUnitSetProperty(unit, property, scope, element, $0,
                                                 UInt32(MemoryLayout<T>.size)), "Configure physical capture")
        }
    }

    func currentIdentity() throws -> InputIdentity {
        guard let unit else { throw AudioFailure.unavailable("Capture closed") }
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try requireAudio(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &device, &size), "Read captured input")
        guard size == MemoryLayout<AudioDeviceID>.size else { throw AudioFailure.unavailable("Unknown captured input") }
        return try CoreAudioInput.identity(device)
    }

    private func verifyTarget() throws {
        let actual = try currentIdentity()
        guard actual.permitsCapture, actual == target else {
            throw AudioFailure.unavailable("Captured input changed")
        }
    }

    private func verifyFormat() throws {
        guard let unit else { throw AudioFailure.unavailable("Capture closed") }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try requireAudio(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1, &format, &size), "Read capture format")
        guard size == MemoryLayout<AudioStreamBasicDescription>.size,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags == kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
              format.mSampleRate == target.sampleRate,
              format.mChannelsPerFrame == target.channels, format.mBitsPerChannel == 32,
              format.mBytesPerFrame == 4 * target.channels,
              format.mFramesPerPacket == 1, format.mBytesPerPacket == 4 * target.channels else {
            throw AudioFailure.unavailable("Captured sample format changed")
        }
    }

    func start() throws {
        guard let unit, !started else { throw AudioFailure.unavailable("Invalid capture start") }
        try verifyTarget()
        try requireAudio(AudioUnitInitialize(unit), "Initialize physical capture")
        initialized = true
        try verifyTarget()
        try verifyFormat()
        accumulator.reset(to: generation)
        try requireAudio(AudioOutputUnitStart(unit), "Start physical capture")
        started = true
        try verifyTarget()
    }

    @discardableResult func stop() -> Bool {
        guard let unit else { return Self.failedDisposalContext == nil }
        if started { AudioOutputUnitStop(unit); started = false }
        if initialized { AudioUnitUninitialize(unit); initialized = false }
        let disposal = AudioComponentInstanceDispose(unit)
        if disposal != noErr {
            accumulator.reset()
            Self.failedDisposalContext = context
        }
        self.unit = nil
        context = nil
        return disposal == noErr
    }

    deinit { stop() }

    private final class CallbackContext {
        let unit: AudioUnit
        let target: InputIdentity
        let accumulator: LevelAccumulator
        let generation: UUID
        var samples: UnsafeMutablePointer<Float>?
        var maximumFrames: UInt32 = 0

        init(unit: AudioUnit, target: InputIdentity, accumulator: LevelAccumulator, generation: UUID) {
            self.unit = unit; self.target = target; self.accumulator = accumulator; self.generation = generation
        }

        func receive(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                     timestamp: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
            guard let samples, frames > 0, frames <= maximumFrames else { return kAudio_ParamError }
            var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: target.channels,
                mDataByteSize: frames * target.channels * 4, mData: samples))
            let status = AudioUnitRender(unit, flags, timestamp, 1, frames, &buffers)
            guard status == noErr else { return status }
            guard buffers.mBuffers.mDataByteSize == frames * target.channels * 4 else { return kAudio_ParamError }
            accumulator.add(UnsafeBufferPointer(start: samples, count: Int(frames * target.channels)),
                frames: frames, generation: generation, now: ProcessInfo.processInfo.systemUptime)
            return noErr
        }

        deinit { samples?.deallocate() }
    }
}
