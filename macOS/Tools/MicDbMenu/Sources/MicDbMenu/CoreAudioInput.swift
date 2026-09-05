import AudioToolbox
import CoreAudio
import Foundation
import MicDbMenuCore

enum AudioFailure: Error, CustomStringConvertible {
    case status(String, OSStatus)
    case unavailable(String)
    var description: String {
        switch self {
        case .status(let operation, let status): return "\(operation): \(status)"
        case .unavailable(let reason): return reason
        }
    }
}

func requireAudio(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw AudioFailure.status(operation, status) }
}

enum CoreAudioInput {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          initial: T) throws -> T {
        var property = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &value) {
            try requireAudio(AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0), "Read input")
        }
        guard size == MemoryLayout<T>.size else { throw AudioFailure.unavailable("Incomplete input identity") }
        return value
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var property = address(selector)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        try withUnsafeMutablePointer(to: &value) {
            try requireAudio(AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0), "Read input UID")
        }
        guard size == MemoryLayout<CFString?>.size, let value else {
            throw AudioFailure.unavailable("Missing input identity")
        }
        return value as String
    }

    static func identity(_ id: AudioObjectID) throws -> InputIdentity {
        guard id != kAudioObjectUnknown else { throw AudioFailure.unavailable("No input device") }
        let uid = try string(id, kAudioDevicePropertyDeviceUID)
        let name = try string(id, kAudioObjectPropertyName)
        let transport: UInt32 = try scalar(id, kAudioDevicePropertyTransportType, initial: 0)
        let alive: UInt32 = try scalar(id, kAudioDevicePropertyDeviceIsAlive, initial: 0)
        let rate: Float64 = try scalar(id, kAudioDevicePropertyNominalSampleRate, initial: 0)
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        try requireAudio(AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size), "Read input channels")
        guard size >= MemoryLayout<AudioBufferList>.size, size <= 4096 else {
            throw AudioFailure.unavailable("Invalid input topology")
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let capacity = size
        try requireAudio(AudioObjectGetPropertyData(id, &property, 0, nil, &size, storage), "Read input channels")
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        guard size <= capacity, list.pointee.mNumberBuffers <= 32,
              Int(size) >= MemoryLayout<AudioBufferList>.size +
                max(0, Int(list.pointee.mNumberBuffers) - 1) * MemoryLayout<AudioBuffer>.stride else {
            throw AudioFailure.unavailable("Incomplete input topology")
        }
        let channelTotal = UnsafeMutableAudioBufferListPointer(list).reduce(UInt64(0)) { $0 + UInt64($1.mNumberChannels) }
        guard channelTotal <= 32 else { throw AudioFailure.unavailable("Unsupported input channel count") }
        let channels = UInt32(channelTotal)
        let kind: InputIdentity.Transport
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeThunderbolt:
            kind = .physical
        case kAudioDeviceTransportTypeVirtual: kind = .virtual
        case kAudioDeviceTransportTypeAggregate: kind = .aggregate
        default: kind = .unsupported
        }
        return InputIdentity(id: id, uid: uid, name: name, transport: kind,
                             alive: alive == 1, channels: channels, sampleRate: rate)
    }

    static func defaultIdentity() throws -> InputIdentity? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let id: AudioDeviceID = try scalar(system, kAudioHardwarePropertyDefaultInputDevice, initial: 0)
        guard id != kAudioObjectUnknown else { return nil }
        let result = try identity(id)
        let after: AudioDeviceID = try scalar(system, kAudioHardwarePropertyDefaultInputDevice, initial: 0)
        guard after == id else { throw AudioFailure.unavailable("Input changed during inspection") }
        return result
    }
}

/// These observers remain installed even when there is no capture object.
final class InputMonitor {
    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock, UUID)] = []
    private var watchedDevice: AudioObjectID?
    private let changed: () -> Void
    private(set) var healthy = false

    init(changed: @escaping () -> Void) {
        self.changed = changed
        do {
            try add(AudioObjectID(kAudioObjectSystemObject), CoreAudioInput.address(kAudioHardwarePropertyDefaultInputDevice))
            try add(AudioObjectID(kAudioObjectSystemObject), CoreAudioInput.address(kAudioHardwarePropertyDevices))
            healthy = true
        } catch { removeAll() }
    }

    func watch(_ device: AudioObjectID?) throws {
        guard device != watchedDevice else { return }
        while registrations.count > 2 { removeLast() }
        watchedDevice = nil
        guard let device else { return }
        do {
            try add(device, CoreAudioInput.address(kAudioDevicePropertyDeviceIsAlive))
            try add(device, CoreAudioInput.address(kAudioDevicePropertyNominalSampleRate))
            try add(device, CoreAudioInput.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput))
            watchedDevice = device
        } catch {
            while registrations.count > 2 { removeLast() }
            throw error
        }
    }

    private func add(_ id: AudioObjectID, _ property: AudioObjectPropertyAddress) throws {
        var property = property
        let token = UUID()
        let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.registrations.contains(where: { $0.3 == token }) else { return }
            self.changed()
        }
        try requireAudio(AudioObjectAddPropertyListenerBlock(id, &property, .main, callback), "Observe input changes")
        registrations.append((id, property, callback, token))
    }

    private func removeLast() {
        guard var item = registrations.popLast() else { return }
        AudioObjectRemovePropertyListenerBlock(item.0, &item.1, .main, item.2)
    }
    private func removeAll() { while !registrations.isEmpty { removeLast() } }
    deinit { removeAll() }
}
