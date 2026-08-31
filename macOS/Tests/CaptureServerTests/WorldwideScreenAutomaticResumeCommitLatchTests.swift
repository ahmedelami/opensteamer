import Foundation
import XCTest
@testable import CaptureServer

final class WorldwideScreenAutomaticResumeCommitLatchTests: XCTestCase {
    func testCommittedAcknowledgementAtomicallyWinsConcurrentCleanup() {
        let latch = WorldwideScreenAutomaticResumeCommitLatch()
        let operationStarted = DispatchSemaphore(value: 0)
        let releaseOperation = DispatchSemaphore(value: 0)
        let commitFinished = DispatchSemaphore(value: 0)
        let cleanupStarted = DispatchSemaphore(value: 0)
        let cleanupFinished = DispatchSemaphore(value: 0)
        let commitFailed = LockedTestValue(false)
        let cleanupClaimedFailure = LockedTestValue<Bool?>(nil)

        DispatchQueue.global(qos: .userInitiated).async {
            defer { commitFinished.signal() }
            do {
                try latch.commit {
                    operationStarted.signal()
                    _ = releaseOperation.wait(timeout: .now() + 2)
                }
            } catch {
                commitFailed.set(true)
            }
        }
        XCTAssertEqual(operationStarted.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            cleanupStarted.signal()
            cleanupClaimedFailure.set(latch.claimFailure())
            cleanupFinished.signal()
        }
        XCTAssertEqual(cleanupStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(cleanupFinished.wait(timeout: .now() + 0.05), .timedOut)

        releaseOperation.signal()
        XCTAssertEqual(commitFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(cleanupFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(commitFailed.get())
        XCTAssertEqual(cleanupClaimedFailure.get(), false)
        XCTAssertTrue(latch.isCommitted)
    }

    func testCleanupClaimAtomicallyPreventsIrreversibleAcknowledgement() {
        let latch = WorldwideScreenAutomaticResumeCommitLatch()
        var operationWasInvoked = false

        XCTAssertTrue(latch.claimFailure())
        XCTAssertThrowsError(
            try latch.commit {
                operationWasInvoked = true
            }
        )
        XCTAssertFalse(operationWasInvoked)
        XCTAssertFalse(latch.isCommitted)
        XCTAssertFalse(latch.claimFailure())
    }

    func testServiceResetClaimsLatchBeforePolicyClassificationAndContextClear() throws {
        let source = try serviceSource()
        let start = try XCTUnwrap(
            source.range(
                of: "    private func resetAutomaticScreenMediaSuspensionState() {"
            )?.upperBound
        )
        let end = try XCTUnwrap(
            source.range(
                of: "    private func resetScreenClientDiagnosticsFreshness()",
                range: start..<source.endIndex
            )?.lowerBound
        )
        let method = String(source[start..<end])
        let claim = try XCTUnwrap(
            method.range(of: "context.finalAcknowledgementCommit.claimFailure()")
        )
        let failed = try XCTUnwrap(
            method.range(of: "screenVideoAdaptationPolicy.automaticResumeAttemptFailed()")
        )
        let succeeded = try XCTUnwrap(
            method.range(of: "screenVideoAdaptationPolicy.automaticResumeAttemptSucceeded()")
        )
        let contextClear = try XCTUnwrap(
            method.range(of: "automaticScreenMediaResumeContext = nil")
        )

        XCTAssertLessThan(claim.lowerBound, failed.lowerBound)
        XCTAssertLessThan(claim.lowerBound, succeeded.lowerBound)
        XCTAssertLessThan(failed.lowerBound, contextClear.lowerBound)
        XCTAssertLessThan(succeeded.lowerBound, contextClear.lowerBound)
        XCTAssertFalse(method.contains("finalAcknowledgementCommit.isCommitted"))
    }

    private func serviceSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
            ),
            encoding: .utf8
        )
    }
}

private final class LockedTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        lock.withLock {
            self.value = value
        }
    }

    func get() -> Value {
        lock.withLock { value }
    }
}
