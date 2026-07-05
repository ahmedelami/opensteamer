import Foundation

public protocol Logger: Sendable {
    func info(_ message: String)
    func debug(_ message: String)
    func error(_ message: String)
}

public struct ConsoleLogger: Logger {
    private let verbose: Bool

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
