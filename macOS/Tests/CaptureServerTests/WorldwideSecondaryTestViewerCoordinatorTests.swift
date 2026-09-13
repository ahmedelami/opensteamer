import Foundation
import XCTest
@testable import CaptureServer

final class WorldwideSecondaryTestViewerCoordinatorTests: XCTestCase {
    @MainActor
    func testSecondaryConstructionFailureIsContainedAfterPrimaryIsReady() {
        let primaryIsReady = true

        let outcome: SecondaryTestViewerConstructionOutcome<String> =
            CaptureServerMain.constructOptionalSecondaryTestViewer {
                throw SecondaryStartupTestError.rendezvousUnavailable
            }

        guard case .unavailable = outcome else {
            return XCTFail("Expected optional construction failure")
        }
        XCTAssertTrue(primaryIsReady)
    }

    func testPrimaryResultIsPresentedBeforeOptionalConstructionInMainFlow() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/CaptureServerMain.swift"
            ),
            encoding: .utf8
        )
        let flowStart = try XCTUnwrap(
            source.range(of: "let startResult = try await runUntilProcessTermination")
        )
        let flowEnd = try XCTUnwrap(
            source.range(
                of: "            } else {\n                worldwideHostCoordinator = nil",
                range: flowStart.upperBound..<source.endIndex
            )
        )
        let flow = source[flowStart.lowerBound..<flowEnd.lowerBound]
        let primaryPresentation = try XCTUnwrap(flow.range(of: "switch startResult"))
        let secondaryConstruction = try XCTUnwrap(
            flow.range(of: "constructOptionalSecondaryTestViewer {")
        )

        XCTAssertLessThan(
            primaryPresentation.lowerBound,
            secondaryConstruction.lowerBound
        )
    }

    func testRecoverableSecondaryStartupFailurePreservesPrimaryPath() async throws {
        let stopProbe = SecondaryStartupStopProbe(confirmation: true)

        let outcome = try await CaptureServerMain.startOptionalSecondaryTestViewer(
            start: {
                throw SecondaryStartupTestError.rendezvousUnavailable
            },
            stop: {
                stopProbe.stop()
            }
        )

        guard case .unavailable = outcome else {
            return XCTFail("Expected a contained optional-sidecar failure")
        }
        XCTAssertEqual(stopProbe.stopCount, 1)
    }

    func testUnconfirmedSecondaryStartupTeardownRemainsFatal() async {
        let stopProbe = SecondaryStartupStopProbe(confirmation: false)

        do {
            _ = try await CaptureServerMain.startOptionalSecondaryTestViewer(
                start: {
                    throw SecondaryStartupTestError.rendezvousUnavailable
                },
                stop: {
                    stopProbe.stop()
                }
            )
            XCTFail("Expected unconfirmed native teardown to remain fatal")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "Native capture did not confirm shutdown"
                )
            )
        }
        XCTAssertEqual(stopProbe.stopCount, 1)
    }

    func testLifecycleRequiresOrderedStartAndStopOwnership() throws {
        var lifecycle = WorldwideSecondaryTestViewerLifecycle()

        XCTAssertEqual(lifecycle.state, .idle)
        try lifecycle.beginStart()
        XCTAssertEqual(lifecycle.state, .starting)
        try lifecycle.didStart()
        XCTAssertEqual(lifecycle.state, .running)
        XCTAssertTrue(lifecycle.beginStop())
        XCTAssertEqual(lifecycle.state, .stopping)
        try lifecycle.didStop()
        XCTAssertEqual(lifecycle.state, .stopped)
        XCTAssertFalse(lifecycle.beginStop())
    }

    func testLifecycleRejectsDuplicateStart() throws {
        var lifecycle = WorldwideSecondaryTestViewerLifecycle()
        try lifecycle.beginStart()

        XCTAssertThrowsError(try lifecycle.beginStart()) { error in
            XCTAssertEqual(
                error as? WorldwideSecondaryTestViewerLifecycleError,
                .invalidTransition
            )
        }
    }

    func testCoordinatorExposesCodeAndStopsServiceExactlyOnce() async throws {
        let service = SecondaryTestViewerServiceStub(
            invitationCode: "TEST-CODE"
        )
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            service: service
        )

        let code = try await coordinator.start()
        let runningState = await coordinator.currentState()
        let firstStop = await coordinator.stop()
        let secondStop = await coordinator.stop()
        let stoppedState = await coordinator.currentState()

        XCTAssertEqual(code, "TEST-CODE")
        XCTAssertEqual(runningState, .running)
        XCTAssertTrue(firstStop)
        XCTAssertTrue(secondStop)
        XCTAssertEqual(service.stopCallCount, 1)
        XCTAssertEqual(stoppedState, .stopped)
    }

    func testServiceCompletionStopsOnlySecondaryOwner() async throws {
        let service = SecondaryTestViewerServiceStub(
            invitationCode: "TEST-CODE"
        )
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            service: service
        )
        _ = try await coordinator.start()

        service.finish()
        for await _ in coordinator.completion { break }
        let stoppedState = await coordinator.currentState()

        XCTAssertEqual(stoppedState, .stopped)
        XCTAssertEqual(service.stopCallCount, 1)
    }

    func testUnconfirmedNativeStopIsRetriedWithoutRestarting() async throws {
        let service = SecondaryTestViewerServiceStub(
            invitationCode: "TEST-CODE",
            nativeStopIsUnconfirmed: true
        )
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            service: service
        )
        _ = try await coordinator.start()

        let firstStop = await coordinator.stop()
        service.nativeStopIsUnconfirmed = false
        let secondStop = await coordinator.stop()

        XCTAssertFalse(firstStop)
        XCTAssertTrue(secondStop)
        XCTAssertEqual(service.startCallCount, 1)
        XCTAssertEqual(service.stopCallCount, 2)
    }

    func testCaptureLifetimeOwnsSecondaryTeardownConfirmation() async throws {
        let service = SecondaryTestViewerServiceStub(
            invitationCode: "TEST-CODE"
        )
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            service: service
        )
        let lifetime = CaptureServiceLifetime()
        try lifetime.install(
            secondaryTestViewerCoordinator: coordinator
        )
        _ = try await coordinator.start()

        let confirmation = await lifetime.shutdown()
        let stoppedState = await coordinator.currentState()

        XCTAssertTrue(confirmation.worldwideNativeCaptureIsConfirmed)
        XCTAssertEqual(service.stopCallCount, 1)
        XCTAssertEqual(stoppedState, .stopped)
    }
}

private enum SecondaryStartupTestError: Error {
    case rendezvousUnavailable
}

private final class SecondaryStartupStopProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let confirmation: Bool
    private var storedStopCount = 0

    init(confirmation: Bool) {
        self.confirmation = confirmation
    }

    var stopCount: Int {
        lock.withLock { storedStopCount }
    }

    func stop() -> Bool {
        lock.withLock { storedStopCount += 1 }
        return confirmation
    }
}

private final class SecondaryTestViewerServiceStub:
    WorldwideSecondaryTestViewerServing,
    @unchecked Sendable
{
    let completion: AsyncStream<Void>

    private let lock = NSLock()
    private let completionContinuation: AsyncStream<Void>.Continuation
    private let invitationCode: String
    private var storedStartCallCount = 0
    private var storedStopCallCount = 0
    private var storedNativeStopIsUnconfirmed: Bool
    private var completionIsFinished = false

    init(
        invitationCode: String,
        nativeStopIsUnconfirmed: Bool = false
    ) {
        let pair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        completion = pair.stream
        completionContinuation = pair.continuation
        self.invitationCode = invitationCode
        storedNativeStopIsUnconfirmed = nativeStopIsUnconfirmed
    }

    var startCallCount: Int {
        lock.withLock { storedStartCallCount }
    }

    var stopCallCount: Int {
        lock.withLock { storedStopCallCount }
    }

    var nativeStopIsUnconfirmed: Bool {
        get { lock.withLock { storedNativeStopIsUnconfirmed } }
        set { lock.withLock { storedNativeStopIsUnconfirmed = newValue } }
    }

    func startSecondaryTestViewer() async throws -> String {
        lock.withLock { storedStartCallCount += 1 }
        return invitationCode
    }

    func stopSecondaryTestViewer() async {
        lock.withLock { storedStopCallCount += 1 }
        finish()
    }

    func secondaryTestViewerHasUnconfirmedNativeCaptureStop() async -> Bool {
        nativeStopIsUnconfirmed
    }

    func finish() {
        let shouldFinish = lock.withLock {
            guard !completionIsFinished else { return false }
            completionIsFinished = true
            return true
        }
        guard shouldFinish else { return }
        completionContinuation.yield(())
        completionContinuation.finish()
    }
}
