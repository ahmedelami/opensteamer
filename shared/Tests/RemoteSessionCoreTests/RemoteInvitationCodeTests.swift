import Foundation
import Testing
@testable import RemoteSessionCore

/// Locks the invitation's canonical encoding, checksum, entropy, normalization, and redaction
/// contract so a presentation change cannot silently weaken capability validation.
struct RemoteInvitationCodeTests {
    private let deterministicSecret = Data(0..<20)
    private let deterministicCanonicalCode = "040020G30G2GC1R81450P30D1R7H048J2EZG8AG3"

    @Test func deterministicEncodingAndRoundTrip() throws {
        let code = try RemoteInvitationCode(secret: deterministicSecret)

        #expect(code.canonicalCode == deterministicCanonicalCode)
        #expect(code.exportedCode == "04002-0G30G-2GC1R-81450-P30D1-R7H04-8J2EZ-G8AG3")

        let parsed = try RemoteInvitationCode(code.exportedCode)
        #expect(parsed.canonicalCode == deterministicCanonicalCode)
    }

    @Test func parsingNormalizesCaseWhitespaceSeparatorsAndCrockfordAliases() throws {
        let code = try RemoteInvitationCode(secret: deterministicSecret)
        let aliased = code.exportedCode
            .lowercased()
            .replacingOccurrences(of: "0", with: "o")
            .replacingOccurrences(of: "1", with: "l")
            .replacingOccurrences(of: "-", with: " \n")

        let parsed = try RemoteInvitationCode(aliased)
        #expect(parsed.canonicalCode == deterministicCanonicalCode)
    }

    @Test func checksumRejectsSingleSymbolTampering() throws {
        let code = try RemoteInvitationCode(secret: deterministicSecret)
        var characters = Array(code.canonicalCode)
        characters[10] = characters[10] == "A" ? "B" : "A"

        #expect(throws: RemoteSessionCoreError.invalidInvitationCode) {
            try RemoteInvitationCode(String(characters))
        }
    }

    @Test func parserRejectsWrongLengthAlphabetAndVersion() throws {
        #expect(throws: RemoteSessionCoreError.invalidInvitationCode) {
            try RemoteInvitationCode(String(deterministicCanonicalCode.dropLast()))
        }
        #expect(throws: RemoteSessionCoreError.invalidInvitationCode) {
            try RemoteInvitationCode("U" + deterministicCanonicalCode.dropFirst())
        }
        #expect(throws: RemoteSessionCoreError.unsupportedInvitationVersion) {
            try RemoteInvitationCode("14" + deterministicCanonicalCode.dropFirst(2))
        }
    }

    @Test func generatedCodesHaveExpectedEntropyAndAreDistinct() throws {
        var codes = Set<String>()
        for _ in 0..<32 {
            let code = try RemoteInvitationCode.generate()
            #expect(code.canonicalCode.count == 40)
            #expect(try RemoteInvitationCode(code.exportedCode).canonicalCode == code.canonicalCode)
            codes.insert(code.canonicalCode)
        }
        #expect(codes.count == 32)
        #expect(RemoteInvitationCode.secretBitCount == 160)
    }

    @Test func descriptionsAreAlwaysRedacted() throws {
        let code = try RemoteInvitationCode(secret: deterministicSecret)
        #expect(code.description == "<redacted remote invitation>")
        #expect(code.debugDescription == "<redacted remote invitation>")
        #expect(!code.description.contains(deterministicCanonicalCode.prefix(8)))
    }

    @Test func publicErrorsNeverContainInvitationMaterial() {
        let secretFragment = deterministicCanonicalCode.prefix(8)
        let errors: [RemoteSessionCoreError] = [
            .invalidInvitationCode,
            .unsupportedInvitationVersion,
            .secureRandomGenerationFailed,
            .invalidRendezvousChannel,
            .unsupportedEnvelopeVersion,
            .wrongRendezvousChannel,
            .unexpectedSignalDirection,
            .authenticationFailed,
            .invalidSignalPayload,
            .replayedSequence,
            .sequenceOutsideReplayWindow,
            .sequenceExhausted
        ]

        for error in errors {
            #expect(!error.localizedDescription.contains(secretFragment))
        }
    }
}
