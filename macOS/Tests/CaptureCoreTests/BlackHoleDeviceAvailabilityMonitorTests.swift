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
        XCTAssertEqual(monitor.currentSnapshot(), ledger.snapshots.last)
        XCTAssertEqual(operations.defaultDeviceWriteCount, 0)

        monitor.stop()
        XCTAssertNil(monitor.currentSnapshot())
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

final class BlackHoleDefaultInputLeaseTests:
    XCTestCase
{
    func testListenerPrecedesOwnedWriteAndReleaseRestoresPriorUID() {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(operations)

        XCTAssertTrue(lease.acquire(generation: 1))
        XCTAssertEqual(
            operations.currentUID,
            BlackHoleDefaultInputLease.canonicalDeviceUID
        )
        XCTAssertEqual(
            Array(operations.events.prefix(4)),
            ["register", "read", "resolve:BlackHole2ch_UID", "write:2"]
        )

        lease.release(generation: 1)
        XCTAssertEqual(operations.currentUID, "BuiltInMic_UID")
        XCTAssertEqual(operations.writtenDeviceIDs, [2, 1])
        XCTAssertTrue(operations.removedExactRegistration)
        XCTAssertTrue(operations.registeredExactInputAddress)
    }

    func testNoErrWithoutNotificationProofDegradesAndRestoresBestEffort() {
        let operations = DefaultInputLeaseOperationsFake()
        operations.emitsNotifications = false
        let lease = makeLease(
            operations,
            proofTimeout: 0.01
        )

        XCTAssertFalse(lease.acquire(generation: 1))
        XCTAssertEqual(operations.currentUID, "BuiltInMic_UID")
        lease.release(generation: 1)
        XCTAssertTrue(operations.removedExactRegistration)
    }

    func testExternalChoiceIsNotOverwrittenOrRestored() {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(operations)
        XCTAssertTrue(lease.acquire(generation: 1))

        operations.externalSelect(deviceID: 3)
        lease.drainForTesting()
        XCTAssertEqual(
            operations.currentUID,
            "USBMic_UID"
        )

        lease.release(generation: 1)
        XCTAssertEqual(operations.currentUID, "USBMic_UID")
        XCTAssertFalse(lease.acquire(generation: 1))
        XCTAssertEqual(operations.currentUID, "USBMic_UID")
    }

    func testStaleGenerationCannotRestoreOverReplacement() {
        let operations = DefaultInputLeaseOperationsFake()
        let lease = makeLease(operations)
        XCTAssertTrue(lease.acquire(generation: 1))
        XCTAssertTrue(lease.acquire(generation: 2))

        lease.release(generation: 1)
        XCTAssertEqual(
            operations.currentUID,
            BlackHoleDefaultInputLease.canonicalDeviceUID
        )

        lease.release(generation: 2)
        XCTAssertEqual(operations.currentUID, "BuiltInMic_UID")
    }

    private func makeLease(
        _ operations: DefaultInputLeaseOperationsFake,
        proofTimeout: TimeInterval = 0.1
    ) -> BlackHoleDefaultInputLease {
        BlackHoleDefaultInputLease(
            operations: operations,
            operationQueue: DispatchQueue(
                label: "test.BlackHoleDefaultInputLease.operations"
            ),
            listenerQueue: DispatchQueue(
                label: "test.BlackHoleDefaultInputLease.listener"
            ),
            proofTimeout: proofTimeout
        )
    }
}

private final class DefaultInputLeaseOperationsFake:
    BlackHoleDefaultInputLeaseOperations,
    @unchecked Sendable
{
    private struct Listener {
        var address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let block: AudioObjectPropertyListenerBlock
        let identity: UnsafeMutableRawPointer
    }

    private let lock = NSLock()
    private let uids: [AudioDeviceID: String] = [
        1: "BuiltInMic_UID",
        2: "BlackHole2ch_UID",
        3: "USBMic_UID",
    ]
    private var currentDeviceID: AudioDeviceID = 1
    private var listener: Listener?
    private var eventStorage: [String] = []
    private var writes: [AudioDeviceID] = []
    private var exactInputAddress = false
    private var exactRemoval = false
    var emitsNotifications = true

    var currentUID: String {
        lock.withLock { uids[currentDeviceID]! }
    }

    var events: [String] {
        lock.withLock { eventStorage }
    }

    var writtenDeviceIDs: [AudioDeviceID] {
        lock.withLock { writes }
    }

    var registeredExactInputAddress: Bool {
        lock.withLock { exactInputAddress }
    }

    var removedExactRegistration: Bool {
        lock.withLock { exactRemoval }
    }

    func addDefaultInputListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        lock.withLock {
            eventStorage.append("register")
            exactInputAddress =
                address.mSelector
                    == kAudioHardwarePropertyDefaultInputDevice
                && address.mScope
                    == kAudioObjectPropertyScopeGlobal
                && address.mElement
                    == kAudioObjectPropertyElementMain
            listener = Listener(
                address: address,
                queue: queue,
                block: block,
                identity: blockPointer(block)
            )
        }
        return noErr
    }

    func removeDefaultInputListener(
        address: inout AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        lock.withLock {
            eventStorage.append("remove")
            guard let listener else { return }
            exactRemoval =
                listener.address.mSelector == address.mSelector
                && listener.address.mScope == address.mScope
                && listener.address.mElement == address.mElement
                && listener.queue === queue
                && listener.identity == blockPointer(block)
            self.listener = nil
        }
        return noErr
    }

    func currentDefaultInputUID() throws -> String {
        lock.withLock {
            eventStorage.append("read")
            return uids[currentDeviceID]!
        }
    }

    func resolveDeviceID(uid: String) throws -> AudioDeviceID {
        try lock.withLock {
            eventStorage.append("resolve:\(uid)")
            guard let entry = uids.first(where: {
                $0.value == uid
            }) else {
                throw BlackHoleDefaultInputFakeError.missingUID
            }
            return entry.key
        }
    }

    func setDefaultInputDevice(
        _ deviceID: AudioDeviceID
    ) -> OSStatus {
        let callback: Listener? = lock.withLock {
            eventStorage.append("write:\(deviceID)")
            guard uids[deviceID] != nil else {
                return nil
            }
            currentDeviceID = deviceID
            writes.append(deviceID)
            return emitsNotifications ? listener : nil
        }
        emit(callback)
        return noErr
    }

    func externalSelect(deviceID: AudioDeviceID) {
        let callback: Listener? = lock.withLock {
            currentDeviceID = deviceID
            return listener
        }
        emit(callback)
    }

    private func emit(_ listener: Listener?) {
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
        Unmanaged.passUnretained(
            block as AnyObject
        ).toOpaque()
    }
}

private enum BlackHoleDefaultInputFakeError: Error {
    case missingUID
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
