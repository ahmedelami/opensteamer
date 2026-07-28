#if os(macOS)
import CoreAudio
import Foundation
import XCTest
@testable import CaptureCore

final class BlackHoleDeviceAvailabilityMonitorTests:
    XCTestCase
{
    func testListenerRegistersBeforeInitialInventoryAndUsesExactRemovalIdentity()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("BlackHole2ch_UID"),
            ]
        )
        let ledger = BlackHoleSnapshotLedger()
        let queue = DispatchQueue(
            label: "test.BlackHoleDeviceAvailabilityMonitor.order"
        )
        let epoch = UUID()
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: queue,
            makeEpoch: { epoch }
        )

        let returnedEpoch = try monitor.start {
            ledger.append($0)
        }

        XCTAssertEqual(returnedEpoch, epoch)
        XCTAssertEqual(
            operations.events,
            ["register", "inventory"]
        )
        XCTAssertTrue(operations.registeredExactDevicesAddress)
        XCTAssertEqual(
            ledger.snapshots,
            [
                BlackHoleDeviceAvailabilitySnapshot(
                    monitorEpoch: epoch,
                    deviceGeneration: 1,
                    isAvailable: true,
                    deviceUID: "BlackHole2ch_UID"
                ),
            ]
        )
        XCTAssertEqual(operations.defaultDeviceWriteCount, 0)

        monitor.stop()
        XCTAssertTrue(operations.removedExactRegistration)
        XCTAssertEqual(
            operations.events,
            ["register", "inventory", "remove"]
        )
    }

    func testStoppedAndOldEpochCallbacksAreFenced() throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("BlackHole2ch_UID"),
                .uid("BlackHole2ch_UID"),
                .uid("BlackHole2ch_UID"),
            ]
        )
        let ledger = BlackHoleSnapshotLedger()
        let epochs = [UUID(), UUID()]
        let epochSource = LockedEpochSource(epochs)
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label: "test.BlackHoleDeviceAvailabilityMonitor.epoch"
            ),
            makeEpoch: { epochSource.next() }
        )

        let firstEpoch = try monitor.start {
            ledger.append($0)
        }
        monitor.stop()
        let secondEpoch = try monitor.start {
            ledger.append($0)
        }
        XCTAssertNotEqual(firstEpoch, secondEpoch)
        XCTAssertEqual(ledger.snapshots.count, 2)

        operations.emitRetiredListener(at: 0)
        XCTAssertEqual(
            ledger.snapshots.count,
            2,
            "A callback retained from the stopped epoch must be ignored."
        )

        operations.emitCurrentListener()
        XCTAssertEqual(ledger.snapshots.count, 3)
        XCTAssertEqual(
            ledger.snapshots.last?.monitorEpoch,
            secondEpoch
        )
        monitor.stop()
    }

    func testLookupFailureAndDeviceReinstallPublishMonotonicGenerations()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("BlackHole2ch_UID"),
                .failure,
                .uid("BlackHole2ch_UID"),
            ]
        )
        let ledger = BlackHoleSnapshotLedger()
        let epoch = UUID()
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label: "test.BlackHoleDeviceAvailabilityMonitor.reinstall"
            ),
            makeEpoch: { epoch }
        )

        try monitor.start {
            ledger.append($0)
        }
        operations.emitCurrentListener()
        operations.emitCurrentListener()

        XCTAssertEqual(
            ledger.snapshots.map(\.deviceGeneration),
            [1, 2, 3]
        )
        XCTAssertEqual(
            ledger.snapshots.map(\.isAvailable),
            [true, false, true]
        )
        XCTAssertEqual(
            ledger.snapshots.map(\.deviceUID),
            [
                "BlackHole2ch_UID",
                nil,
                "BlackHole2ch_UID",
            ]
        )
        XCTAssertEqual(operations.defaultDeviceWriteCount, 0)
        monitor.stop()
    }

    func testNonIncreasingGenerationAndForeignEpochAreRejected()
        throws {
        let operations = BlackHoleMonitorOperationsFake(
            lookupResults: [
                .uid("BlackHole2ch_UID"),
            ]
        )
        let ledger = BlackHoleSnapshotLedger()
        let epoch = UUID()
        let monitor = BlackHoleDeviceAvailabilityMonitor(
            operations: operations,
            callbackQueue: DispatchQueue(
                label: "test.BlackHoleDeviceAvailabilityMonitor.generation"
            ),
            makeEpoch: { epoch }
        )

        try monitor.start {
            ledger.append($0)
        }
        monitor.publishForTesting(
            BlackHoleDeviceAvailabilitySnapshot(
                monitorEpoch: epoch,
                deviceGeneration: 3,
                isAvailable: true,
                deviceUID: "BlackHole2ch_UID"
            )
        )
        monitor.publishForTesting(
            BlackHoleDeviceAvailabilitySnapshot(
                monitorEpoch: epoch,
                deviceGeneration: 2,
                isAvailable: false,
                deviceUID: nil
            )
        )
        monitor.publishForTesting(
            BlackHoleDeviceAvailabilitySnapshot(
                monitorEpoch: UUID(),
                deviceGeneration: 4,
                isAvailable: false,
                deviceUID: nil
            )
        )

        XCTAssertEqual(
            ledger.snapshots.map(\.deviceGeneration),
            [1, 3]
        )
        XCTAssertTrue(ledger.snapshots.last?.isAvailable == true)
        monitor.stop()
    }
}

private final class BlackHoleMonitorOperationsFake:
    BlackHoleDeviceAvailabilityMonitoringOperations,
    @unchecked Sendable
{
    enum LookupResult {
        case uid(String)
        case failure
    }

    private struct ListenerRecord {
        var address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let block: AudioObjectPropertyListenerBlock
        let blockIdentity: UnsafeMutableRawPointer
    }

    private let lock = NSLock()
    private var lookupResults: [LookupResult]
    private var eventsStorage: [String] = []
    private var activeListener: ListenerRecord?
    private var retiredListeners: [ListenerRecord] = []
    private var registeredExactAddress = false
    private var removedExact = false

    init(lookupResults: [LookupResult]) {
        self.lookupResults = lookupResults
    }

    var events: [String] {
        lock.withLock { eventsStorage }
    }

    var registeredExactDevicesAddress: Bool {
        lock.withLock { registeredExactAddress }
    }

    var removedExactRegistration: Bool {
        lock.withLock { removedExact }
    }

    var defaultDeviceWriteCount: Int {
        0
    }

    func addDevicesListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        lock.withLock {
            eventsStorage.append("register")
            registeredExactAddress =
                address.mSelector == kAudioHardwarePropertyDevices
                && address.mScope
                    == kAudioObjectPropertyScopeGlobal
                && address.mElement
                    == kAudioObjectPropertyElementMain
            activeListener = ListenerRecord(
                address: address,
                queue: queue,
                block: block,
                blockIdentity: blockPointer(block)
            )
        }
        return noErr
    }

    func removeDevicesListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        lock.withLock {
            eventsStorage.append("remove")
            guard let activeListener else {
                return
            }
            removedExact =
                Self.addressesEqual(
                    address,
                    activeListener.address
                )
                && queue === activeListener.queue
                && blockPointer(block)
                    == activeListener.blockIdentity
            retiredListeners.append(activeListener)
            self.activeListener = nil
        }
        return noErr
    }

    func resolveBlackHole2ChannelDeviceUID() throws -> String {
        try lock.withLock {
            eventsStorage.append("inventory")
            guard !lookupResults.isEmpty else {
                throw BlackHoleMonitorLookupError.injected
            }
            switch lookupResults.removeFirst() {
            case .uid(let uid):
                return uid
            case .failure:
                throw BlackHoleMonitorLookupError.injected
            }
        }
    }

    func emitCurrentListener() {
        let listener = lock.withLock { activeListener }
        emit(listener)
    }

    func emitRetiredListener(at index: Int) {
        let listener: ListenerRecord? = lock.withLock {
            guard retiredListeners.indices.contains(index) else {
                return nil
            }
            return retiredListeners[index]
        }
        emit(listener)
    }

    private func emit(_ listener: ListenerRecord?) {
        guard let listener else { return }
        listener.queue.sync {
            var address = listener.address
            withUnsafePointer(to: &address) {
                listener.block(1, $0)
            }
        }
    }

    private func blockPointer(
        _ block: AudioObjectPropertyListenerBlock
    ) -> UnsafeMutableRawPointer {
        Unmanaged.passUnretained(block as AnyObject).toOpaque()
    }

    private static func addressesEqual(
        _ lhs: AudioObjectPropertyAddress,
        _ rhs: AudioObjectPropertyAddress
    ) -> Bool {
        lhs.mSelector == rhs.mSelector
            && lhs.mScope == rhs.mScope
            && lhs.mElement == rhs.mElement
    }
}

private enum BlackHoleMonitorLookupError: Error {
    case injected
}

private final class BlackHoleSnapshotLedger:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage:
        [BlackHoleDeviceAvailabilitySnapshot] = []

    func append(
        _ snapshot: BlackHoleDeviceAvailabilitySnapshot
    ) {
        lock.withLock {
            storage.append(snapshot)
        }
    }

    var snapshots: [BlackHoleDeviceAvailabilitySnapshot] {
        lock.withLock { storage }
    }
}

private final class LockedEpochSource: @unchecked Sendable {
    private let lock = NSLock()
    private var epochs: [UUID]

    init(_ epochs: [UUID]) {
        self.epochs = epochs
    }

    func next() -> UUID {
        lock.withLock {
            guard !epochs.isEmpty else {
                return UUID()
            }
            return epochs.removeFirst()
        }
    }
}

private extension NSLock {
    func withLock<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
#endif
