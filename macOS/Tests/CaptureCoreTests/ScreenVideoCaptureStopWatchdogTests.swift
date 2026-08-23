import Foundation
import XCTest

@testable import CaptureCore

final class ScreenCaptureLifecycleWatchdogTests: XCTestCase {
    func testSuccessfulStopCancelsAndDrainsWatchdog() async throws {
        let state = StopWatchdogState()

        let result = try await ScreenCaptureLifecycleWatchdog.perform(
            makeWatchdog: {
                state.recordFactoryCall()
                return Task {
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch {}
                    state.recordCompletion(cancelled: Task.isCancelled)
                }
            },
            operation: { 42 }
        )

        XCTAssertEqual(result, 42)
        XCTAssertEqual(state.snapshot, .init(factoryCalls: 1, cancellationCompletions: 1))
    }

    func testFailedStopPreservesErrorAfterCancellingWatchdog() async {
        let state = StopWatchdogState()

        do {
            _ = try await ScreenCaptureLifecycleWatchdog.perform(
                makeWatchdog: {
                    state.recordFactoryCall()
                    return Task {
                        do {
                            try await Task.sleep(for: .seconds(60))
                        } catch {}
                        state.recordCompletion(cancelled: Task.isCancelled)
                    }
                },
                operation: { throw StopWatchdogTestError.expected }
            ) as Void
            XCTFail("The native stop error must propagate")
        } catch StopWatchdogTestError.expected {
            // Expected after the watchdog has been cancelled and drained.
        } catch {
            XCTFail("Unexpected stop error: \(error)")
        }

        XCTAssertEqual(state.snapshot, .init(factoryCalls: 1, cancellationCompletions: 1))
    }

    func testAbsentWatchdogRunsOperationNormally() async throws {
        let result = try await ScreenCaptureLifecycleWatchdog.perform(
            makeWatchdog: { nil },
            operation: { "stopped" }
        )

        XCTAssertEqual(result, "stopped")
    }
}

private enum StopWatchdogTestError: Error {
    case expected
}

private final class StopWatchdogState: @unchecked Sendable {
    struct Snapshot: Equatable {
        var factoryCalls = 0
        var cancellationCompletions = 0
    }

    private let lock = NSLock()
    private var value = Snapshot()

    var snapshot: Snapshot {
        lock.withLock { value }
    }

    func recordFactoryCall() {
        lock.withLock { value.factoryCalls += 1 }
    }

    func recordCompletion(cancelled: Bool) {
        guard cancelled else { return }
        lock.withLock { value.cancellationCompletions += 1 }
    }
}
