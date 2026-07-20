import XCTest
@testable import CaptureCore

final class StreamingCaptureManagerTests: XCTestCase {
    func testCancellationAfterStartStillStopsSourceExactlyOnce() async {
        let waitEntered = expectation(description: "capture wait entered")
        let state = CaptureLifecycleState()
        let capture = Task {
            try await StreamingCaptureManager.runStartedSource(
                start: { state.recordStart() },
                wait: {
                    waitEntered.fulfill()
                    try await Task.sleep(for: .seconds(60))
                },
                stop: {
                    try Task.checkCancellation()
                    state.recordStop()
                }
            )
        }

        await fulfillment(of: [waitEntered], timeout: 1)
        capture.cancel()

        do {
            try await capture.value
            XCTFail("A cancelled capture wait must remain cancelled after cleanup")
        } catch is CancellationError {
            // The supervisor still receives the original cancellation after the source stops.
        } catch {
            XCTFail("Unexpected capture error: \(error)")
        }
        XCTAssertEqual(state.snapshot(), .init(starts: 1, stops: 1))
    }

    func testCancellationAfterWaitReturnsNormallyStillStopsSourceExactlyOnce() async {
        let waitEntered = expectation(description: "capture wait entered")
        let gate = CancellationInsensitiveGate()
        let state = CaptureLifecycleState()
        let capture = Task {
            try await StreamingCaptureManager.runStartedSource(
                start: { state.recordStart() },
                wait: {
                    waitEntered.fulfill()
                    await gate.wait()
                },
                stop: {
                    try Task.checkCancellation()
                    state.recordStop()
                }
            )
        }

        await fulfillment(of: [waitEntered], timeout: 1)
        capture.cancel()
        await gate.open()

        do {
            try await capture.value
            XCTFail("Cancellation must propagate after cleanup")
        } catch is CancellationError {
            // Expected after the source has stopped.
        } catch {
            XCTFail("Unexpected capture error: \(error)")
        }

        XCTAssertEqual(
            state.snapshot(),
            .init(starts: 1, stops: 1)
        )
    }

    func testCancellationAfterCleanupBeginsDoesNotCancelCleanup() async {
        let cleanupEntered = expectation(description: "cleanup entered")
        let cleanupGate = CancellationInsensitiveGate()
        let state = CaptureLifecycleState()
        let capture = Task {
            try await StreamingCaptureManager.runStartedSource(
                start: { state.recordStart() },
                wait: {},
                stop: {
                    try Task.checkCancellation()
                    cleanupEntered.fulfill()
                    await cleanupGate.wait()
                    try Task.checkCancellation()
                    state.recordStop()
                }
            )
        }

        await fulfillment(of: [cleanupEntered], timeout: 1)
        capture.cancel()
        XCTAssertEqual(state.snapshot(), .init(starts: 1, stops: 0))
        await cleanupGate.open()

        do {
            try await capture.value
            XCTFail("Cancellation must propagate only after in-flight cleanup completes")
        } catch is CancellationError {
            // The cleanup task remains uncancelled, then the owner reports cancellation.
        } catch {
            XCTFail("Unexpected capture error: \(error)")
        }
        XCTAssertEqual(state.snapshot(), .init(starts: 1, stops: 1))
    }

    func testWaitErrorWinsWhenCleanupAlsoFails() async {
        let state = CaptureLifecycleState()

        do {
            try await StreamingCaptureManager.runStartedSource(
                start: { state.recordStart() },
                wait: { throw CaptureLifecycleError.waitFailed },
                stop: {
                    state.recordStop()
                    throw CaptureLifecycleError.cleanupFailed
                }
            )
            XCTFail("The original wait error must propagate")
        } catch let error as CaptureLifecycleError {
            XCTAssertEqual(error, .waitFailed)
        } catch {
            XCTFail("Unexpected capture error: \(error)")
        }

        XCTAssertEqual(state.snapshot(), .init(starts: 1, stops: 1))
    }

    func testCleanupErrorPropagatesAfterNormalWait() async {
        let state = CaptureLifecycleState()

        do {
            try await StreamingCaptureManager.runStartedSource(
                start: { state.recordStart() },
                wait: {},
                stop: {
                    state.recordStop()
                    throw CaptureLifecycleError.cleanupFailed
                }
            )
            XCTFail("A cleanup failure after a normal wait must propagate")
        } catch let error as CaptureLifecycleError {
            XCTAssertEqual(error, .cleanupFailed)
        } catch {
            XCTFail("Unexpected capture error: \(error)")
        }

        XCTAssertEqual(state.snapshot(), .init(starts: 1, stops: 1))
    }

    func testStartFailureDoesNotAttemptCleanup() async {
        let state = CaptureLifecycleState()

        do {
            try await StreamingCaptureManager.runStartedSource(
                start: {
                    state.recordStart()
                    throw CaptureLifecycleError.startFailed
                },
                wait: { state.recordWait() },
                stop: { state.recordStop() }
            )
            XCTFail("A start failure must propagate")
        } catch let error as CaptureLifecycleError {
            XCTAssertEqual(error, .startFailed)
        } catch {
            XCTFail("Unexpected capture error: \(error)")
        }

        XCTAssertEqual(state.snapshot(), .init(starts: 1, stops: 0))
    }
}

private enum CaptureLifecycleError: Error, Equatable {
    case startFailed
    case waitFailed
    case cleanupFailed
}

private actor CancellationInsensitiveGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private final class CaptureLifecycleState: @unchecked Sendable {
    struct Snapshot: Equatable {
        let starts: Int
        let stops: Int
        let waits: Int

        init(starts: Int, stops: Int, waits: Int = 0) {
            self.starts = starts
            self.stops = stops
            self.waits = waits
        }
    }

    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var waits = 0

    func recordStart() {
        lock.lock()
        starts += 1
        lock.unlock()
    }

    func recordStop() {
        lock.lock()
        stops += 1
        lock.unlock()
    }

    func recordWait() {
        lock.lock()
        waits += 1
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(starts: starts, stops: stops, waits: waits)
    }
}
