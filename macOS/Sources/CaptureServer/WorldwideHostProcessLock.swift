import Darwin
import Foundation

final class WorldwideHostProcessLock {
    private static let directoryName = "org.example.AudioStreamer.CaptureServer.runtime"
    private static let fileName = "worldwide-host.lock"

    private let descriptorLock = NSLock()
    private var descriptor: Int32?

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    static func acquire(lockDirectoryURL: URL? = nil) throws -> WorldwideHostProcessLock {
        let directoryURL = try lockDirectoryURL ?? defaultLockDirectoryURL()
        try prepareLockDirectory(directoryURL)

        let lockURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        let descriptor = try openLockFile(lockURL)
        do {
            try validateAndRestrictLockFile(descriptor)
            return WorldwideHostProcessLock(descriptor: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func release() {
        descriptorLock.lock()
        guard let descriptor else {
            descriptorLock.unlock()
            return
        }
        self.descriptor = nil
        descriptorLock.unlock()

        Darwin.close(descriptor)
    }

    private static func defaultLockDirectoryURL() throws -> URL {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw WorldwideHostProcessLockError.applicationSupportUnavailable
        }
        return applicationSupportURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func prepareLockDirectory(_ directoryURL: URL) throws {
        guard directoryURL.isFileURL else {
            throw WorldwideHostProcessLockError.unsafeLockDirectory
        }

        let path = directoryURL.standardizedFileURL.path
        let createResult = path.withCString { pointer in
            Darwin.mkdir(pointer, mode_t(0o700))
        }
        if createResult != 0, errno != EEXIST {
            throw systemCallError(operation: "create its runtime directory")
        }

        var metadata = stat()
        let statusResult = path.withCString { pointer in
            Darwin.lstat(pointer, &metadata)
        }
        guard statusResult == 0 else {
            throw systemCallError(operation: "inspect its runtime directory")
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == Darwin.geteuid() else {
            throw WorldwideHostProcessLockError.unsafeLockDirectory
        }

        let permissionResult = path.withCString { pointer in
            Darwin.chmod(pointer, mode_t(0o700))
        }
        guard permissionResult == 0 else {
            throw systemCallError(operation: "secure its runtime directory")
        }
    }

    private static func openLockFile(_ lockURL: URL) throws -> Int32 {
        // O_EXLOCK acquires the advisory lock atomically with open; O_NONBLOCK rejects duplicates.
        let flags = O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_EXLOCK
        let descriptor = lockURL.path.withCString { pointer in
            Darwin.open(pointer, flags, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN {
                throw WorldwideHostProcessLockError.alreadyRunning
            }
            throw systemCallError(operation: "open its process lock")
        }
        return descriptor
    }

    private static func validateAndRestrictLockFile(_ descriptor: Int32) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw systemCallError(operation: "inspect its process lock")
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_nlink == 1 else {
            throw WorldwideHostProcessLockError.unsafeLockFile
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw systemCallError(operation: "secure its process lock")
        }
    }

    private static func systemCallError(operation: String) -> WorldwideHostProcessLockError {
        WorldwideHostProcessLockError.systemCall(operation: operation, code: errno)
    }
}

enum WorldwideHostProcessLockError: LocalizedError, Equatable {
    case alreadyRunning
    case applicationSupportUnavailable
    case unsafeLockDirectory
    case unsafeLockFile
    case systemCall(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Another AudioStreamer worldwide host is already running for this macOS account."
        case .applicationSupportUnavailable:
            "AudioStreamer could not locate this macOS account's Application Support directory."
        case .unsafeLockDirectory:
            "AudioStreamer's worldwide-host runtime directory is not safely owned by this account."
        case .unsafeLockFile:
            "AudioStreamer's worldwide-host process lock is not a safe regular file."
        case .systemCall(let operation, let code):
            "AudioStreamer could not \(operation) (errno \(code))."
        }
    }
}
