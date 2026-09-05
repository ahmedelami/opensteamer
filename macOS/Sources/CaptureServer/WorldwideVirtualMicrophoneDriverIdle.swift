import CoreAudio
import Darwin
import Foundation

enum WorldwideVirtualMicrophoneDriverDiagnosticError: Error, Equatable, Sendable {
    case property(OSStatus)
    case propertySize(UInt32)
    case propertyType
    case snapshotSize(Int)
    case unsupportedSchema
    case incoherentSnapshot
    case staleObservation
}

struct WorldwideVirtualMicrophoneDriverDiagnosticSnapshot: Equatable, Sendable {
    // OSVADiagnosticSnapshot in OpensteamerVirtualMicrophoneDriver.h pins this
    // little-endian POD ABI for both supported Mac architectures.
    static let property: AudioObjectPropertySelector = 0x6F73_4453
    static let byteCount = 8_608
    private static let requiredFlags: UInt64 = 0x3_FF01
    private static let timelineActiveFlag: UInt64 = 2

    struct Epoch: Equatable, Sendable {
        let instance: UInt64
        let driverLifecycle: UInt64
        let coreLifecycle: UInt64
        let timelineSeed: UInt64
        let seedGeneration: UInt64
        let anchorHostTicks: UInt64
        let lastIssuedSeed: UInt64
        let lastIssuedSessionID: UInt64
    }

    let sequence: UInt64
    let capturedHostTicks: UInt64
    let epoch: Epoch
    let isIdle: Bool

    static func decode(_ data: Data) -> Result<Self, WorldwideVirtualMicrophoneDriverDiagnosticError> {
        guard data.count == byteCount else {
            return .failure(.snapshotSize(data.count))
        }
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
        }
        func u64(_ offset: Int) -> UInt64 {
            data.withUnsafeBytes {
                UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
            }
        }
        guard u32(0) == 1, u32(4) == UInt32(byteCount) else {
            return .failure(.unsupportedSchema)
        }
        let flags = u64(32)
        let knownFlags = requiredFlags | timelineActiveFlag
        let sequence = u64(8)
        let capturedHostTicks = u64(16)
        let epoch = Epoch(
            instance: u64(24),
            driverLifecycle: u64(40),
            coreLifecycle: u64(48),
            timelineSeed: u64(64),
            seedGeneration: u64(72),
            anchorHostTicks: u64(80),
            lastIssuedSeed: u64(88),
            lastIssuedSessionID: u64(96)
        )
        let active = u64(104)
        let visible = u64(112)
        let hidden = u64(120)
        let coreSlots = u64(128)
        let registered = u64(144)
        let started = u64(152)
        let visibleRegistered = u64(160)
        let hiddenRegistered = u64(168)
        let visibleStarted = u64(176)
        let hiddenStarted = u64(184)
        let counts = [active, visible, hidden, coreSlots, registered, started,
                      visibleRegistered, hiddenRegistered, visibleStarted, hiddenStarted]
        guard sequence > 0, capturedHostTicks > 0, epoch.instance > 0,
              epoch.driverLifecycle > 0, epoch.coreLifecycle % 2 == 0,
              u64(56) > 0, u32(328) == 64, u32(332) == 0,
              flags & requiredFlags == requiredFlags,
              flags & ~knownFlags == 0,
              counts.allSatisfy({ $0 <= 64 }),
              visible + hidden == active, coreSlots == active,
              visibleRegistered + hiddenRegistered == registered,
              visibleStarted + hiddenStarted == started,
              started == active, visibleStarted == visible, hiddenStarted == hidden,
              visibleStarted <= visibleRegistered, hiddenStarted <= hiddenRegistered,
              u64(136).nonzeroBitCount == Int(coreSlots),
              u64(192).nonzeroBitCount == Int(registered),
              u64(200).nonzeroBitCount == Int(started) else {
            return .failure(.incoherentSnapshot)
        }
        let timelineActive = flags & timelineActiveFlag != 0
        let isIdle = active == 0
        if isIdle {
            guard !timelineActive, epoch.timelineSeed == 0,
                  epoch.seedGeneration == 0, epoch.anchorHostTicks == 0,
                  u64(248) == u64(264), u64(272) == u64(280),
                  u64(1_192) == 0, u64(1_264) == 0 else {
                return .failure(.incoherentSnapshot)
            }
        } else {
            guard timelineActive, epoch.timelineSeed > 0,
                  epoch.seedGeneration == epoch.timelineSeed,
                  epoch.anchorHostTicks > 0 else {
                return .failure(.incoherentSnapshot)
            }
        }
        return .success(Self(
            sequence: sequence,
            capturedHostTicks: capturedHostTicks,
            epoch: epoch,
            isIdle: isIdle
        ))
    }

    static func provesMirroredIdle(_ observations: [Self]) -> Bool {
        guard observations.count == 4, let first = observations.first,
              observations.allSatisfy({ $0.isIdle && $0.epoch == first.epoch }) else {
            return false
        }
        return zip(observations, observations.dropFirst()).allSatisfy {
            $0.sequence < $1.sequence && $0.capturedHostTicks < $1.capturedHostTicks
        }
    }
}

struct WorldwideVirtualMicrophoneDriverDiagnosticReader: Sendable {
    typealias PropertyRead = @Sendable (
        AudioDeviceID, AudioObjectPropertyAddress,
        inout UInt32, inout Unmanaged<CFPropertyList>?
    ) -> OSStatus
    private let readProperty: PropertyRead
    private let hostTicks: @Sendable () -> UInt64

    init(
        readProperty: @escaping PropertyRead = { deviceID, address, size, value in
            var address = address
            return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        },
        hostTicks: @escaping @Sendable () -> UInt64 = { mach_absolute_time() }
    ) {
        self.readProperty = readProperty
        self.hostTicks = hostTicks
    }

    func read(_ deviceID: AudioDeviceID) -> Result<
        WorldwideVirtualMicrophoneDriverDiagnosticSnapshot,
        WorldwideVirtualMicrophoneDriverDiagnosticError
    > {
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        var value: Unmanaged<CFPropertyList>?
        let address = AudioObjectPropertyAddress(
            mSelector: WorldwideVirtualMicrophoneDriverDiagnosticSnapshot.property,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let before = hostTicks()
        let status = readProperty(deviceID, address, &size, &value)
        let after = hostTicks()
        defer { value?.release() }
        guard status == noErr else { return .failure(.property(status)) }
        guard size == UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size) else {
            return .failure(.propertySize(size))
        }
        guard let property = value?.takeUnretainedValue(),
              CFGetTypeID(property) == CFDataGetTypeID() else {
            return .failure(.propertyType)
        }
        let data = unsafeBitCast(property, to: CFData.self)
        guard CFDataGetLength(data) == WorldwideVirtualMicrophoneDriverDiagnosticSnapshot.byteCount else {
            return .failure(.snapshotSize(CFDataGetLength(data)))
        }
        guard let bytes = CFDataGetBytePtr(data) else { return .failure(.propertyType) }
        let decoded = WorldwideVirtualMicrophoneDriverDiagnosticSnapshot.decode(
            Data(bytes: bytes, count: CFDataGetLength(data))
        )
        guard case .success(let snapshot) = decoded else { return decoded }
        guard before <= snapshot.capturedHostTicks, snapshot.capturedHostTicks <= after else {
            return .failure(.staleObservation)
        }
        return decoded
    }
}
