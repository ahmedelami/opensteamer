import CoreVideo
import Foundation
import RemoteSessionCore
@testable import WebRTCTransport
import XCTest

final class WebRTCPeerLoopbackTests: XCTestCase {
#if DEBUG
    func testFailedVisibilitySendStillRevokesViewerInputSynchronously() async throws {
        let viewer = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [])
        )
        let capability = WebRTCInputCapability(
            inputSessionID: UUID(),
            screenRequestID: 1
        )
        let authorization = WebRTCInputAuthorization()
        try await viewer.installViewerInputSessionForTesting(
            capability: capability,
            authorization: authorization
        )
        XCTAssertTrue(authorization.isValid)

        do {
            _ = try await viewer.setScreenVisible(false)
            XCTFail("The unopened control channel must reject Hide.")
        } catch {
            // The send failure is expected; revocation must happen before it.
        }

        XCTAssertFalse(authorization.isValid)
        let currentCapability = await viewer.currentInputCapability()
        XCTAssertNil(currentCapability)
    }

    func testPublicEventBufferOverflowRevokesInputAndClosesTransport() async throws {
        let viewer = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [])
        )
        let capability = WebRTCInputCapability(
            inputSessionID: UUID(),
            screenRequestID: 1
        )
        let authorization = WebRTCInputAuthorization()
        try await viewer.installViewerInputSessionForTesting(
            capability: capability,
            authorization: authorization
        )

        for _ in 0...256 {
            await viewer.emitPublicEventForTesting()
        }

        XCTAssertFalse(authorization.isValid)
        let currentCapability = await viewer.currentInputCapability()
        XCTAssertNil(currentCapability)
        do {
            _ = try await viewer.sendInput(
                .tap(.init(x: 0.5, y: 0.5)),
                capability: capability,
                authorization: authorization
            )
            XCTFail("A public event loss must permanently close this transport.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .transportClosed)
        }
    }

    func testActiveAcknowledgementForHideClosesViewerTransportImmediately() async throws {
        let viewer = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [])
        )
        let request = WebRTCControlRequest(id: 1, command: .hideScreen)

        try await viewer.receiveControlAcknowledgementForTesting(
            request: request,
            acknowledgement: .init(id: request.id, state: .active)
        )

        let isClosed = await viewer.isClosedForTesting
        XCTAssertTrue(isClosed)
        do {
            _ = try await viewer.requestControl(.hideScreen)
            XCTFail("Active-for-Hide must close the transport without waiting for a UI timeout.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .transportClosed)
        }
    }
#endif

    func testPreDescriptionCandidateQueueFailsClosedAtItsBound() async throws {
        let viewer = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [])
        )
        let candidate = RemoteICECandidate(
            sdp: "candidate:1 1 UDP 1 192.0.2.1 50000 typ host",
            sdpMid: "0",
            sdpMLineIndex: 0
        )

        for _ in 0..<256 {
            try await viewer.handle(.candidate(candidate))
        }
        do {
            try await viewer.handle(.candidate(candidate))
            XCTFail("The 257th pre-description candidate must fail closed.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .pendingRemoteCandidateLimitExceeded(256))
        }
        do {
            try await viewer.handle(.candidate(candidate))
            XCTFail("Candidate overflow must terminate the transport.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .transportClosed)
        }
    }

    func testRestartRejectsAnUnansweredOffer() async throws {
        let host = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .host, iceServers: [])
        )
        try await host.start()

        do {
            try await host.restartICE()
            XCTFail("A second offer must not overlap the unanswered initial offer.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .iceRestartAlreadyInProgress)
        }

        await host.close(reason: .protocolError)
    }

    func testHostViewerLoopbackNegotiatesControlsVideoAndCloses() async throws {
        let host = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .host, iceServers: [])
        )
        let viewer = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [])
        )
        let recorder = LoopbackRecorder()
        let expectations = LoopbackExpectations()
        let secondAnswerDeliveryGate = SecondAnswerDeliveryGate()

        let hostForwarder = Task {
            do {
                for await event in host.events {
                    for milestone in await recorder.observe(event, from: .host) {
                        expectations.fulfill(milestone)
                    }
                    if case .outboundSignal(let payload) = event {
                        for milestone in await recorder.recordEmitted(payload, from: .host) {
                            expectations.fulfill(milestone)
                        }
                        try await viewer.handle(payload)
                        for milestone in await recorder.recordDelivered(payload, from: .host) {
                            expectations.fulfill(milestone)
                        }
                    }
                }
            } catch {
                await recorder.recordForwardingError(error)
            }
            expectations.hostForwarderFinished.fulfill()
        }

        let viewerForwarder = Task {
            do {
                for await event in viewer.events {
                    let milestones = await recorder.observe(event, from: .viewer)
                    for milestone in milestones {
                        expectations.fulfill(milestone)
                    }
                    if case .outboundSignal(let payload) = event {
                        let emittedMilestones = await recorder.recordEmitted(
                            payload,
                            from: .viewer
                        )
                        for milestone in emittedMilestones {
                            expectations.fulfill(milestone)
                        }
                        if emittedMilestones.contains(.secondAnswerEmitted) {
                            await secondAnswerDeliveryGate.waitUntilReleased()
                        }
                        try await host.handle(payload)
                        for milestone in await recorder.recordDelivered(payload, from: .viewer) {
                            expectations.fulfill(milestone)
                        }
                    }
                }
            } catch {
                await recorder.recordForwardingError(error)
            }
            expectations.viewerForwarderFinished.fulfill()
        }

        defer {
            Task { await secondAnswerDeliveryGate.release() }
            hostForwarder.cancel()
            viewerForwarder.cancel()
        }

        try await host.start()

        await fulfillment(
            of: [
                expectations.hostConnected,
                expectations.viewerConnected,
                expectations.viewerDataChannelOpen,
                expectations.directRoute,
                expectations.remoteVideoTrack
            ],
            timeout: 10
        )

        let connectedSnapshot = await recorder.snapshot()
        guard connectedSnapshot.hasAllConnectionMilestones else {
            await host.close(reason: .protocolError)
            await fulfillment(
                of: [
                    expectations.hostForwarderFinished,
                    expectations.viewerForwarderFinished
                ],
                timeout: 3
            )
            return
        }

        let showID = try await viewer.setScreenVisible(true)
        await fulfillment(of: [expectations.showRequestReceived], timeout: 3)
        let showSnapshot = await recorder.snapshot()
        XCTAssertEqual(showSnapshot.controlRequests, [
            WebRTCControlRequest(id: showID, command: .showScreen)
        ])

        do {
            try await host.acknowledgeControlRequest(id: showID, state: .active)
            XCTFail("A Show/Active transition must require a capture authorization.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .controlAuthorizationRequired)
        }
        let revokedAuthorization = WebRTCControlAuthorization()
        revokedAuthorization.revoke()
        do {
            try await host.acknowledgeActiveControlRequestIfTransportHealthy(
                id: showID,
                authorization: revokedAuthorization
            )
            XCTFail("A revoked capture authorization must not emit an Active acknowledgement.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .controlAuthorizationRevoked)
        }
        let inputCapability = WebRTCInputCapability(
            inputSessionID: UUID(),
            screenRequestID: showID
        )
        let hostInputAuthorization = WebRTCInputAuthorization()
        try await host.acknowledgeActiveControlRequestIfTransportHealthy(
            id: showID,
            authorization: WebRTCControlAuthorization(),
            inputCapability: inputCapability,
            inputAuthorization: hostInputAuthorization
        )
        await fulfillment(of: [expectations.showAcknowledged], timeout: 3)
        let activeSnapshot = await recorder.snapshot()
        XCTAssertEqual(activeSnapshot.controlAcknowledgements, [
            WebRTCControlAcknowledgement(
                id: showID,
                state: .active,
                inputCapability: inputCapability
            )
        ])
        let viewerInputAuthorization = try XCTUnwrap(
            activeSnapshot.viewerInputAuthorizations.first
        )
        XCTAssertTrue(viewerInputAuthorization.isValid)
        XCTAssertTrue(hostInputAuthorization.isValid)
        XCTAssertFalse(viewerInputAuthorization === hostInputAuthorization)

        let inputID = try await viewer.sendInput(
            .tap(.init(x: 0.25, y: 0.75)),
            capability: inputCapability,
            authorization: viewerInputAuthorization
        )
        await fulfillment(of: [expectations.inputRequestReceived], timeout: 3)
        let inputRequestSnapshot = await recorder.snapshot()
        XCTAssertEqual(inputRequestSnapshot.inputRequests, [
            WebRTCInputRequest(
                id: inputID,
                screenRequestID: showID,
                inputSessionID: inputCapability.inputSessionID,
                action: .tap(.init(x: 0.25, y: 0.75))
            )
        ])
        XCTAssertTrue(
            inputRequestSnapshot.hostInputAuthorizations.first === hostInputAuthorization
        )
        try await host.sendInputFeedback(
            for: inputID,
            result: .accepted,
            focus: .editable(generation: 1, secure: false)
        )
        await fulfillment(of: [expectations.inputFeedbackReceived], timeout: 3)
        let inputFeedbackSnapshot = await recorder.snapshot()
        XCTAssertEqual(inputFeedbackSnapshot.inputFeedback, [
            WebRTCInputFeedback(
                id: inputID,
                screenRequestID: showID,
                inputSessionID: inputCapability.inputSessionID,
                result: .accepted,
                focus: .editable(generation: 1, secure: false)
            )
        ])

        let pixelBuffer = try makePixelBuffer(width: 64, height: 64)
        guard let capturer = host.externalVideoCapturer else {
            XCTFail("The host did not expose its external screen capturer.")
            await host.close(reason: .protocolError)
            return
        }
        capturer.capture(
            pixelBuffer: pixelBuffer,
            timestampNanoseconds: Int64(clamping: DispatchTime.now().uptimeNanoseconds)
        )

        let hideID = try await viewer.setScreenVisible(false)
        do {
            _ = try await viewer.sendInput(.backspace(focusGeneration: 1))
            XCTFail("Sending Hide must synchronously revoke the viewer input capability.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .inputUnavailable)
        }
        await fulfillment(of: [expectations.hideRequestReceived], timeout: 3)
        XCTAssertFalse(viewerInputAuthorization.isValid)
        XCTAssertFalse(hostInputAuthorization.isValid)
        XCTAssertEqual(hideID, showID + 1)

        do {
            try await host.acknowledgeControlRequest(id: showID, state: .active)
            XCTFail("A superseded acknowledgement must be rejected as stale.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .staleControlRequest(showID))
        }

        try await host.acknowledgeControlRequest(id: hideID, state: .inactive)
        await fulfillment(of: [expectations.hideAcknowledged], timeout: 3)
        let hideSnapshot = await recorder.snapshot()
        XCTAssertEqual(hideSnapshot.controlRequests.last, .init(id: hideID, command: .hideScreen))
        XCTAssertEqual(
            hideSnapshot.controlAcknowledgements.last,
            .init(id: hideID, state: .inactive)
        )

        // Repeating an identical host acknowledgement is safe. The wire replay is suppressed at
        // the viewer, while a contradictory acknowledgement for the same ID fails closed.
        try await host.acknowledgeControlRequest(id: hideID, state: .inactive)
        try await Task.sleep(for: .milliseconds(100))
        let duplicateSnapshot = await recorder.snapshot()
        XCTAssertEqual(duplicateSnapshot.controlAcknowledgements.count, 2)
        do {
            try await host.acknowledgeControlRequest(id: hideID, state: .active)
            XCTFail("A contradictory acknowledgement must be rejected.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .conflictingControlAcknowledgement(hideID))
        }

        let keyFrameID = try await viewer.requestControl(.requestKeyFrame)
        await fulfillment(of: [expectations.keyFrameRequestReceived], timeout: 3)
        XCTAssertEqual(keyFrameID, hideID + 1)
        try await host.acknowledgeControlRequest(id: keyFrameID, state: .inactive)
        await fulfillment(of: [expectations.keyFrameAcknowledged], timeout: 3)

        try await host.restartICE()
        await fulfillment(
            of: [
                expectations.secondOfferEmitted,
                expectations.secondAnswerEmitted
            ],
            timeout: 10
        )

        // The data channel can cross the WSS answer path. Prove that a privacy-monotone Hide
        // received before the second answer is applied cannot be acknowledged as recovered.
        let recoveryProbeID = try await viewer.setScreenVisible(false)
        XCTAssertEqual(recoveryProbeID, keyFrameID + 1)
        await fulfillment(of: [expectations.recoveryProbeRequestReceived], timeout: 3)
        do {
            try await host.acknowledgeControlRequestIfTransportHealthy(
                id: recoveryProbeID,
                state: .inactive,
                authorization: WebRTCControlAuthorization()
            )
            XCTFail("The recovery probe must not be acknowledged before the answer is applied.")
        } catch let error as WebRTCTransportError {
            XCTAssertEqual(error, .transportNotHealthy)
        }

        await secondAnswerDeliveryGate.release()
        await fulfillment(of: [expectations.secondAnswerDelivered], timeout: 10)

        let restartSnapshot = await recorder.snapshot()
        XCTAssertEqual(restartSnapshot.hostOffers.count, 2)
        XCTAssertEqual(restartSnapshot.viewerAnswers.count, 2)
        let firstOfferFragments = ICEUsernameFragmentParser.fragments(
            inSessionDescription: restartSnapshot.hostOffers[0]
        )
        let secondOfferFragments = ICEUsernameFragmentParser.fragments(
            inSessionDescription: restartSnapshot.hostOffers[1]
        )
        let firstAnswerFragments = ICEUsernameFragmentParser.fragments(
            inSessionDescription: restartSnapshot.viewerAnswers[0]
        )
        let secondAnswerFragments = ICEUsernameFragmentParser.fragments(
            inSessionDescription: restartSnapshot.viewerAnswers[1]
        )
        XCTAssertFalse(firstOfferFragments.isEmpty)
        XCTAssertFalse(firstAnswerFragments.isEmpty)
        XCTAssertNotEqual(firstOfferFragments, secondOfferFragments)
        XCTAssertNotEqual(firstAnswerFragments, secondAnswerFragments)
        XCTAssertTrue(firstOfferFragments.isDisjoint(with: secondOfferFragments))
        XCTAssertTrue(firstAnswerFragments.isDisjoint(with: secondAnswerFragments))

        let oldViewerCandidate = try XCTUnwrap(
            restartSnapshot.viewerCandidates.first(where: {
                $0.usernameFragment.map {
                    firstAnswerFragments.contains($0) && !secondAnswerFragments.contains($0)
                } == true
            })
        )
        let oldHostCandidate = try XCTUnwrap(
            restartSnapshot.hostCandidates.first(where: {
                $0.usernameFragment.map {
                    firstOfferFragments.contains($0) && !secondOfferFragments.contains($0)
                } == true
            })
        )
        // A delayed first-generation trickle candidate must be ignored after the second SDP is
        // installed instead of reaching native WebRTC and terminating the recovered session.
        try await host.handle(.candidate(oldViewerCandidate))
        try await viewer.handle(.candidate(oldHostCandidate))

        try await host.acknowledgeControlRequestIfTransportHealthy(
            id: recoveryProbeID,
            state: .inactive,
            authorization: WebRTCControlAuthorization()
        )
        await fulfillment(of: [expectations.recoveryProbeAcknowledged], timeout: 3)

        let recoveredShowID = try await viewer.setScreenVisible(true)
        XCTAssertEqual(recoveredShowID, recoveryProbeID + 1)
        await fulfillment(of: [expectations.postRestartShowRequestReceived], timeout: 3)
        try await host.acknowledgeActiveControlRequestIfTransportHealthy(
            id: recoveredShowID,
            authorization: WebRTCControlAuthorization()
        )
        await fulfillment(of: [expectations.postRestartShowAcknowledged], timeout: 3)

        capturer.capture(
            pixelBuffer: pixelBuffer,
            timestampNanoseconds: Int64(clamping: DispatchTime.now().uptimeNanoseconds)
        )

        let statistics = await host.statisticsSnapshot()
        XCTAssertEqual(statistics.route?.kind, .direct)

        let beforeClose = await recorder.snapshot()
        XCTAssertEqual(beforeClose.emitted.host.offers, 2)
        XCTAssertEqual(beforeClose.emitted.viewer.answers, 2)
        XCTAssertEqual(beforeClose.emitted.host.iceRestartRequests, 0)
        XCTAssertEqual(beforeClose.emitted.viewer.iceRestartRequests, 0)
        XCTAssertGreaterThan(beforeClose.emitted.host.candidates, 0)
        XCTAssertGreaterThan(beforeClose.emitted.viewer.candidates, 0)
        XCTAssertTrue(beforeClose.hostCandidates.allSatisfy { $0.usernameFragment != nil })
        XCTAssertTrue(beforeClose.viewerCandidates.allSatisfy { $0.usernameFragment != nil })
        XCTAssertTrue(beforeClose.forwardingErrors.isEmpty, beforeClose.forwardingErrors.joined(separator: "\n"))

        await host.close()
        await fulfillment(
            of: [
                expectations.hostForwarderFinished,
                expectations.viewerForwarderFinished
            ],
            timeout: 5
        )

        let finalSnapshot = await recorder.snapshot()
        XCTAssertEqual(finalSnapshot.emitted.host.ends, 1)
        XCTAssertEqual(finalSnapshot.emitted, finalSnapshot.delivered)
        XCTAssertTrue(finalSnapshot.forwardingErrors.isEmpty, finalSnapshot.forwardingErrors.joined(separator: "\n"))
    }
}

private actor SecondAnswerDeliveryGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private enum LoopbackSide: Sendable {
    case host
    case viewer
}

private enum LoopbackMilestone: Hashable, Sendable {
    case hostConnected
    case viewerConnected
    case viewerDataChannelOpen
    case directRoute
    case remoteTrack
    case inputRequestReceived
    case inputFeedbackReceived
    case showRequestReceived
    case hideRequestReceived
    case keyFrameRequestReceived
    case showAcknowledged
    case hideAcknowledged
    case keyFrameAcknowledged
    case secondOfferEmitted
    case secondAnswerEmitted
    case secondAnswerDelivered
    case recoveryProbeRequestReceived
    case recoveryProbeAcknowledged
    case postRestartShowRequestReceived
    case postRestartShowAcknowledged
}

private struct SignalCounts: Equatable, Sendable {
    var offers = 0
    var answers = 0
    var candidates = 0
    var ends = 0
    var controls = 0
    var identities = 0
    var iceRestartRequests = 0

    mutating func record(_ payload: RemoteSignalPayload) {
        switch payload {
        case .offer: offers += 1
        case .answer: answers += 1
        case .candidate: candidates += 1
        case .end: ends += 1
        case .control: controls += 1
        case .identity: identities += 1
        case .iceRestartRequest: iceRestartRequests += 1
        }
    }
}

private struct DirectionalSignalCounts: Equatable, Sendable {
    var host = SignalCounts()
    var viewer = SignalCounts()

    mutating func record(_ payload: RemoteSignalPayload, from side: LoopbackSide) {
        switch side {
        case .host: host.record(payload)
        case .viewer: viewer.record(payload)
        }
    }
}

private struct LoopbackSnapshot: Sendable {
    let milestones: Set<LoopbackMilestone>
    let emitted: DirectionalSignalCounts
    let delivered: DirectionalSignalCounts
    let forwardingErrors: [String]
    let controlRequests: [WebRTCControlRequest]
    let controlAcknowledgements: [WebRTCControlAcknowledgement]
    let viewerInputAuthorizations: [WebRTCInputAuthorization]
    let inputRequests: [WebRTCInputRequest]
    let hostInputAuthorizations: [WebRTCInputAuthorization]
    let inputFeedback: [WebRTCInputFeedback]
    let hostOffers: [String]
    let viewerAnswers: [String]
    let hostCandidates: [RemoteICECandidate]
    let viewerCandidates: [RemoteICECandidate]

    var hasAllConnectionMilestones: Bool {
        milestones.isSuperset(of: [
            .hostConnected,
            .viewerConnected,
            .viewerDataChannelOpen,
            .directRoute,
            .remoteTrack
        ])
    }

}

private actor LoopbackRecorder {
    private var milestones: Set<LoopbackMilestone> = []
    private var emitted = DirectionalSignalCounts()
    private var delivered = DirectionalSignalCounts()
    private var forwardingErrors: [String] = []
    private var retainedRemoteTrack: WebRTCRemoteVideoTrack?
    private var controlRequests: [WebRTCControlRequest] = []
    private var controlAcknowledgements: [WebRTCControlAcknowledgement] = []
    private var viewerInputAuthorizations: [WebRTCInputAuthorization] = []
    private var inputRequests: [WebRTCInputRequest] = []
    private var hostInputAuthorizations: [WebRTCInputAuthorization] = []
    private var inputFeedback: [WebRTCInputFeedback] = []
    private var hostOffers: [String] = []
    private var viewerAnswers: [String] = []
    private var hostCandidates: [RemoteICECandidate] = []
    private var viewerCandidates: [RemoteICECandidate] = []

    func observe(
        _ event: WebRTCTransportEvent,
        from side: LoopbackSide
    ) -> [LoopbackMilestone] {
        var observed: [LoopbackMilestone] = []

        switch event {
        case .peerStateChanged(.connected):
            observed.append(side == .host ? .hostConnected : .viewerConnected)
        case .dataChannelStateChanged(.open) where side == .viewer:
            observed.append(.viewerDataChannelOpen)
        case .routeChanged(let route) where route.kind == .direct:
            observed.append(.directRoute)
        case .remoteVideoTrack(let track) where side == .viewer:
            retainedRemoteTrack = track
            observed.append(.remoteTrack)
        case .controlRequestReceived(let request) where side == .host:
            controlRequests.append(request)
            switch request.command {
            case .showScreen:
                observed.append(
                    controlRequests.filter { $0.command == .showScreen }.count == 1
                        ? .showRequestReceived
                        : .postRestartShowRequestReceived
                )
            case .hideScreen:
                observed.append(
                    controlRequests.filter { $0.command == .hideScreen }.count == 1
                        ? .hideRequestReceived
                        : .recoveryProbeRequestReceived
                )
            case .requestKeyFrame: observed.append(.keyFrameRequestReceived)
            }
        case .controlAcknowledgementReceived(
            let acknowledgement,
            inputAuthorization: let inputAuthorization
        ) where side == .viewer:
            controlAcknowledgements.append(acknowledgement)
            if let inputAuthorization {
                viewerInputAuthorizations.append(inputAuthorization)
            }
            switch controlRequests.first(where: { $0.id == acknowledgement.id })?.command {
            case .showScreen:
                observed.append(
                    controlAcknowledgements.filter { acknowledgement in
                        controlRequests.first(where: { $0.id == acknowledgement.id })?.command
                            == .showScreen
                    }.count == 1 ? .showAcknowledged : .postRestartShowAcknowledged
                )
            case .hideScreen:
                observed.append(
                    controlAcknowledgements.filter { acknowledgement in
                        controlRequests.first(where: { $0.id == acknowledgement.id })?.command
                            == .hideScreen
                    }.count == 1 ? .hideAcknowledged : .recoveryProbeAcknowledged
                )
            case .requestKeyFrame: observed.append(.keyFrameAcknowledged)
            case nil: break
            }
        case .inputRequestReceived(
            let request,
            authorization: let authorization
        ) where side == .host:
            inputRequests.append(request)
            hostInputAuthorizations.append(authorization)
            observed.append(.inputRequestReceived)
        case .inputFeedbackReceived(let feedback) where side == .viewer:
            inputFeedback.append(feedback)
            observed.append(.inputFeedbackReceived)
        default:
            break
        }

        return observed.filter { milestones.insert($0).inserted }
    }

    func recordEmitted(
        _ payload: RemoteSignalPayload,
        from side: LoopbackSide
    ) -> [LoopbackMilestone] {
        emitted.record(payload, from: side)
        switch (side, payload) {
        case (.host, .offer(let sdp)):
            hostOffers.append(sdp)
        case (.viewer, .answer(let sdp)):
            viewerAnswers.append(sdp)
        case (.host, .candidate(let candidate)):
            hostCandidates.append(candidate)
        case (.viewer, .candidate(let candidate)):
            viewerCandidates.append(candidate)
        default:
            break
        }
        var observed: [LoopbackMilestone] = []
        if side == .host, emitted.host.offers == 2 {
            observed.append(.secondOfferEmitted)
        }
        if side == .viewer, emitted.viewer.answers == 2 {
            observed.append(.secondAnswerEmitted)
        }
        return observed.filter { milestones.insert($0).inserted }
    }

    func recordDelivered(
        _ payload: RemoteSignalPayload,
        from side: LoopbackSide
    ) -> [LoopbackMilestone] {
        delivered.record(payload, from: side)
        var observed: [LoopbackMilestone] = []
        if side == .viewer, delivered.viewer.answers == 2,
           case .answer = payload {
            observed.append(.secondAnswerDelivered)
        }
        return observed.filter { milestones.insert($0).inserted }
    }

    func recordForwardingError(_ error: any Error) {
        forwardingErrors.append(String(describing: error))
    }

    func snapshot() -> LoopbackSnapshot {
        LoopbackSnapshot(
            milestones: milestones,
            emitted: emitted,
            delivered: delivered,
            forwardingErrors: forwardingErrors,
            controlRequests: controlRequests,
            controlAcknowledgements: controlAcknowledgements,
            viewerInputAuthorizations: viewerInputAuthorizations,
            inputRequests: inputRequests,
            hostInputAuthorizations: hostInputAuthorizations,
            inputFeedback: inputFeedback,
            hostOffers: hostOffers,
            viewerAnswers: viewerAnswers,
            hostCandidates: hostCandidates,
            viewerCandidates: viewerCandidates
        )
    }
}

private final class LoopbackExpectations: @unchecked Sendable {
    let hostConnected = XCTestExpectation(description: "host connected")
    let viewerConnected = XCTestExpectation(description: "viewer connected")
    let viewerDataChannelOpen = XCTestExpectation(description: "viewer data channel opened")
    let directRoute = XCTestExpectation(description: "ICE selected a direct route")
    let remoteVideoTrack = XCTestExpectation(description: "viewer received the remote video track")
    let inputRequestReceived = XCTestExpectation(description: "host received remote input")
    let inputFeedbackReceived = XCTestExpectation(description: "viewer received input feedback")
    let showRequestReceived = XCTestExpectation(description: "host received Show request")
    let hideRequestReceived = XCTestExpectation(description: "host received Hide request")
    let keyFrameRequestReceived = XCTestExpectation(description: "host received key-frame request")
    let showAcknowledged = XCTestExpectation(description: "viewer received active acknowledgement")
    let hideAcknowledged = XCTestExpectation(description: "viewer received inactive acknowledgement")
    let keyFrameAcknowledged = XCTestExpectation(description: "viewer received key-frame acknowledgement")
    let secondOfferEmitted = XCTestExpectation(description: "host emitted a second ICE offer")
    let secondAnswerEmitted = XCTestExpectation(description: "viewer emitted a second ICE answer")
    let secondAnswerDelivered = XCTestExpectation(
        description: "host applied the second ICE answer"
    )
    let recoveryProbeRequestReceived = XCTestExpectation(
        description: "host received the post-answer Hide liveness probe"
    )
    let recoveryProbeAcknowledged = XCTestExpectation(
        description: "viewer received the probe's inactive acknowledgement"
    )
    let postRestartShowRequestReceived = XCTestExpectation(
        description: "host received a fresh Show request after restart"
    )
    let postRestartShowAcknowledged = XCTestExpectation(
        description: "viewer received a fresh active acknowledgement after restart"
    )
    let hostForwarderFinished = XCTestExpectation(description: "host forwarder finished")
    let viewerForwarderFinished = XCTestExpectation(description: "viewer forwarder finished")

    func fulfill(_ milestone: LoopbackMilestone) {
        switch milestone {
        case .hostConnected: hostConnected.fulfill()
        case .viewerConnected: viewerConnected.fulfill()
        case .viewerDataChannelOpen: viewerDataChannelOpen.fulfill()
        case .directRoute: directRoute.fulfill()
        case .remoteTrack: remoteVideoTrack.fulfill()
        case .inputRequestReceived: inputRequestReceived.fulfill()
        case .inputFeedbackReceived: inputFeedbackReceived.fulfill()
        case .showRequestReceived: showRequestReceived.fulfill()
        case .hideRequestReceived: hideRequestReceived.fulfill()
        case .keyFrameRequestReceived: keyFrameRequestReceived.fulfill()
        case .showAcknowledged: showAcknowledged.fulfill()
        case .hideAcknowledged: hideAcknowledged.fulfill()
        case .keyFrameAcknowledged: keyFrameAcknowledged.fulfill()
        case .secondOfferEmitted: secondOfferEmitted.fulfill()
        case .secondAnswerEmitted: secondAnswerEmitted.fulfill()
        case .secondAnswerDelivered: secondAnswerDelivered.fulfill()
        case .recoveryProbeRequestReceived: recoveryProbeRequestReceived.fulfill()
        case .recoveryProbeAcknowledged: recoveryProbeAcknowledged.fulfill()
        case .postRestartShowRequestReceived: postRestartShowRequestReceived.fulfill()
        case .postRestartShowAcknowledged: postRestartShowAcknowledged.fulfill()
        }
    }
}

private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw PixelBufferTestError.creationFailed(status)
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
        memset(
            baseAddress,
            0x33,
            CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
        )
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    return pixelBuffer
}

private enum PixelBufferTestError: Error {
    case creationFailed(CVReturn)
}
