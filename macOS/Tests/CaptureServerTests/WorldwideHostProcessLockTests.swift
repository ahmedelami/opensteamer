import Foundation
import XCTest
@testable import CaptureServer

final class WorldwideHostProcessLockTests: XCTestCase {
    func testSecondWorldwideHostCannotAcquireSamePerUserLock() throws {
        let lockDirectoryURL = makeLockDirectoryURL()
        defer { try? FileManager.default.removeItem(at: lockDirectoryURL) }

        let firstLock = try WorldwideHostProcessLock.acquire(
            lockDirectoryURL: lockDirectoryURL
        )
        defer { firstLock.release() }

        XCTAssertThrowsError(
            try WorldwideHostProcessLock.acquire(lockDirectoryURL: lockDirectoryURL)
        ) { error in
            XCTAssertEqual(error as? WorldwideHostProcessLockError, .alreadyRunning)
        }
    }

    func testReleasedLockCanBeReacquired() throws {
        let lockDirectoryURL = makeLockDirectoryURL()
        defer { try? FileManager.default.removeItem(at: lockDirectoryURL) }

        let firstLock = try WorldwideHostProcessLock.acquire(
            lockDirectoryURL: lockDirectoryURL
        )
        firstLock.release()

        let replacementLock = try WorldwideHostProcessLock.acquire(
            lockDirectoryURL: lockDirectoryURL
        )
        replacementLock.release()
    }

    func testLockDirectoryAndFileArePrivateToCurrentUser() throws {
        let lockDirectoryURL = makeLockDirectoryURL()
        defer { try? FileManager.default.removeItem(at: lockDirectoryURL) }

        let lock = try WorldwideHostProcessLock.acquire(lockDirectoryURL: lockDirectoryURL)
        defer { lock.release() }

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: lockDirectoryURL.path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: lockDirectoryURL.appendingPathComponent("worldwide-host.lock").path
        )

        XCTAssertEqual(directoryAttributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
        XCTAssertEqual(fileAttributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
        XCTAssertEqual(directoryAttributes[.ownerAccountID] as? NSNumber, NSNumber(value: geteuid()))
        XCTAssertEqual(fileAttributes[.ownerAccountID] as? NSNumber, NSNumber(value: geteuid()))
    }

    private func makeLockDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioStreamerLockTests-\(UUID().uuidString)", isDirectory: true)
    }
}
