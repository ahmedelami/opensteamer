import Testing
@testable import WebRTCTransport

/// Pins SDP scope inheritance and candidate-to-media matching so delayed candidates cannot cross
/// an ICE generation or exploit ambiguous MID/m-line locators.
struct ICEUsernameFragmentParserTests {
    @Test func sessionDescriptionCollectsEveryICEUsernameFragment() {
        let sdp = """
        v=0\r
        a=ice-ufrag:bundle-one\r
        m=video 9 UDP/TLS/RTP/SAVPF 96\r
        a=ice-ufrag:media-two\r
        """

        #expect(
            ICEUsernameFragmentParser.fragments(inSessionDescription: sdp)
                == ["bundle-one", "media-two"]
        )
        #expect(
            ICEUsernameFragmentParser.fragments(
                inSessionDescription: "v=0\na=ice-ufrag:lf-only\n"
            ) == ["lf-only"]
        )
    }

    @Test func candidateParserRequiresAValueAfterTheUfragToken() {
        #expect(
            ICEUsernameFragmentParser.fragment(
                inCandidateSDP: "candidate:1 1 UDP 1 192.0.2.1 50000 typ host ufrag abc123"
            ) == "abc123"
        )
        #expect(
            ICEUsernameFragmentParser.fragment(
                inCandidateSDP: "candidate:1 1 UDP 1 192.0.2.1 50000 typ host UFRAG MixedCase"
            ) == "MixedCase"
        )
        #expect(
            ICEUsernameFragmentParser.fragment(
                inCandidateSDP: "candidate:1 1 UDP 1 192.0.2.1 50000 typ host ufrag"
            ) == nil
        )
        #expect(
            ICEUsernameFragmentParser.fragment(
                inCandidateSDP: "candidate:1 1 UDP 1 192.0.2.1 50000 typ host"
            ) == nil
        )
    }

    @Test func mediaSectionMappingAppliesInheritanceOverridesAndLocatorAgreement() throws {
        let mapping = try #require(
            ICEUsernameFragmentParser.mapping(
                inSessionDescription: """
                v=0\r
                a=ice-ufrag:session-generation\r
                m=audio 9 UDP/TLS/RTP/SAVPF 111\r
                a=mid:audio\r
                m=video 9 UDP/TLS/RTP/SAVPF 96\r
                a=mid:video\r
                a=ice-ufrag:video-generation\r
                """
            )
        )

        #expect(
            mapping.effectiveFragment(sdpMid: "audio", sdpMLineIndex: nil)
                == "session-generation"
        )
        #expect(
            mapping.effectiveFragment(sdpMid: nil, sdpMLineIndex: 1)
                == "video-generation"
        )
        #expect(
            mapping.effectiveFragment(sdpMid: "video", sdpMLineIndex: 1)
                == "video-generation"
        )
        #expect(mapping.effectiveFragment(sdpMid: "audio", sdpMLineIndex: 1) == nil)
        #expect(mapping.effectiveFragment(sdpMid: "missing", sdpMLineIndex: 0) == nil)
    }

    @Test func sessionDescriptionMappingRejectsAmbiguousScopesAndMIDs() {
        #expect(
            ICEUsernameFragmentParser.mapping(
                inSessionDescription: """
                v=0
                a=ice-ufrag:one
                a=ice-ufrag:two
                m=audio 9 UDP/TLS/RTP/SAVPF 111
                a=mid:audio
                """
            ) == nil
        )
        #expect(
            ICEUsernameFragmentParser.mapping(
                inSessionDescription: """
                v=0
                a=ice-ufrag:one
                m=audio 9 UDP/TLS/RTP/SAVPF 111
                a=mid:duplicate
                m=video 9 UDP/TLS/RTP/SAVPF 96
                a=mid:duplicate
                """
            ) == nil
        )
    }

    @Test func candidateValidationIsBoundToItsExactMediaSection() throws {
        let mapping = try #require(
            ICEUsernameFragmentParser.mapping(
                inSessionDescription: """
                v=0
                a=ice-ufrag:audio-generation
                m=audio 9 UDP/TLS/RTP/SAVPF 111
                a=mid:audio
                m=video 9 UDP/TLS/RTP/SAVPF 96
                a=mid:video
                a=ice-ufrag:video-generation
                """
            )
        )
        let base = "candidate:1 1 UDP 1 192.0.2.1 50000 typ host"

        #expect(
            ICECandidateUsernameFragmentValidator.validatedCandidate(
                .init(
                    sdp: base + " ufrag video-generation",
                    sdpMid: "audio",
                    sdpMLineIndex: 0,
                    usernameFragment: "video-generation"
                ),
                against: mapping,
                requiresExplicitFragment: true
            ) == nil
        )
        #expect(
            ICECandidateUsernameFragmentValidator.validatedCandidate(
                .init(
                    sdp: base + " ufrag audio-generation",
                    sdpMid: "audio",
                    sdpMLineIndex: 1,
                    usernameFragment: "audio-generation"
                ),
                against: mapping,
                requiresExplicitFragment: true
            ) == nil
        )
        #expect(
            ICECandidateUsernameFragmentValidator.validatedCandidate(
                .init(
                    sdp: base + " ufrag audio-generation",
                    sdpMid: "audio",
                    sdpMLineIndex: 0,
                    usernameFragment: "different"
                ),
                against: mapping,
                requiresExplicitFragment: true
            ) == nil
        )

        let initialCandidate = ICECandidateUsernameFragmentValidator.validatedCandidate(
            .init(sdp: base, sdpMid: "video", sdpMLineIndex: 1),
            against: mapping,
            requiresExplicitFragment: false
        )
        #expect(initialCandidate?.usernameFragment == "video-generation")

        let midOnlyCandidate = ICECandidateUsernameFragmentValidator.validatedCandidate(
            .init(
                sdp: base + " ufrag video-generation",
                sdpMid: "video",
                usernameFragment: "video-generation"
            ),
            against: mapping,
            requiresExplicitFragment: true
        )
        #expect(midOnlyCandidate?.sdpMLineIndex == 1)

        let indexOnlyCandidate = ICECandidateUsernameFragmentValidator.validatedCandidate(
            .init(
                sdp: base + " ufrag video-generation",
                sdpMLineIndex: 1,
                usernameFragment: "video-generation"
            ),
            against: mapping,
            requiresExplicitFragment: true
        )
        #expect(indexOnlyCandidate?.sdpMid == "video")
        #expect(
            ICECandidateUsernameFragmentValidator.validatedCandidate(
                .init(sdp: base, sdpMid: "video", sdpMLineIndex: 1),
                against: mapping,
                requiresExplicitFragment: true
            ) == nil
        )
    }
}
