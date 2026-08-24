import XCTest
import CaptureCore
import Darwin

@testable import CaptureServer

final class VirtualDisplayLifetimeSupervisorTests: XCTestCase {
    func testInvalidDisplayInvokesFailClosedHandler() async throws {
        let events = ThreadSafeEvents()
        let invalidationFinished = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let monitor = VirtualDisplayLifetimeMonitor(
            pollInterval: .zero,
            isValid: { false },
            sleeper: { _ in }
        )

        let task = try XCTUnwrap(
            VirtualDisplayLifetimeSupervisor.start(
                monitor: monitor,
                onInvalidation: {
                    events.append("invalidate")
                    invalidationFinished.continuation.yield(())
                    invalidationFinished.continuation.finish()
                },
                watchdogGracePeriod: .zero,
                watchdogSleeper: { _ in
                    for await _ in invalidationFinished.stream { break }
                },
                terminateProcess: { events.append("terminate") }
            )
        )
        await task.value

        XCTAssertEqual(events.values, ["invalidate", "terminate"])
    }

    func testCancellationWhileValidDoesNotInvalidate() async throws {
        let invalidationWasInvoked = ThreadSafeFlag()
        let monitor = VirtualDisplayLifetimeMonitor(
            pollInterval: .zero,
            isValid: { true },
            sleeper: { _ in try await Task.sleep(for: .seconds(60)) }
        )

        let task = try XCTUnwrap(
            VirtualDisplayLifetimeSupervisor.start(
                monitor: monitor,
                onInvalidation: { invalidationWasInvoked.set() }
            )
        )
        task.cancel()
        await task.value

        XCTAssertFalse(invalidationWasInvoked.value)
    }

    func testNoMonitorCreatesNoTask() {
        XCTAssertNil(
            VirtualDisplayLifetimeSupervisor.start(
                monitor: nil,
                onInvalidation: { XCTFail("No monitor must never invalidate") }
            )
        )
    }

    func testGracefulCleanupCanCancelHardExitWatchdog() async throws {
        let events = ThreadSafeEvents()
        let watchdogStarted = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let monitor = VirtualDisplayLifetimeMonitor(
            pollInterval: .zero,
            isValid: { false },
            sleeper: { _ in }
        )
        let task = try XCTUnwrap(
            VirtualDisplayLifetimeSupervisor.start(
                monitor: monitor,
                onInvalidation: { events.append("invalidate") },
                watchdogSleeper: { _ in
                    watchdogStarted.continuation.yield(())
                    try await Task.sleep(for: .seconds(60))
                },
                terminateProcess: { events.append("terminate") }
            )
        )

        for await _ in watchdogStarted.stream { break }
        task.cancel()
        await task.value

        XCTAssertEqual(events.values, ["invalidate"])
    }

    func testWatchdogIsArmedBeforeInvalidationHandler() async throws {
        let watchdogWasArmed = ThreadSafeFlag()
        let invalidationObservedArmedWatchdog = ThreadSafeFlag()
        let monitor = VirtualDisplayLifetimeMonitor(
            pollInterval: .zero,
            isValid: { false },
            sleeper: { _ in }
        )
        let task = try XCTUnwrap(
            VirtualDisplayLifetimeSupervisor.start(
                monitor: monitor,
                onInvalidation: {
                    if watchdogWasArmed.value {
                        invalidationObservedArmedWatchdog.set()
                    }
                },
                watchdogGracePeriod: .zero,
                watchdogSleeper: { _ in },
                watchdogArmed: { watchdogWasArmed.set() },
                terminateProcess: {}
            )
        )

        await task.value
        XCTAssertTrue(invalidationObservedArmedWatchdog.value)
    }

    func testInvalidationSignalIsBufferedAndOneShot() async {
        let signal = VirtualDisplayInvalidationSignal()
        signal.signal()
        signal.signal()

        var eventCount = 0
        for await _ in signal.events {
            eventCount += 1
        }
        XCTAssertEqual(eventCount, 1)
    }

    func testInvalidationSignalWakesIndefiniteServiceLoop() async throws {
        let signal = VirtualDisplayInvalidationSignal()
        signal.signal()

        do {
            _ = try await CaptureServerMain.runUntilVirtualDisplayInvalidation(
                events: signal.events
            ) {
                try await Task.sleep(for: .seconds(60))
                return nil
            }
            XCTFail("An invalid owned display must end an indefinite service loop")
        } catch VirtualDisplayLifetimeError.displayInvalid {
            // Expected fail-closed wake-up.
        }
    }

    func testTerminationSignalDrainsLANOperationBeforeSurfacingRequest() async throws {
        let signals = AsyncStream<Int32>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let operationStarted = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let cleanupFinished = ThreadSafeFlag()
        let run = Task {
            try await CaptureServerMain.runUntilProcessTermination(
                terminationSignals: signals.stream
            ) {
                operationStarted.continuation.yield(())
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    cleanupFinished.set()
                    throw error
                }
            }
        }

        for await _ in operationStarted.stream { break }
        signals.continuation.yield(SIGTERM)
        do {
            try await run.value
            XCTFail("SIGTERM must surface only after the LAN operation drains")
        } catch let request as ProcessTerminationRequest {
            XCTAssertEqual(request.signalNumber, SIGTERM)
        }
        XCTAssertTrue(cleanupFinished.value)
    }

    func testTerminationMonitorPolicyCoversVirtualLANAndWorldwideStartup() {
        XCTAssertTrue(
            ProcessTerminationSignalPolicy.requiresMonitor(
                virtualDisplayEnabled: true,
                worldwideEnabled: false
            )
        )
        XCTAssertTrue(
            ProcessTerminationSignalPolicy.requiresMonitor(
                virtualDisplayEnabled: false,
                worldwideEnabled: true
            )
        )
        XCTAssertFalse(
            ProcessTerminationSignalPolicy.requiresMonitor(
                virtualDisplayEnabled: false,
                worldwideEnabled: false
            )
        )
        XCTAssertTrue(
            ProcessTerminationSignalPolicy.requiresIndependentFallback(
                virtualDisplayEnabled: false,
                worldwideEnabled: true
            )
        )
        XCTAssertFalse(
            ProcessTerminationSignalPolicy.requiresIndependentFallback(
                virtualDisplayEnabled: true,
                worldwideEnabled: true
            )
        )
        XCTAssertFalse(
            ProcessTerminationSignalPolicy.requiresIndependentFallback(
                virtualDisplayEnabled: false,
                worldwideEnabled: false
            )
        )
    }

    func testSignalDefaultsRemainOwnedUntilFullCleanupIsConfirmed() {
        XCTAssertFalse(
            ProcessTerminationSignalPolicy.mayRestoreDefaultHandling(
                fullCleanupIsConfirmed: false
            )
        )
        XCTAssertTrue(
            ProcessTerminationSignalPolicy.mayRestoreDefaultHandling(
                fullCleanupIsConfirmed: true
            )
        )
    }

    func testCancelledSignalSubscriptionDoesNotDisableLaterStartupBoundary() async {
        let monitor = ProcessTerminationSignalMonitor(signalNumbers: [])
        let firstSubscription = monitor.events
        let firstWait = Task {
            for await _ in firstSubscription { break }
        }
        firstWait.cancel()
        await firstWait.value

        let laterSubscription = monitor.events
        monitor.receive(SIGTERM)
        var iterator = laterSubscription.makeAsyncIterator()
        let deliveredSignal = await iterator.next()
        XCTAssertEqual(deliveredSignal, SIGTERM)
        XCTAssertEqual(monitor.pendingSignal(), SIGTERM)
        XCTAssertEqual(monitor.cancelAndReturnPendingSignal(), SIGTERM)
    }

    func testInvalidationCannotHideCanceledOperationNativeStopUncertainty() async {
        let signal = VirtualDisplayInvalidationSignal()
        let operationStarted = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let run = Task {
            try await CaptureServerMain.runUntilVirtualDisplayInvalidation(
                events: signal.events
            ) {
                operationStarted.continuation.yield(())
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    throw TestNativeScreenCaptureStopUnconfirmedError()
                }
                return nil
            }
        }

        for await _ in operationStarted.stream { break }
        signal.signal()
        do {
            _ = try await run.value
            XCTFail("The retained native-stop error must outrank display invalidation")
        } catch {
            XCTAssertTrue(
                StreamingCaptureManager.hasUnconfirmedNativeScreenCaptureStop(error)
            )
        }
    }

    func testCaptureLifetimeRejectsCallbacksAfterOwnerProbeFails() {
        let lifetime = CaptureServiceLifetime(validityProbe: { false })

        XCTAssertFalse(lifetime.isValid)
        XCTAssertFalse(lifetime.allowsCallbackEntry)
    }

    func testOwnerProbeFailureClosesCallbackGateBeforeTeardownCanPause() {
        let probeEntered = DispatchSemaphore(value: 0)
        let releaseProbe = DispatchSemaphore(value: 0)
        let teardownEntered = DispatchSemaphore(value: 0)
        let releaseTeardown = DispatchSemaphore(value: 0)
        let validityFinished = DispatchSemaphore(value: 0)
        let callbackFinished = DispatchSemaphore(value: 0)
        let callbackWasAdmitted = ThreadSafeOptionalBool()
        let lifetime = CaptureServiceLifetime(
            validityProbe: {
                probeEntered.signal()
                releaseProbe.wait()
                return false
            },
            teardownDidBegin: {
                teardownEntered.signal()
                releaseTeardown.wait()
            }
        )

        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertFalse(lifetime.isValid)
            validityFinished.signal()
        }
        XCTAssertEqual(probeEntered.wait(timeout: .now() + .seconds(1)), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            callbackWasAdmitted.set(lifetime.allowsCallbackEntry)
            callbackFinished.signal()
        }
        releaseProbe.signal()
        XCTAssertEqual(teardownEntered.wait(timeout: .now() + .seconds(1)), .success)

        // The callback must remain behind the lifetime lock until terminal invalidation is
        // published, even if teardown setup itself pauses.
        XCTAssertEqual(
            callbackFinished.wait(timeout: .now() + .milliseconds(50)),
            .timedOut
        )
        releaseTeardown.signal()
        XCTAssertEqual(validityFinished.wait(timeout: .now() + .seconds(1)), .success)
        XCTAssertEqual(callbackFinished.wait(timeout: .now() + .seconds(1)), .success)
        XCTAssertEqual(callbackWasAdmitted.value, false)
    }

    func testRealtimeCallbackGateDoesNotRunWindowServerValidityProbe() {
        let probes = ThreadSafeCounter()
        let lifetime = CaptureServiceLifetime(validityProbe: {
            probes.increment()
            return true
        })

        XCTAssertTrue(lifetime.allowsCallbackEntry)
        XCTAssertEqual(probes.value, 0)
        XCTAssertTrue(lifetime.isValid)
        XCTAssertEqual(probes.value, 1)
    }

    func testUniversalTeardownWatchdogFiresWithoutDisplayDrift() async {
        let didTerminate = ThreadSafeFlag()
        let terminated = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let deadline = VirtualDisplayTeardownDeadline(
            gracePeriod: .zero,
            sleeper: { _ in },
            terminateProcess: {
                didTerminate.set()
                terminated.continuation.yield(())
                terminated.continuation.finish()
            }
        )

        deadline.arm()
        for await _ in terminated.stream { break }
        XCTAssertTrue(didTerminate.value)
    }

    func testConfirmedTeardownCanCancelUniversalWatchdog() async {
        let didTerminate = ThreadSafeFlag()
        let watchdogStarted = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let deadline = VirtualDisplayTeardownDeadline(
            sleeper: { _ in
                watchdogStarted.continuation.yield(())
                try await Task.sleep(for: .seconds(60))
            },
            terminateProcess: { didTerminate.set() }
        )

        deadline.arm()
        deadline.arm()
        for await _ in watchdogStarted.stream { break }
        await deadline.cancel()
        XCTAssertFalse(didTerminate.value)
    }

    func testNestedWatchdogBudgetsDoNotShadowTerminalDeadline() async {
        XCTAssertGreaterThan(
            VirtualDisplayTeardownBudgets.terminal,
            VirtualDisplayTeardownBudgets.combinedVirtualTeardownEnvelope
        )
        XCTAssertEqual(
            VirtualDisplayTeardownBudgets.combinedVirtualTeardownEnvelope,
            .seconds(89)
        )
        XCTAssertEqual(
            VirtualDisplayTeardownBudgets.terminal,
            .seconds(105)
        )
        XCTAssertEqual(
            VirtualDisplayTeardownBudgets.nonVirtualProcessCleanup,
            .seconds(60)
        )
        let starts = ThreadSafeCounter()
        let watchdogStarted = AsyncStream<(Int, Duration)>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        let deadline = VirtualDisplayTeardownDeadline(
            sleeper: { duration in
                starts.increment()
                watchdogStarted.continuation.yield((starts.value, duration))
                try await Task.sleep(for: .seconds(60))
            },
            terminateProcess: { XCTFail("Canceled watchdog must not terminate") }
        )
        var iterator = watchdogStarted.stream.makeAsyncIterator()

        let nativeWatchdog = deadline.makeNativeCaptureWatchdog()
        let nativeWatchdogStart = await iterator.next()
        XCTAssertEqual(nativeWatchdogStart?.0, 1)
        XCTAssertEqual(nativeWatchdogStart?.1, .seconds(10))
        nativeWatchdog.cancel()
        await nativeWatchdog.value

        let mediaServiceWatchdog = deadline.makeMediaServiceWatchdog()
        let mediaServiceWatchdogStart = await iterator.next()
        XCTAssertEqual(mediaServiceWatchdogStart?.0, 2)
        XCTAssertEqual(mediaServiceWatchdogStart?.1, .seconds(45))
        mediaServiceWatchdog.cancel()
        await mediaServiceWatchdog.value

        let initializationWatchdog = deadline.makeInitializationWatchdog()
        let initializationWatchdogStart = await iterator.next()
        XCTAssertEqual(initializationWatchdogStart?.0, 3)
        XCTAssertEqual(initializationWatchdogStart?.1, .seconds(40))
        initializationWatchdog.cancel()
        await initializationWatchdog.value

        deadline.arm()
        let terminalWatchdogStart = await iterator.next()
        XCTAssertEqual(terminalWatchdogStart?.0, 4)
        XCTAssertEqual(
            terminalWatchdogStart?.1,
            VirtualDisplayTeardownBudgets.terminal
        )
        await deadline.cancel()
        XCTAssertEqual(starts.value, 4)
    }

    func testShutdownConfirmationRequiresEveryNativeScreenStop() {
        XCTAssertTrue(
            CaptureServiceShutdownConfirmation.confirmed
                .allNativeCapturesAreConfirmed
        )
        XCTAssertFalse(
            CaptureServiceShutdownConfirmation(
                lanScreenCaptureIsConfirmed: false,
                worldwideNativeCaptureIsConfirmed: true
            ).allNativeCapturesAreConfirmed
        )
        XCTAssertFalse(
            CaptureServiceShutdownConfirmation(
                lanScreenCaptureIsConfirmed: true,
                worldwideNativeCaptureIsConfirmed: false
            ).allNativeCapturesAreConfirmed
        )
    }

    func testFatalExitKeepsVirtualDisplayUntilEveryNativeCaptureStops() {
        XCTAssertTrue(
            CaptureServerFatalExitPolicy.mayRemoveVirtualDisplay(
                shutdownConfirmation: .confirmed,
                lanAudioStopIsConfirmed: true
            )
        )
        XCTAssertFalse(
            CaptureServerFatalExitPolicy.mayRemoveVirtualDisplay(
                shutdownConfirmation: .confirmed,
                lanAudioStopIsConfirmed: false
            )
        )
        XCTAssertFalse(
            CaptureServerFatalExitPolicy.mayRemoveVirtualDisplay(
                shutdownConfirmation: .init(
                    lanScreenCaptureIsConfirmed: false,
                    worldwideNativeCaptureIsConfirmed: true
                ),
                lanAudioStopIsConfirmed: true
            )
        )
        XCTAssertFalse(
            CaptureServerFatalExitPolicy.mayRemoveVirtualDisplay(
                shutdownConfirmation: .init(
                    lanScreenCaptureIsConfirmed: true,
                    worldwideNativeCaptureIsConfirmed: false
                ),
                lanAudioStopIsConfirmed: true
            )
        )
    }

    func testEmptyServiceLifetimeReportsConfirmedIdempotentShutdown() async {
        let lifetime = CaptureServiceLifetime()

        let first = await lifetime.shutdown()
        let second = await lifetime.shutdown()

        XCTAssertEqual(first, .confirmed)
        XCTAssertEqual(second, .confirmed)
    }
}

private final class ThreadSafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    var value: Bool {
        lock.withLock { isSet }
    }

    func set() {
        lock.withLock { isSet = true }
    }
}

private struct TestNativeScreenCaptureStopUnconfirmedError:
    NativeScreenCaptureStopUnconfirmedError
{}

private final class ThreadSafeOptionalBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool?

    var value: Bool? {
        lock.withLock { storedValue }
    }

    func set(_ value: Bool) {
        lock.withLock { storedValue = value }
    }
}

private final class ThreadSafeEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var values: [String] {
        lock.withLock { events }
    }

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }
}

private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
