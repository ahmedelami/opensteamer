import AudioToolbox
import Foundation

/// Supplies deinterleaved floating-point PCM to an audio device callback.
///
/// Implementations must be safe to call from the real-time render thread and should not block on
/// network I/O or allocate unbounded storage.
public protocol PCMFrameProvider: AnyObject, Sendable {
    /// Writes exactly `frameCount` frames, using silence when source audio is unavailable.
    func render(frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>)
}
