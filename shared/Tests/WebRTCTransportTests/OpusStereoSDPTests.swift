import Foundation
@testable import WebRTCTransport
import XCTest

/// Pins high-fidelity Opus policy insertion, preservation of unmanaged fmtp parameters,
/// idempotence, dynamic payload discovery, and compatibility with older mono offers.
final class OpusStereoSDPTests: XCTestCase {
    func testPolicyFindsDynamicPayloadAndMergesOnlyManagedFormatParameters() {
        let input = [
            "v=0",
            "m=video 9 UDP/TLS/RTP/SAVPF 111",
            "a=rtpmap:111 H264/90000",
            "a=fmtp:111 profile-level-id=42e01f",
            "m=audio 9 UDP/TLS/RTP/SAVPF 109 0",
            "a=rtpmap:109 OPUS/48000/2",
            "a=fmtp:109 minptime=10;useinbandfec=1;Stereo=0;X-vendor-mode=music;MAXAVERAGEBITRATE=64000;sprop-stereo=0",
            "a=rtpmap:0 PCMU/8000",
            ""
        ].joined(separator: "\r\n")

        let output = OpusStereoSDP.applyingHighFidelityPolicy(to: input)

        XCTAssertEqual(
            output,
            [
                "v=0",
                "m=video 9 UDP/TLS/RTP/SAVPF 111",
                "a=rtpmap:111 H264/90000",
                "a=fmtp:111 profile-level-id=42e01f",
                "m=audio 9 UDP/TLS/RTP/SAVPF 109 0",
                "a=rtpmap:109 OPUS/48000/2",
                "a=fmtp:109 minptime=10;useinbandfec=1;X-vendor-mode=music;stereo=1;sprop-stereo=1;maxaveragebitrate=192000",
                "a=rtpmap:0 PCMU/8000",
                ""
            ].joined(separator: "\r\n")
        )
    }

    func testPolicyInsertsFormatParametersForEveryOpusAudioSection() {
        let input = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 98",
            "a=rtpmap:98 opus/48000/2",
            "a=sendonly",
            "m=audio 9 UDP/TLS/RTP/SAVPF 120",
            "a=rtpmap:120 opus/48000/2",
            "a=recvonly"
        ].joined(separator: "\n")

        let output = OpusStereoSDP.applyingHighFidelityPolicy(to: input)

        XCTAssertTrue(output.contains(
            "a=rtpmap:98 opus/48000/2\na=fmtp:98 stereo=1;sprop-stereo=1;maxaveragebitrate=192000"
        ))
        XCTAssertTrue(output.contains(
            "a=rtpmap:120 opus/48000/2\na=fmtp:120 stereo=1;sprop-stereo=1;maxaveragebitrate=192000"
        ))
    }

    func testPolicyIsIdempotentAndRemovesDuplicateManagedParameters() {
        let input = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 127",
            "a=rtpmap:127 opus/48000/2",
            "a=fmtp:127 stereo=0;stereo=1;unknown-flag;sprop-stereo=0;maxaveragebitrate=32000;foo=bar",
            ""
        ].joined(separator: "\n")

        let once = OpusStereoSDP.applyingHighFidelityPolicy(to: input)
        let twice = OpusStereoSDP.applyingHighFidelityPolicy(to: once)

        XCTAssertEqual(once, twice)
        XCTAssertTrue(once.contains(
            "a=fmtp:127 unknown-flag;foo=bar;stereo=1;sprop-stereo=1;maxaveragebitrate=192000"
        ))
        XCTAssertEqual(once.components(separatedBy: "stereo=1").count - 1, 2)
        XCTAssertEqual(once.components(separatedBy: "maxaveragebitrate=192000").count - 1, 1)
    }

    func testPolicyLeavesDescriptionsWithoutOpusAudioUnchanged() {
        let input = [
            "v=0",
            "m=video 9 UDP/TLS/RTP/SAVPF 111",
            "a=rtpmap:111 opus/48000/2",
            "a=fmtp:111 unrelated=1",
            "m=audio 9 UDP/TLS/RTP/SAVPF 0",
            "a=rtpmap:0 PCMU/8000",
            ""
        ].joined(separator: "\r\n")

        XCTAssertEqual(
            OpusStereoSDP.applyingHighFidelityPolicy(to: input),
            input
        )
    }

    func testNewViewerDoesNotUpgradeAnOlderMonoOffer() {
        let oldOffer = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=rtpmap:111 opus/48000/2",
            "a=fmtp:111 minptime=10;useinbandfec=1",
            "a=sendonly",
            ""
        ].joined(separator: "\r\n")
        let nativeAnswer = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=rtpmap:111 opus/48000/2",
            "a=fmtp:111 minptime=10;useinbandfec=1",
            "a=recvonly",
            ""
        ].joined(separator: "\r\n")

        XCTAssertEqual(
            OpusStereoSDP.applyingHighFidelityAnswerPolicy(
                to: nativeAnswer,
                remoteOffer: oldOffer
            ),
            nativeAnswer
        )
    }

    func testNewViewerAppliesPolicyWhenOfferAdvertisesTheCompleteProfile() {
        let offer = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 109",
            "a=rtpmap:109 opus/48000/2",
            "a=fmtp:109 useinbandfec=1;stereo=1;sprop-stereo=1;maxaveragebitrate=192000",
            "a=sendonly"
        ].joined(separator: "\n")
        let nativeAnswer = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 109",
            "a=rtpmap:109 opus/48000/2",
            "a=fmtp:109 useinbandfec=1",
            "a=recvonly"
        ].joined(separator: "\n")

        let answer = OpusStereoSDP.applyingHighFidelityAnswerPolicy(
            to: nativeAnswer,
            remoteOffer: offer
        )

        XCTAssertTrue(answer.contains(
            "a=fmtp:109 useinbandfec=1;stereo=1;sprop-stereo=1;maxaveragebitrate=192000"
        ))
    }

    func testTwoAudioSectionOfferAndAnswerKeepIndependentOpusPolicies() throws {
        let nativeOffer = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 109",
            "a=mid:system",
            "a=rtpmap:109 opus/48000/2",
            "a=fmtp:109 useinbandfec=1",
            "a=sendonly",
            "m=audio 9 UDP/TLS/RTP/SAVPF 120",
            "a=mid:microphone",
            "a=rtpmap:120 opus/48000/2",
            "a=fmtp:120 useinbandfec=1",
            "a=recvonly"
        ].joined(separator: "\r\n")

        let stereoOffer = OpusStereoSDP.applyingHighFidelityPolicy(
            to: nativeOffer,
            mediaMID: "system"
        )
        let productOffer = IPhoneMicrophoneSDP.applyingMonoPolicy(
            to: stereoOffer,
            microphoneMID: "microphone"
        )
        let offerSections = audioSections(in: productOffer)
        XCTAssertEqual(offerSections.count, 2)
        XCTAssertTrue(
            offerSections[0].contains(
                "stereo=1;sprop-stereo=1;maxaveragebitrate=192000"
            )
        )
        XCTAssertTrue(offerSections[1].contains("stereo=0;sprop-stereo=0"))
        XCTAssertFalse(
            offerSections[1].contains("maxaveragebitrate=192000")
        )

        let nativeAnswer = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 109",
            "a=mid:system",
            "a=rtpmap:109 opus/48000/2",
            "a=fmtp:109 useinbandfec=1",
            "a=recvonly",
            "m=audio 9 UDP/TLS/RTP/SAVPF 120",
            "a=mid:microphone",
            "a=rtpmap:120 opus/48000/2",
            "a=fmtp:120 useinbandfec=1",
            "a=sendonly"
        ].joined(separator: "\r\n")
        let stereoAnswer = OpusStereoSDP.applyingHighFidelityAnswerPolicy(
            to: nativeAnswer,
            remoteOffer: productOffer,
            mediaMID: "system"
        )
        let productAnswer = IPhoneMicrophoneSDP.applyingMonoPolicy(
            to: stereoAnswer,
            microphoneMID: "microphone"
        )
        let answerSections = audioSections(in: productAnswer)
        XCTAssertEqual(answerSections.count, 2)
        XCTAssertTrue(
            answerSections[0].contains(
                "stereo=1;sprop-stereo=1;maxaveragebitrate=192000"
            )
        )
        XCTAssertTrue(answerSections[1].contains("stereo=0;sprop-stereo=0"))
        XCTAssertFalse(
            answerSections[1].contains("maxaveragebitrate=192000")
        )
    }
}

private func audioSections(in sdp: String) -> [String] {
    let lines = sdp
        .replacingOccurrences(of: "\r\n", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    let starts = lines.indices.filter { lines[$0].hasPrefix("m=audio ") }
    return starts.enumerated().map { index, start in
        let end = index + 1 < starts.count
            ? starts[index + 1]
            : lines.endIndex
        return lines[start..<end].joined(separator: "\n")
    }
}
