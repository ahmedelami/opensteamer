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

    func testFeedbackExclusionSelectsOnlyExactIPhoneMirroringBundle() {
        let bundleIdentifiers: [String?] = [
            "com.apple.ScreenContinuity",
            "com.spotify.client",
            "COM.APPLE.SCREENCONTINUITY",
            "com.apple.ScreenContinuity.helper",
            nil,
            "com.apple.ScreenContinuity"
        ]

        let excluded = SystemAudioApplicationExclusionPolicy.excludedApplications(
            from: bundleIdentifiers,
            bundleIdentifier: { $0 }
        )

        XCTAssertEqual(excluded, [
            "com.apple.ScreenContinuity",
            "com.apple.ScreenContinuity"
        ])
    }

    func testOnlyIPhoneMirroringLifecycleEventsRefreshTheAudioFilter() {
        XCTAssertTrue(
            SystemAudioApplicationExclusionPolicy.requiresFilterRefresh(
                bundleIdentifier: "com.apple.ScreenContinuity"
            )
        )
        XCTAssertFalse(
            SystemAudioApplicationExclusionPolicy.requiresFilterRefresh(
                bundleIdentifier: "com.apple.ScreenContinuity.helper"
            )
        )
        XCTAssertFalse(
            SystemAudioApplicationExclusionPolicy.requiresFilterRefresh(
                bundleIdentifier: nil
            )
        )
    }
}
