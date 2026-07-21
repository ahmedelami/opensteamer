import Foundation

/// Minimal logging surface shared by capture components and command-line hosts.
public protocol Logger: Sendable {
    /// Emits an operator-relevant lifecycle message.
    func info(_ message: String)
    /// Emits verbose diagnostic detail when enabled by the implementation.
    func debug(_ message: String)
    /// Emits a failure message.
    func error(_ message: String)
}

/// Writes line-buffered capture logs to standard output and standard error.
public struct ConsoleLogger: Logger {
    private let verbose: Bool

    /// Creates a logger that conditionally includes debug output.
    public init(verbose: Bool) {
        self.verbose = verbose
    }

    public func info(_ message: String) {
        print("[info] \(message)")
        fflush(stdout)
    }

    public func debug(_ message: String) {
        guard verbose else { return }
        print("[debug] \(message)")
        fflush(stdout)
    }

    public func error(_ message: String) {
        fputs("[error] \(message)\n", stderr)
        fflush(stderr)
    }
}
