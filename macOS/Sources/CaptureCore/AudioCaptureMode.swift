import Foundation

/// Selects the macOS system-audio capture backend.
///
/// `blackHoleInput` reads an explicitly configured loopback device, whereas
/// `screen` asks ScreenCaptureKit to supply the display's audio samples.
public enum AudioCaptureMode: String, Sendable {
    case blackHoleInput = "blackhole-input"
    case screen = "screen"
}
