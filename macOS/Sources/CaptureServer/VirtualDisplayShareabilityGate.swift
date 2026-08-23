import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Stable display metadata used while waiting for ScreenCaptureKit registration.
struct VirtualDisplaySnapshot: Equatable, Sendable {
    let displayID: UInt32
    let vendorID: UInt32
    let productID: UInt32
}

/// Proves that ScreenCaptureKit sees the exact owned display before listeners advertise it.
struct VirtualDisplayShareabilityGate: Sendable {
    typealias SnapshotProvider = @Sendable () async throws -> [VirtualDisplaySnapshot]
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    let maximumAttempts: Int
    let retryDelay: Duration
    let snapshotTimeout: Duration
    let snapshotProvider: SnapshotProvider
    let sleeper: Sleeper

    init(
        maximumAttempts: Int,
        retryDelay: Duration,
        snapshotTimeout: Duration = .seconds(5),
        snapshotProvider: @escaping SnapshotProvider,
        sleeper: @escaping Sleeper
    ) {
        self.maximumAttempts = maximumAttempts
        self.retryDelay = retryDelay
        self.snapshotTimeout = snapshotTimeout
        self.snapshotProvider = snapshotProvider
        self.sleeper = sleeper
    }

    static let live = Self(
        maximumAttempts: 100,
        retryDelay: .milliseconds(50),
        snapshotTimeout: .seconds(5),
        snapshotProvider: {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            return content.displays.map {
                VirtualDisplaySnapshot(
                    displayID: $0.displayID,
                    vendorID: CGDisplayVendorNumber($0.displayID),
                    productID: CGDisplayModelNumber($0.displayID)
                )
            }
        },
        sleeper: { duration in
            try await Task.sleep(for: duration)
        }
    )

    func waitUntilReady(
        displayID: UInt32,
        vendorID: UInt32,
        productID: UInt32,
        displayIsAlive: @escaping @Sendable () -> Bool
    ) async throws {
        guard maximumAttempts > 0 else {
            throw VirtualDisplayShareabilityError.invalidAttemptCount
        }
        for attempt in 0..<maximumAttempts {
            try Task.checkCancellation()
            guard displayIsAlive() else {
                throw VirtualDisplayShareabilityError.displayTerminated(displayID)
            }
            let snapshots = try await snapshotsBeforeDeadline(displayID: displayID)
            guard displayIsAlive() else {
                throw VirtualDisplayShareabilityError.displayTerminated(displayID)
            }
            if let snapshot = snapshots.first(where: { $0.displayID == displayID }) {
                guard snapshot.vendorID == vendorID,
                    snapshot.productID == productID
                else {
                    throw VirtualDisplayShareabilityError.identityMismatch(
                        displayID: displayID,
                        expectedVendorID: vendorID,
                        expectedProductID: productID,
                        actualVendorID: snapshot.vendorID,
                        actualProductID: snapshot.productID
                    )
                }
                return
            }
            if attempt + 1 < maximumAttempts {
                try await sleeper(retryDelay)
            }
        }
        throw VirtualDisplayShareabilityError.timedOut(displayID)
    }

    /// Bounds a framework snapshot even if ScreenCaptureKit does not honor task cancellation.
    ///
    /// The provider is deliberately unstructured: the deadline can finish this method and let
    /// Main release the virtual display and process lock without awaiting a wedged framework call.
    private func snapshotsBeforeDeadline(
        displayID: UInt32
    ) async throws -> [VirtualDisplaySnapshot] {
        let pair = AsyncThrowingStream<[VirtualDisplaySnapshot], any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let providerTask = Task {
            do {
                pair.continuation.yield(try await snapshotProvider())
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: snapshotTimeout)
                pair.continuation.finish(
                    throwing: VirtualDisplayShareabilityError.snapshotTimedOut(displayID)
                )
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        defer {
            providerTask.cancel()
            timeoutTask.cancel()
            pair.continuation.finish()
        }

        return try await withTaskCancellationHandler {
            var iterator = pair.stream.makeAsyncIterator()
            guard let snapshots = try await iterator.next() else {
                throw VirtualDisplayShareabilityError.snapshotTimedOut(displayID)
            }
            return snapshots
        } onCancel: {
            providerTask.cancel()
            timeoutTask.cancel()
            pair.continuation.finish(throwing: CancellationError())
        }
    }
}

enum VirtualDisplayShareabilityError: LocalizedError, Equatable, Sendable {
    case invalidAttemptCount
    case displayTerminated(UInt32)
    case identityMismatch(
        displayID: UInt32,
        expectedVendorID: UInt32,
        expectedProductID: UInt32,
        actualVendorID: UInt32,
        actualProductID: UInt32
    )
    case snapshotTimedOut(UInt32)
    case timedOut(UInt32)

    var errorDescription: String? {
        switch self {
        case .invalidAttemptCount:
            "Virtual display shareability requires at least one bounded attempt"
        case .displayTerminated(let displayID):
            "Virtual display \(displayID) terminated before ScreenCaptureKit could use it"
        case .identityMismatch(let displayID, _, _, _, _):
            "Display \(displayID) was reused by an unexpected display identity"
        case .snapshotTimedOut(let displayID):
            "ScreenCaptureKit did not complete the display \(displayID) snapshot before its deadline"
        case .timedOut(let displayID):
            "ScreenCaptureKit did not expose virtual display \(displayID) before the timeout"
        }
    }
}
