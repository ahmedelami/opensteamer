import Foundation

/// Holds destructive invitation cleanup behind the exact rendezvous generation
/// that accepted it. Starting a connection is intentionally not enough to fire it.
@MainActor
struct InvitationAcceptanceAction {
    private var generation: UUID?
    private var action: (@MainActor () -> Void)?

    mutating func arm(
        generation: UUID,
        action: @escaping @MainActor () -> Void
    ) {
        self.generation = generation
        self.action = action
    }

    mutating func accept(generation: UUID) {
        guard self.generation == generation, let action else { return }
        self.generation = nil
        self.action = nil
        action()
    }

    mutating func cancel(generation: UUID) {
        guard self.generation == generation else { return }
        self.generation = nil
        action = nil
    }
}
