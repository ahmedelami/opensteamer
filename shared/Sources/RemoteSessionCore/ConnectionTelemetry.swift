import CryptoKit
import Dispatch
import Foundation
#if canImport(OSLog)
import OSLog
#endif

public enum ConnectionTelemetryRole: String, Codable, Sendable {
    case viewer
    case host
}

/// Closed, privacy-reviewed connection stages. The journal deliberately has no free-form message,
/// URL, address, candidate, or credential field.
public enum ConnectionTelemetryStage: String, Codable, Sendable {
    case attemptStarted
    case availabilityLoopStarted
    case availabilitySocketOpening
    case availabilitySocketOpened
    case viewerWorkerWaitingForHost
    case hostWorkerWaitingForViewer
    case availabilityReady
    case reconnectRequestSent
    case reconnectRequestReceived
    case reconnectResponseSent
    case reconnectResponseReceived
    case reconnectResponseTimedOut
    case mediaSignalingPrepared
    case retryScheduled
    case availabilityDeadlineExpired
    case attemptSucceeded
    case attemptCancelled
    case attemptFailed
    case availabilityLoopUnexpectedlyEnded
    case hostStopped
}

public enum ConnectionTelemetryFailure: String, Codable, Sendable {
    case connectionClosed
    case connectionFailed
    case sendFailed
    case transportCancellation
    case peerUnavailable
    case roleConflict
    case reconnectResponseTimedOut
    case availabilityDeadlineExpired
    case unexpectedLoopEnd
    case protocolViolation
    case authenticationFailed
    case unknown
}

public enum ConnectionTelemetryTerminal: String, Codable, Sendable {
    case success
    case cancelled
    case failed
}

public enum ConnectionTelemetryFingerprintDomain: String, Sendable {
    case pair
    case attempt
    case exchange
    case session
}

/// A non-secret, domain-separated 96-bit digest used only to correlate sanitized local events.
public struct ConnectionTelemetryFingerprint: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.count == 24,
              rawValue.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public static func derive(
        domain: ConnectionTelemetryFingerprintDomain,
        bytes: Data
    ) -> Self {
        var material = Data("AudioStreamer.ConnectionTelemetry.v1.".utf8)
        material.append(contentsOf: domain.rawValue.utf8)
        material.append(0)
        material.append(bytes)
        let value = SHA256.hash(data: material).prefix(12).map {
            String(format: "%02x", $0)
        }.joined()
        return Self(rawValue: value)!
    }

    public static func derive(
        domain: ConnectionTelemetryFingerprintDomain,
        uuid: UUID
    ) -> Self {
        derive(domain: domain, bytes: Data(uuid.uuidString.lowercased().utf8))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let fingerprint = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid connection telemetry fingerprint"
            )
        }
        self = fingerprint
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ConnectionTelemetryDraft: Equatable, Sendable {
    public let role: ConnectionTelemetryRole
    public let stage: ConnectionTelemetryStage
    public let attemptReference: ConnectionTelemetryFingerprint?
    public let pairReference: ConnectionTelemetryFingerprint?
    public let exchangeReference: ConnectionTelemetryFingerprint?
    public let retryOrdinal: UInt16?
    public let delayMilliseconds: UInt64?
    public let failure: ConnectionTelemetryFailure?
    public let terminal: ConnectionTelemetryTerminal?

    public init(
        role: ConnectionTelemetryRole,
        stage: ConnectionTelemetryStage,
        attemptReference: ConnectionTelemetryFingerprint? = nil,
        pairReference: ConnectionTelemetryFingerprint? = nil,
        exchangeReference: ConnectionTelemetryFingerprint? = nil,
        retryOrdinal: UInt16? = nil,
        delayMilliseconds: UInt64? = nil,
        failure: ConnectionTelemetryFailure? = nil,
        terminal: ConnectionTelemetryTerminal? = nil
    ) {
        self.role = role
        self.stage = stage
        self.attemptReference = attemptReference
        self.pairReference = pairReference
        self.exchangeReference = exchangeReference
        self.retryOrdinal = retryOrdinal
        self.delayMilliseconds = delayMilliseconds
        self.failure = failure
        self.terminal = terminal
    }
}

public struct ConnectionTelemetryEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UInt64
    public let timestamp: Date
    public let monotonicNanoseconds: UInt64
    public let role: ConnectionTelemetryRole
    public let stage: ConnectionTelemetryStage
    public let attemptReference: ConnectionTelemetryFingerprint?
    public let pairReference: ConnectionTelemetryFingerprint?
    public let exchangeReference: ConnectionTelemetryFingerprint?
    public let retryOrdinal: UInt16?
    public let delayMilliseconds: UInt64?
    public let failure: ConnectionTelemetryFailure?
    public let terminal: ConnectionTelemetryTerminal?

    public init(
        id: UInt64,
        timestamp: Date,
        monotonicNanoseconds: UInt64,
        role: ConnectionTelemetryRole,
        stage: ConnectionTelemetryStage,
        attemptReference: ConnectionTelemetryFingerprint? = nil,
        pairReference: ConnectionTelemetryFingerprint? = nil,
        exchangeReference: ConnectionTelemetryFingerprint? = nil,
        retryOrdinal: UInt16? = nil,
        delayMilliseconds: UInt64? = nil,
        failure: ConnectionTelemetryFailure? = nil,
        terminal: ConnectionTelemetryTerminal? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.monotonicNanoseconds = monotonicNanoseconds
        self.role = role
        self.stage = stage
        self.attemptReference = attemptReference
        self.pairReference = pairReference
        self.exchangeReference = exchangeReference
        self.retryOrdinal = retryOrdinal
        self.delayMilliseconds = delayMilliseconds
        self.failure = failure
        self.terminal = terminal
    }
}

public struct ConnectionTelemetrySnapshot: Equatable, Sendable {
    public let events: [ConnectionTelemetryEvent]
    public let droppedEventCount: UInt64
    public let persistenceHealthy: Bool

    public static let empty = Self(
        events: [],
        droppedEventCount: 0,
        persistenceHealthy: true
    )

    public init(
        events: [ConnectionTelemetryEvent],
        droppedEventCount: UInt64,
        persistenceHealthy: Bool
    ) {
        self.events = events
        self.droppedEventCount = droppedEventCount
        self.persistenceHealthy = persistenceHealthy
    }
}

public protocol ConnectionTelemetryRecording: Sendable {
    @discardableResult
    func record(_ draft: ConnectionTelemetryDraft) -> ConnectionTelemetrySnapshot
    func snapshot() -> ConnectionTelemetrySnapshot
    func flush() async -> ConnectionTelemetrySnapshot
}

public extension ConnectionTelemetryRecording {
    /// Waits for any implementation-owned persistence already scheduled by `record`.
    /// Recorders without asynchronous persistence need no special behavior.
    func flush() async -> ConnectionTelemetrySnapshot {
        snapshot()
    }
}

public struct NoopConnectionTelemetryRecorder: ConnectionTelemetryRecording {
    public init() {}

    public func record(_: ConnectionTelemetryDraft) -> ConnectionTelemetrySnapshot {
        .empty
    }

    public func snapshot() -> ConnectionTelemetrySnapshot {
        .empty
    }
}

/// A small local journal for low-frequency connection transitions. It never uploads data, never
/// runs on media callbacks, and cannot accept arbitrary strings. Recording is nonthrowing so a
/// diagnostics failure cannot alter connection behavior.
public final class LocalConnectionTelemetryJournal:
    ConnectionTelemetryRecording,
    @unchecked Sendable
{
    private struct Envelope: Codable, Sendable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        var droppedEventCount: UInt64
        var events: [ConnectionTelemetryEvent]
    }

    private struct State {
        var envelope: Envelope
        var persistenceHealthy: Bool
        var latestScheduledPersistence: UInt64
    }

    public typealias WallClock = @Sendable () -> Date
    public typealias MonotonicClock = @Sendable () -> UInt64

    private let lock = NSLock()
    private let persistenceQueue = DispatchQueue(
        label: "org.example.AudioStreamer.ConnectionTelemetryPersistence",
        qos: .utility
    )
    private let fileURL: URL
    private let maximumEventCount: Int
    private let maximumEncodedBytes: Int
    private let wallClock: WallClock
    private let monotonicClock: MonotonicClock
    private let beforePersistenceEnqueue: @Sendable (UInt64) -> Void
    private var state: State

    public convenience init(
        fileURL: URL,
        maximumEventCount: Int = 512,
        maximumEncodedBytes: Int = 1_048_576,
        wallClock: @escaping WallClock = Date.init,
        monotonicClock: @escaping MonotonicClock = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.init(
            fileURL: fileURL,
            maximumEventCount: maximumEventCount,
            maximumEncodedBytes: maximumEncodedBytes,
            wallClock: wallClock,
            monotonicClock: monotonicClock,
            beforePersistenceEnqueue: { _ in }
        )
    }

    init(
        fileURL: URL,
        maximumEventCount: Int = 512,
        maximumEncodedBytes: Int = 1_048_576,
        wallClock: @escaping WallClock = Date.init,
        monotonicClock: @escaping MonotonicClock = {
            DispatchTime.now().uptimeNanoseconds
        },
        beforePersistenceEnqueue: @escaping @Sendable (UInt64) -> Void
    ) {
        self.fileURL = fileURL
        self.maximumEventCount = max(1, maximumEventCount)
        self.maximumEncodedBytes = max(256, maximumEncodedBytes)
        self.wallClock = wallClock
        self.monotonicClock = monotonicClock
        self.beforePersistenceEnqueue = beforePersistenceEnqueue
        state = Self.loadState(from: fileURL)
    }

    public static func applicationSupport(
        component: String
    ) -> LocalConnectionTelemetryJournal {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return LocalConnectionTelemetryJournal(
            fileURL: base
                .appendingPathComponent("AudioStreamer", isDirectory: true)
                .appendingPathComponent("ConnectionTelemetry", isDirectory: true)
                .appendingPathComponent(component + ".json", isDirectory: false)
        )
    }

    @discardableResult
    public func record(_ draft: ConnectionTelemetryDraft) -> ConnectionTelemetrySnapshot {
        let recorded: (ConnectionTelemetryEvent, Envelope, UInt64) = lock.withLock {
            let nextSequence: UInt64
            if let lastID = state.envelope.events.last?.id, lastID == .max {
                state.envelope.events.removeAll(keepingCapacity: true)
                state.envelope.droppedEventCount = .max
                nextSequence = 1
            } else {
                nextSequence = (state.envelope.events.last?.id ?? 0) + 1
            }
            let event = ConnectionTelemetryEvent(
                id: nextSequence,
                timestamp: wallClock(),
                monotonicNanoseconds: monotonicClock(),
                role: draft.role,
                stage: draft.stage,
                attemptReference: draft.attemptReference,
                pairReference: draft.pairReference,
                exchangeReference: draft.exchangeReference,
                retryOrdinal: draft.retryOrdinal,
                delayMilliseconds: draft.delayMilliseconds,
                failure: draft.failure,
                terminal: draft.terminal
            )
            state.envelope.events.append(event)
            trimToCountBound()
            state.latestScheduledPersistence &+= 1
            return (
                event,
                state.envelope,
                state.latestScheduledPersistence
            )
        }
        beforePersistenceEnqueue(recorded.2)
        schedulePersistence(
            envelope: recorded.1,
            generation: recorded.2
        )
        Self.logToSystem(recorded.0)
        return snapshot()
    }

    public func snapshot() -> ConnectionTelemetrySnapshot {
        lock.withLock {
            ConnectionTelemetrySnapshot(
                events: state.envelope.events,
                droppedEventCount: state.envelope.droppedEventCount,
                persistenceHealthy: state.persistenceHealthy
            )
        }
    }

    public func flush() async -> ConnectionTelemetrySnapshot {
        await withCheckedContinuation { continuation in
            persistenceQueue.async { [self] in
                continuation.resume(returning: snapshot())
            }
        }
    }

    private func trimToCountBound() {
        while state.envelope.events.count > maximumEventCount {
            state.envelope.events.removeFirst()
            state.envelope.droppedEventCount = saturatingIncrement(
                state.envelope.droppedEventCount
            )
        }
    }

    private func schedulePersistence(
        envelope: Envelope,
        generation: UInt64
    ) {
        persistenceQueue.async { [self] in
            // `record` is Sendable and concurrent callers can enqueue out of generation order.
            // Never let a late, stale block overwrite a newer complete snapshot on disk.
            guard lock.withLock({ generation == state.latestScheduledPersistence }) else {
                return
            }
            var boundedEnvelope = envelope
            while !boundedEnvelope.events.isEmpty,
                  Self.encodedEnvelope(boundedEnvelope)?.count ?? .max > maximumEncodedBytes {
                boundedEnvelope.events.removeFirst()
                boundedEnvelope.droppedEventCount = saturatingIncrement(
                    boundedEnvelope.droppedEventCount
                )
            }
            let persisted = persist(boundedEnvelope)
            lock.withLock {
                state.persistenceHealthy = persisted
                if generation == state.latestScheduledPersistence {
                    state.envelope = boundedEnvelope
                }
            }
        }
    }

    private func persist(_ envelope: Envelope) -> Bool {
        guard let data = Self.encodedEnvelope(envelope),
              data.count <= maximumEncodedBytes else {
            return false
        }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var excludedDirectory = directory
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? excludedDirectory.setResourceValues(resourceValues)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
            #endif
            return true
        } catch {
            return false
        }
    }

    private static func encodedEnvelope(_ envelope: Envelope) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(envelope)
    }

    private static func loadState(from fileURL: URL) -> State {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return State(
                envelope: Envelope(
                    schemaVersion: Envelope.currentSchemaVersion,
                    droppedEventCount: 0,
                    events: []
                ),
                persistenceHealthy: true,
                latestScheduledPersistence: 0
            )
        }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard data.count <= 1_048_576 else { throw TelemetryLoadError.invalidArchive }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.schemaVersion == Envelope.currentSchemaVersion,
                  envelope.droppedEventCount < UInt64.max,
                  Self.hasValidEventSequence(envelope.events) else {
                throw TelemetryLoadError.invalidArchive
            }
            return State(
                envelope: envelope,
                persistenceHealthy: true,
                latestScheduledPersistence: 0
            )
        } catch {
            return State(
                envelope: Envelope(
                    schemaVersion: Envelope.currentSchemaVersion,
                    droppedEventCount: 0,
                    events: []
                ),
                persistenceHealthy: false,
                latestScheduledPersistence: 0
            )
        }
    }

    private static func hasValidEventSequence(
        _ events: [ConnectionTelemetryEvent]
    ) -> Bool {
        var previousID: UInt64 = 0
        for event in events {
            guard event.id > previousID, event.id < UInt64.max else { return false }
            previousID = event.id
        }
        return true
    }

    private func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == .max ? .max : value + 1
    }

    private static func logToSystem(_ event: ConnectionTelemetryEvent) {
        #if canImport(OSLog)
        let logger = Logger(
            subsystem: "org.example.AudioStreamer",
            category: "ConnectionTelemetry"
        )
        let retry = event.retryOrdinal.map(String.init) ?? "none"
        let failure = event.failure?.rawValue ?? "none"
        logger.info(
            "role=\(event.role.rawValue, privacy: .public) stage=\(event.stage.rawValue, privacy: .public) retry=\(retry, privacy: .public) failure=\(failure, privacy: .public)"
        )
        #endif
    }
}

private enum TelemetryLoadError: Error {
    case invalidArchive
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
