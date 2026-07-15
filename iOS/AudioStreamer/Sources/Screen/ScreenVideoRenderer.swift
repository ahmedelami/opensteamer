@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation

final class ScreenVideoRenderer: @unchecked Sendable {
    enum Event: Sendable {
        case needsKeyFrame
        case failed(String)
    }

    private struct EncodedFrame: Sendable {
        let data: Data
        let presentationTimestampNanoseconds: UInt64
        let isKeyFrame: Bool
        let completion: @Sendable (Bool) -> Void
    }

    private let queue = DispatchQueue(label: "AudioStreamer.ScreenVideoRenderer")
    private var renderer: AVSampleBufferVideoRenderer?
    private var builder: H264SampleBuilder?
    private var pendingFrames: [EncodedFrame] = []
    private var waitingForKeyFrame = true
    private var attachmentGeneration: UInt64 = 0
    private var observerTokens: [NSObjectProtocol] = []
    private let onEvent: @Sendable (Event) -> Void

    init(onEvent: @escaping @Sendable (Event) -> Void) {
        self.onEvent = onEvent
    }

    @MainActor
    func attach(to renderer: AVSampleBufferVideoRenderer) {
        queue.async { [weak self] in
            guard let self else { return }
            self.renderer?.stopRequestingMediaData()
            self.removeObservers()
            self.rejectPendingFrames()
            self.attachmentGeneration &+= 1
            let attachmentGeneration = self.attachmentGeneration
            self.renderer = renderer
            self.waitingForKeyFrame = true
            self.installObservers(on: renderer, attachmentGeneration: attachmentGeneration)
            renderer.requestMediaDataWhenReady(on: self.queue) { [weak self, weak renderer] in
                guard let self, let renderer else { return }
                self.drain(
                    renderer: renderer,
                    attachmentGeneration: attachmentGeneration
                )
            }
            self.onEvent(.needsKeyFrame)
        }
    }

    @MainActor
    func detach(from renderer: AVSampleBufferVideoRenderer, removeImage: Bool) {
        queue.async { [weak self] in
            guard let self, self.renderer === renderer else { return }
            renderer.stopRequestingMediaData()
            self.removeObservers()
            self.attachmentGeneration &+= 1
            self.renderer = nil
            self.builder = nil
            self.rejectPendingFrames()
            self.waitingForKeyFrame = true
            renderer.flush(removingDisplayedImage: removeImage, completionHandler: nil)
        }
    }

    func configure(parameterSets: [Data], nalUnitHeaderLength: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                self.builder = try H264SampleBuilder(
                    parameterSets: parameterSets,
                    nalUnitHeaderLength: nalUnitHeaderLength
                )
                self.rejectPendingFrames()
                self.waitingForKeyFrame = true
                self.renderer?.flush()
            } catch {
                self.onEvent(.failed("Invalid H.264 configuration: \(error.localizedDescription)"))
            }
        }
    }

    func enqueue(
        avccAccessUnit: Data,
        presentationTimestampNanoseconds: UInt64,
        isKeyFrame: Bool,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, let renderer = self.renderer, self.builder != nil else {
                completion(false)
                return
            }

            if renderer.requiresFlushToResumeDecoding || renderer.status == .failed {
                let message = renderer.error?.localizedDescription
                self.flushAndRequestKeyFrame(removeImage: false)
                if let message {
                    self.onEvent(.failed(message))
                }
                completion(false)
                return
            }
            guard !self.waitingForKeyFrame || isKeyFrame else {
                completion(false)
                return
            }

            if self.pendingFrames.count >= 4 {
                self.flushAndRequestKeyFrame(removeImage: false)
                guard isKeyFrame else {
                    completion(false)
                    return
                }
            }

            self.pendingFrames.append(EncodedFrame(
                data: avccAccessUnit,
                presentationTimestampNanoseconds: presentationTimestampNanoseconds,
                isKeyFrame: isKeyFrame,
                completion: completion
            ))
            self.drain(renderer: renderer)
        }
    }

    func reset(removeImage: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.rejectPendingFrames()
            self.builder = nil
            self.waitingForKeyFrame = true
            if removeImage {
                self.renderer?.flush(removingDisplayedImage: true, completionHandler: nil)
            } else {
                self.renderer?.flush()
            }
        }
    }

    private func flushAndRequestKeyFrame(removeImage: Bool) {
        rejectPendingFrames()
        waitingForKeyFrame = true
        if removeImage {
            renderer?.flush(removingDisplayedImage: true, completionHandler: nil)
        } else {
            renderer?.flush()
        }
        onEvent(.needsKeyFrame)
    }

    private func drain(
        renderer: AVSampleBufferVideoRenderer,
        attachmentGeneration: UInt64? = nil
    ) {
        guard self.renderer === renderer,
              attachmentGeneration == nil || self.attachmentGeneration == attachmentGeneration,
              let builder else { return }

        while renderer.isReadyForMoreMediaData, !pendingFrames.isEmpty {
            let frame = pendingFrames.removeFirst()
            guard !waitingForKeyFrame || frame.isKeyFrame else {
                frame.completion(false)
                continue
            }
            do {
                let sampleBuffer = try builder.makeSampleBuffer(
                    avccAccessUnit: frame.data,
                    presentationTimeStamp: CMTime(
                        value: Int64(clamping: frame.presentationTimestampNanoseconds),
                        timescale: 1_000_000_000
                    ),
                    isKeyFrame: frame.isKeyFrame
                )
                renderer.enqueue(sampleBuffer)
                frame.completion(true)
                if frame.isKeyFrame {
                    waitingForKeyFrame = false
                }
            } catch {
                frame.completion(false)
                rejectPendingFrames()
                waitingForKeyFrame = true
                onEvent(.failed("Could not build H.264 sample: \(error.localizedDescription)"))
                return
            }
        }
    }

    private func installObservers(
        on renderer: AVSampleBufferVideoRenderer,
        attachmentGeneration: UInt64
    ) {
        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
            object: renderer,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self,
                      self.renderer === renderer,
                      self.attachmentGeneration == attachmentGeneration,
                      renderer.requiresFlushToResumeDecoding else { return }
                self.flushAndRequestKeyFrame(removeImage: false)
            }
        })
        observerTokens.append(center.addObserver(
            forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
            object: renderer,
            queue: nil
        ) { [weak self] notification in
            let message = (
                notification.userInfo?[AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey]
                    as? Error
            )?.localizedDescription ?? "H.264 decoding failed"
            self?.queue.async { [weak self] in
                guard let self,
                      self.renderer === renderer,
                      self.attachmentGeneration == attachmentGeneration else { return }
                self.flushAndRequestKeyFrame(removeImage: false)
                self.onEvent(.failed(message))
            }
        })
    }

    private func removeObservers() {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
    }

    private func rejectPendingFrames() {
        let rejected = pendingFrames
        pendingFrames.removeAll(keepingCapacity: true)
        for frame in rejected {
            frame.completion(false)
        }
    }
}
