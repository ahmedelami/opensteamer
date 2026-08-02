import Darwin
import Foundation

/// Per-user advisory lock that prevents concurrent legacy and rebranded worldwide hosts.
///
/// The canonical runtime-directory inode is opened with `O_NOFOLLOW`, all lock operations use
/// `openat`/`fstatat` relative to that descriptor, and the pathname is re-opened and compared before
/// the lock is returned. A directory rename/replacement or lock-entry substitution therefore fails
/// closed instead of allowing a second host to acquire a different inode under the same pathname.
final class WorldwideHostProcessLock {
    static let legacyRuntimeDirectoryName = "com.elamin.AudioStreamer.CaptureServer.runtime"
    private static let fileName = "worldwide-host.lock"

    private let descriptorLock = NSLock()
    private var descriptor: Int32?
    let generationNonce: String

    private init(descriptor: Int32, generationNonce: String) {
        self.descriptor = descriptor
        self.generationNonce = generationNonce
    }

    deinit {
        release()
    }

    static func acquire(
        lockDirectoryURL: URL? = nil,
        afterDirectoryValidationForTesting: (() throws -> Void)? = nil,
        afterLockOpenForTesting: (() throws -> Void)? = nil
    ) throws -> WorldwideHostProcessLock {
        let directoryURL = try lockDirectoryURL ?? defaultLockDirectoryURL()
        let openedDirectory = try openValidatedLockDirectory(directoryURL)
        defer { Darwin.close(openedDirectory.descriptor) }

        try afterDirectoryValidationForTesting?()
        let lockDescriptor = try openLockFile(in: openedDirectory.descriptor)
        do {
            try afterLockOpenForTesting?()
            try validateAndRestrictLockFile(
                lockDescriptor,
                in: openedDirectory.descriptor
            )
            try revalidateCanonicalPath(
                directoryURL,
                expectedDirectory: openedDirectory.metadata,
                expectedLockDescriptor: lockDescriptor
            )
            let generationNonce = makeGenerationNonce()
            try publishGenerationRecord(
                descriptor: lockDescriptor,
                nonce: generationNonce
            )
            try revalidateCanonicalPath(
                directoryURL,
                expectedDirectory: openedDirectory.metadata,
                expectedLockDescriptor: lockDescriptor
            )
            return WorldwideHostProcessLock(
                descriptor: lockDescriptor,
                generationNonce: generationNonce
            )
        } catch {
            Darwin.close(lockDescriptor)
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

    private struct OpenedDirectory {
        let descriptor: Int32
        let metadata: stat
    }

    private static func defaultLockDirectoryURL() throws -> URL {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw WorldwideHostProcessLockError.applicationSupportUnavailable
        }
        return applicationSupportURL.appendingPathComponent(
            legacyRuntimeDirectoryName,
            isDirectory: true
        )
    }

    private static func openValidatedLockDirectory(_ directoryURL: URL) throws -> OpenedDirectory {
        guard directoryURL.isFileURL else {
            throw WorldwideHostProcessLockError.unsafeLockDirectory
        }
        let path = directoryURL.standardizedFileURL.path
        let createResult = path.withCString { pointer in
            Darwin.mkdir(pointer, mode_t(0o700))
        }
        if createResult != 0, errno != EEXIST {
            throw systemCallError(operation: "create its runtime directory", code: errno)
        }

        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let descriptor = path.withCString { pointer in
            Darwin.open(pointer, flags)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw WorldwideHostProcessLockError.unsafeLockDirectory
            }
            throw systemCallError(operation: "open its runtime directory", code: errno)
        }

        do {
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0 else {
                throw systemCallError(operation: "inspect its runtime directory", code: errno)
            }
            guard metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == Darwin.geteuid() else {
                throw WorldwideHostProcessLockError.unsafeLockDirectory
            }
            guard Darwin.fchmod(descriptor, mode_t(0o700)) == 0 else {
                throw systemCallError(operation: "secure its runtime directory", code: errno)
            }
            var securedMetadata = stat()
            guard Darwin.fstat(descriptor, &securedMetadata) == 0 else {
                throw systemCallError(operation: "reinspect its secured runtime directory", code: errno)
            }
            guard securedMetadata.st_mode & S_IFMT == S_IFDIR,
                  securedMetadata.st_uid == Darwin.geteuid(),
                  securedMetadata.st_mode & mode_t(0o777) == mode_t(0o700),
                  sameIdentity(metadata, securedMetadata) else {
                throw WorldwideHostProcessLockError.unsafeLockDirectory
            }
            return OpenedDirectory(descriptor: descriptor, metadata: securedMetadata)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openLockFile(in directoryDescriptor: Int32) throws -> Int32 {
        let existingFlags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_EXLOCK
        let existing = fileName.withCString { pointer in
            Darwin.openat(directoryDescriptor, pointer, existingFlags)
        }
        if existing >= 0 {
            return existing
        }
        let existingError = errno
        if existingError == EWOULDBLOCK || existingError == EAGAIN {
            throw WorldwideHostProcessLockError.alreadyRunning
        }
        if existingError == ELOOP {
            throw WorldwideHostProcessLockError.unsafeLockFile
        }
        guard existingError == ENOENT else {
            throw systemCallError(operation: "open its existing process lock", code: existingError)
        }

        let createFlags = existingFlags | O_CREAT | O_EXCL
        let created = fileName.withCString { pointer in
            Darwin.openat(directoryDescriptor, pointer, createFlags, mode_t(0o600))
        }
        if created >= 0 {
            return created
        }
        let createError = errno
        if createError == EEXIST {
            let raced = fileName.withCString { pointer in
                Darwin.openat(directoryDescriptor, pointer, existingFlags)
            }
            if raced >= 0 {
                return raced
            }
            let racedError = errno
            if racedError == EWOULDBLOCK || racedError == EAGAIN {
                throw WorldwideHostProcessLockError.alreadyRunning
            }
            if racedError == ELOOP {
                throw WorldwideHostProcessLockError.unsafeLockFile
            }
            throw systemCallError(operation: "open its raced process lock", code: racedError)
        }
        if createError == EWOULDBLOCK || createError == EAGAIN {
            throw WorldwideHostProcessLockError.alreadyRunning
        }
        if createError == ELOOP {
            throw WorldwideHostProcessLockError.unsafeLockFile
        }
        throw systemCallError(operation: "exclusively create its process lock", code: createError)
    }

    private static func validateAndRestrictLockFile(
        _ descriptor: Int32,
        in directoryDescriptor: Int32
    ) throws {
        var descriptorMetadata = stat()
        guard Darwin.fstat(descriptor, &descriptorMetadata) == 0 else {
            throw systemCallError(operation: "inspect its process lock", code: errno)
        }
        guard isStructurallySafeLockMetadata(descriptorMetadata) else {
            throw WorldwideHostProcessLockError.unsafeLockFile
        }

        var entryMetadata = stat()
        let entryStatus = fileName.withCString { pointer in
            Darwin.fstatat(
                directoryDescriptor,
                pointer,
                &entryMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard entryStatus == 0 else {
            throw systemCallError(operation: "reinspect its process lock", code: errno)
        }
        guard isStructurallySafeLockMetadata(entryMetadata),
              sameIdentity(descriptorMetadata, entryMetadata) else {
            throw WorldwideHostProcessLockError.unsafeLockFile
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw systemCallError(operation: "secure its process lock", code: errno)
        }
        var securedDescriptorMetadata = stat()
        guard Darwin.fstat(descriptor, &securedDescriptorMetadata) == 0 else {
            throw systemCallError(operation: "reinspect its secured process lock", code: errno)
        }
        var securedEntryMetadata = stat()
        let securedEntryStatus = fileName.withCString { pointer in
            Darwin.fstatat(
                directoryDescriptor,
                pointer,
                &securedEntryMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard securedEntryStatus == 0,
              isSafeLockMetadata(securedDescriptorMetadata),
              isSafeLockMetadata(securedEntryMetadata),
              sameIdentity(securedDescriptorMetadata, securedEntryMetadata) else {
            throw WorldwideHostProcessLockError.unsafeLockFile
        }
    }

    /// Re-opens the canonical pathname and binds it to the directory and lock inodes already held.
    private static func revalidateCanonicalPath(
        _ directoryURL: URL,
        expectedDirectory: stat,
        expectedLockDescriptor: Int32
    ) throws {
        let path = directoryURL.standardizedFileURL.path
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let currentDirectoryDescriptor = path.withCString { pointer in
            Darwin.open(pointer, flags)
        }
        guard currentDirectoryDescriptor >= 0 else {
            throw WorldwideHostProcessLockError.unsafeLockDirectory
        }
        defer { Darwin.close(currentDirectoryDescriptor) }

        var currentDirectoryMetadata = stat()
        guard Darwin.fstat(currentDirectoryDescriptor, &currentDirectoryMetadata) == 0 else {
            throw systemCallError(operation: "reinspect its canonical runtime directory", code: errno)
        }
        guard currentDirectoryMetadata.st_mode & S_IFMT == S_IFDIR,
              currentDirectoryMetadata.st_uid == Darwin.geteuid(),
              currentDirectoryMetadata.st_mode & mode_t(0o777) == mode_t(0o700),
              sameIdentity(expectedDirectory, currentDirectoryMetadata) else {
            throw WorldwideHostProcessLockError.unsafeLockDirectory
        }

        var descriptorMetadata = stat()
        guard Darwin.fstat(expectedLockDescriptor, &descriptorMetadata) == 0 else {
            throw systemCallError(operation: "reinspect its open process lock", code: errno)
        }
        var currentEntryMetadata = stat()
        let entryStatus = fileName.withCString { pointer in
            Darwin.fstatat(
                currentDirectoryDescriptor,
                pointer,
                &currentEntryMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard entryStatus == 0 else {
            throw WorldwideHostProcessLockError.unsafeLockFile
        }
        guard isSafeLockMetadata(currentEntryMetadata),
              sameIdentity(descriptorMetadata, currentEntryMetadata) else {
            throw WorldwideHostProcessLockError.unsafeLockFile
        }
    }

    private static func makeGenerationNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            Darwin.arc4random_buf(baseAddress, buffer.count)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func publishGenerationRecord(
        descriptor: Int32,
        nonce: String
    ) throws {
        guard nonce.count == 64, nonce.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw WorldwideHostProcessLockError.unsafeLockFile
        }
        let record = """
        OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1
        pid=\(Darwin.getpid())
        nonce=\(nonce)

        """
        let bytes = Array(record.utf8)
        guard Darwin.ftruncate(descriptor, 0) == 0 else {
            throw systemCallError(operation: "reset its process generation record", code: errno)
        }
        guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw systemCallError(operation: "seek its process generation record", code: errno)
        }
        var written = 0
        while written < bytes.count {
            let result = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: written),
                    bytes.count - written
                )
            }
            guard result > 0 else {
                throw systemCallError(operation: "write its process generation record", code: errno)
            }
            written += result
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw systemCallError(operation: "durably publish its process generation record", code: errno)
        }
    }

    private static func isStructurallySafeLockMetadata(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_uid == Darwin.geteuid()
            && metadata.st_nlink == 1
    }

    private static func isSafeLockMetadata(_ metadata: stat) -> Bool {
        isStructurallySafeLockMetadata(metadata)
            && metadata.st_mode & mode_t(0o777) == mode_t(0o600)
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func systemCallError(
        operation: String,
        code: Int32
    ) -> WorldwideHostProcessLockError {
        WorldwideHostProcessLockError.systemCall(operation: operation, code: code)
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
            "Another opensteamer worldwide host is already running for this macOS account."
        case .applicationSupportUnavailable:
            "opensteamer could not locate this macOS account's Application Support directory."
        case .unsafeLockDirectory:
            "opensteamer's worldwide-host runtime directory changed or is not safely owned."
        case .unsafeLockFile:
            "opensteamer's worldwide-host process lock changed or is not a safe regular file."
        case .systemCall(let operation, let code):
            "opensteamer could not \(operation) (errno \(code))."
        }
    }
}
