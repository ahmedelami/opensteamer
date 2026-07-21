import Foundation

/// Framing rules for the optional authentication prefix on the legacy PCM transport.
///
/// The token length is bounded before allocation so an unauthenticated peer cannot request
/// unbounded memory. Worldwide pairing and media use the separate RemoteSessionCore protocol.
public enum PCMAuthProtocol {
    public static let magic = "MCAT"
    public static let version: UInt16 = 1
    public static let headerByteCount = 8
    public static let maximumTokenByteCount = 512

    /// Encodes an authentication request as magic, version, byte length, then UTF-8 token bytes.
    public static func makeRequest(token: String) throws -> Data {
        let tokenBytes = Array(token.utf8)
        guard !tokenBytes.isEmpty else {
            throw PCMAuthError.emptyToken
        }
        guard tokenBytes.count <= maximumTokenByteCount else {
            throw PCMAuthError.tokenTooLong(tokenBytes.count)
        }

        var data = Data(capacity: headerByteCount + tokenBytes.count)
        data.appendASCII(magic)
        data.appendLE(version)
        data.appendLE(UInt16(tokenBytes.count))
        data.append(contentsOf: tokenBytes)
        return data
    }

    /// Validates a fixed-width authentication header and returns its bounded token byte count.
    public static func tokenLength(fromHeader data: Data) throws -> Int {
        guard data.count == headerByteCount,
              String(decoding: data[0..<4], as: UTF8.self) == magic else {
            throw PCMAuthError.invalidHeader
        }

        let version = data.readUInt16LE(at: 4)
        guard version == Self.version else {
            throw PCMAuthError.unsupportedVersion(version)
        }

        let byteCount = Int(data.readUInt16LE(at: 6))
        guard byteCount > 0 else {
            throw PCMAuthError.emptyToken
        }
        guard byteCount <= maximumTokenByteCount else {
            throw PCMAuthError.tokenTooLong(byteCount)
        }

        return byteCount
    }

    /// Decodes a bounded, nonempty UTF-8 token payload.
    public static func parseToken(_ data: Data) throws -> String {
        guard !data.isEmpty else {
            throw PCMAuthError.emptyToken
        }
        guard data.count <= maximumTokenByteCount else {
            throw PCMAuthError.tokenTooLong(data.count)
        }
        guard let token = String(data: data, encoding: .utf8) else {
            throw PCMAuthError.invalidUTF8
        }
        return token
    }
}

/// Validation failures for legacy authentication messages.
public enum PCMAuthError: LocalizedError {
    case invalidHeader
    case unsupportedVersion(UInt16)
    case emptyToken
    case tokenTooLong(Int)
    case invalidUTF8

    public var errorDescription: String? {
        switch self {
        case .invalidHeader:
            "Invalid authentication header"
        case .unsupportedVersion(let version):
            "Unsupported authentication version \(version)"
        case .emptyToken:
            "Authentication token is empty"
        case .tokenTooLong(let byteCount):
            "Authentication token is too long (\(byteCount) bytes)"
        case .invalidUTF8:
            "Authentication token is not valid UTF-8"
        }
    }
}

private extension Data {
    mutating func appendASCII(_ text: String) {
        append(contentsOf: text.utf8)
    }

    mutating func appendLE(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func readUInt16LE(at offset: Int) -> UInt16 {
        var value: UInt16 = 0
        for index in 0..<2 {
            value |= UInt16(self[offset + index]) << (index * 8)
        }
        return value
    }
}
