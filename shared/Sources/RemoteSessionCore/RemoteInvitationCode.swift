import CryptoKit
import Foundation
import Security

/// A high-entropy, human-transcribable capability used to bootstrap one remote session.
///
/// Reading `description` never reveals the capability. UI that intentionally presents the
/// secret must use `exportedCode` and must avoid logging the returned value.
public struct RemoteInvitationCode: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let version: UInt8 = 1
    public static let secretByteCount = 20
    public static let secretBitCount = secretByteCount * 8

    private static let checksumByteCount = 4
    private static let encodedByteCount = 1 + secretByteCount + checksumByteCount
    private static let checksumDomain = Data("AudioStreamer.RemoteInvitation.Checksum.v1\0".utf8)

    private let secret: Data

    public init(_ input: String) throws {
        let packet: Data
        do {
            packet = try CrockfordBase32.decode(input, expectedByteCount: Self.encodedByteCount)
        } catch {
            throw RemoteSessionCoreError.invalidInvitationCode
        }

        guard packet.count == Self.encodedByteCount else {
            throw RemoteSessionCoreError.invalidInvitationCode
        }
        guard packet[packet.startIndex] == Self.version else {
            throw RemoteSessionCoreError.unsupportedInvitationVersion
        }

        let bodyByteCount = 1 + Self.secretByteCount
        let body = Data(packet.prefix(bodyByteCount))
        let suppliedChecksum = Data(packet.suffix(Self.checksumByteCount))
        guard timingSafeEqual(suppliedChecksum, Self.checksum(for: body)) else {
            throw RemoteSessionCoreError.invalidInvitationCode
        }

        secret = Data(body.dropFirst())
    }

    /// Generates 160 bits of entropy with Apple's cryptographically secure random source.
    public static func generate() throws -> RemoteInvitationCode {
        var bytes = [UInt8](repeating: 0, count: secretByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RemoteSessionCoreError.secureRandomGenerationFailed
        }
        return try RemoteInvitationCode(secret: Data(bytes))
    }

    /// The deliberately explicit escape hatch for showing or transferring the secret.
    /// Never include this value in telemetry, diagnostics, crash reports, or URLs.
    public var exportedCode: String {
        CrockfordBase32.group(canonicalCode, every: 5)
    }

    public var description: String { "<redacted remote invitation>" }
    public var debugDescription: String { description }

    internal init(secret: Data) throws {
        guard secret.count == Self.secretByteCount else {
            throw RemoteSessionCoreError.invalidInvitationCode
        }
        self.secret = secret
    }

    internal var secretMaterial: Data { secret }

    internal var canonicalCode: String {
        var body = Data([Self.version])
        body.append(secret)

        var packet = body
        packet.append(Self.checksum(for: body))
        return CrockfordBase32.encode(packet)
    }

    private static func checksum(for body: Data) -> Data {
        var input = checksumDomain
        input.append(body)
        return Data(SHA256.hash(data: input).prefix(checksumByteCount))
    }
}

internal enum CrockfordBase32 {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

    static func encode(_ data: Data) -> String {
        var output = [UInt8]()
        output.reserveCapacity((data.count * 8 + 4) / 5)

        var buffer: UInt32 = 0
        var bufferedBitCount = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bufferedBitCount += 8
            while bufferedBitCount >= 5 {
                bufferedBitCount -= 5
                let index = Int((buffer >> UInt32(bufferedBitCount)) & 0x1f)
                output.append(alphabet[index])
            }
        }

        if bufferedBitCount > 0 {
            let index = Int((buffer << UInt32(5 - bufferedBitCount)) & 0x1f)
            output.append(alphabet[index])
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func decode(_ text: String, expectedByteCount: Int) throws -> Data {
        let symbols = try normalizedSymbols(text)
        let expectedSymbolCount = (expectedByteCount * 8 + 4) / 5
        guard symbols.count == expectedSymbolCount else {
            throw RemoteSessionCoreError.invalidInvitationCode
        }

        var output = Data()
        output.reserveCapacity(expectedByteCount)
        var buffer: UInt32 = 0
        var bufferedBitCount = 0

        for symbol in symbols {
            guard let value = value(of: symbol) else {
                throw RemoteSessionCoreError.invalidInvitationCode
            }
            buffer = (buffer << 5) | UInt32(value)
            bufferedBitCount += 5
            while bufferedBitCount >= 8 {
                bufferedBitCount -= 8
                output.append(UInt8((buffer >> UInt32(bufferedBitCount)) & 0xff))
            }
        }

        // A non-zero padded tail would permit multiple spellings of the same capability.
        if bufferedBitCount > 0 {
            let tailMask = UInt32((1 << bufferedBitCount) - 1)
            guard buffer & tailMask == 0 else {
                throw RemoteSessionCoreError.invalidInvitationCode
            }
        }
        guard output.count == expectedByteCount else {
            throw RemoteSessionCoreError.invalidInvitationCode
        }
        return output
    }

    static func group(_ text: String, every groupSize: Int) -> String {
        guard groupSize > 0 else { return text }
        var groups = [Substring]()
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: groupSize, limitedBy: text.endIndex) ?? text.endIndex
            groups.append(text[start..<end])
            start = end
        }
        return groups.joined(separator: "-")
    }

    private static func normalizedSymbols(_ text: String) throws -> [UInt8] {
        var output = [UInt8]()
        output.reserveCapacity(text.utf8.count)

        for scalar in text.unicodeScalars {
            var byte = scalar.value
            switch byte {
            case 9, 10, 13, 32, 45: // ASCII whitespace and hyphen separators.
                continue
            case 97...122:
                byte -= 32
            default:
                break
            }

            switch byte {
            case 79: // O
                output.append(48)
            case 73, 76: // I and L
                output.append(49)
            case 0...127:
                output.append(UInt8(byte))
            default:
                throw RemoteSessionCoreError.invalidInvitationCode
            }
        }
        return output
    }

    private static func value(of symbol: UInt8) -> UInt8? {
        switch symbol {
        case 48...57:
            symbol - 48
        case 65:
            10
        case 66:
            11
        case 67:
            12
        case 68:
            13
        case 69:
            14
        case 70:
            15
        case 71:
            16
        case 72:
            17
        case 74:
            18
        case 75:
            19
        case 77:
            20
        case 78:
            21
        case 80:
            22
        case 81:
            23
        case 82:
            24
        case 83:
            25
        case 84:
            26
        case 86:
            27
        case 87:
            28
        case 88:
            29
        case 89:
            30
        case 90:
            31
        default:
            nil
        }
    }
}

private func timingSafeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for (left, right) in zip(lhs, rhs) {
        difference |= left ^ right
    }
    return difference == 0
}
