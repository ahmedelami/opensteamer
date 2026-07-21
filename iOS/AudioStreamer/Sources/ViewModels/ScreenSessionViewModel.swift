import Foundation
import Streaming

/// Presentation-scoped owner of the legacy screen transport and sample-buffer renderer.
/// A UUID generation fences callbacks from superseded reconnect attempts so stale frames cannot
/// update the current SwiftUI presentation or acknowledge data on a replacement connection.
@MainActor
final class ScreenSessionViewModel: ObservableObject {
    @Published private(set) var stateText = "Ready"
    @Published private(set) var lastError: String?
    @Published private(set) var aspectRatio = 16.0 / 9.0
    @Published private(set) var frameCount: UInt64 = 0

    let displayName: String
    lazy var renderer = ScreenVideoRenderer { [weak self] event in
        Task { @MainActor [weak self] in
            self?.handleRendererEvent(event)
        }
    }

    private let descriptor: ScreenVideoConnectionDescriptor
    private var client: ScreenVideoClient?
    private var connectionTask: Task<Void, Never>?
    private var sessionGeneration = UUID()

    init(descriptor: ScreenVideoConnectionDescriptor) {
        self.descriptor = descriptor
        self.displayName = descriptor.displayName
    }

    func start() {
        guard connectionTask == nil else { return }
        sessionGeneration = UUID()
        let generation = sessionGeneration
        stateText = "Connecting"
        lastError = nil
        frameCount = 0
        connectionTask = Task { [weak self] in
            await self?.runConnectionLoop(generation: generation)
        }
    }

    func stop() {
        sessionGeneration = UUID()
        connectionTask?.cancel()
        client?.cancel()
        connectionTask = nil
        client = nil
        renderer.reset(removeImage: true)
        stateText = "Hidden"
    }

    private func runConnectionLoop(generation: UUID) async {
        defer {
            if generation == sessionGeneration {
                connectionTask = nil
                client = nil
            }
        }

        var attempt = 0
        while !Task.isCancelled, generation == sessionGeneration {
            let client = ScreenVideoClient(descriptor: descriptor)
            self.client = client
            let renderer = renderer

            do {
                try await client.run { [weak self, weak client] event in
                    Task { @MainActor [weak self, weak client] in
                        guard let self,
                              let client,
                              self.sessionGeneration == generation,
                              self.client === client else {
                            if case .frame(_, let disposition) = event {
                                disposition.resolve(accepted: false)
                            }
                            return
                        }

                        switch event {
                        case .connected:
                            self.stateText = "Waiting for Mac screen"
                            self.lastError = nil
                        case .configuration(let configuration, _):
                            renderer.configure(
                                parameterSets: configuration.parameterSets.map(\.bytes),
                                nalUnitHeaderLength: Int(configuration.nalUnitHeaderLength)
                            )
                            self.aspectRatio = Double(configuration.width) / Double(configuration.height)
                            self.stateText = "Live"
                            self.lastError = nil
                        case .frame(let packet, let disposition):
                            // Transport acknowledgement is deferred until the renderer accepts the
                            // frame, so the Mac never advances its stream based on receipt alone.
                            renderer.enqueue(
                                avccAccessUnit: packet.payload,
                                presentationTimestampNanoseconds: packet.presentationTimestampNanoseconds,
                                isKeyFrame: packet.flags.contains(.keyFrame)
                            ) { [weak self] accepted in
                                disposition.resolve(accepted: accepted)
                                guard accepted else { return }
                                Task { @MainActor [weak self] in
                                    guard self?.sessionGeneration == generation else { return }
                                    self?.frameCount &+= 1
                                }
                            }
                        }
                    }
                }
                break
            } catch is CancellationError {
                break
            } catch {
                client.cancel()
                if self.client === client {
                    self.client = nil
                }
                renderer.reset(removeImage: false)
                guard !Task.isCancelled, generation == sessionGeneration else { break }

                attempt += 1
                lastError = error.localizedDescription
                stateText = "Reconnecting"
                // Bound exponential retry avoids a hot loop while keeping local-network recovery
                // responsive after short sleep or route changes.
                let delay = min(0.25 * pow(2, Double(max(0, attempt - 1))), 5)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func handleRendererEvent(_ event: ScreenVideoRenderer.Event) {
        switch event {
        case .needsKeyFrame:
            client?.requestKeyFrame()
        case .failed(let message):
            lastError = message
            client?.requestKeyFrame()
        }
    }
}
