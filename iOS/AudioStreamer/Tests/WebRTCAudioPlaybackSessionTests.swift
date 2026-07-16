import AVFAudio
import XCTest
@testable import WebRTCTransport

@MainActor
final class WebRTCAudioPlaybackSessionTests: XCTestCase {
    func testPrimaryConfigurationActivatesExactlyOnce() throws {
        let native = WebRTCAudioSessionStub()
        let playback = WebRTCAudioPlaybackSession(session: native)

        try playback.activate()
        try playback.recover()

        XCTAssertEqual(native.configuredModes, [
            AVAudioSession.Mode.moviePlayback.rawValue,
            AVAudioSession.Mode.moviePlayback.rawValue,
        ])
        XCTAssertEqual(native.setActiveValues, [true])
        XCTAssertTrue(native.isAudioEnabled)

        playback.deactivate()
        XCTAssertEqual(native.setActiveValues, [true, false])
    }

    func testConfigurationParamErrFallsBackToDefaultModeBeforeActivation() throws {
        let native = WebRTCAudioSessionStub()
        native.configurationErrors[AVAudioSession.Mode.moviePlayback.rawValue] = parameterError
        let playback = WebRTCAudioPlaybackSession(session: native)

        try playback.activate()

        XCTAssertEqual(
            native.configuredModes,
            [AVAudioSession.Mode.moviePlayback.rawValue, AVAudioSession.Mode.default.rawValue]
        )
        XCTAssertEqual(native.setActiveValues, [true])
        XCTAssertTrue(native.isAudioEnabled)
        XCTAssertEqual(native.lockCount, 1)
        XCTAssertEqual(native.unlockCount, 1)
    }

    func testNonParameterConfigurationFailureDoesNotFallbackOrActivate() {
        let native = WebRTCAudioSessionStub()
        native.configurationErrors[AVAudioSession.Mode.moviePlayback.rawValue] = NSError(
            domain: NSOSStatusErrorDomain,
            code: -108
        )
        let playback = WebRTCAudioPlaybackSession(session: native)

        XCTAssertThrowsError(try playback.activate()) { error in
            let sessionError = error as? WebRTCAudioPlaybackSessionError
            XCTAssertEqual(sessionError?.stage, .configuration)
            XCTAssertEqual(sessionError?.attemptedMode, AVAudioSession.Mode.moviePlayback.rawValue)
            XCTAssertEqual(sessionError?.compatibilityFallbackAttempted, false)
        }
        XCTAssertEqual(native.configuredModes, [AVAudioSession.Mode.moviePlayback.rawValue])
        XCTAssertTrue(native.setActiveValues.isEmpty)
        XCTAssertFalse(native.isAudioEnabled)
        XCTAssertEqual(native.lockCount, native.unlockCount)
    }

    func testActivationFailureNeverTriggersConfigurationFallback() {
        let native = WebRTCAudioSessionStub()
        native.activationError = parameterError
        let playback = WebRTCAudioPlaybackSession(session: native)

        XCTAssertThrowsError(try playback.activate()) { error in
            let sessionError = error as? WebRTCAudioPlaybackSessionError
            XCTAssertEqual(sessionError?.stage, .activation)
            XCTAssertEqual(sessionError?.attemptedMode, AVAudioSession.Mode.moviePlayback.rawValue)
            XCTAssertEqual(sessionError?.compatibilityFallbackAttempted, false)
        }
        XCTAssertEqual(native.configuredModes, [AVAudioSession.Mode.moviePlayback.rawValue])
        XCTAssertEqual(native.setActiveValues, [true])
        XCTAssertFalse(native.isAudioEnabled)

        playback.deactivate()
        XCTAssertEqual(native.setActiveValues, [true])
    }

    func testFailedDefaultModeFallbackRemainsAConfigurationFailure() {
        let native = WebRTCAudioSessionStub()
        native.configurationErrors[AVAudioSession.Mode.moviePlayback.rawValue] = parameterError
        native.configurationErrors[AVAudioSession.Mode.default.rawValue] = NSError(
            domain: NSOSStatusErrorDomain,
            code: -108
        )
        let playback = WebRTCAudioPlaybackSession(session: native)

        XCTAssertThrowsError(try playback.activate()) { error in
            let sessionError = error as? WebRTCAudioPlaybackSessionError
            XCTAssertEqual(sessionError?.stage, .configuration)
            XCTAssertEqual(sessionError?.attemptedMode, AVAudioSession.Mode.default.rawValue)
            XCTAssertEqual(sessionError?.compatibilityFallbackAttempted, true)
        }
        XCTAssertEqual(
            native.configuredModes,
            [AVAudioSession.Mode.moviePlayback.rawValue, AVAudioSession.Mode.default.rawValue]
        )
        XCTAssertTrue(native.setActiveValues.isEmpty)
        XCTAssertFalse(native.isAudioEnabled)
    }

    func testRecoverNeverAcquiresASecondActivationLeaseAfterInterruption() throws {
        let native = WebRTCAudioSessionStub()
        native.isActive = true
        let playback = WebRTCAudioPlaybackSession(session: native)

        try playback.recover()
        XCTAssertEqual(native.setActiveValues, [true])
        XCTAssertTrue(native.isAudioEnabled)

        try playback.recover()
        XCTAssertEqual(native.setActiveValues, [true])

        native.isActive = false
        XCTAssertThrowsError(try playback.recover()) { error in
            XCTAssertEqual(
                (error as? WebRTCAudioPlaybackSessionError)?.stage,
                .activation
            )
        }
        XCTAssertEqual(native.setActiveValues, [true])
        XCTAssertFalse(native.isAudioEnabled)

        playback.deactivate()
        XCTAssertEqual(native.setActiveValues, [true, false])
        XCTAssertFalse(native.isAudioEnabled)
        XCTAssertEqual(native.lockCount, native.unlockCount)
    }

    func testDeactivationFailureCannotCauseASecondLeaseDecrement() throws {
        let native = WebRTCAudioSessionStub()
        let playback = WebRTCAudioPlaybackSession(session: native)
        try playback.activate()
        native.deactivationError = NSError(domain: NSOSStatusErrorDomain, code: -108)

        playback.deactivate()
        native.deactivationError = nil
        playback.deactivate()

        XCTAssertEqual(native.setActiveValues, [true, false])
        XCTAssertFalse(native.isAudioEnabled)
        XCTAssertEqual(native.lockCount, native.unlockCount)
    }

    private var parameterError: NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: AVAudioSession.ErrorCode.badParam.rawValue
        )
    }
}

@MainActor
private final class WebRTCAudioSessionStub: WebRTCAudioSessionControlling {
    var isActive = false
    var isAudioEnabled = false
    var configurationErrors: [String: any Error] = [:]
    var activationError: (any Error)?
    var deactivationError: (any Error)?
    private(set) var configuredModes: [String] = []
    private(set) var setActiveValues: [Bool] = []
    private(set) var prepareCount = 0
    private(set) var lockCount = 0
    private(set) var unlockCount = 0

    func prepareForManualAudio() {
        prepareCount += 1
    }

    func lockForConfiguration() {
        lockCount += 1
    }

    func unlockForConfiguration() {
        unlockCount += 1
    }

    func configurePlayback(mode: AVAudioSession.Mode) throws {
        configuredModes.append(mode.rawValue)
        if let error = configurationErrors[mode.rawValue] {
            throw error
        }
    }

    func setActive(_ active: Bool) throws {
        setActiveValues.append(active)
        if active, let activationError {
            throw activationError
        }
        if !active, let deactivationError {
            throw deactivationError
        }
        isActive = active
    }
}
