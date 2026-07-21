import Foundation
import Network

/// Immutable handoff from server discovery to the legacy screen-video session.
/// `authToken` is optional because authenticated remote endpoints and trusted local endpoints use
/// the same viewer flow; callers must never log or expose a present token.
struct ScreenVideoConnectionDescriptor {
    let endpoint: NWEndpoint
    let authToken: String?
    let displayName: String
}
