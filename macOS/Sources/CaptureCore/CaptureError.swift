import Foundation

/// Failures that can prevent macOS audio or display capture from producing PCM.
public enum CaptureError: LocalizedError {
    case noDisplays
    case displayNotFound(UInt32)
    case missingAudioFormat
    case emptyAudioBuffer
    case audioBufferListFailure(OSStatus)
    case audioDeviceNotFound(String)
    case audioDeviceConfiguration(String, OSStatus)
    case audioRouteUnhealthy(String)
    case unsupportedAudioFormat(String)

    /// A diagnostic suitable for CLI output and operational logs.
    public var errorDescription: String? {
        switch self {
        case .noDisplays:
            "ScreenCaptureKit did not return any displays"
        case .displayNotFound(let id):
            "No ScreenCaptureKit display matched display ID \(id)"
        case .missingAudioFormat:
            "The audio sample buffer did not include an audio stream description"
        case .emptyAudioBuffer:
            "The audio sample buffer did not include any PCM frames"
        case .audioBufferListFailure(let status):
            "CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer failed with OSStatus \(status)"
        case .audioDeviceNotFound(let detail):
            "Audio device not found: \(detail)"
        case .audioDeviceConfiguration(let detail, let status):
            "Audio device configuration failed: \(detail) returned OSStatus \(status)"
        case .audioRouteUnhealthy(let detail):
            "Audio route is not healthy: \(detail)"
        case .unsupportedAudioFormat(let detail):
            "Unsupported audio format: \(detail)"
        }
    }
}
