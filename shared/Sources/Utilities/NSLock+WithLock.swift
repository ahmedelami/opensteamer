import Foundation

public extension NSLock {
    /// Executes `body` while holding the lock and always unlocks, including when `body` throws.
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
