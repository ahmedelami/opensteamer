/// Selects whether a healthy transport should publish, resume, or create system audio.
enum WorldwideSystemAudioStartMode: Equatable {
    case alreadyLive
    case resumeExisting
    case startNew
}

/// Pure ownership policy for the actor's native system-audio source.
enum WorldwideSystemAudioRecoveryPolicy {
    static func startMode(
        isLive: Bool,
        isPausedForRecovery: Bool,
        hasSource: Bool,
        hasSink: Bool,
        hasValidAuthorization: Bool,
        peerGenerationMatches: Bool
    ) -> WorldwideSystemAudioStartMode? {
        if isLive,
           !isPausedForRecovery,
           hasSource,
           hasSink,
           hasValidAuthorization,
           peerGenerationMatches {
            return .alreadyLive
        }
        if !isLive,
           isPausedForRecovery,
           hasSource,
           hasSink,
           !hasValidAuthorization,
           peerGenerationMatches {
            return .resumeExisting
        }
        if !isLive,
           !isPausedForRecovery,
           !hasSource,
           !hasSink,
           !hasValidAuthorization {
            return .startNew
        }
        return nil
    }
}
