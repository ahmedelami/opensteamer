import CryptoKit
import Foundation
import Security

/// A long-lived, device-bound Ed25519 signing identity.
///
/// The encoded form contains private key material and must only be persisted in a
/// this-device-only Keychain item. Its textual descriptions are deliberately redacted.
public struct RemoteDeviceIdentity: Codable, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public static let currentVersion: UInt8 = 1

    public let version: UInt8
    public let deviceID: UUID
    public let role: RemotePeerRole
    public let displayName: String?
    public let signingPublicKey: Data

    private let signingPrivateKey: Data

    public static func generate(
        role: RemotePeerRole,
        displayName: String? = nil
    ) throws -> RemoteDeviceIdentity {
        let key = Curve25519.Signing.PrivateKey()
        return try RemoteDeviceIdentity(
            deviceID: UUID(),
            role: role,
            displayName: displayName,
            signingPrivateKeyRawRepresentation: key.rawRepresentation
        )
    }

    internal init(
        deviceID: UUID,
        role: RemotePeerRole,
        displayName: String? = nil,
        signingPrivateKeyRawRepresentation: Data,
        version: UInt8 = RemoteDeviceIdentity.currentVersion
    ) throws {
        guard version == Self.currentVersion,
              !remoteUUIDIsZero(deviceID),
              remoteValidDisplayName(displayName),
              signingPrivateKeyRawRepresentation.count == 32 else {
            throw RemoteSessionCoreError.invalidDeviceIdentity
        }

        let key: Curve25519.Signing.PrivateKey
        do {
            key = try Curve25519.Signing.PrivateKey(
                rawRepresentation: signingPrivateKeyRawRepresentation
            )
        } catch {
            throw RemoteSessionCoreError.invalidDeviceIdentity
        }

        self.version = version
        self.deviceID = deviceID
        self.role = role
        self.displayName = displayName
        signingPrivateKey = signingPrivateKeyRawRepresentation
        signingPublicKey = key.publicKey.rawRepresentation
    }

    public var description: String { "<redacted remote device identity>" }
    public var debugDescription: String { description }

    internal func signature(for data: Data) throws -> Data {
        do {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKey)
            return try key.signature(for: data)
        } catch {
            throw RemoteSessionCoreError.invalidDeviceIdentity
        }
    }

    internal func matches(deviceID: UUID, role: RemotePeerRole, publicKey: Data) -> Bool {
        self.deviceID == deviceID
            && self.role == role
            && remoteConstantTimeEqual(signingPublicKey, publicKey)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case deviceID
        case role
        case displayName
        case signingPrivateKey
        case signingPublicKey
    }

    public init(from decoder: any Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedVersion = try container.decode(UInt8.self, forKey: .version)
            let decodedDeviceID = try container.decode(UUID.self, forKey: .deviceID)
            let decodedRole = try container.decode(RemotePeerRole.self, forKey: .role)
            let decodedDisplayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            let decodedPrivateKey = try container.decode(Data.self, forKey: .signingPrivateKey)
            let suppliedPublicKey = try container.decode(Data.self, forKey: .signingPublicKey)
            try self.init(
                deviceID: decodedDeviceID,
                role: decodedRole,
                displayName: decodedDisplayName,
                signingPrivateKeyRawRepresentation: decodedPrivateKey,
                version: decodedVersion
            )
            guard remoteConstantTimeEqual(signingPublicKey, suppliedPublicKey) else {
                throw RemoteSessionCoreError.invalidDeviceIdentity
            }
        } catch let error as RemoteSessionCoreError {
            throw error
        } catch {
            throw RemoteSessionCoreError.invalidDeviceIdentity
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encode(signingPrivateKey, forKey: .signingPrivateKey)
        try container.encode(signingPublicKey, forKey: .signingPublicKey)
    }
}

internal func remoteVerifySignature(
    _ signature: Data,
    for data: Data,
    publicKey: Data
) -> Bool {
    guard signature.count == 64, publicKey.count == 32,
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
        return false
    }
    return key.isValidSignature(signature, for: data)
}

internal func remoteCanonicalData<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
        return try encoder.encode(value)
    } catch {
        throw RemoteSessionCoreError.invalidSignalPayload
    }
}

internal func remoteDomainSeparated(_ domain: String, _ pieces: Data...) -> Data {
    var result = Data(domain.utf8)
    result.append(0)
    for piece in pieces {
        var length = UInt64(piece.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(piece)
    }
    return result
}

internal func remoteSHA256(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
}

internal func remoteHMAC(key: Data, data: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
}

internal func remoteHKDF(
    input: Data,
    salt: Data,
    label: String,
    outputByteCount: Int = 32
) -> Data {
    let key = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: input),
        salt: salt,
        info: Data(label.utf8),
        outputByteCount: outputByteCount
    )
    return key.withUnsafeBytes { Data($0) }
}

internal func remoteRandomBytes(count: Int) throws -> Data {
    guard count > 0 else { return Data() }
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
        throw RemoteSessionCoreError.secureRandomGenerationFailed
    }
    return Data(bytes)
}

internal func remoteConstantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for (left, right) in zip(lhs, rhs) {
        difference |= left ^ right
    }
    return difference == 0
}

internal func remoteIsAllZero(_ data: Data) -> Bool {
    var aggregate: UInt8 = 0
    for byte in data {
        aggregate |= byte
    }
    return aggregate == 0
}

internal func remoteUUIDIsZero(_ id: UUID) -> Bool {
    withUnsafeBytes(of: id.uuid) { raw in
        raw.allSatisfy { $0 == 0 }
    }
}

internal func remoteUUID(from data: Data) -> UUID {
    precondition(data.count >= 16)
    var bytes = Array(data.prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

internal func remoteUUIDData(_ id: UUID) -> Data {
    var uuid = id.uuid
    return withUnsafeBytes(of: &uuid) { Data($0) }
}

internal func remoteValidDisplayName(_ name: String?) -> Bool {
    guard let name else { return true }
    return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && name.utf8.count <= 128
        && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
}
