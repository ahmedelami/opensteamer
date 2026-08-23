/// Identifies which half of the fail-closed Inactive transition failed.
enum WorldwideScreenInactiveTransitionFailure {
    case nativeStop(any Error)
    case acknowledgement(any Error)
}

/// Linearizes the native ScreenCaptureKit stop with the protocol-level Inactive ACK.
///
/// A viewer must never interpret Inactive as proof that screen capture stopped when the native
/// stop actually threw. The fail-closed callback therefore runs before this operation returns,
/// and the acknowledgement closure is unreachable on that path.
enum WorldwideScreenInactiveTransition {
    /// Stops native capture before acknowledging Inactive, closing the session if stop fails.
    static func perform(
        isolation: isolated (any Actor)? = #isolation,
        stopNativeCapture: () async throws -> Void,
        acknowledgeInactive: () async throws -> Void,
        failClosed: (any Error) async -> Void
    ) async -> WorldwideScreenInactiveTransitionFailure? {
        do {
            try await stopNativeCapture()
        } catch {
            await failClosed(error)
            return .nativeStop(error)
        }

        do {
            try await acknowledgeInactive()
            return nil
        } catch {
            return .acknowledgement(error)
        }
    }
}
