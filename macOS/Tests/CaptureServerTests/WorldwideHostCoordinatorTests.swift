import CaptureCore
import Darwin
import Foundation
import RemoteSessionCore
import XCTest
@testable import CaptureServer

/// Specifies supervision of the long-lived worldwide availability loop.
///
/// The coordinator must distinguish a transport-shaped `CancellationError` from cancellation of
/// its owning task, retry the former with telemetry, and fail its completion stream if a supervised
/// child returns unexpectedly. Explicit shutdown is the sole path where child cancellation and a
/// normal completion event are accepted.
final class WorldwideHostCoordinatorTests: XCTestCase {
    func testAvailabilityOnlineMarkerBindsProcessAndGenerationNonce() async throws {
        let store = try makeActivePairingStore()
        let client = HostAvailabilityClientStub(behavior: .validatedWaiting)
        let logger = RecordingLogger()
        let expectedPID: Int32 = 42_424
        let expectedNonce = String(repeating: "a", count: 64)
        let expectedMarker =
            "Worldwide paired-device availability is online " +
            "pid=\(expectedPID) nonce=\(expectedNonce)"
        let coordinator = makeCoordinator(
            store: store,
            availabilityClientFactory: { _, _ in client },
            availabilityMarkerProcessIdentifier: expectedPID,
            availabilityMarkerGenerationNonce: expectedNonce,
            logger: logger
        )

        let startResult = try await coordinator.start(resetPairing: false)
        guard case .paired = startResult else {
            return XCTFail("Expected the persisted pair to start availability")
        }

        let markerWasLogged = await eventually {
            logger.informationMessages.contains(expectedMarker)
        }
        XCTAssertTrue(markerWasLogged)
        XCTAssertEqual(
            logger.informationMessages.filter { $0.hasPrefix(
                "Worldwide paired-device availability is online"
            ) },
            [expectedMarker]
        )
        await coordinator.stop()
    }

    func testTransportCancellationFromAvailabilityConnectRetriesWithoutCancellingHostLoop() async throws {
        let store = try makeActivePairingStore()
        let cancelledClient = HostAvailabilityClientStub(behavior: .transportCancellation)
        let waitingClient = HostAvailabilityClientStub(behavior: .wait)
        let factory = HostAvailabilityClientFactoryStub(
            clients: [cancelledClient, waitingClient]
        )
        let retryDelays = LockedValues<Int>()
        let telemetry = RecordingConnectionTelemetry()
        let coordinator = makeCoordinator(
            store: store,
            availabilityClientFactory: { _, _ in try factory.next() },
            availabilityRetrySleep: { retryDelays.append($0) },
            connectionTelemetry: telemetry
        )

        let startResult = try await coordinator.start(resetPairing: false)
        guard case .paired = startResult else {
            return XCTFail("Expected the persisted pair to start availability")
        }

        let retried = await eventually {
            factory.attemptCount == 2
                && telemetry.snapshot().events.last?.stage == .availabilitySocketOpened
        }
        if !retried {
            await coordinator.stop()
            return XCTFail("A transport-shaped CancellationError killed the host loop")
        }

        XCTAssertEqual(cancelledClient.connectObservedOwnerCancellation, false)
        XCTAssertEqual(cancelledClient.closeCount, 1)
        XCTAssertEqual(retryDelays.values, [1])
        XCTAssertEqual(
            telemetry.snapshot().events.map(\.stage),
            [
                .availabilityLoopStarted,
                .availabilitySocketOpening,
                .retryScheduled,
                .availabilitySocketOpening,
                .availabilitySocketOpened,
            ]
        )
        XCTAssertEqual(
            telemetry.snapshot().events.first(where: { $0.stage == .retryScheduled })?.failure,
            .transportCancellation
        )
        await coordinator.stop()
    }

    func testUnexpectedAvailabilityLoopReturnFailsCoordinatorCompletion() async throws {
        let store = try makeActivePairingStore()
        let telemetry = RecordingConnectionTelemetry()
        let coordinator = makeCoordinator(
            store: store,
            availabilityLoopOverride: {},
            connectionTelemetry: telemetry
        )
        let completion = CompletionOutcomeProbe()
        let observer = Task {
            do {
                for try await _ in coordinator.completion {}
                completion.set(.normal)
            } catch WorldwideHostCoordinatorError.availabilityLoopEndedUnexpectedly {
                completion.set(.unexpectedLoopEnd)
            } catch {
                completion.set(.otherError)
            }
        }

        _ = try await coordinator.start(resetPairing: false)
        let failedClosed = await eventually {
            completion.value != nil
        }
        if !failedClosed {
            await coordinator.stop()
            observer.cancel()
            return XCTFail("An unsupervised availability child returned without failing the host")
        }

        XCTAssertEqual(completion.value, .unexpectedLoopEnd)
        XCTAssertEqual(
            telemetry.snapshot().events.map(\.stage),
            [.availabilityLoopStarted, .availabilityLoopUnexpectedlyEnded]
        )
        XCTAssertEqual(telemetry.snapshot().events.last?.terminal, .failed)
        _ = await observer.result
    }

    func testExplicitStopDoesNotReportUnexpectedAvailabilityLoopEnd() async throws {
        let store = try makeActivePairingStore()
        let overrideStarted = LockedFlag()
        let telemetry = RecordingConnectionTelemetry()
        let coordinator = makeCoordinator(
            store: store,
            availabilityLoopOverride: {
                overrideStarted.set()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    // The coordinator owns this child and cancellation is a normal stop.
                }
            },
            connectionTelemetry: telemetry
        )
        let completion = CompletionOutcomeProbe()
        let observer = Task {
            do {
                var yielded = 0
                for try await _ in coordinator.completion { yielded += 1 }
                completion.set(yielded == 1 ? .normal : .otherError)
            } catch {
                completion.set(.otherError)
            }
        }

        _ = try await coordinator.start(resetPairing: false)
        let didStartOverride = await eventually { overrideStarted.value }
        XCTAssertTrue(didStartOverride)
        await coordinator.stop()
        let didFinishNormally = await eventually { completion.value != nil }
        XCTAssertTrue(didFinishNormally)
        XCTAssertEqual(completion.value, .normal)
        XCTAssertEqual(
            telemetry.snapshot().events.map(\.stage),
            [.availabilityLoopStarted, .hostStopped]
        )
        XCTAssertFalse(
            telemetry.snapshot().events.contains {
                $0.stage == .availabilityLoopUnexpectedlyEnded
            }
        )
        _ = await observer.result
    }

    func testConcurrentStopJoinsOwningCoordinatorShutdown() async throws {
        let telemetry = SuspendedFlushConnectionTelemetry()
        let teardownDidBegin = LockedFlag()
        let coordinator = makeCoordinator(
            store: try makeActivePairingStore(),
            connectionTelemetry: telemetry,
            teardownDidBegin: { teardownDidBegin.set() }
        )
        let firstFinished = LockedFlag()
        let secondFinished = LockedFlag()

        let firstStop = Task {
            await coordinator.stop()
            firstFinished.set()
        }
        for await _ in telemetry.flushStarted { break }
        XCTAssertTrue(teardownDidBegin.value)

        let secondStop = Task {
            await coordinator.stop()
            secondFinished.set()
        }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(firstFinished.value)
        XCTAssertFalse(secondFinished.value)

        telemetry.releaseFlush()
        await firstStop.value
        await secondStop.value
        XCTAssertTrue(firstFinished.value)
        XCTAssertTrue(secondFinished.value)
    }

    func testCoexistencePropagatesWorldwideSupervisorFailureBeforeLANEnds() async throws {
        let coordinator = makeCoordinator(
            store: try makeActivePairingStore(),
            availabilityLoopOverride: {}
        )
        _ = try await coordinator.start(resetPairing: false)

        do {
            _ = try await CaptureServerMain.runCoexistingLANAndWorldwide(
                coordinator: coordinator
            ) {
                try await Task.sleep(for: .milliseconds(250))
                throw CoordinatorTestError.noClient
            }
            XCTFail("Coexistence must not outlive the failed worldwide supervisor")
        } catch WorldwideHostCoordinatorError.availabilityLoopEndedUnexpectedly {
            // This typed error reaches main, which exits nonzero for launchd replacement.
        } catch {
            XCTFail("Expected worldwide supervisor failure, got \(error)")
        }
    }

    func testWorldwideFailureCannotHideCanceledLANNativeStopUncertainty() async throws {
        let coordinator = makeCoordinator(
            store: try makeActivePairingStore(),
            availabilityLoopOverride: {}
        )
        _ = try await coordinator.start(resetPairing: false)

        do {
            _ = try await CaptureServerMain.runCoexistingLANAndWorldwide(
                coordinator: coordinator
            ) {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    throw TestCoexistenceNativeScreenStopUnconfirmedError()
                }
                throw CoordinatorTestError.noClient
            }
            XCTFail("The retained LAN native-stop error must outrank worldwide failure")
        } catch {
            XCTAssertTrue(
                StreamingCaptureManager.hasUnconfirmedNativeScreenCaptureStop(error)
            )
        }
    }

    func testCoexistenceSignalWaitsForLANCancellationCleanup() async throws {
        let coordinator = makeCoordinator(
            store: try makeActivePairingStore(),
            availabilityLoopOverride: {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        )
        _ = try await coordinator.start(resetPairing: false)
        let signals = AsyncStream<Int32>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let lanStarted = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let lanCleanupFinished = LockedFlag()
        let run = Task {
            try await CaptureServerMain.runCoexistingLANAndWorldwide(
                coordinator: coordinator,
                terminationSignals: signals.stream
            ) {
                lanStarted.continuation.yield(())
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    lanCleanupFinished.set()
                    throw error
                }
                throw CoordinatorTestError.noClient
            }
        }

        for await _ in lanStarted.stream { break }
        signals.continuation.yield(SIGTERM)
        signals.continuation.finish()
        do {
            _ = try await run.value
            XCTFail("The signal must reach Main only after LAN cancellation is drained")
        } catch let request as ProcessTerminationRequest {
            XCTAssertEqual(request.signalNumber, SIGTERM)
            XCTAssertTrue(lanCleanupFinished.value)
        } catch {
            XCTFail("Expected an orderly termination request, got \(error)")
        }
        _ = await coordinator.stop()
    }

    private func makeCoordinator(
        store: WorldwidePairingStore,
        availabilityClientFactory: @escaping @Sendable (
            URL,
            RemoteAvailabilityLocator
        ) throws -> any WorldwideHostAvailabilityTransport = { _, _ in
            HostAvailabilityClientStub(behavior: .wait)
        },
        availabilityRetrySleep: @escaping @Sendable (Int) async throws -> Void = { _ in },
        availabilityLoopOverride: (@Sendable () async -> Void)? = nil,
        connectionTelemetry: any ConnectionTelemetryRecording =
            NoopConnectionTelemetryRecorder(),
        teardownDidBegin: @escaping @Sendable () -> Void = {},
        availabilityMarkerProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        availabilityMarkerGenerationNonce: String = String(repeating: "0", count: 64),
        logger: any Logger = SilentLogger()
    ) -> WorldwideHostCoordinator {
        WorldwideHostCoordinator(
            // Reserved `.invalid` prevents accidental external I/O if a test reaches the default
            // transport path instead of one of the injected stubs.
            endpoint: URL(string: "wss://example.invalid")!,
            forceRelay: false,
            screenDisplayID: nil,
            systemAudioDisplayID: nil,
            maximumWidth: 1_280,
            framesPerSecond: 30,
            maximumVideoBitrate: 4_000_000,
            remoteInputController: MacRemoteInputController(allowRemoteControl: false),
            store: store,
            hostDisplayName: "Test Mac",
            availabilityMarkerProcessIdentifier: availabilityMarkerProcessIdentifier,
            availabilityMarkerGenerationNonce: availabilityMarkerGenerationNonce,
            availabilityClientFactory: availabilityClientFactory,
            availabilityRetrySleep: availabilityRetrySleep,
            availabilityLoopOverride: availabilityLoopOverride,
            connectionTelemetry: connectionTelemetry,
            teardownDidBegin: teardownDidBegin,
            logger: logger
        )
    }

    private func makeActivePairingStore() throws -> WorldwidePairingStore {
        // Build a genuinely active cryptographic record through the complete pairing transcript;
        // hand-authored serialized state could bypass invariants used by coordinator startup.
        let dataStore = CoordinatorMemoryPairingDataStore()
        let store = WorldwidePairingStore(dataStore: dataStore)
        let hostIdentity = try store.loadOrCreateHostIdentity(displayName: "Test Mac")
        let viewerIdentity = try RemoteDeviceIdentity.generate(
            role: .viewer,
            displayName: "Test iPhone"
        )
        let invitation = try RemoteInvitationCode.generate()
        let hostParticipant = try RemotePairingParticipant(
            identity: hostIdentity,
            invitation: invitation
        )
        let viewerParticipant = try RemotePairingParticipant(
            identity: viewerIdentity,
            invitation: invitation
        )
        let hostAgreement = try hostParticipant.accept(viewerParticipant.hello)
        let viewerAgreement = try viewerParticipant.accept(hostParticipant.hello)
        var hostRecord = try hostAgreement.makePendingRecord(
            peerConfirmation: viewerAgreement.makeConfirmation()
        )
        var viewerRecord = try viewerAgreement.makePendingRecord(
            peerConfirmation: hostAgreement.makeConfirmation()
        )
        let proposal = try hostRecord.prepareProposal(using: hostIdentity)
        let acknowledgement = try viewerRecord.prepareAcknowledgement(
            after: proposal,
            using: viewerIdentity
        )
        try hostRecord.acceptAcknowledgement(acknowledgement)
        let completion = try hostRecord.prepareCompletion(using: hostIdentity)
        let activation = try viewerRecord.acceptCompletion(
            completion,
            using: viewerIdentity
        )
        try hostRecord.acceptActivationAcknowledgement(activation)
        try store.savePairedViewer(hostRecord, for: hostIdentity)
        return store
    }

    private func eventually(
        attempts: Int = 1_000,
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        // One thousand one-millisecond yields bound asynchronous observation to roughly one second
        // while allowing the coordinator and its child tasks to make progress under CI load.
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }
}

private struct TestCoexistenceNativeScreenStopUnconfirmedError:
    NativeScreenCaptureStopUnconfirmedError
{}

/// Availability transport with two intentional behaviors: a transport-originated cancellation,
/// or an open event stream that remains alive until `close`. Locking models cross-task callbacks.
private final class HostAvailabilityClientStub:
    WorldwideHostAvailabilityTransport,
    @unchecked Sendable
{
    enum Behavior: Sendable {
        case transportCancellation
        case validatedWaiting
        case wait
    }

    private let behavior: Behavior
    private let lock = NSLock()
    private var continuation: PairedAvailabilitySignalingClient.EventStream.Continuation?
    private var observedOwnerCancellation: Bool?
    private var closes = 0

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func connect() async throws -> PairedAvailabilitySignalingClient.EventStream {
        if behavior == .transportCancellation {
            lock.withLock { observedOwnerCancellation = Task.isCancelled }
            throw CancellationError()
        }
        let pair = PairedAvailabilitySignalingClient.EventStream.makeStream()
        lock.withLock { continuation = pair.continuation }
        if behavior == .validatedWaiting {
            pair.continuation.yield(.waiting)
        }
        return pair.stream
    }

    func send(_: RemoteAvailabilityPayload) async throws {}

    func close() async {
        let streamContinuation = lock.withLock { () -> PairedAvailabilitySignalingClient.EventStream.Continuation? in
            closes += 1
            defer { continuation = nil }
            return continuation
        }
        streamContinuation?.finish()
    }

    var connectObservedOwnerCancellation: Bool? {
        lock.withLock { observedOwnerCancellation }
    }

    var closeCount: Int {
        lock.withLock { closes }
    }
}

/// Ordered, thread-safe client supplier used to prove that retry creates a fresh transport.
private final class HostAvailabilityClientFactoryStub: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [HostAvailabilityClientStub]
    private var attempts = 0

    init(clients: [HostAvailabilityClientStub]) {
        self.clients = clients
    }

    func next() throws -> any WorldwideHostAvailabilityTransport {
        try lock.withLock {
            attempts += 1
            guard !clients.isEmpty else { throw CoordinatorTestError.noClient }
            return clients.removeFirst()
        }
    }

    var attemptCount: Int {
        lock.withLock { attempts }
    }
}

private enum CompletionOutcome: Equatable, Sendable {
    case normal
    case unexpectedLoopEnd
    case otherError
}

private final class CompletionOutcomeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: CompletionOutcome?

    func set(_ newValue: CompletionOutcome) {
        lock.withLock { outcome = newValue }
    }

    var value: CompletionOutcome? {
        lock.withLock { outcome }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    func set() {
        lock.withLock { storage = true }
    }

    var value: Bool {
        lock.withLock { storage }
    }
}

private final class LockedValues<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ value: Element) {
        lock.withLock { storage.append(value) }
    }

    var values: [Element] {
        lock.withLock { storage }
    }
}

private final class CoordinatorMemoryPairingDataStore:
    WorldwidePairingDataStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(for account: String) throws -> Data? {
        lock.withLock { values[account] }
    }

    func set(_ data: Data, for account: String) throws {
        lock.withLock { values[account] = data }
    }

    func removeData(for account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: account) }
    }
}

private struct SilentLogger: Logger {
    func info(_: String) {}
    func debug(_: String) {}
    func error(_: String) {}
}

private final class RecordingLogger: Logger, @unchecked Sendable {
    private let lock = NSLock()
    private var information: [String] = []

    func info(_ message: String) {
        lock.withLock { information.append(message) }
    }

    func debug(_: String) {}
    func error(_: String) {}

    var informationMessages: [String] {
        lock.withLock { information }
    }
}

private enum CoordinatorTestError: Error {
    case noClient
}

private final class RecordingConnectionTelemetry:
    ConnectionTelemetryRecording,
    @unchecked Sendable
{
    // Fixed wall-clock and monotonic values keep assertions focused on event ordering and fields;
    // timing behavior is exercised separately through the injected retry sleeper.
    private let lock = NSLock()
    private var events: [ConnectionTelemetryEvent] = []

    func record(_ draft: ConnectionTelemetryDraft) -> ConnectionTelemetrySnapshot {
        lock.withLock {
            events.append(
                ConnectionTelemetryEvent(
                    id: UInt64(events.count + 1),
                    timestamp: Date(timeIntervalSince1970: 0),
                    monotonicNanoseconds: UInt64(events.count),
                    role: draft.role,
                    stage: draft.stage,
                    attemptReference: draft.attemptReference,
                    pairReference: draft.pairReference,
                    exchangeReference: draft.exchangeReference,
                    retryOrdinal: draft.retryOrdinal,
                    delayMilliseconds: draft.delayMilliseconds,
                    failure: draft.failure,
                    terminal: draft.terminal
                )
            )
            return snapshotLocked()
        }
    }

    func snapshot() -> ConnectionTelemetrySnapshot {
        lock.withLock { snapshotLocked() }
    }

    private func snapshotLocked() -> ConnectionTelemetrySnapshot {
        ConnectionTelemetrySnapshot(
            events: events,
            droppedEventCount: 0,
            persistenceHealthy: true
        )
    }
}

private final class SuspendedFlushConnectionTelemetry:
    ConnectionTelemetryRecording,
    @unchecked Sendable
{
    let flushStarted: AsyncStream<Void>

    private let flushStartedContinuation: AsyncStream<Void>.Continuation
    private let flushRelease: AsyncStream<Void>
    private let flushReleaseContinuation: AsyncStream<Void>.Continuation

    init() {
        let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        flushStarted = started.stream
        flushStartedContinuation = started.continuation
        let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        flushRelease = release.stream
        flushReleaseContinuation = release.continuation
    }

    func record(_: ConnectionTelemetryDraft) -> ConnectionTelemetrySnapshot {
        .empty
    }

    func snapshot() -> ConnectionTelemetrySnapshot {
        .empty
    }

    func flush() async -> ConnectionTelemetrySnapshot {
        flushStartedContinuation.yield(())
        flushStartedContinuation.finish()
        for await _ in flushRelease { break }
        return .empty
    }

    func releaseFlush() {
        flushReleaseContinuation.yield(())
        flushReleaseContinuation.finish()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
