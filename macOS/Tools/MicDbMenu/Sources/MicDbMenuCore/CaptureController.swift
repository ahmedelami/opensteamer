import Foundation

public struct InputIdentity: Equatable {
    public enum Transport: Equatable { case physical, virtual, aggregate, unsupported }
    public let id: UInt32
    public let uid: String
    public let name: String
    public let transport: Transport
    public let alive: Bool
    public let channels: UInt32
    public let sampleRate: Double

    public init(id: UInt32, uid: String, name: String, transport: Transport,
                alive: Bool = true, channels: UInt32 = 1, sampleRate: Double = 48_000) {
        self.id = id; self.uid = uid; self.name = name; self.transport = transport
        self.alive = alive; self.channels = channels; self.sampleRate = sampleRate
    }

    public var permitsCapture: Bool {
        id != 0 && !uid.isEmpty && transport == .physical && alive &&
        (1...32).contains(channels) && sampleRate.isFinite &&
        (8_000...384_000).contains(sampleRate) &&
        !uid.hasPrefix("com.elamin.opensteamer.virtual-microphone.")
    }
}

public protocol MeterCapture: AnyObject {
    func currentIdentity() throws -> InputIdentity
    func start() throws
    @discardableResult func stop() -> Bool
}

/// Main-thread owner. The native adapter is always pinned before start; a default
/// change can invalidate a reading, but cannot redirect this capture to a virtual mic.
public final class CaptureController {
    public enum State: Equatable {
        case waiting
        case inactive(InputIdentity?)
        case running(InputIdentity)
        case failed(String)
    }

    public typealias Factory = (InputIdentity, UUID) throws -> MeterCapture
    private let observe: () throws -> InputIdentity?
    private let makeCapture: Factory
    private let clearLevels: () -> Void
    private var capture: MeterCapture?
    private var generation = UUID()
    private var pendingTicket: UUID?
    private var teardownBlocked = false
    public private(set) var state: State = .waiting

    public init(observe: @escaping () throws -> InputIdentity?,
                makeCapture: @escaping Factory, clearLevels: @escaping () -> Void) {
        self.observe = observe; self.makeCapture = makeCapture; self.clearLevels = clearLevels
    }

    @discardableResult public func invalidate() -> UUID {
        generation = UUID()
        pendingTicket = nil
        let old = capture
        capture = nil
        clearLevels()
        if old?.stop() == false { teardownBlocked = true }
        guard !teardownBlocked else {
            state = .failed("Capture teardown failed; relaunch the meter before retrying")
            return generation
        }
        pendingTicket = generation
        state = .waiting
        return generation
    }

    public func reconcile(_ ticket: UUID) {
        guard !teardownBlocked, ticket == generation, pendingTicket == ticket else { return }
        pendingTicket = nil
        var candidate: MeterCapture?
        do {
            let observed = try observe()
            guard let target = observed, target.permitsCapture else {
                state = .inactive(observed)
                return
            }
            let created = try makeCapture(target, ticket)
            candidate = created
            guard ticket == generation,
                  try observe() == target,
                  try created.currentIdentity() == target else { throw CaptureError.changed }
            try created.start()
            guard ticket == generation,
                  try observe() == target,
                  try created.currentIdentity() == target else { throw CaptureError.changed }
            capture = created
            state = .running(target)
        } catch {
            if candidate?.stop() == false { teardownBlocked = true }
            if case CaptureError.teardownFailed = error { teardownBlocked = true }
            if teardownBlocked {
                pendingTicket = nil
                clearLevels()
                state = .failed("Capture teardown failed; relaunch the meter before retrying")
                return
            }
            guard ticket == generation else { return }
            clearLevels()
            state = .failed(String(describing: error))
        }
    }

    public func needsReconcile(observed: InputIdentity?) -> Bool {
        switch state {
        case .running(let target):
            guard observed == target, let capture else { return true }
            return (try? capture.currentIdentity()) != target
        case .inactive(let previous): return observed != previous
        case .waiting, .failed: return false
        }
    }

    public enum CaptureError: Error { case changed, teardownFailed }
}
