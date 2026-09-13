import Foundation
import WebRTCTransport

/// Selects which process-global media facilities a worldwide screen session may own.
///
/// A secondary consume-once viewer shares screen capture and remote-input plumbing with the
/// primary host, but must not compete for system audio, virtual-microphone/default-input routing,
/// or the single system Now Playing controller.
enum WorldwideScreenServiceFeatureProfile: String, Equatable, Sendable {
    static let secondaryTestMaximumVideoBitrate = 4_000_000

    case fullPrimary
    case secondaryTest

    var allowsSystemAudio: Bool {
        self == .fullPrimary
    }

    var allowsIPhoneMicrophoneAndDefaultInputRouting: Bool {
        self == .fullPrimary
    }

    var allowsNowPlaying: Bool {
        self == .fullPrimary
    }

    var allowsAudioClientDiagnostics: Bool {
        self == .fullPrimary
    }

    var transportMediaTopology: WebRTCTransportMediaTopology {
        switch self {
        case .fullPrimary:
            .full
        case .secondaryTest:
            .videoControlOnly
        }
    }

    func maximumVideoBitrate(configured: Int) -> Int {
        switch self {
        case .fullPrimary:
            configured
        case .secondaryTest:
            min(configured, Self.secondaryTestMaximumVideoBitrate)
        }
    }
}
