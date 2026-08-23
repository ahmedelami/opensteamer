import XCTest

@testable import CaptureServer

final class VirtualDisplayShareabilityGateTests: XCTestCase {
    func testReadyDisplayRequiresExactIdentity() async throws {
        let gate = makeGate(snapshots: [[expectedSnapshot]])

        try await gate.waitUntilReady(
            displayID: expectedSnapshot.displayID,
            vendorID: expectedSnapshot.vendorID,
            productID: expectedSnapshot.productID,
            displayIsAlive: { true }
        )
    }

    func testDelayedScreenCaptureKitRegistrationRetriesBoundedly() async throws {
        let sequence = SnapshotSequence([[], [], [expectedSnapshot]])
        let gate = VirtualDisplayShareabilityGate(
            maximumAttempts: 3,
            retryDelay: .zero,
            snapshotProvider: { sequence.next() },
            sleeper: { _ in }
        )

        try await gate.waitUntilReady(
            displayID: expectedSnapshot.displayID,
            vendorID: expectedSnapshot.vendorID,
            productID: expectedSnapshot.productID,
            displayIsAlive: { true }
        )
        XCTAssertEqual(sequence.callCount, 3)
    }

    func testReusedDisplayIDWithWrongIdentityFailsClosed() async {
        let wrongIdentity = VirtualDisplaySnapshot(
            displayID: expectedSnapshot.displayID,
            vendorID: 0xFFFF,
            productID: expectedSnapshot.productID
        )
        let gate = makeGate(snapshots: [[wrongIdentity]])

        await XCTAssertThrowsErrorAsync(
            try await gate.waitUntilReady(
                displayID: expectedSnapshot.displayID,
                vendorID: expectedSnapshot.vendorID,
                productID: expectedSnapshot.productID,
                displayIsAlive: { true }
            )
        ) { error in
            XCTAssertEqual(
                error as? VirtualDisplayShareabilityError,
                .identityMismatch(
                    displayID: expectedSnapshot.displayID,
                    expectedVendorID: expectedSnapshot.vendorID,
                    expectedProductID: expectedSnapshot.productID,
                    actualVendorID: wrongIdentity.vendorID,
                    actualProductID: wrongIdentity.productID
                )
            )
        }
    }

    func testTerminatedDisplayFailsBeforeEnumerating() async {
        let sequence = SnapshotSequence([[expectedSnapshot]])
        let gate = VirtualDisplayShareabilityGate(
            maximumAttempts: 1,
            retryDelay: .zero,
            snapshotProvider: { sequence.next() },
            sleeper: { _ in }
        )

        await XCTAssertThrowsErrorAsync(
            try await gate.waitUntilReady(
                displayID: expectedSnapshot.displayID,
                vendorID: expectedSnapshot.vendorID,
                productID: expectedSnapshot.productID,
                displayIsAlive: { false }
            )
        ) { error in
            XCTAssertEqual(
                error as? VirtualDisplayShareabilityError,
                .displayTerminated(expectedSnapshot.displayID)
            )
        }
        XCTAssertEqual(sequence.callCount, 0)
    }

    func testDisplayTerminatingDuringSnapshotFailsBeforeSuccess() async {
        let validity = ValiditySequence([true, false])
        let gate = makeGate(snapshots: [[expectedSnapshot]])

        await XCTAssertThrowsErrorAsync(
            try await gate.waitUntilReady(
                displayID: expectedSnapshot.displayID,
                vendorID: expectedSnapshot.vendorID,
                productID: expectedSnapshot.productID,
                displayIsAlive: { validity.next() }
            )
        ) { error in
            XCTAssertEqual(
                error as? VirtualDisplayShareabilityError,
                .displayTerminated(expectedSnapshot.displayID)
            )
        }
        XCTAssertEqual(validity.callCount, 2)
    }

    func testMissingDisplayTimesOutAfterExactAttemptBudget() async {
        let sequence = SnapshotSequence([[], [], []])
        let gate = VirtualDisplayShareabilityGate(
            maximumAttempts: 3,
            retryDelay: .zero,
            snapshotProvider: { sequence.next() },
            sleeper: { _ in }
        )

        await XCTAssertThrowsErrorAsync(
            try await gate.waitUntilReady(
                displayID: expectedSnapshot.displayID,
                vendorID: expectedSnapshot.vendorID,
                productID: expectedSnapshot.productID,
                displayIsAlive: { true }
            )
        ) { error in
            XCTAssertEqual(
                error as? VirtualDisplayShareabilityError,
                .timedOut(expectedSnapshot.displayID)
            )
        }
        XCTAssertEqual(sequence.callCount, 3)
    }

    func testHangingScreenCaptureKitSnapshotHasAnIndependentDeadline() async {
        let gate = VirtualDisplayShareabilityGate(
            maximumAttempts: 100,
            retryDelay: .seconds(1),
            snapshotTimeout: .milliseconds(10),
            snapshotProvider: {
                try await Task.sleep(for: .seconds(60))
                return []
            },
            sleeper: { _ in }
        )

        let startedAt = ContinuousClock.now
        await XCTAssertThrowsErrorAsync(
            try await gate.waitUntilReady(
                displayID: expectedSnapshot.displayID,
                vendorID: expectedSnapshot.vendorID,
                productID: expectedSnapshot.productID,
                displayIsAlive: { true }
            )
        ) { error in
            XCTAssertEqual(
                error as? VirtualDisplayShareabilityError,
                .snapshotTimedOut(expectedSnapshot.displayID)
            )
        }
        XCTAssertLessThan(startedAt.duration(to: .now), .seconds(1))
    }

    private let expectedSnapshot = VirtualDisplaySnapshot(
        displayID: 42,
        vendorID: 0x6F73,
        productID: 0x1718
    )

    private func makeGate(
        snapshots: [[VirtualDisplaySnapshot]]
    ) -> VirtualDisplayShareabilityGate {
        let sequence = SnapshotSequence(snapshots)
        return VirtualDisplayShareabilityGate(
            maximumAttempts: snapshots.count,
            retryDelay: .zero,
            snapshotProvider: { sequence.next() },
            sleeper: { _ in }
        )
    }
}

private final class SnapshotSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshots: [[VirtualDisplaySnapshot]]
    private var index = 0

    init(_ snapshots: [[VirtualDisplaySnapshot]]) {
        self.snapshots = snapshots
    }

    var callCount: Int {
        lock.withLock { index }
    }

    func next() -> [VirtualDisplaySnapshot] {
        lock.withLock {
            defer { index += 1 }
            return snapshots[min(index, snapshots.count - 1)]
        }
    }
}

private final class ValiditySequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [Bool]
    private var index = 0

    init(_ values: [Bool]) {
        self.values = values
    }

    var callCount: Int {
        lock.withLock { index }
    }

    func next() -> Bool {
        lock.withLock {
            defer { index += 1 }
            return values[min(index, values.count - 1)]
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
