import Foundation

/// Minimal lifecycle surface shared by the production AudioQueue sink and deterministic fakes.
protocol WorldwideIPhoneMicrophoneOutput: AnyObject, Sendable {
    func start() throws
    func stop()
    var forwardingProgressSnapshot:
        BlackHoleMicrophoneOutputProgressSnapshot { get }
}

extension BlackHoleMicrophoneOutput: WorldwideIPhoneMicrophoneOutput {}
