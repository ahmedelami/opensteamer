import Foundation

/// User-visible lifecycle states for a legacy PCM streaming session.
public enum StreamState: Sendable, Equatable {
    case idle
    case connecting
    case buffering(bufferedFrames: Int, targetFrames: Int)
    case playing
    case reconnecting(attempt: Int, delaySeconds: Double)
    case paused
    case disconnected
    case failed(String)
}
