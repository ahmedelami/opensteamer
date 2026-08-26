import CoreGraphics
import Foundation
import XCTest
@testable import CaptureCore

final class ScreenVideoDisplayModeObserverTests: XCTestCase {
    func testOnlyActiveTargetConfigurationEventsAreDelivered() throws {
        let operations = ScreenVideoDisplayModeObservingOperationsFake()
        let willReconfigurations = LockedDisplayModeObservationCount()
        let settledConfigurations = LockedDisplayModeObservationCount()
        let targetDisplayID: CGDirectDisplayID = 73
        let observer = try ScreenVideoDisplayModeObserver(
            displayID: targetDisplayID,
            operations: operations,
            willReconfigure: {
                willReconfigurations.increment()
            }
        ) {
            settledConfigurations.increment()
        }

        XCTAssertEqual(operations.registrationCount, 1)
        XCTAssertEqual(willReconfigurations.value, 0, "Registration must begin inactive")
        XCTAssertEqual(settledConfigurations.value, 0, "Registration must begin inactive")

        XCTAssertTrue(observer.activate())
        XCTAssertTrue(observer.activate(), "Activation must be idempotent")
        XCTAssertTrue(observer.commitActivation())
        XCTAssertTrue(observer.commitActivation(), "Commit must be idempotent")
        operations.emit(displayID: 99, flags: [.beginConfigurationFlag])
        operations.emit(displayID: 99, flags: [.setModeFlag])
        XCTAssertEqual(willReconfigurations.value, 0)
        XCTAssertEqual(settledConfigurations.value, 0)
        operations.emit(
            displayID: targetDisplayID,
            flags: [.beginConfigurationFlag, .setModeFlag]
        )
        operations.emit(
            displayID: targetDisplayID,
            flags: [.beginConfigurationFlag]
        )
        XCTAssertEqual(willReconfigurations.value, 1)
        XCTAssertEqual(settledConfigurations.value, 0)

        // The first target post callback settles the transaction even without set-mode.
        operations.emit(displayID: targetDisplayID, flags: [.movedFlag])
        operations.emit(displayID: targetDisplayID, flags: [.setModeFlag])
        XCTAssertEqual(willReconfigurations.value, 1)
        XCTAssertEqual(settledConfigurations.value, 1)
    }

    func testActiveBeginAndPostCallbacksAreEachDeduplicatedPerConfiguration() throws {
        let operations = ScreenVideoDisplayModeObservingOperationsFake()
        let willReconfigurations = LockedDisplayModeObservationCount()
        let settledConfigurations = LockedDisplayModeObservationCount()
        let observer = try ScreenVideoDisplayModeObserver(
            displayID: 73,
            operations: operations,
            willReconfigure: {
                willReconfigurations.increment()
            }
        ) {
            settledConfigurations.increment()
        }
        XCTAssertTrue(observer.activate())
        XCTAssertTrue(observer.commitActivation())

        operations.emit(displayID: 73, flags: [.beginConfigurationFlag])
        operations.emit(displayID: 73, flags: [.beginConfigurationFlag])
        XCTAssertEqual(willReconfigurations.value, 1)
        XCTAssertEqual(settledConfigurations.value, 0)

        operations.emit(displayID: 73, flags: [])
        operations.emit(displayID: 73, flags: [.desktopShapeChangedFlag])
        XCTAssertEqual(willReconfigurations.value, 1)
        XCTAssertEqual(settledConfigurations.value, 1)

        operations.emit(displayID: 73, flags: [.beginConfigurationFlag])
        operations.emit(displayID: 73, flags: [.setModeFlag])
        XCTAssertEqual(willReconfigurations.value, 2)
        XCTAssertEqual(settledConfigurations.value, 2)
    }

    func testModeChangeBeforeActivationRejectsTheStartupFence() throws {
        let operations = ScreenVideoDisplayModeObservingOperationsFake()
        let observations = LockedDisplayModeObservationCount()
        let observer = try ScreenVideoDisplayModeObserver(
            displayID: 73,
            operations: operations
        ) {
            observations.increment()
        }

        operations.emit(displayID: 73, flags: [.beginConfigurationFlag])
        operations.emit(displayID: 73, flags: [.setModeFlag])

        XCTAssertFalse(observer.activate())
        XCTAssertEqual(observations.value, 0)
        XCTAssertEqual(observer.stop(), .stopped)
    }

    func testDuplicatePostCallbacksAreSuppressedUntilNextTargetConfiguration() throws {
        let operations = ScreenVideoDisplayModeObservingOperationsFake()
        let observations = LockedDisplayModeObservationCount()
        let targetDisplayID: CGDirectDisplayID = 73
        let observer = try ScreenVideoDisplayModeObserver(
            displayID: targetDisplayID,
            operations: operations
        ) {
            observations.increment()
        }
        XCTAssertTrue(observer.activate())
        XCTAssertTrue(observer.commitActivation())

        operations.emit(displayID: targetDisplayID, flags: [.beginConfigurationFlag])
        operations.emit(displayID: targetDisplayID, flags: [.setModeFlag])
        operations.emit(displayID: targetDisplayID, flags: [.setModeFlag])
        operations.emit(displayID: 99, flags: [.beginConfigurationFlag])
        operations.emit(displayID: targetDisplayID, flags: [.setModeFlag])
        XCTAssertEqual(observations.value, 1)

        operations.emit(displayID: targetDisplayID, flags: [.beginConfigurationFlag])
        operations.emit(displayID: targetDisplayID, flags: [.setModeFlag, .movedFlag])
        XCTAssertEqual(observations.value, 2)
    }

    func testActivationDuringAnInProgressConfigurationIsRejected() throws {
        let operations = ScreenVideoDisplayModeObservingOperationsFake()
        let willReconfigurations = LockedDisplayModeObservationCount()
        let observations = LockedDisplayModeObservationCount()
        let observer = try ScreenVideoDisplayModeObserver(
            displayID: 73,
            operations: operations,
            willReconfigure: {
                willReconfigurations.increment()
            }
        ) {
            observations.increment()
        }

        operations.emit(displayID: 73, flags: [.beginConfigurationFlag])
        XCTAssertEqual(observations.value, 0)
        XCTAssertFalse(observer.activate())
        operations.emit(displayID: 73, flags: [.setModeFlag])

        XCTAssertEqual(willReconfigurations.value, 0)
        XCTAssertEqual(observations.value, 0)
    }

    func testModeChangeBetweenActivationAndCommitRejectsTheCommit() throws {
        let operations = ScreenVideoDisplayModeObservingOperationsFake()
        let observations = LockedDisplayModeObservationCount()
        let observer = try ScreenVideoDisplayModeObserver(
            displayID: 73,
            operations: operations
        ) {
            observations.increment()
        }

        XCTAssertTrue(observer.activate())
        operations.emit(displayID: 73, flags: [.beginConfigurationFlag])
        operations.emit(displayID: 73, flags: [.setModeFlag])

        XCTAssertFalse(observer.commitActivation())
        XCTAssertEqual(observations.value, 0)
    }

    func testConfigurationBeginningBetweenActivationAndCommitRejectsTheCommit() throws {
        let operations = ScreenVideoDisplayModeObservingOperationsFake()
        let observer = try ScreenVideoDisplayModeObserver(
            displayID: 73,
            operations: operations,
            observer: {}
        )

        XCTAssertTrue(observer.activate())
        operations.emit(displayID: 73, flags: [.beginConfigurationFlag])

        XCTAssertFalse(observer.commitActivation())
    }

    func testStopClosesDeliveryRemovesExactRegistrationAndRejectsReactivation() throws {
        let operations = ScreenVideoDisplayModeObservingOperationsFake()
        let willReconfigurations = LockedDisplayModeObservationCount()
        let observations = LockedDisplayModeObservationCount()
        let observer = try ScreenVideoDisplayModeObserver(
            displayID: 73,
            operations: operations,
            willReconfigure: {
                willReconfigurations.increment()
            }
        ) {
            observations.increment()
        }
        XCTAssertTrue(observer.activate())
        XCTAssertTrue(observer.commitActivation())

        XCTAssertEqual(observer.stop(), .stopped)
        XCTAssertEqual(observer.stop(), .stopped)
        XCTAssertFalse(observer.activate())
        XCTAssertEqual(operations.removalCount, 1)
        XCTAssertTrue(operations.removedExactRegistration)

        operations.emit(displayID: 73, flags: [.beginConfigurationFlag])
        operations.emit(displayID: 73, flags: [.setModeFlag])
        XCTAssertEqual(willReconfigurations.value, 0)
        XCTAssertEqual(observations.value, 0)
    }

    func testFailedRemovalRetainsAnInertRegistrationForExactRetry() throws {
        let operations = ScreenVideoDisplayModeObservingOperationsFake(
            removalResults: [.failure, .success]
        )
        let observations = LockedDisplayModeObservationCount()
        let observer = try ScreenVideoDisplayModeObserver(
            displayID: 73,
            operations: operations
        ) {
            observations.increment()
        }
        XCTAssertTrue(observer.activate())
        XCTAssertTrue(observer.commitActivation())

        XCTAssertEqual(observer.stop(), .removalFailed(.failure))
        XCTAssertFalse(observer.activate())
        operations.emit(displayID: 73, flags: [.beginConfigurationFlag])
        operations.emit(displayID: 73, flags: [.setModeFlag])
        XCTAssertEqual(observations.value, 0)

        XCTAssertEqual(observer.stop(), .stopped)
        XCTAssertEqual(operations.removalCount, 2)
        XCTAssertTrue(operations.removedExactRegistration)
    }

    func testRegistrationFailureIsReportedWithoutInstallingARegistration() {
        let operations = ScreenVideoDisplayModeObservingOperationsFake(
            registrationResult: .failure
        )

        XCTAssertThrowsError(
            try ScreenVideoDisplayModeObserver(
                displayID: 73,
                operations: operations,
                observer: {}
            )
        ) { error in
            XCTAssertEqual(
                error as? ScreenVideoDisplayModeObserverError,
                .registrationFailed(.failure)
            )
        }
        XCTAssertEqual(operations.registrationCount, 1)
        XCTAssertEqual(operations.removalCount, 0)
        XCTAssertFalse(operations.hasRegistration)
    }
}

private final class ScreenVideoDisplayModeObservingOperationsFake:
    ScreenVideoDisplayModeObservingOperations,
    @unchecked Sendable
{
    private struct Registration {
        let callback: CGDisplayReconfigurationCallBack
        let userInfo: UnsafeMutableRawPointer?
    }

    private let lock = NSLock()
    private let registrationResult: CGError
    private var removalResults: [CGError]
    private var registration: Registration?
    private var registrations = 0
    private var removals = 0
    private var exactRemoval = false

    init(
        registrationResult: CGError = .success,
        removalResults: [CGError] = [.success]
    ) {
        self.registrationResult = registrationResult
        self.removalResults = removalResults
    }

    var registrationCount: Int {
        lock.withLock { registrations }
    }

    var removalCount: Int {
        lock.withLock { removals }
    }

    var removedExactRegistration: Bool {
        lock.withLock { exactRemoval }
    }

    var hasRegistration: Bool {
        lock.withLock { registration != nil }
    }

    func register(
        callback: CGDisplayReconfigurationCallBack?,
        userInfo: UnsafeMutableRawPointer?
    ) -> CGError {
        lock.withLock {
            registrations += 1
            guard registrationResult == .success, let callback else {
                return registrationResult
            }
            registration = Registration(callback: callback, userInfo: userInfo)
            return .success
        }
    }

    func remove(
        callback: CGDisplayReconfigurationCallBack?,
        userInfo: UnsafeMutableRawPointer?
    ) -> CGError {
        lock.withLock {
            removals += 1
            let result = removalResults.isEmpty ? .success : removalResults.removeFirst()
            guard result == .success else { return result }
            guard let callback, let registration else { return .illegalArgument }
            exactRemoval = Self.identity(of: callback) == Self.identity(of: registration.callback)
                && userInfo == registration.userInfo
            guard exactRemoval else { return .illegalArgument }
            self.registration = nil
            return .success
        }
    }

    func emit(
        displayID: CGDirectDisplayID,
        flags: CGDisplayChangeSummaryFlags
    ) {
        let registration = lock.withLock { self.registration }
        registration?.callback(displayID, flags, registration?.userInfo)
    }

    private static func identity(
        of callback: CGDisplayReconfigurationCallBack
    ) -> UInt {
        unsafeBitCast(callback, to: UInt.self)
    }
}

private final class LockedDisplayModeObservationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}
