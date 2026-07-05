import Foundation

struct PCMClientOptions {
    var host = "127.0.0.1"
    var port: UInt16 = 9000
    var maxPackets = 300
    var authToken = ProcessInfo.processInfo.environment["MCAP_TOKEN"]?.nilIfEmpty
    var showHelp = false

    static let usage = """
    Usage:
      swift run PCMClient --host 127.0.0.1 --port 9000 --packets 300

    Options:
      --host <host>      Server host. Defaults to 127.0.0.1.
      --port <port>      Server port. Defaults to 9000.
      --packets <count>  Number of packets to validate. Defaults to 300.
      --token <token>    Client token. Defaults to MCAP_TOKEN if set.
      --help             Print this help.
    """

    static func parse(_ arguments: [String]) throws -> PCMClientOptions {
        var options = PCMClientOptions()
        var index = 1

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--host":
                index += 1
                guard index < arguments.count else {
                    throw PCMClientOptionError.invalid("--host requires a value")
                }
                options.host = arguments[index]
            case "--port":
                index += 1
                guard index < arguments.count, let value = UInt16(arguments[index]) else {
                    throw PCMClientOptionError.invalid("--port requires a valid UInt16")
                }
                options.port = value
            case "--packets":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw PCMClientOptionError.invalid("--packets requires a positive integer")
                }
                options.maxPackets = value
            case "--token":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw PCMClientOptionError.invalid("--token requires a non-empty value")
                }
                options.authToken = arguments[index]
            case "--help", "-h":
                options.showHelp = true
            default:
                throw PCMClientOptionError.invalid("unknown argument: \(arg)")
            }
            index += 1
        }

        return options
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum PCMClientOptionError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            message
        }
    }
}
