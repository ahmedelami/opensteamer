import Foundation
import Testing
@testable import RemoteSessionCore

/// Exercises the bounded local telemetry journal and its privacy-preserving schema.
///
/// Fixtures use values generated entirely inside the test process. Never paste a
/// production invitation, activation code, endpoint credential, or device identity
/// into this suite: the repository itself is outside the runtime trust boundary.
struct ConnectionTelemetryTests {
    /// A deterministic canary with a deliberately invalid runtime-credential prefix.
    private static let syntheticSecretCanary = "test-only:" + Data(
        (0..<24).map { UInt8($0) }
    ).base64EncodedString()

    @Test func boundedJournalPersistsNewestEventsAndSequenceAcrossRecreation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("trace.json")
        let first = LocalConnectionTelemetryJournal(
            fileURL: fileURL,
            maximumEventCount: 3,
            wallClock: { Date(timeIntervalSince1970: 1_700_000_000) },
            monotonicClock: { 42 }
        )

        for retry in 0..<5 {
            first.record(
                ConnectionTelemetryDraft(
                    role: .viewer,
                    stage: .retryScheduled,
                    retryOrdinal: UInt16(retry)
                )
            )
        }
        _ = await first.flush()

        let firstSnapshot = first.snapshot()
        #expect(firstSnapshot.events.map(\.id) == [3, 4, 5])
        #expect(firstSnapshot.events.compactMap(\.retryOrdinal) == [2, 3, 4])
        #expect(firstSnapshot.droppedEventCount == 2)
        #expect(firstSnapshot.persistenceHealthy)

        let recreated = LocalConnectionTelemetryJournal(
            fileURL: fileURL,
            maximumEventCount: 3,
            wallClock: { Date(timeIntervalSince1970: 1_700_000_001) },
            monotonicClock: { 43 }
        )
        recreated.record(
            ConnectionTelemetryDraft(role: .viewer, stage: .attemptSucceeded)
        )
        _ = await recreated.flush()
        let recreatedSnapshot = recreated.snapshot()
        #expect(recreatedSnapshot.events.map(\.id) == [4, 5, 6])
        #expect(recreatedSnapshot.events.last?.stage == .attemptSucceeded)
        #expect(recreatedSnapshot.droppedEventCount == 3)
    }

    @Test func journalSchemaCannotEncodeRawSecretsNetworkMetadataOrFreeFormText() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("trace.json")
        let rawPairID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let rawAttemptID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let journal = LocalConnectionTelemetryJournal(fileURL: fileURL)

        journal.record(
            ConnectionTelemetryDraft(
                role: .viewer,
                stage: .viewerWorkerWaitingForHost,
                attemptReference: .derive(domain: .attempt, uuid: rawAttemptID),
                pairReference: .derive(domain: .pair, uuid: rawPairID),
                retryOrdinal: 2,
                failure: .peerUnavailable
            )
        )
        _ = await journal.flush()

        let data = try Data(contentsOf: fileURL)
        let encoded = String(decoding: data, as: UTF8.self)
        for forbidden in [
            rawPairID.uuidString,
            rawAttemptID.uuidString,
            Self.syntheticSecretCanary,
            "wss://audiostreamer.example",
            "203.0.113.9",
            "candidate:",
            "v=0\\r\\n",
        ] {
            #expect(!encoded.localizedCaseInsensitiveContains(forbidden))
        }

        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(Set(object.keys) == ["schemaVersion", "droppedEventCount", "events"])
        let events = try #require(object["events"] as? [[String: Any]])
        let event = try #require(events.first)
        #expect(
            Set(event.keys) == [
                "id", "timestamp", "monotonicNanoseconds", "role", "stage",
                "attemptReference", "pairReference", "retryOrdinal", "failure",
            ]
        )
    }

    @Test func fingerprintIsDomainSeparatedAndContainsOnlyNinetySixDigestBits() {
        let bytes = Data(repeating: 0xA5, count: 32)
        let pair = ConnectionTelemetryFingerprint.derive(domain: .pair, bytes: bytes)
        let attempt = ConnectionTelemetryFingerprint.derive(domain: .attempt, bytes: bytes)

        #expect(pair != attempt)
        #expect(pair.rawValue.count == 24)
        #expect(ConnectionTelemetryFingerprint(rawValue: pair.rawValue) == pair)
        #expect(ConnectionTelemetryFingerprint(rawValue: "not-a-fingerprint") == nil)
    }

    @Test func corruptArchiveRecoversWithoutThrowingAndNextRecordRepairsPersistence() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("trace.json")
        try Data("not-json".utf8).write(to: fileURL)

        let journal = LocalConnectionTelemetryJournal(fileURL: fileURL)
        #expect(!journal.snapshot().persistenceHealthy)
        journal.record(
            ConnectionTelemetryDraft(role: .host, stage: .availabilityLoopStarted)
        )
        let snapshot = await journal.flush()
        #expect(snapshot.persistenceHealthy)
        #expect(snapshot.events.map(\.stage) == [.availabilityLoopStarted])
    }

    @Test func persistenceFailureIsObservableButNeverDropsTheInMemoryEvent() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nonDirectory = directory.appendingPathComponent("ordinary-file")
        try Data("occupied".utf8).write(to: nonDirectory)
        let journal = LocalConnectionTelemetryJournal(
            fileURL: nonDirectory.appendingPathComponent("trace.json")
        )

        journal.record(
            ConnectionTelemetryDraft(role: .host, stage: .retryScheduled)
        )
        let snapshot = await journal.flush()
        #expect(!snapshot.persistenceHealthy)
        #expect(snapshot.events.map(\.stage) == [.retryScheduled])
    }

    #if os(macOS)
    @Test func persistedArchiveIsOwnerReadableAndWritableOnly() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("nested/trace.json")
        let journal = LocalConnectionTelemetryJournal(fileURL: fileURL)
        journal.record(
            ConnectionTelemetryDraft(role: .host, stage: .availabilityLoopStarted)
        )
        _ = await journal.flush()

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.deletingLastPathComponent().path
        )
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
    #endif

    @Test func decodedArchiveRejectsOverflowAndUnvalidatedFingerprints() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("trace.json")
        let overflowArchive = #"{"schemaVersion":1,"droppedEventCount":18446744073709551615,"events":[{"id":18446744073709551615,"timestamp":0,"monotonicNanoseconds":0,"role":"host","stage":"availabilityLoopStarted"}]}"#
        try Data(overflowArchive.utf8).write(to: fileURL)

        let overflowJournal = LocalConnectionTelemetryJournal(fileURL: fileURL)
        #expect(!overflowJournal.snapshot().persistenceHealthy)
        overflowJournal.record(
            ConnectionTelemetryDraft(role: .host, stage: .availabilityLoopStarted)
        )
        let repaired = await overflowJournal.flush()
        #expect(repaired.persistenceHealthy)
        #expect(repaired.events.map(\.id) == [1])

        let invalidFingerprintArchive = """
        {"schemaVersion":1,"droppedEventCount":0,"events":[{"id":1,"timestamp":0,"monotonicNanoseconds":0,"role":"viewer","stage":"attemptStarted","attemptReference":"\(Self.syntheticSecretCanary)"}]}
        """
        try Data(invalidFingerprintArchive.utf8).write(to: fileURL, options: .atomic)
        let fingerprintJournal = LocalConnectionTelemetryJournal(fileURL: fileURL)
        #expect(!fingerprintJournal.snapshot().persistenceHealthy)
        #expect(fingerprintJournal.snapshot().events.isEmpty)
    }

    @Test func encodedByteLimitIsAppliedOffTheCallerAndReflectedAfterFlush() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("trace.json")
        let journal = LocalConnectionTelemetryJournal(
            fileURL: fileURL,
            maximumEventCount: 100,
            maximumEncodedBytes: 512
        )

        for retry in 0..<20 {
            journal.record(
                ConnectionTelemetryDraft(
                    role: .viewer,
                    stage: .retryScheduled,
                    retryOrdinal: UInt16(retry),
                    failure: .connectionClosed
                )
            )
        }
        let snapshot = await journal.flush()
        let data = try Data(contentsOf: fileURL)

        #expect(data.count <= 512)
        #expect(snapshot.events.count < 20)
        #expect(snapshot.droppedEventCount > 0)
        #expect(snapshot.events.last?.retryOrdinal == 19)
    }

    @Test func existentialRecorderFlushWaitsForConcreteJournalPersistence() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("trace.json")
        let recorder: any ConnectionTelemetryRecording = LocalConnectionTelemetryJournal(
            fileURL: fileURL
        )

        recorder.record(
            ConnectionTelemetryDraft(role: .host, stage: .hostStopped, terminal: .cancelled)
        )
        let snapshot = await recorder.flush()

        #expect(snapshot.events.map(\.stage) == [.hostStopped])
        let data = try Data(contentsOf: fileURL)
        let encoded = String(decoding: data, as: UTF8.self)
        #expect(encoded.contains(ConnectionTelemetryStage.hostStopped.rawValue))
    }

    @Test func existentialFlushDispatchesToConcreteProtocolWitness() async {
        let concrete = FlushWitnessRecorder()
        let recorder: any ConnectionTelemetryRecording = concrete

        let snapshot = await recorder.flush()

        #expect(concrete.wasFlushed())
        #expect(!snapshot.persistenceHealthy)
    }

    @Test func concurrentOutOfOrderEnqueueCannotOverwriteNewerDiskSnapshot() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("trace.json")
        let gate = PersistenceEnqueueGate()
        let journal = LocalConnectionTelemetryJournal(
            fileURL: fileURL,
            beforePersistenceEnqueue: gate.beforeEnqueue
        )

        let firstRecord = Task.detached {
            journal.record(
                ConnectionTelemetryDraft(role: .viewer, stage: .attemptStarted)
            )
        }
        let firstPaused = gate.waitUntilFirstPaused()
        #expect(firstPaused)
        let secondRecord = Task.detached {
            journal.record(
                ConnectionTelemetryDraft(role: .viewer, stage: .attemptSucceeded)
            )
        }
        _ = await secondRecord.value
        gate.releaseFirst()
        _ = await firstRecord.value
        _ = await journal.flush()

        let recreated = LocalConnectionTelemetryJournal(fileURL: fileURL)
        #expect(recreated.snapshot().events.map(\.stage) == [.attemptStarted, .attemptSucceeded])
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamerTelemetryTests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}

/// Forces a deterministic inversion between two persistence enqueues to expose stale-write races.
private final class PersistenceEnqueueGate: @unchecked Sendable {
    private let firstReached = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func beforeEnqueue(_ generation: UInt64) {
        guard generation == 1 else { return }
        firstReached.signal()
        _ = release.wait(timeout: .now() + 2)
    }

    func waitUntilFirstPaused() -> Bool {
        firstReached.wait(timeout: .now() + 1) == .success
    }

    func releaseFirst() {
        release.signal()
    }
}

/// Proves existential `flush()` dispatches to the concrete protocol witness rather than defaulting.
private final class FlushWitnessRecorder: ConnectionTelemetryRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var flushObserved = false

    func record(_: ConnectionTelemetryDraft) -> ConnectionTelemetrySnapshot {
        .empty
    }

    func snapshot() -> ConnectionTelemetrySnapshot {
        .empty
    }

    func flush() async -> ConnectionTelemetrySnapshot {
        markFlushed()
        return ConnectionTelemetrySnapshot(
            events: [],
            droppedEventCount: 0,
            persistenceHealthy: false
        )
    }

    func wasFlushed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return flushObserved
    }

    private func markFlushed() {
        lock.lock()
        flushObserved = true
        lock.unlock()
    }
}
