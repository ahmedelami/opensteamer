import Foundation
import Network

final class BonjourBrowser {
    private let queue = DispatchQueue(label: "AudioStreamer.BonjourBrowser")
    private var browser: NWBrowser?

    var onServersChanged: @Sendable ([ServerInfo]) -> Void = { _ in }
    var onError: @Sendable (String) -> Void = { _ in }

    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_mcap._tcp", domain: nil),
            using: parameters
        )

        let onError = onError
        let onServersChanged = onServersChanged

        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                onError(error.localizedDescription)
            }
        }

        browser.browseResultsChangedHandler = { results, _ in
            let servers = results
                .map { ServerInfo(endpoint: $0.endpoint, metadata: $0.metadata) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            onServersChanged(servers)
        }

        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
