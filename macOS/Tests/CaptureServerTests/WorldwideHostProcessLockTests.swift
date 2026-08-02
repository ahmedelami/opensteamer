import Darwin
import Dispatch
import Foundation
import XCTest
@testable import CaptureServer

/// Verifies cross-version exclusion, owner-only metadata, and canonical inode binding.
final class WorldwideHostProcessLockTests: XCTestCase {
    private final class ContentionResult: @unchecked Sendable {
        private let lock = NSLock()
        private var storedError: WorldwideHostProcessLockError?
        private var storedUnexpected: String?

        func store(error: WorldwideHostProcessLockError) {
            lock.lock()
            storedError = error
            lock.unlock()
        }

        func store(unexpected: String) {
            lock.lock()
            storedUnexpected = unexpected
            lock.unlock()
        }

        func snapshot() -> (WorldwideHostProcessLockError?, String?) {
            lock.lock()
            defer { lock.unlock() }
            return (storedError, storedUnexpected)
        }
    }

    func testVisibleRebrandPreservesCrossVersionRuntimeNamespace() {
        XCTAssertEqual(
            WorldwideHostProcessLock.legacyRuntimeDirectoryName,
            "com.elamin.AudioStreamer.CaptureServer.runtime"
        )
    }

    func testSecondWorldwideHostCannotAcquireSamePerUserLock() throws {
        let directory = makeLockDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try WorldwideHostProcessLock.acquire(lockDirectoryURL: directory)
        defer { first.release() }
        XCTAssertThrowsError(
            try WorldwideHostProcessLock.acquire(lockDirectoryURL: directory)
        ) { error in
            XCTAssertEqual(error as? WorldwideHostProcessLockError, .alreadyRunning)
        }
    }

    func testReleasedLockCanBeReacquired() throws {
        let directory = makeLockDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try WorldwideHostProcessLock.acquire(lockDirectoryURL: directory)
        first.release()
        let second = try WorldwideHostProcessLock.acquire(lockDirectoryURL: directory)
        second.release()
    }

    func testLockDirectoryAndFileArePrivateToCurrentUser() throws {
        let directory = makeLockDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = try WorldwideHostProcessLock.acquire(lockDirectoryURL: directory)
        defer { lock.release() }

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("worldwide-host.lock").path
        )
        XCTAssertEqual(directoryAttributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
        XCTAssertEqual(fileAttributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
        XCTAssertEqual(directoryAttributes[.ownerAccountID] as? NSNumber, NSNumber(value: geteuid()))
        XCTAssertEqual(fileAttributes[.ownerAccountID] as? NSNumber, NSNumber(value: geteuid()))
    }

    func testAcquisitionPublishesDurableGenerationRecordBoundToCurrentPID() throws {
        let directory = makeLockDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = try WorldwideHostProcessLock.acquire(lockDirectoryURL: directory)
        defer { lock.release() }

        let recordURL = directory.appendingPathComponent("worldwide-host.lock")
        let record = try String(contentsOf: recordURL, encoding: .utf8)
        XCTAssertEqual(
            record,
            "OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\npid=\(getpid())\nnonce=\(lock.generationNonce)\n"
        )
        XCTAssertEqual(lock.generationNonce.count, 64)
        XCTAssertTrue(lock.generationNonce.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testReacquisitionPublishesANewGenerationNonce() throws {
        let directory = makeLockDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try WorldwideHostProcessLock.acquire(lockDirectoryURL: directory)
        let firstNonce = first.generationNonce
        first.release()
        let second = try WorldwideHostProcessLock.acquire(lockDirectoryURL: directory)
        defer { second.release() }
        XCTAssertNotEqual(second.generationNonce, firstNonce)
        let record = try String(
            contentsOf: directory.appendingPathComponent("worldwide-host.lock"),
            encoding: .utf8
        )
        XCTAssertTrue(record.contains("nonce=\(second.generationNonce)\n"))
        XCTAssertFalse(record.contains("nonce=\(firstNonce)\n"))
    }

    func testCanonicalDirectoryRenameAndReplacementIsRejected() throws {
        let fileManager = FileManager.default
        let root = makeLockDirectoryURL()
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        let canonical = root.appendingPathComponent("runtime", isDirectory: true)
        let displaced = root.appendingPathComponent("runtime-displaced", isDirectory: true)
        try fileManager.createDirectory(at: canonical, withIntermediateDirectories: false)

        XCTAssertThrowsError(
            try WorldwideHostProcessLock.acquire(
                lockDirectoryURL: canonical,
                afterDirectoryValidationForTesting: {
                    try fileManager.moveItem(at: canonical, to: displaced)
                    try fileManager.createDirectory(at: canonical, withIntermediateDirectories: false)
                }
            )
        ) { error in
            XCTAssertEqual(error as? WorldwideHostProcessLockError, .unsafeLockDirectory)
        }

        let replacementLock = try WorldwideHostProcessLock.acquire(lockDirectoryURL: canonical)
        replacementLock.release()
    }

    func testLockInodeSubstitutionAfterOpenIsRejected() throws {
        let fileManager = FileManager.default
        let directory = makeLockDirectoryURL()
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        let lockFile = directory.appendingPathComponent("worldwide-host.lock")
        let displaced = directory.appendingPathComponent("worldwide-host.lock.displaced")

        XCTAssertThrowsError(
            try WorldwideHostProcessLock.acquire(
                lockDirectoryURL: directory,
                afterLockOpenForTesting: {
                    try fileManager.moveItem(at: lockFile, to: displaced)
                    XCTAssertTrue(fileManager.createFile(atPath: lockFile.path, contents: Data()))
                }
            )
        ) { error in
            XCTAssertEqual(error as? WorldwideHostProcessLockError, .unsafeLockFile)
        }
    }

    func testSymbolicLinkDirectoryIsRejected() throws {
        let fileManager = FileManager.default
        let root = makeLockDirectoryURL()
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        let real = root.appendingPathComponent("real", isDirectory: true)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try fileManager.createDirectory(at: real, withIntermediateDirectories: false)
        try fileManager.createSymbolicLink(at: linked, withDestinationURL: real)
        XCTAssertThrowsError(
            try WorldwideHostProcessLock.acquire(lockDirectoryURL: linked)
        ) { error in
            guard let lockError = error as? WorldwideHostProcessLockError else {
                return XCTFail("Unexpected error: \(error)")
            }
            switch lockError {
            case .unsafeLockDirectory, .systemCall:
                break
            default:
                XCTFail("Unexpected lock error: \(lockError)")
            }
        }
    }

    func testSymbolicLinkAndHardLinkedLockFilesAreRejected() throws {
        let fileManager = FileManager.default

        do {
            let directory = makeLockDirectoryURL()
            defer { try? fileManager.removeItem(at: directory) }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            let target = directory.appendingPathComponent("target")
            try Data().write(to: target)
            try fileManager.createSymbolicLink(
                at: directory.appendingPathComponent("worldwide-host.lock"),
                withDestinationURL: target
            )
            XCTAssertThrowsError(
                try WorldwideHostProcessLock.acquire(lockDirectoryURL: directory)
            )
        }

        do {
            let directory = makeLockDirectoryURL()
            defer { try? fileManager.removeItem(at: directory) }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            let lockFile = directory.appendingPathComponent("worldwide-host.lock")
            let secondLink = directory.appendingPathComponent("second-link")
            try Data().write(to: lockFile)
            try fileManager.linkItem(at: lockFile, to: secondLink)
            XCTAssertThrowsError(
                try WorldwideHostProcessLock.acquire(lockDirectoryURL: directory)
            ) { error in
                XCTAssertEqual(error as? WorldwideHostProcessLockError, .unsafeLockFile)
            }
        }
    }

    func testConcurrentLegacyToNewAndNewToLegacyContention() throws {
        try assertConcurrentContention(label: "legacy-to-new")
        try assertConcurrentContention(label: "new-to-legacy")
    }

    private func assertConcurrentContention(label: String) throws {
        let root = makeLockDirectoryURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let directory = root.appendingPathComponent(label, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try WorldwideHostProcessLock.acquire(lockDirectoryURL: directory)
        defer { first.release() }

        let startGate = DispatchSemaphore(value: 0)
        let completion = DispatchGroup()
        let result = ContentionResult()
        completion.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            startGate.wait()
            do {
                let contender = try WorldwideHostProcessLock.acquire(lockDirectoryURL: directory)
                contender.release()
                result.store(unexpected: "concurrent contender acquired the held lock")
            } catch let error as WorldwideHostProcessLockError {
                result.store(error: error)
            } catch {
                result.store(unexpected: String(describing: error))
            }
            completion.leave()
        }
        startGate.signal()
        XCTAssertEqual(completion.wait(timeout: .now() + 5), .success)
        let snapshot = result.snapshot()
        XCTAssertNil(snapshot.1)
        XCTAssertEqual(snapshot.0, .alreadyRunning)
    }

    private func makeLockDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamerLockTests-\(UUID().uuidString)", isDirectory: true)
    }
}
