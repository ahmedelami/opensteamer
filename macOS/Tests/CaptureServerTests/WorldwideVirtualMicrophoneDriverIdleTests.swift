import CoreAudio
import Foundation
import XCTest
@testable import CaptureServer

@MainActor
final class WorldwideVirtualMicrophoneDriverIdleTests: XCTestCase {
    func testNativeHeaderFixtureDistinguishesIdleFromRetainedClientLease() throws {
        let idle = try snapshot()
        let active = try snapshot("active")
        XCTAssertTrue(idle.isIdle)
        XCTAssertFalse(active.isIdle)
        XCTAssertEqual(active.epoch.timelineSeed, 7)
        XCTAssertEqual(active.epoch.lastIssuedSessionID, 11)
    }

    func testDecoderRejectsNativeHeaderMutations() throws {
        for mode in ["schema", "struct-size", "missing-invariant", "unknown-flag",
                     "retained-seed", "retained-slot", "count-mismatch", "count-overflow",
                     "unbalanced-stop", "work-loop-active"] {
            let data = try VirtualMicrophoneDiagnosticFixture.data(mode)
            if case .success = WorldwideVirtualMicrophoneDriverDiagnosticSnapshot.decode(data) {
                XCTFail("Accepted invalid diagnostic fixture: \(mode)")
            }
        }
        let data = try VirtualMicrophoneDiagnosticFixture.data()
        for malformed in [Data(), Data(data.dropLast()), data + Data([0])] {
            XCTAssertEqual(
                WorldwideVirtualMicrophoneDriverDiagnosticSnapshot.decode(malformed),
                .failure(.snapshotSize(malformed.count))
            )
        }
    }

    func testMirroredReadsRequireOneIdleEpochWithFreshObservations() throws {
        let idle = try (1...4).map { try snapshot(sequence: UInt64($0)) }
        XCTAssertTrue(WorldwideVirtualMicrophoneDriverDiagnosticSnapshot.provesMirroredIdle(idle))
        for mode in ["active", "new-instance", "new-lifecycle", "new-session", "new-seed"] {
            var replaced = idle
            replaced[2] = try snapshot(mode, sequence: 3)
            XCTAssertFalse(
                WorldwideVirtualMicrophoneDriverDiagnosticSnapshot.provesMirroredIdle(replaced),
                "Accepted changed or active epoch: \(mode)"
            )
        }
        XCTAssertFalse(WorldwideVirtualMicrophoneDriverDiagnosticSnapshot.provesMirroredIdle(Array(idle.prefix(3))))
        XCTAssertFalse(WorldwideVirtualMicrophoneDriverDiagnosticSnapshot.provesMirroredIdle(Array(repeating: idle[0], count: 4)))
        XCTAssertFalse(WorldwideVirtualMicrophoneDriverDiagnosticSnapshot.provesMirroredIdle(Array(idle.reversed())))
    }

    func testProductionCFPropertyBoundaryValidatesAddressTypeAndFreshness() throws {
        let data = try VirtualMicrophoneDiagnosticFixture.data(capturedHostTicks: 1_000)
        let properties = LockedDiagnosticProperty(data: data)
        let reader = WorldwideVirtualMicrophoneDriverDiagnosticReader(
            readProperty: { deviceID, address, size, value in
                properties.read(deviceID, address, &size, &value)
            },
            hostTicks: { 1_000 }
        )
        XCTAssertTrue(try reader.read(31).get().isIdle)
        XCTAssertEqual(properties.lastDeviceID, 31)
        XCTAssertEqual(properties.lastSelector, 0x6F73_4453)
        XCTAssertEqual(properties.lastScope, kAudioObjectPropertyScopeGlobal)
        XCTAssertEqual(properties.lastElement, kAudioObjectPropertyElementMain)
        XCTAssertEqual(properties.requestedSize, UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size))
        let stale = WorldwideVirtualMicrophoneDriverDiagnosticReader(
            readProperty: { deviceID, address, size, value in
                properties.read(deviceID, address, &size, &value)
            },
            hostTicks: { 2_000 }
        )
        XCTAssertEqual(stale.read(31), .failure(.staleObservation))
    }

    func testProductionCFPropertyBoundaryFailsClosedOnReadErrorsAndWrongTypes() throws {
        let data = try VirtualMicrophoneDiagnosticFixture.data()
        let cases: [(OSStatus, UInt32, Bool, WorldwideVirtualMicrophoneDriverDiagnosticError)] = [
            (kAudioHardwareUnknownPropertyError, 8, false, .property(kAudioHardwareUnknownPropertyError)),
            (noErr, 0, false, .propertySize(0)),
            (noErr, 8, true, .propertyType),
        ]
        for (status, size, wrongType, expected) in cases {
            let properties = LockedDiagnosticProperty(data: data, status: status, size: size, wrongType: wrongType)
            let reader = WorldwideVirtualMicrophoneDriverDiagnosticReader(
                readProperty: { deviceID, address, size, value in
                    properties.read(deviceID, address, &size, &value)
                }
            )
            XCTAssertEqual(reader.read(31), .failure(expected))
        }
    }

    private func snapshot(
        _ mode: String = "idle", sequence: UInt64 = 1
    ) throws -> WorldwideVirtualMicrophoneDriverDiagnosticSnapshot {
        try WorldwideVirtualMicrophoneDriverDiagnosticSnapshot.decode(
            VirtualMicrophoneDiagnosticFixture.data(mode, sequence: sequence, capturedHostTicks: 100 + sequence)
        ).get()
    }
}

@MainActor
enum VirtualMicrophoneDiagnosticFixture {
    private static let binary: Result<URL, Error> = Result {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let macOS = tests.deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-diagnostic-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let executable = directory.appendingPathComponent("fixture")
        _ = try run(
            URL(fileURLWithPath: "/usr/bin/clang"),
            [macOS.appendingPathComponent("VirtualAudioDriver/tests/VirtualMicrophoneDiagnosticFixture.c").path,
             "-I", macOS.appendingPathComponent("VirtualAudioDriver/include").path,
             "-framework", "CoreAudio", "-framework", "CoreFoundation", "-o", executable.path]
        )
        return executable
    }

    static func data(
        _ mode: String = "idle", sequence: UInt64 = 1, capturedHostTicks: UInt64 = 1_000
    ) throws -> Data {
        try run(binary.get(), [mode, String(sequence), String(capturedHostTicks)])
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "VirtualMicrophoneDiagnosticFixture", code: Int(process.terminationStatus))
        }
        return data
    }
}

private final class LockedDiagnosticProperty: @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private let status: OSStatus
    private let size: UInt32
    private let wrongType: Bool
    private var address: AudioObjectPropertyAddress?
    private var deviceID: AudioDeviceID?
    private var inputSize: UInt32?

    init(data: Data, status: OSStatus = noErr, size: UInt32 = 8, wrongType: Bool = false) {
        self.data = data
        self.status = status
        self.size = size
        self.wrongType = wrongType
    }

    func read(
        _ deviceID: AudioDeviceID, _ address: AudioObjectPropertyAddress,
        _ size: inout UInt32, _ value: inout Unmanaged<CFPropertyList>?
    ) -> OSStatus {
        lock.withLock {
            self.address = address
            self.deviceID = deviceID
            inputSize = size
        }
        size = self.size
        if wrongType {
            value = Unmanaged.passRetained("invalid" as CFString)
        } else {
            value = Unmanaged.passRetained(data as CFData)
        }
        return status
    }

    var lastDeviceID: AudioDeviceID? { lock.withLock { deviceID } }
    var lastSelector: AudioObjectPropertySelector? { lock.withLock { address?.mSelector } }
    var lastScope: AudioObjectPropertyScope? { lock.withLock { address?.mScope } }
    var lastElement: AudioObjectPropertyElement? { lock.withLock { address?.mElement } }
    var requestedSize: UInt32? { lock.withLock { inputSize } }
}
