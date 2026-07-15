import Foundation
import Network

struct ScreenVideoConnectionDescriptor {
    let endpoint: NWEndpoint
    let authToken: String?
    let displayName: String
}
