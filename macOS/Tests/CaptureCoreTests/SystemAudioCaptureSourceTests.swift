import ScreenCaptureKit
import XCTest
@testable import CaptureCore

final class SystemAudioCaptureSourceTests: XCTestCase {
    func testProductionConfigurationRequestsFortyEightKilohertzStereoAudioOnly() {
        let configuration = SystemAudioCaptureConfiguration.make()

        XCTAssertTrue(configuration.capturesAudio)
        XCTAssertTrue(configuration.excludesCurrentProcessAudio)
        XCTAssertEqual(configuration.sampleRate, 48_000)
        XCTAssertEqual(configuration.channelCount, 2)
        XCTAssertEqual(configuration.width, 2)
        XCTAssertEqual(configuration.height, 2)
    }

    func testPublishedFormatCannotDriftFromCaptureConfiguration() {
        let format = SystemAudioCaptureFormat(displayID: 73)
        let configuration = SystemAudioCaptureConfiguration.make()

        XCTAssertEqual(format.displayID, 73)
        XCTAssertEqual(format.sampleRate, configuration.sampleRate)
        XCTAssertEqual(format.channelCount, configuration.channelCount)
    }

    func testCaptureErrorsDistinguishConcurrentStartFromCancellation() {
        XCTAssertNotEqual(
            SystemAudioCaptureError.alreadyRunning.localizedDescription,
            SystemAudioCaptureError.startCancelled.localizedDescription
        )
        XCTAssertTrue(
            SystemAudioCaptureError.displayNotFound(9).localizedDescription.contains("9")
        )
    }
}
