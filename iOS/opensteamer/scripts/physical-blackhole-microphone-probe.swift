import Foundation
import AudioToolbox
import CoreAudio
import CryptoKit
import Darwin
import Dispatch
private enum Policy { /* A proof window passes only with density 0.85...1.15, two independently advancing progress deltas, callback gaps <=100 ms, no near-silent run >500 ms, >=20% non-silent frames, peak 512..<32760, clipping <0.5%, >=16 symbols, >=80% symbol matches, normalized spectral correlation >=0.60, and a discrimination margin >=0.10. The three defaults must compare equal and must produce zero in-window notifications. */ static let schema = "opensteamer.physical-virtual-microphone.v2"; static let captureUID = "com.elamin.opensteamer.virtual-microphone.input"; static let hiddenMirrorUID = "com.elamin.opensteamer.virtual-microphone.writer"; static let modelUID = "com.elamin.opensteamer.virtual-microphone.model"; static let clockDomain: UInt32 = 0x6F73564D; static let legacyVisibleUID = "BlackHole2ch_UID"; static let legacyHiddenUID = "BlackHole2ch_2_UID"; static let algorithm = "nonce-splitmix64-frequency-hop-raised-envelope"; static let algorithmVersion = 1; static let sampleRate: Double = 48_000; static let sampleRateInt = 48_000; static let captureChannels = 1; static let physicalOutputChannels = 2; static let proofSeconds = 6.0; static let retentionSeconds = 12.0; static let symbolSeconds = 0.25; static let symbolFrames = 12_000; static let edgeRampFrames = 576; static let frequencies: [Double] = [700, 950, 1_250, 1_650, 2_200, 3_500, 4_300, 5_100]; static let outputAmplitudes: [Double] = [0.16, 0.20, 0.24]; static let bufferFrames = 480; static let bufferCount = 4; static let analysisBlockFrames = 2_880; static let analysisHopFrames = 2_400; static let analysisEdgeGuardSeconds = 0.040; static let minimumLagSeconds = 0.040; static let maximumLagSeconds = 5.0; static let lagStepSeconds = 0.020; static let minimumCandidateSymbols = 8; static let minimumSymbols = 16; static let minimumFrameDensity = 0.85; static let maximumFrameDensity = 1.15; static let maximumCallbackGapMs = 100.0; static let maximumSilentGapMs = 500.0; static let minimumNonSilentRatio = 0.20; static let nonSilentThreshold = 128; static let minimumPeak = 512; static let clippedMagnitude = 32_760; static let maximumClippedRatio = 0.005; static let minimumMatchRatio = 0.80; static let minimumNormalizedCorrelation = 0.60; static let minimumDiscriminationMargin = 0.10; static let progressIntervalSeconds = 0.5; static let evaluationIntervalSeconds = 1.0; static let minimumTimeoutSeconds = 8.0; static let maximumTimeoutSeconds = 120.0; static let maximumFailureReasons = 20; static let maximumProgressRecords = 16 }
private extension Policy {
    /// Operational lab prerequisite only. This declaration is not cryptographic acoustic
    /// provenance; it states that the controlled host was reviewed with no audio taps or digital
    /// loopback routes before the nonce challenge is accepted.
    static let controlledHostNoAudioTapsConfirmation =
        "controlled-host-no-audio-taps-reviewed"
}
private struct ProbeError: Error { let code: String }
private struct AudioFormatEvidence: Codable { let sampleRate: Int; let channels: Int; let signedInt16: Bool; let interleaved: Bool }
private struct ProgressEvidence: Codable { let elapsedSeconds: Double; let callbackCount: UInt64; let capturedFrameCount: UInt64; let callbackDelta: UInt64; let frameDelta: UInt64; let advancing: Bool }
private struct ChannelEvidence: Codable { let channel: Int; let rms: Double; let peak: Int; let clippedRatio: Double; let nonSilentRatio: Double; let challengeSymbolCount: Int; let matchedSymbolCount: Int; let matchRatio: Double; let normalizedCorrelation: Double; let discriminationMargin: Double; let envelopeCorrelation: Double }
private struct ProbeResult: Codable { let schema: String; let status: String; let runNonce: String; let challengeAlgorithm: String; let challengeVersion: Int; let canonicalCaptureUID: String; let captureUIDMatches: Bool; let physicalOutputValidated: Bool; let challengeNonceMatches: Bool; let queueReadbackMatches: Bool; let captureQueueReadbackMatches: Bool; let physicalOutputQueueReadbackMatches: Bool; let format: AudioFormatEvidence; let proofWindowSeconds: Double; let captureSeconds: Double; let callbackCount: UInt64; let capturedFrameCount: UInt64; let totalCallbackCount: UInt64; let totalCapturedFrameCount: UInt64; let frameDensity: Double; let maxCallbackGapMs: Double; let longestNonSilentGapMs: Double; let nonSilentFrameRatio: Double; let aggregateClippedRatio: Double; let progressObservationCount: Int; let advancingProgressObservationCount: Int; let progressSnapshots: [ProgressEvidence]; let channels: [ChannelEvidence]; let recognizedChannel: Int; let symbolCount: Int; let matchedSymbolCount: Int; let matchRatio: Double; let normalizedCorrelation: Double; let discriminationMargin: Double; let envelopeCorrelation: Double; let detectedLagMs: Double; let defaultInputBeforeAfterEqual: Bool; let defaultOutputBeforeAfterEqual: Bool; let defaultSystemOutputBeforeAfterEqual: Bool; let defaultChangeNotificationCount: Int; let failureCode: String; let failureReasons: [String] }
private struct SplitMix64 { private var state: UInt64; init(seed: UInt64) { state = seed }; mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var value = state; value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9; value = (value ^ (value >> 27)) &* 0x94D049BB133111EB; return value ^ (value >> 31) } }
private struct ChallengeSymbol { let frequencyIndex: Int; let amplitudeIndex: Int; let envelopeCode: Int }
private struct ChallengePlan { let nonce: String; let symbols: [ChallengeSymbol]; init(nonce: String, symbolCount: Int) { self.nonce = nonce; var generator = SplitMix64(seed: Self.seed(for: nonce)); var made: [ChallengeSymbol] = []; made.reserveCapacity(symbolCount); var previousFrequency: Int?; while made.count < symbolCount { var permutation = Array(0..<Policy.frequencies.count); if permutation.count > 1 { for index in stride(from: permutation.count - 1, through: 1, by: -1) { let other = Int(generator.next() % UInt64(index + 1)); permutation.swapAt(index, other) } }; if permutation.first == previousFrequency, permutation.count > 1 { permutation.swapAt(0, 1) }; for frequencyIndex in permutation { guard made.count < symbolCount else { break }; let amplitudeIndex = Int(generator.next() % UInt64(Policy.outputAmplitudes.count)); let envelopeCode = Int(generator.next() % 4); made.append(ChallengeSymbol(frequencyIndex: frequencyIndex, amplitudeIndex: amplitudeIndex, envelopeCode: envelopeCode)); previousFrequency = frequencyIndex } }; symbols = made }; private init(nonce: String, symbols: [ChallengeSymbol]) { self.nonce = nonce; self.symbols = symbols }; func frozen() -> ChallengePlan { guard let first = symbols.first else { return self }; return ChallengePlan(nonce: nonce, symbols: Array(repeating: first, count: symbols.count)) }; static func seed(for nonce: String) -> UInt64 { var hash: UInt64 = 14_695_981_039_346_656_037; for byte in nonce.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }; hash ^= 0xA5A5D3C47E291B6F; return hash == 0 ? 0xD1B54A32D192ED03 : hash } }
private final class ChallengeGenerator { private let plan: ChallengePlan; private var frameIndex: Int64 = 0; private var phase = 0.0; private(set) var exhausted = false; init(plan: ChallengePlan) { self.plan = plan }; func nextNormalized() -> Double { let symbolIndex = Int(frameIndex) / Policy.symbolFrames; guard symbolIndex >= 0, symbolIndex < plan.symbols.count else { exhausted = true; frameIndex &+= 1; return 0 }; let symbol = plan.symbols[symbolIndex]; let localFrame = Int(frameIndex) % Policy.symbolFrames; let edgeDistance = min(localFrame, Policy.symbolFrames - 1 - localFrame); let edge = edgeDistance >= Policy.edgeRampFrames ? 1.0 : 0.5 - 0.5 * cos(Double.pi * Double(edgeDistance) / Double(Policy.edgeRampFrames)); let symbolFraction = Double(localFrame) / Double(Policy.symbolFrames); let envelopeRate = Double(2 + symbol.envelopeCode); let envelopePhase = Double(symbol.envelopeCode) * 0.73; let nonceEnvelope = 0.92 + 0.08 * sin(2.0 * Double.pi * envelopeRate * symbolFraction + envelopePhase); let frequency = Policy.frequencies[symbol.frequencyIndex]; let value = sin(phase) * Policy.outputAmplitudes[symbol.amplitudeIndex] * edge * nonceEnvelope; phase += 2.0 * Double.pi * frequency / Policy.sampleRate; if phase >= 2.0 * Double.pi { phase -= 2.0 * Double.pi }; frameIndex &+= 1; return value } }
private struct CaptureChunk { let samples: [Int16]; let endUptime: Double; let frameCount: Int }
private struct ProgressObservation { let uptime: Double; let callbackCount: UInt64; let capturedFrameCount: UInt64 }
private struct EvaluationWindow { let startUptime: Double; let endUptime: Double; let samples: [Int16]; let callbackEndTimes: [Double]; let progress: [ProgressObservation]; let totalCallbackCount: UInt64; let totalCapturedFrameCount: UInt64 }
private struct CaptureSnapshot { let chunks: [CaptureChunk]; let progress: [ProgressObservation]; let totalCallbackCount: UInt64; let totalCapturedFrameCount: UInt64; func window(endingAt endUptime: Double, duration: Double) -> EvaluationWindow { let startUptime = endUptime - duration; var samples: [Int16] = []; samples.reserveCapacity(Int(duration * Policy.sampleRate) * Policy.captureChannels); var callbackEndTimes: [Double] = []; for chunk in chunks { let chunkStart = chunk.endUptime - Double(chunk.frameCount) / Policy.sampleRate; guard chunk.endUptime > startUptime, chunkStart < endUptime else { continue }; let firstFrame = max(0, Int(ceil((startUptime - chunkStart) * Policy.sampleRate))); let lastFrame = min(chunk.frameCount, Int(floor((endUptime - chunkStart) * Policy.sampleRate))); if lastFrame > firstFrame { let firstSample = firstFrame * Policy.captureChannels; let lastSample = lastFrame * Policy.captureChannels; samples.append(contentsOf: chunk.samples[firstSample..<lastSample]) }; callbackEndTimes.append(min(endUptime, max(startUptime, chunk.endUptime))) }; var selectedProgress: [ProgressObservation] = []; if let anchor = progress.last(where: { $0.uptime < startUptime }) { selectedProgress.append(anchor) }; selectedProgress.append(contentsOf: progress.filter { $0.uptime >= startUptime && $0.uptime <= endUptime }); return EvaluationWindow(startUptime: startUptime, endUptime: endUptime, samples: samples, callbackEndTimes: callbackEndTimes, progress: selectedProgress, totalCallbackCount: totalCallbackCount, totalCapturedFrameCount: totalCapturedFrameCount) } }
private final class CaptureStore: @unchecked Sendable { private let lock = NSLock(); private let retention: Double; private var chunks: [CaptureChunk] = []; private var progress: [ProgressObservation] = []; private var callbackCount: UInt64 = 0; private var capturedFrameCount: UInt64 = 0; init(retention: Double) { self.retention = retention }; func append(interleaved samples: [Int16], endUptime: Double) { let frames = samples.count / Policy.captureChannels; lock.lock(); defer { lock.unlock() }; callbackCount &+= 1; capturedFrameCount &+= UInt64(max(0, frames)); chunks.append(CaptureChunk(samples: samples, endUptime: endUptime, frameCount: frames)); let cutoff = endUptime - retention; while let first = chunks.first, first.endUptime < cutoff { chunks.removeFirst() } }; func recordProgress(at uptime: Double) { lock.lock(); defer { lock.unlock() }; progress.append(ProgressObservation(uptime: uptime, callbackCount: callbackCount, capturedFrameCount: capturedFrameCount)); let cutoff = uptime - retention - 2.0; progress.removeAll { $0.uptime < cutoff } }; func snapshot() -> CaptureSnapshot { lock.lock(); defer { lock.unlock() }; return CaptureSnapshot(chunks: chunks, progress: progress, totalCallbackCount: callbackCount, totalCapturedFrameCount: capturedFrameCount) } }
private final class QueueFailureLatch: @unchecked Sendable { private let lock = NSLock(); private var failed = false; func record(_ status: OSStatus) { guard status != noErr else { return }; recordFailure() }; func recordFailure() { lock.lock(); failed = true; lock.unlock() }; func hasFailure() -> Bool { lock.lock(); defer { lock.unlock() }; return failed } }
private final class CallbackLifecycle: @unchecked Sendable { private let condition = NSCondition(); private var accepting = false; private var inFlight = 0; func activate() { condition.lock(); while inFlight > 0 { condition.wait() }; accepting = true; condition.unlock() }; func begin() -> Bool { condition.lock(); inFlight += 1; let accepted = accepting; condition.unlock(); return accepted }; func end() { condition.lock(); precondition(inFlight > 0); inFlight -= 1; if inFlight == 0 { condition.broadcast() }; condition.unlock() }; func stopAcceptingAndWait() { condition.lock(); accepting = false; while inFlight > 0 { condition.wait() }; condition.unlock() }; func waitUntilIdle() { condition.lock(); while inFlight > 0 { condition.wait() }; condition.unlock() } }
private final class InputCallbackContext: @unchecked Sendable { let store: CaptureStore; let failureLatch: QueueFailureLatch; private let lifecycle = CallbackLifecycle(); init(store: CaptureStore, failureLatch: QueueFailureLatch) { self.store = store; self.failureLatch = failureLatch }; func activate() { lifecycle.activate() }; func stopAcceptingAndWait() { lifecycle.stopAcceptingAndWait() }; func waitUntilIdle() { lifecycle.waitUntilIdle() }; func handle(queue: AudioQueueRef, buffer: AudioQueueBufferRef) { let accepted = lifecycle.begin(); defer { lifecycle.end() }; guard accepted else { return }; let byteCount = Int(buffer.pointee.mAudioDataByteSize); let sampleCount = max(0, byteCount / MemoryLayout<Int16>.size); let safeSampleCount = sampleCount - sampleCount % Policy.captureChannels; var copy: [Int16] = []; if safeSampleCount > 0 { let pointer = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self); copy = Array(UnsafeBufferPointer(start: pointer, count: safeSampleCount)) }; store.append(interleaved: copy, endUptime: ProcessInfo.processInfo.systemUptime); failureLatch.record(AudioQueueEnqueueBuffer(queue, buffer, 0, nil)) } }
private func physicalProbeInputCallback(_ userData: UnsafeMutableRawPointer?, _ queue: AudioQueueRef, _ buffer: AudioQueueBufferRef, _ startTime: UnsafePointer<AudioTimeStamp>, _ packetCount: UInt32, _ packetDescriptions: UnsafePointer<AudioStreamPacketDescription>?) { guard let userData else { return }; Unmanaged<InputCallbackContext>.fromOpaque(userData).takeUnretainedValue().handle(queue: queue, buffer: buffer) }
private enum OutputPCMBufferFiller { static func fillInterleavedStereo(_ destination: UnsafeMutableBufferPointer<Int16>, frameCount: Int, generator: ChallengeGenerator) -> Bool { guard frameCount > 0, destination.count >= frameCount * Policy.physicalOutputChannels else { return false }; var complete = true; for frame in 0..<frameCount { let normalized = generator.nextNormalized(); if generator.exhausted { complete = false }; let sample = AudioSupport.quantize(normalized); let base = frame * Policy.physicalOutputChannels; for channel in 0..<Policy.physicalOutputChannels { destination[base + channel] = sample } }; return complete }; static func fillAudioQueueBuffer(_ buffer: AudioQueueBufferRef, generator: ChallengeGenerator) -> Bool { let bytesPerFrame = Policy.physicalOutputChannels * MemoryLayout<Int16>.size; let requiredByteCount = Policy.bufferFrames * bytesPerFrame; guard Int(buffer.pointee.mAudioDataBytesCapacity) >= requiredByteCount else { buffer.pointee.mAudioDataByteSize = 0; return false }; let pointer = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self); let destination = UnsafeMutableBufferPointer(start: pointer, count: Policy.bufferFrames * Policy.physicalOutputChannels); let complete = fillInterleavedStereo(destination, frameCount: Policy.bufferFrames, generator: generator); buffer.pointee.mAudioDataByteSize = UInt32(requiredByteCount); return complete } }
private enum OutputGeneratorSelfTest { static func passes(nonce: String) -> Bool { let symbolCount = 32; let frameCount = Policy.symbolFrames * 4 + Policy.bufferFrames; let plan = ChallengePlan(nonce: nonce, symbolCount: symbolCount); guard let actual = renderProduction(plan: plan, frameCount: frameCount), let expected = renderReference(plan: plan, frameCount: frameCount), actual == expected, validatesAudioQueueContract(nonce: nonce) else { return false }; let peak = actual.reduce(0) { max($0, Int(abs(Int32($1)))) }; guard peak >= Policy.minimumPeak, let first = actual.first, actual.contains(where: { $0 != first }), let frozen = renderProduction(plan: plan.frozen(), frameCount: frameCount), frozen != actual else { return false }; var mismatchedPlan: ChallengePlan?; var mismatchedExpected: [Int16]?; for attempt in 0..<8 { let candidate = ChallengePlan(nonce: nonce + ":output-generator-mismatch:\(attempt)", symbolCount: symbolCount); guard let candidateExpected = renderReference(plan: candidate, frameCount: frameCount) else { return false }; if candidateExpected != expected { mismatchedPlan = candidate; mismatchedExpected = candidateExpected; break } }; guard let mismatchedPlan, let mismatchedExpected, let mismatchedActual = renderProduction(plan: mismatchedPlan, frameCount: frameCount) else { return false }; return mismatchedActual == mismatchedExpected && mismatchedActual != actual }; private static func validatesAudioQueueContract(nonce: String) -> Bool { let bytesPerFrame = Policy.physicalOutputChannels * MemoryLayout<Int16>.size; let requiredByteCount = Policy.bufferFrames * bytesPerFrame; guard requiredByteCount > 0 else { return false }; let capacityPlan = ChallengePlan(nonce: nonce + ":output-generator-capacity", symbolCount: 1); let capacityFailureLatch = QueueFailureLatch(); let capacityContext = OutputCallbackContext(plan: capacityPlan, failureLatch: capacityFailureLatch); capacityContext.activate(); defer { capacityContext.stopAcceptingAndWait() }; var capacityEnqueueAttempts = 0; let undersizedRejected = withTestAudioQueueBuffer(reportedByteCapacity: requiredByteCount - 1, backingByteCapacity: requiredByteCount, initialByteSize: UInt32.max) { buffer -> Bool in capacityContext.handleCallback(buffer: buffer) { capacityEnqueueAttempts += 1; return noErr }; return buffer.pointee.mAudioDataByteSize == 0 }; guard undersizedRejected, capacityFailureLatch.hasFailure(), capacityEnqueueAttempts == 0, Policy.bufferFrames > 0, Policy.symbolFrames.isMultiple(of: Policy.bufferFrames) else { return false }; let successfulBufferCount = Policy.symbolFrames / Policy.bufferFrames; guard successfulBufferCount > 0 else { return false }; let exhaustionPlan = ChallengePlan(nonce: nonce + ":output-generator-exhaustion", symbolCount: 1); let exhaustionFailureLatch = QueueFailureLatch(); let exhaustionContext = OutputCallbackContext(plan: exhaustionPlan, failureLatch: exhaustionFailureLatch); exhaustionContext.activate(); defer { exhaustionContext.stopAcceptingAndWait() }; var enqueueAttempts = 0; for _ in 0..<successfulBufferCount { let successfulFill = withTestAudioQueueBuffer(reportedByteCapacity: requiredByteCount, initialByteSize: UInt32.max) { buffer -> Bool in let attemptsBeforeFill = enqueueAttempts; exhaustionContext.handleCallback(buffer: buffer) { enqueueAttempts += 1; return noErr }; return enqueueAttempts == attemptsBeforeFill + 1 && Int(buffer.pointee.mAudioDataByteSize) == requiredByteCount }; guard successfulFill, !exhaustionFailureLatch.hasFailure() else { return false } }; let attemptsBeforeExhaustion = enqueueAttempts; let exhaustionRejected = withTestAudioQueueBuffer(reportedByteCapacity: requiredByteCount, initialByteSize: UInt32.max) { buffer -> Bool in exhaustionContext.handleCallback(buffer: buffer) { enqueueAttempts += 1; return noErr }; return Int(buffer.pointee.mAudioDataByteSize) == requiredByteCount }; return exhaustionRejected && exhaustionFailureLatch.hasFailure() && enqueueAttempts == attemptsBeforeExhaustion }; private static func withTestAudioQueueBuffer<Result>(reportedByteCapacity: Int, backingByteCapacity: Int? = nil, initialByteSize: UInt32 = 0, _ body: (AudioQueueBufferRef) -> Result) -> Result { let actualBackingByteCapacity = backingByteCapacity ?? reportedByteCapacity; precondition(reportedByteCapacity >= 0 && actualBackingByteCapacity >= reportedByteCapacity && reportedByteCapacity <= Int(UInt32.max) && actualBackingByteCapacity <= Int(UInt32.max)); let allocationSize = max(1, actualBackingByteCapacity); let sampleCapacity = max(1, (allocationSize + MemoryLayout<Int16>.stride - 1) / MemoryLayout<Int16>.stride); let audioSamples = UnsafeMutablePointer<Int16>.allocate(capacity: sampleCapacity); audioSamples.initialize(repeating: 0, count: sampleCapacity); defer { audioSamples.deinitialize(count: sampleCapacity); audioSamples.deallocate() }; var buffer = AudioQueueBuffer(mAudioDataBytesCapacity: UInt32(reportedByteCapacity), mAudioData: UnsafeMutableRawPointer(audioSamples), mAudioDataByteSize: initialByteSize, mUserData: nil, mPacketDescriptionCapacity: 0, mPacketDescriptions: nil, mPacketDescriptionCount: 0); return withUnsafeMutablePointer(to: &buffer) { body($0) } }; private static func renderProduction(plan: ChallengePlan, frameCount: Int) -> [Int16]? { guard frameCount > 0, Policy.bufferFrames > 0, frameCount.isMultiple(of: Policy.bufferFrames) else { return nil }; let generator = ChallengeGenerator(plan: plan); let bytesPerFrame = Policy.physicalOutputChannels * MemoryLayout<Int16>.size; let requiredByteCount = Policy.bufferFrames * bytesPerFrame; let acceptedByteCapacity = requiredByteCount + bytesPerFrame; let requiredSampleCount = Policy.bufferFrames * Policy.physicalOutputChannels; var samples: [Int16] = []; samples.reserveCapacity(frameCount * Policy.physicalOutputChannels); var frameOffset = 0; while frameOffset < frameCount { let bufferSamples: [Int16]? = withTestAudioQueueBuffer(reportedByteCapacity: acceptedByteCapacity, initialByteSize: UInt32.max) { buffer in guard OutputPCMBufferFiller.fillAudioQueueBuffer(buffer, generator: generator), Int(buffer.pointee.mAudioDataByteSize) == requiredByteCount else { return nil }; let pointer = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self); return Array(UnsafeBufferPointer(start: pointer, count: requiredSampleCount)) }; guard let bufferSamples else { return nil }; samples.append(contentsOf: bufferSamples); frameOffset += Policy.bufferFrames }; return samples }; private static func renderReference(plan: ChallengePlan, frameCount: Int) -> [Int16]? { guard frameCount > 0 else { return nil }; var samples: [Int16] = []; samples.reserveCapacity(frameCount * Policy.physicalOutputChannels); var phase = 0.0; for frameIndex in 0..<frameCount { let symbolIndex = frameIndex / Policy.symbolFrames; guard symbolIndex < plan.symbols.count else { return nil }; let symbol = plan.symbols[symbolIndex]; let localFrame = frameIndex % Policy.symbolFrames; let edgeDistance = min(localFrame, Policy.symbolFrames - 1 - localFrame); let edge = edgeDistance >= Policy.edgeRampFrames ? 1.0 : 0.5 - 0.5 * cos(Double.pi * Double(edgeDistance) / Double(Policy.edgeRampFrames)); let symbolFraction = Double(localFrame) / Double(Policy.symbolFrames); let envelopeRate = Double(2 + symbol.envelopeCode); let envelopePhase = Double(symbol.envelopeCode) * 0.73; let nonceEnvelope = 0.92 + 0.08 * sin(2.0 * Double.pi * envelopeRate * symbolFraction + envelopePhase); let frequency = Policy.frequencies[symbol.frequencyIndex]; let value = sin(phase) * Policy.outputAmplitudes[symbol.amplitudeIndex] * edge * nonceEnvelope; phase += 2.0 * Double.pi * frequency / Policy.sampleRate; if phase >= 2.0 * Double.pi { phase -= 2.0 * Double.pi }; let sample = referenceQuantize(value); for _ in 0..<Policy.physicalOutputChannels { samples.append(sample) } }; return samples }; private static func referenceQuantize(_ value: Double) -> Int16 { let bounded = max(-0.999969, min(0.999969, value)); return Int16(Int32((bounded * Double(Int16.max)).rounded())) } }
private final class OutputCallbackContext: @unchecked Sendable { let failureLatch: QueueFailureLatch; private let lifecycle = CallbackLifecycle(); private let generator: ChallengeGenerator; init(plan: ChallengePlan, failureLatch: QueueFailureLatch) { generator = ChallengeGenerator(plan: plan); self.failureLatch = failureLatch }; func activate() { lifecycle.activate() }; func stopAcceptingAndWait() { lifecycle.stopAcceptingAndWait() }; func waitUntilIdle() { lifecycle.waitUntilIdle() }; func fill(buffer: AudioQueueBufferRef) -> Bool { let filled = OutputPCMBufferFiller.fillAudioQueueBuffer(buffer, generator: generator); if !filled { failureLatch.recordFailure() }; return filled }; func handleCallback(buffer: AudioQueueBufferRef, enqueue: () -> OSStatus) { let accepted = lifecycle.begin(); defer { lifecycle.end() }; guard accepted, fill(buffer: buffer) else { return }; failureLatch.record(enqueue()) }; func handle(queue: AudioQueueRef, buffer: AudioQueueBufferRef) { handleCallback(buffer: buffer) { AudioQueueEnqueueBuffer(queue, buffer, 0, nil) } } }
private func physicalProbeOutputCallback(_ userData: UnsafeMutableRawPointer?, _ queue: AudioQueueRef, _ buffer: AudioQueueBufferRef) { guard let userData else { return }; Unmanaged<OutputCallbackContext>.fromOpaque(userData).takeUnretainedValue().handle(queue: queue, buffer: buffer) }
private enum AudioSupport { static func format(channels: Int) -> AudioStreamBasicDescription { let bytesPerFrame = UInt32(channels * MemoryLayout<Int16>.size); return AudioStreamBasicDescription(mSampleRate: Policy.sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0) }; static func pinCurrentDevice(_ uid: String, queue: AudioQueueRef, failureCode: String) throws -> Bool { var value = uid as CFString; let status = withUnsafePointer(to: &value) { AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, $0, UInt32(MemoryLayout<CFString>.size)) }; guard status == noErr else { throw ProbeError(code: failureCode) }; return currentDevice(queue) == uid }; static func currentDevice(_ queue: AudioQueueRef) -> String? { var value: CFString = "" as CFString; var size = UInt32(MemoryLayout<CFString>.size); let status = withUnsafeMutablePointer(to: &value) { AudioQueueGetProperty(queue, kAudioQueueProperty_CurrentDevice, $0, &size) }; guard status == noErr, size > 0 else { return nil }; let string = value as String; return string.isEmpty ? nil : string }; static func quantize(_ value: Double) -> Int16 { let bounded = max(-0.999969, min(0.999969, value)); return Int16(Int32((bounded * Double(Int16.max)).rounded())) } }
private final class InputQueueSession {
  private let context: InputCallbackContext; private var queue: AudioQueueRef?;
  private var buffers: [AudioQueueBufferRef] = [];
  private var callbackContextRetain: Unmanaged<InputCallbackContext>?; private var started = false;
  private(set) var readbackMatches = false;
  init(store: CaptureStore, failureLatch: QueueFailureLatch) {
    context = InputCallbackContext(store: store, failureLatch: failureLatch)
  };
  func start(uid: String) throws {
    guard queue == nil else { return }; readbackMatches = false; started = false;
    context.activate(); var description = AudioSupport.format(channels: Policy.captureChannels); var created: AudioQueueRef?;
    let retainedContext = Unmanaged.passRetained(context);
    let createStatus = AudioQueueNewInput(
      &description, physicalProbeInputCallback, retainedContext.toOpaque(), nil, nil, 0, &created);
    guard createStatus == noErr, let created else {
      context.stopAcceptingAndWait(); retainedContext.release();
      throw ProbeError(code: "capture_queue_create_failed")
    }; callbackContextRetain = retainedContext; queue = created;
    do {
      let firstReadback = try AudioSupport.pinCurrentDevice(
        uid, queue: created, failureCode: "capture_queue_device_set_failed");
      guard firstReadback else { throw ProbeError(code: "capture_queue_device_readback_mismatch") };
      let byteCount = UInt32(Policy.bufferFrames * Policy.captureChannels * MemoryLayout<Int16>.size);
      for _ in 0..<Policy.bufferCount {
        var buffer: AudioQueueBufferRef?;
        let allocationStatus = AudioQueueAllocateBuffer(created, byteCount, &buffer);
        guard allocationStatus == noErr, let buffer else {
          throw ProbeError(code: "capture_queue_buffer_allocation_failed")
        }; buffers.append(buffer);
        guard AudioQueueEnqueueBuffer(created, buffer, 0, nil) == noErr else {
          throw ProbeError(code: "capture_queue_buffer_enqueue_failed")
        }
      };
      guard AudioQueueStart(created, nil) == noErr else {
        throw ProbeError(code: "capture_queue_start_failed")
      }; started = true;
      readbackMatches = firstReadback && AudioSupport.currentDevice(created) == uid;
      guard readbackMatches else {
        throw ProbeError(code: "capture_queue_device_readback_mismatch")
      }
    } catch { _ = stop(); throw error }
  };
  func stop() -> Bool {
    guard let queue else { return true }; context.stopAcceptingAndWait();
    var stopStatus: OSStatus = noErr;
    if started { stopStatus = AudioQueueStop(queue, true); started = false };
    context.waitUntilIdle(); let disposeStatus = AudioQueueDispose(queue, true);
    context.waitUntilIdle();
    // AudioQueueDispose is terminal after it returns, regardless of status.
    self.queue = nil; buffers.removeAll(keepingCapacity: false); callbackContextRetain?.release();
    callbackContextRetain = nil;
    return stopStatus == noErr && disposeStatus == noErr
  }; deinit { _ = stop() }
}
private final class OutputQueueSession {
  private let plan: ChallengePlan; private let context: OutputCallbackContext;
  private let failureLatch: QueueFailureLatch; private var queue: AudioQueueRef?;
  private var buffers: [AudioQueueBufferRef] = [];
  private var callbackContextRetain: Unmanaged<OutputCallbackContext>?; private var started = false;
  private var teardownFailed = false; private(set) var readbackMatches = false;
  private(set) var startUptime = 0.0;
  init(plan: ChallengePlan, failureLatch: QueueFailureLatch) {
    self.plan = plan; self.failureLatch = failureLatch;
    context = OutputCallbackContext(plan: plan, failureLatch: failureLatch)
  };
  func start(uid: String) throws {
    guard queue == nil else { return }; readbackMatches = false; startUptime = 0.0; started = false;
    context.activate(); var description = AudioSupport.format(channels: Policy.physicalOutputChannels); var created: AudioQueueRef?;
    let retainedContext = Unmanaged.passRetained(context);
    let createStatus = AudioQueueNewOutput(
      &description, physicalProbeOutputCallback, retainedContext.toOpaque(), nil, nil, 0, &created);
    failureLatch.record(createStatus);
    guard createStatus == noErr, let created else {
      if createStatus == noErr { failureLatch.recordFailure() }; context.stopAcceptingAndWait();
      retainedContext.release(); throw ProbeError(code: "physical_output_queue_create_failed")
    }; callbackContextRetain = retainedContext; queue = created;
    do {
      let firstReadback = try AudioSupport.pinCurrentDevice(
        uid, queue: created, failureCode: "physical_output_queue_device_set_failed");
      guard firstReadback else {
        throw ProbeError(code: "physical_output_queue_device_readback_mismatch")
      }; let byteCount = UInt32(Policy.bufferFrames * Policy.physicalOutputChannels * MemoryLayout<Int16>.size);
      for _ in 0..<Policy.bufferCount {
        var buffer: AudioQueueBufferRef?;
        let allocationStatus = AudioQueueAllocateBuffer(created, byteCount, &buffer);
        failureLatch.record(allocationStatus);
        guard allocationStatus == noErr, let buffer else {
          if allocationStatus == noErr { failureLatch.recordFailure() };
          throw ProbeError(code: "physical_output_queue_buffer_allocation_failed")
        }; buffers.append(buffer);
        guard context.fill(buffer: buffer) else {
          throw ProbeError(code: "physical_output_queue_buffer_fill_failed")
        }; let enqueueStatus = AudioQueueEnqueueBuffer(created, buffer, 0, nil);
        failureLatch.record(enqueueStatus);
        guard enqueueStatus == noErr else {
          throw ProbeError(code: "physical_output_queue_buffer_enqueue_failed")
        }
      }; let requestedStartUptime = ProcessInfo.processInfo.systemUptime;
      let startStatus = AudioQueueStart(created, nil); failureLatch.record(startStatus);
      guard startStatus == noErr else {
        throw ProbeError(code: "physical_output_queue_start_failed")
      }; started = true; startUptime = requestedStartUptime;
      readbackMatches = firstReadback && AudioSupport.currentDevice(created) == uid;
      guard readbackMatches else {
        throw ProbeError(code: "physical_output_queue_device_readback_mismatch")
      }
    } catch { _ = stop(); throw error }
  };
  func stop() -> Bool {
    guard let queue else { return !teardownFailed }; context.stopAcceptingAndWait();
    var stopStatus: OSStatus = noErr;
    if started {
      stopStatus = AudioQueueStop(queue, true); if stopStatus == noErr { started = false }
    }; context.waitUntilIdle(); let disposeStatus = AudioQueueDispose(queue, true);
    context.waitUntilIdle();
    // AudioQueueDispose is terminal after it returns, regardless of status.
    started = false; self.queue = nil; buffers.removeAll(keepingCapacity: false);
    callbackContextRetain?.release(); callbackContextRetain = nil;
    if stopStatus != noErr || disposeStatus != noErr { teardownFailed = true };
    return !teardownFailed
  }; deinit { _ = stop() }
}
private extension InputQueueSession {
    func currentDeviceMatches(_ uid: String) -> Bool {
        guard let queue else { return false }
        return AudioSupport.currentDevice(queue) == uid
    }
}
private extension OutputQueueSession {
    func currentDeviceMatches(_ uid: String) -> Bool {
        guard let queue else { return false }
        return AudioSupport.currentDevice(queue) == uid
    }
}
private enum CoreAudioReader {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private static let maximumDeviceInventoryBytes = 1_048_576
    private static let maximumStreamConfigurationBytes = 1_048_576

    private static func validDeviceInventoryByteCount(_ byteCount: Int) -> Bool {
        byteCount >= 0
            && byteCount <= maximumDeviceInventoryBytes
            && byteCount.isMultiple(of: MemoryLayout<AudioDeviceID>.stride)
    }

    private static func returnedDeviceCount(
        allocatedByteCount: Int,
        returnedByteCount: Int
    ) -> Int? {
        guard validDeviceInventoryByteCount(allocatedByteCount),
              returnedByteCount >= 0,
              returnedByteCount <= allocatedByteCount,
              returnedByteCount.isMultiple(
                of: MemoryLayout<AudioDeviceID>.stride
              ) else {
            return nil
        }
        return returnedByteCount / MemoryLayout<AudioDeviceID>.stride
    }

    static func allDevices() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            systemObject, &address, 0, nil, &size
        ) == noErr else {
            throw ProbeError(code: "core_audio_device_inventory_failed")
        }
        let deviceStride = MemoryLayout<AudioDeviceID>.stride
        guard validDeviceInventoryByteCount(Int(size)) else {
            throw ProbeError(code: "core_audio_device_inventory_failed")
        }
        let count = Int(size) / deviceStride
        guard count > 0 else { return [] }
        var devices = Array(
            repeating: AudioDeviceID(kAudioObjectUnknown), count: count
        )
        var readSize = size
        let status = devices.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                systemObject, &address, 0, nil, &readSize, bytes.baseAddress!
            )
        }
        guard status == noErr else {
            throw ProbeError(code: "core_audio_device_inventory_failed")
        }
        guard let returnedCount = returnedDeviceCount(
            allocatedByteCount: Int(size),
            returnedByteCount: Int(readSize)
        ) else {
            throw ProbeError(code: "core_audio_device_inventory_failed")
        }
        return devices.prefix(returnedCount).filter {
            $0 != kAudioObjectUnknown
        }
    }

    static func uid(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(
                device, &address, 0, nil, &size, $0
            )
        }
        guard status == noErr, size > 0 else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }

    private static func audioBufferListHeaderSize() throws -> Int {
        guard let headerSize = MemoryLayout<AudioBufferList>.offset(
            of: \AudioBufferList.mBuffers
        ), headerSize >= MemoryLayout<UInt32>.size else {
            throw ProbeError(code: "core_audio_channel_inventory_failed")
        }
        return headerSize
    }

    private static func validStreamConfigurationAllocationSize(
        _ byteCount: Int,
        headerSize: Int
    ) -> Bool {
        byteCount >= headerSize
            && byteCount <= maximumStreamConfigurationBytes
    }

    static func parsedChannelCount(
        _ raw: UnsafeRawPointer,
        allocatedByteCount: Int,
        returnedByteCount: Int
    ) throws -> Int {
        let headerSize = try audioBufferListHeaderSize()
        guard allocatedByteCount >= headerSize,
              returnedByteCount >= headerSize,
              returnedByteCount <= allocatedByteCount else {
            throw ProbeError(code: "core_audio_channel_inventory_failed")
        }
        var numberOfBuffers: UInt32 = 0
        memcpy(&numberOfBuffers, raw, MemoryLayout<UInt32>.size)
        let maximumBufferCount =
            (returnedByteCount - headerSize) / MemoryLayout<AudioBuffer>.stride
        guard UInt64(numberOfBuffers) <= UInt64(maximumBufferCount) else {
            throw ProbeError(code: "core_audio_channel_inventory_failed")
        }

        var channelCount: UInt64 = 0
        for index in 0..<Int(numberOfBuffers) {
            var buffer = AudioBuffer(
                mNumberChannels: 0, mDataByteSize: 0, mData: nil
            )
            memcpy(
                &buffer,
                raw.advanced(
                    by: headerSize + index * MemoryLayout<AudioBuffer>.stride
                ),
                MemoryLayout<AudioBuffer>.size
            )
            channelCount += UInt64(buffer.mNumberChannels)
            guard channelCount <= UInt64(UInt32.max) else {
                throw ProbeError(code: "core_audio_channel_inventory_failed")
            }
        }
        return Int(channelCount)
    }

    static func channelCount(
        _ device: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let headerSize = try audioBufferListHeaderSize()
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            device, &address, 0, nil, &size
        ) == noErr,
        validStreamConfigurationAllocationSize(
            Int(size), headerSize: headerSize
        ) else {
            throw ProbeError(code: "core_audio_channel_inventory_failed")
        }
        let allocationSize = Int(size)
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: allocationSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        raw.initializeMemory(
            as: UInt8.self, repeating: 0, count: allocationSize
        )
        var readSize = size
        guard AudioObjectGetPropertyData(
            device, &address, 0, nil, &readSize, raw
        ) == noErr,
        readSize <= size else {
            throw ProbeError(code: "core_audio_channel_inventory_failed")
        }
        return try parsedChannelCount(
            UnsafeRawPointer(raw),
            allocatedByteCount: allocationSize,
            returnedByteCount: Int(readSize)
        )
    }

    static func channelCountParserSelfTestPasses() -> Bool {
        guard let headerSize = try? audioBufferListHeaderSize() else {
            return false
        }
        let bufferStride = MemoryLayout<AudioBuffer>.stride
        let populatedSize = headerSize + bufferStride
        let storageSize = populatedSize + bufferStride
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: storageSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        func prepare(numberOfBuffers: UInt32, channels: [UInt32]) {
            raw.initializeMemory(
                as: UInt8.self, repeating: 0, count: storageSize
            )
            var count = numberOfBuffers
            memcpy(raw, &count, MemoryLayout<UInt32>.size)
            for (index, channelTotal) in channels.enumerated() {
                var buffer = AudioBuffer(
                    mNumberChannels: channelTotal,
                    mDataByteSize: 0,
                    mData: nil
                )
                memcpy(
                    raw.advanced(by: headerSize + index * bufferStride),
                    &buffer,
                    MemoryLayout<AudioBuffer>.size
                )
            }
        }

        prepare(numberOfBuffers: 0, channels: [7])
        guard (try? parsedChannelCount(
            UnsafeRawPointer(raw),
            allocatedByteCount: headerSize,
            returnedByteCount: headerSize
        )) == 0 else { return false }
        guard (try? parsedChannelCount(
            UnsafeRawPointer(raw),
            allocatedByteCount: populatedSize,
            returnedByteCount: populatedSize
        )) == 0 else { return false }

        prepare(numberOfBuffers: 1, channels: [1])
        guard (try? parsedChannelCount(
            UnsafeRawPointer(raw),
            allocatedByteCount: populatedSize,
            returnedByteCount: populatedSize
        )) == 1 else { return false }

        prepare(numberOfBuffers: 2, channels: [1, 2])
        guard (try? parsedChannelCount(
            UnsafeRawPointer(raw),
            allocatedByteCount: storageSize,
            returnedByteCount: storageSize
        )) == 3 else { return false }

        prepare(numberOfBuffers: 1, channels: [])
        let truncatedBufferRejected = (try? parsedChannelCount(
            UnsafeRawPointer(raw),
            allocatedByteCount: headerSize,
            returnedByteCount: headerSize
        )) == nil
        prepare(numberOfBuffers: 2, channels: [1])
        let truncatedLastBufferRejected = (try? parsedChannelCount(
            UnsafeRawPointer(raw),
            allocatedByteCount: populatedSize,
            returnedByteCount: populatedSize
        )) == nil
        prepare(numberOfBuffers: 2, channels: [1, 2])
        let returnedSizeNotCapacityBoundsCount = (try? parsedChannelCount(
            UnsafeRawPointer(raw),
            allocatedByteCount: storageSize,
            returnedByteCount: populatedSize
        )) == nil
        let partialLastBufferRejected = (try? parsedChannelCount(
            UnsafeRawPointer(raw),
            allocatedByteCount: storageSize,
            returnedByteCount: populatedSize + 1
        )) == nil
        prepare(numberOfBuffers: 2, channels: [UInt32.max, 1])
        let aggregateChannelOverflowRejected = (try? parsedChannelCount(
            UnsafeRawPointer(raw),
            allocatedByteCount: storageSize,
            returnedByteCount: storageSize
        )) == nil
        let shortHeaderRejected = (try? parsedChannelCount(
            UnsafeRawPointer(raw),
            allocatedByteCount: headerSize,
            returnedByteCount: headerSize - 1
        )) == nil
        let oversizedReturnRejected = (try? parsedChannelCount(
            UnsafeRawPointer(raw),
            allocatedByteCount: populatedSize,
            returnedByteCount: populatedSize + 1
        )) == nil
        let allocationCapRetained = validStreamConfigurationAllocationSize(
            maximumStreamConfigurationBytes,
            headerSize: headerSize
        ) && validStreamConfigurationAllocationSize(
            headerSize,
            headerSize: headerSize
        ) && !validStreamConfigurationAllocationSize(
            maximumStreamConfigurationBytes + 1,
            headerSize: headerSize
        ) && !validStreamConfigurationAllocationSize(
            headerSize - 1,
            headerSize: headerSize
        )
        return truncatedBufferRejected
            && truncatedLastBufferRejected
            && returnedSizeNotCapacityBoundsCount
            && partialLastBufferRejected
            && aggregateChannelOverflowRejected
            && shortHeaderRejected
            && oversizedReturnRejected
            && allocationCapRetained
    }

    static func deviceInventorySizeSelfTestPasses() -> Bool {
        let stride = MemoryLayout<AudioDeviceID>.stride
        let maximumAligned = maximumDeviceInventoryBytes
            - maximumDeviceInventoryBytes % stride
        return validDeviceInventoryByteCount(0)
            && validDeviceInventoryByteCount(stride)
            && validDeviceInventoryByteCount(maximumAligned)
            && !validDeviceInventoryByteCount(stride - 1)
            && !validDeviceInventoryByteCount(maximumAligned + stride)
            && returnedDeviceCount(
                allocatedByteCount: 2 * stride,
                returnedByteCount: stride
            ) == 1
            && returnedDeviceCount(
                allocatedByteCount: stride,
                returnedByteCount: 0
            ) == 0
            && returnedDeviceCount(
                allocatedByteCount: stride,
                returnedByteCount: stride + 1
            ) == nil
            && returnedDeviceCount(
                allocatedByteCount: 2 * stride,
                returnedByteCount: stride + 1
            ) == nil
    }

    static func defaultUID(
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            systemObject, &address, 0, nil, &size, &device
        ) == noErr,
        device != kAudioObjectUnknown,
        let uid = uid(device) else {
            throw ProbeError(code: "default_device_snapshot_failed")
        }
        return uid
    }
}
private extension CoreAudioReader {
    static func scalarUInt32(
        _ device: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr,
        size == UInt32(MemoryLayout<UInt32>.size) else {
            throw ProbeError(code: "physical_output_device_metadata_unavailable")
        }
        return value
    }

    static func aggregateSubdeviceUIDs(_ device: AudioDeviceID) throws -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return [] }
        var value: CFArray = [] as CFArray
        var size = UInt32(MemoryLayout<CFArray>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr,
              size == UInt32(MemoryLayout<CFArray>.size) else {
            throw ProbeError(code: "physical_output_subdevice_inventory_failed")
        }
        let objects = value as NSArray
        var identifiers: [String] = []
        identifiers.reserveCapacity(objects.count)
        for object in objects {
            guard let identifier = object as? String, !identifier.isEmpty else {
                throw ProbeError(code: "physical_output_subdevice_inventory_failed")
            }
            identifiers.append(identifier)
        }
        return identifiers
    }

    static func string(
        _ device: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard withUnsafeMutablePointer(to: &value, {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }) == noErr,
        size == UInt32(MemoryLayout<CFString>.size) else {
            throw ProbeError(code: "core_audio_device_identity_unavailable")
        }
        let result = value as String
        guard !result.isEmpty else {
            throw ProbeError(code: "core_audio_device_identity_unavailable")
        }
        return result
    }

    static func identity(_ device: AudioDeviceID) throws -> DeviceIdentity {
        guard let deviceUID = uid(device) else {
            throw ProbeError(code: "core_audio_device_identity_unavailable")
        }
        return DeviceIdentity(
            objectID: device,
            uid: deviceUID,
            objectClass: try scalarUInt32(
                device,
                selector: kAudioObjectPropertyClass
            ),
            transportType: try scalarUInt32(
                device,
                selector: kAudioDevicePropertyTransportType
            ),
            alive: try scalarUInt32(
                device,
                selector: kAudioDevicePropertyDeviceIsAlive
            ) == 1,
            hidden: try scalarUInt32(
                device,
                selector: kAudioDevicePropertyIsHidden
            ) != 0,
            inputChannels: try channelCount(
                device,
                scope: kAudioObjectPropertyScopeInput
            ),
            outputChannels: try channelCount(
                device,
                scope: kAudioObjectPropertyScopeOutput
            ),
            modelUID: try string(
                device,
                selector: kAudioDevicePropertyModelUID
            ),
            clockDomain: try scalarUInt32(
                device,
                selector: kAudioDevicePropertyClockDomain
            ),
            subdeviceUIDs: try aggregateSubdeviceUIDs(device)
        )
    }

    static func defaultTransportClass(
        selector: AudioObjectPropertySelector
    ) throws -> String {
        let defaultDeviceUID = try defaultUID(selector: selector)
        let matches = try allDevices().filter {
            uid($0) == defaultDeviceUID
        }
        guard matches.count == 1 else {
            throw ProbeError(code: "default_device_transport_unavailable")
        }
        let transport = try scalarUInt32(
            matches[0],
            selector: kAudioDevicePropertyTransportType
        )
        switch transport {
        case UInt32(kAudioDeviceTransportTypeBuiltIn):
            return "built-in"
        case UInt32(kAudioDeviceTransportTypeVirtual):
            return "virtual"
        case UInt32(kAudioDeviceTransportTypeAggregate),
             UInt32(kAudioDeviceTransportTypeAutoAggregate):
            return "aggregate"
        case UInt32(kAudioDeviceTransportTypeUSB):
            return "usb"
        case UInt32(kAudioDeviceTransportTypeBluetooth),
             UInt32(kAudioDeviceTransportTypeBluetoothLE):
            return "bluetooth"
        default:
            return "other"
        }
    }
}

private enum PhysicalOutputPolicy {
    static let reviewedOutputUID = "BuiltInSpeakerDevice"

    static func rejectionCode(
        outputUID: String,
        objectClass: UInt32,
        transportType: UInt32,
        subdeviceUIDs: [String]
    ) -> String? {
        guard outputUID == reviewedOutputUID else {
            return "physical_output_uid_not_reviewed_builtin_speaker"
        }
        guard objectClass == UInt32(kAudioDeviceClassID) else {
            return "physical_output_device_class_rejected"
        }
        guard subdeviceUIDs.isEmpty else {
            return "physical_output_composite_device_rejected"
        }
        guard transportType == UInt32(kAudioDeviceTransportTypeBuiltIn) else {
            return "physical_output_transport_rejected"
        }
        return nil
    }

    static func selfTestPasses() -> Bool {
        let builtIn = UInt32(kAudioDeviceTransportTypeBuiltIn)
        let device = UInt32(kAudioDeviceClassID)
        return rejectionCode(
            outputUID: reviewedOutputUID,
            objectClass: device,
            transportType: builtIn,
            subdeviceUIDs: []
        ) == nil
            && rejectionCode(
                outputUID: "USB-speaker",
                objectClass: device,
                transportType: UInt32(kAudioDeviceTransportTypeUSB),
                subdeviceUIDs: []
            ) == "physical_output_uid_not_reviewed_builtin_speaker"
            && rejectionCode(
                outputUID: reviewedOutputUID,
                objectClass: device,
                transportType: UInt32(kAudioDeviceTransportTypeVirtual),
                subdeviceUIDs: []
            ) == "physical_output_transport_rejected"
            && rejectionCode(
                outputUID: reviewedOutputUID,
                objectClass: UInt32(kAudioAggregateDeviceClassID),
                transportType: UInt32(kAudioDeviceTransportTypeAggregate),
                subdeviceUIDs: [Policy.captureUID]
            ) == "physical_output_device_class_rejected"
            && rejectionCode(
                outputUID: reviewedOutputUID,
                objectClass: device,
                transportType: UInt32(kAudioDeviceTransportTypeUnknown),
                subdeviceUIDs: []
            ) == "physical_output_transport_rejected"
    }
}

private struct DeviceIdentity: Equatable {
    let objectID: AudioDeviceID
    let uid: String
    let objectClass: UInt32
    let transportType: UInt32
    let alive: Bool
    let hidden: Bool
    let inputChannels: Int
    let outputChannels: Int
    let modelUID: String
    let clockDomain: UInt32
    let subdeviceUIDs: [String]
}

private struct DeviceValidation {
    let captureIdentity: DeviceIdentity
    let outputIdentity: DeviceIdentity
}

private enum DeviceResolver {
    static func validate(
        physicalOutputUID: String
    ) throws -> DeviceValidation {
        guard physicalOutputUID == PhysicalOutputPolicy.reviewedOutputUID else {
            throw ProbeError(code: "physical_output_uid_rejected")
        }
        let devices = try CoreAudioReader.allDevices()
        let captureMatches = devices.filter {
            CoreAudioReader.uid($0) == Policy.captureUID
        }
        guard captureMatches.count == 1 else {
            throw ProbeError(code: "canonical_capture_device_not_found")
        }
        let captureIdentity = try CoreAudioReader.identity(captureMatches[0])
        guard captureIdentity.objectClass == UInt32(kAudioDeviceClassID),
              captureIdentity.alive,
              !captureIdentity.hidden,
              captureIdentity.inputChannels == Policy.captureChannels,
              captureIdentity.outputChannels == 0,
              captureIdentity.modelUID == Policy.modelUID,
              captureIdentity.clockDomain == Policy.clockDomain else {
            throw ProbeError(code: "canonical_capture_device_has_no_usable_input")
        }
        let outputMatches = devices.filter {
            CoreAudioReader.uid($0) == physicalOutputUID
        }
        guard outputMatches.count == 1 else {
            throw ProbeError(code: "physical_output_device_not_found")
        }
        let outputIdentity = try CoreAudioReader.identity(outputMatches[0])
        guard outputIdentity.alive,
              outputIdentity.outputChannels
                >= Policy.physicalOutputChannels else {
            throw ProbeError(code: "physical_output_device_has_no_usable_output")
        }
        if let rejection = PhysicalOutputPolicy.rejectionCode(
            outputUID: physicalOutputUID,
            objectClass: outputIdentity.objectClass,
            transportType: outputIdentity.transportType,
            subdeviceUIDs: outputIdentity.subdeviceUIDs
        ) {
            throw ProbeError(code: rejection)
        }
        return DeviceValidation(
            captureIdentity: captureIdentity,
            outputIdentity: outputIdentity
        )
    }
}
private struct DefaultSnapshot: Equatable { let inputUID: String; let outputUID: String; let systemOutputUID: String }
private enum DefaultRouteSafety {
    static func failureCode(_ snapshot: DefaultSnapshot) -> String? {
        switch snapshot.outputUID {
        case Policy.captureUID:
            return "default_output_is_virtual_microphone_input"
        case Policy.hiddenMirrorUID:
            return "default_output_is_virtual_microphone_writer"
        case Policy.legacyVisibleUID:
            return "default_output_is_legacy_blackhole_visible"
        case Policy.legacyHiddenUID:
            return "default_output_is_legacy_blackhole_hidden"
        default:
            break
        }
        switch snapshot.systemOutputUID {
        case Policy.captureUID:
            return "default_system_output_is_virtual_microphone_input"
        case Policy.hiddenMirrorUID:
            return "default_system_output_is_virtual_microphone_writer"
        case Policy.legacyVisibleUID:
            return "default_system_output_is_legacy_blackhole_visible"
        case Policy.legacyHiddenUID:
            return "default_system_output_is_legacy_blackhole_hidden"
        default:
            return nil
        }
    }
}
private final class DefaultDeviceListenerContext: @unchecked Sendable { private let lock = NSLock(); private var notificationTotal = 0; func recordNotification(_ count: Int) { lock.lock(); notificationTotal = min(1_000_000, notificationTotal + max(1, count)); lock.unlock() }; func notificationCount() -> Int { lock.lock(); defer { lock.unlock() }; return notificationTotal } }
private final class DefaultDeviceGuard: @unchecked Sendable { private let listenerContext = DefaultDeviceListenerContext(); private let listenerQueue = DispatchQueue(label: "opensteamer.physical-blackhole-microphone.default-device-listener"); private var listenerBlock: AudioObjectPropertyListenerBlock?; private var addresses: [AudioObjectPropertyAddress] = []; private var installed = false; func install() throws { guard !installed, listenerBlock == nil else { return }; let context = listenerContext; let block: AudioObjectPropertyListenerBlock = { [context] addressCount, _ in context.recordNotification(Int(addressCount)) }; listenerBlock = block; installed = true; for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] { var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain); let status = AudioObjectAddPropertyListenerBlock(CoreAudioReader.systemObject, &address, listenerQueue, block); guard status == noErr else { _ = remove(); throw ProbeError(code: "default_device_listener_install_failed") }; addresses.append(address) } }; func snapshot() throws -> DefaultSnapshot { DefaultSnapshot(inputUID: try CoreAudioReader.defaultUID(selector: kAudioHardwarePropertyDefaultInputDevice), outputUID: try CoreAudioReader.defaultUID(selector: kAudioHardwarePropertyDefaultOutputDevice), systemOutputUID: try CoreAudioReader.defaultUID(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)) }; func notificationCount() -> Int { listenerContext.notificationCount() }; func remove() -> Bool { guard installed || !addresses.isEmpty || listenerBlock != nil else { return true }; guard let block = listenerBlock else { return false }; var remaining: [AudioObjectPropertyAddress] = []; remaining.reserveCapacity(addresses.count); for stored in addresses { var address = stored; let status = AudioObjectRemovePropertyListenerBlock(CoreAudioReader.systemObject, &address, listenerQueue, block); if status != noErr { remaining.append(stored) } }; listenerQueue.sync {}; addresses = remaining; installed = !addresses.isEmpty; if !installed { listenerBlock = nil }; return !installed }; deinit { _ = remove() } }
private struct RouteContinuityObservation {
    let inputQueueMatches: Bool
    let outputQueueMatches: Bool
    let defaults: DefaultSnapshot
    let defaultNotificationCount: Int
    let devices: DeviceValidation
}
private enum RouteContinuityValidator {
    static func failureCode(
        expectedDevices: DeviceValidation,
        inputSession: InputQueueSession,
        outputSession: OutputQueueSession,
        defaultGuard: DefaultDeviceGuard,
        expectedDefaults: DefaultSnapshot
    ) -> String? {
        guard inputSession.currentDeviceMatches(Policy.captureUID),
              outputSession.currentDeviceMatches(
                PhysicalOutputPolicy.reviewedOutputUID
              ) else {
            return "queue_device_changed_during_proof"
        }
        do {
            let currentDefaults = try defaultGuard.snapshot()
            let currentDevices = try DeviceResolver.validate(
                physicalOutputUID:
                    PhysicalOutputPolicy.reviewedOutputUID
            )
            return failureCode(
                expectedDevices: expectedDevices,
                expectedDefaults: expectedDefaults,
                observation: RouteContinuityObservation(
                    inputQueueMatches: true,
                    outputQueueMatches: true,
                    defaults: currentDefaults,
                    defaultNotificationCount:
                        defaultGuard.notificationCount(),
                    devices: currentDevices
                )
            )
        } catch {
            return "route_identity_changed_during_proof"
        }
    }

    /// Shared by the live probe and deterministic fake sequences. Keeping policy here means the
    /// self-test exercises the production decision path rather than manufacturing a failure code.
    static func failureCode(
        expectedDevices: DeviceValidation,
        expectedDefaults: DefaultSnapshot,
        observation: RouteContinuityObservation
    ) -> String? {
        guard observation.inputQueueMatches,
              observation.outputQueueMatches else {
            return "queue_device_changed_during_proof"
        }
        if let unsafeDefault = DefaultRouteSafety.failureCode(
            observation.defaults
        ) {
            return unsafeDefault
        }
        guard observation.defaults == expectedDefaults else {
            return "default_route_changed_during_proof"
        }
        guard observation.defaultNotificationCount == 0 else {
            return "default_change_notification_observed"
        }
        guard observation.devices.captureIdentity
                == expectedDevices.captureIdentity,
              observation.devices.outputIdentity
                == expectedDevices.outputIdentity else {
            return "route_identity_changed_during_proof"
        }
        return nil
    }
}
private enum SyntheticRouteMutation: Equatable {
    case identity
    case defaultOutputCanonicalBlackHole
    case defaultOutputHiddenMirrorBlackHole
    case defaultSystemOutputCanonicalBlackHole
    case defaultSystemOutputHiddenMirrorBlackHole
    case defaultOutputLegacyBlackHoleVisible
    case defaultOutputLegacyBlackHoleHidden
    case defaultSystemOutputLegacyBlackHoleVisible
    case defaultSystemOutputLegacyBlackHoleHidden

    var expectedFailureCode: String {
        switch self {
        case .identity:
            return "route_identity_changed_during_proof"
        case .defaultOutputCanonicalBlackHole:
            return "default_output_is_virtual_microphone_input"
        case .defaultOutputHiddenMirrorBlackHole:
            return "default_output_is_virtual_microphone_writer"
        case .defaultSystemOutputCanonicalBlackHole:
            return "default_system_output_is_virtual_microphone_input"
        case .defaultSystemOutputHiddenMirrorBlackHole:
            return "default_system_output_is_virtual_microphone_writer"
        case .defaultOutputLegacyBlackHoleVisible:
            return "default_output_is_legacy_blackhole_visible"
        case .defaultOutputLegacyBlackHoleHidden:
            return "default_output_is_legacy_blackhole_hidden"
        case .defaultSystemOutputLegacyBlackHoleVisible:
            return "default_system_output_is_legacy_blackhole_visible"
        case .defaultSystemOutputLegacyBlackHoleHidden:
            return "default_system_output_is_legacy_blackhole_hidden"
        }
    }
}
private enum RouteContinuitySelfTest {
    static func failureCode(
        for mutation: SyntheticRouteMutation
    ) -> String {
        let capture = DeviceIdentity(
            objectID: 101,
            uid: Policy.captureUID,
            objectClass: UInt32(kAudioDeviceClassID),
            transportType: UInt32(kAudioDeviceTransportTypeVirtual),
            alive: true,
            hidden: false,
            inputChannels: Policy.captureChannels,
            outputChannels: 0,
            modelUID: Policy.modelUID,
            clockDomain: Policy.clockDomain,
            subdeviceUIDs: []
        )
        let output = DeviceIdentity(
            objectID: 202,
            uid: PhysicalOutputPolicy.reviewedOutputUID,
            objectClass: UInt32(kAudioDeviceClassID),
            transportType: UInt32(kAudioDeviceTransportTypeBuiltIn),
            alive: true,
            hidden: false,
            inputChannels: 0,
            outputChannels: Policy.physicalOutputChannels,
            modelUID: "built-in-speaker-model",
            clockDomain: 0,
            subdeviceUIDs: []
        )
        let expectedDevices = DeviceValidation(
            captureIdentity: capture,
            outputIdentity: output
        )
        let safeDefaults = DefaultSnapshot(
            inputUID: "BuiltInMicrophoneDevice",
            outputUID: PhysicalOutputPolicy.reviewedOutputUID,
            systemOutputUID: PhysicalOutputPolicy.reviewedOutputUID
        )
        let healthy = RouteContinuityObservation(
            inputQueueMatches: true,
            outputQueueMatches: true,
            defaults: safeDefaults,
            defaultNotificationCount: 0,
            devices: expectedDevices
        )

        var mutatedDefaults = safeDefaults
        var mutatedDevices = expectedDevices
        switch mutation {
        case .identity:
            mutatedDevices = DeviceValidation(
                captureIdentity: DeviceIdentity(
                    objectID: capture.objectID + 1,
                    uid: capture.uid,
                    objectClass: capture.objectClass,
                    transportType: capture.transportType,
                    alive: capture.alive,
                    hidden: capture.hidden,
                    inputChannels: capture.inputChannels,
                    outputChannels: capture.outputChannels,
                    modelUID: capture.modelUID,
                    clockDomain: capture.clockDomain,
                    subdeviceUIDs: capture.subdeviceUIDs
                ),
                outputIdentity: output
            )
        case .defaultOutputCanonicalBlackHole:
            mutatedDefaults = DefaultSnapshot(
                inputUID: safeDefaults.inputUID,
                outputUID: Policy.captureUID,
                systemOutputUID: safeDefaults.systemOutputUID
            )
        case .defaultOutputHiddenMirrorBlackHole:
            mutatedDefaults = DefaultSnapshot(
                inputUID: safeDefaults.inputUID,
                outputUID: Policy.hiddenMirrorUID,
                systemOutputUID: safeDefaults.systemOutputUID
            )
        case .defaultSystemOutputCanonicalBlackHole:
            mutatedDefaults = DefaultSnapshot(
                inputUID: safeDefaults.inputUID,
                outputUID: safeDefaults.outputUID,
                systemOutputUID: Policy.captureUID
            )
        case .defaultSystemOutputHiddenMirrorBlackHole:
            mutatedDefaults = DefaultSnapshot(
                inputUID: safeDefaults.inputUID,
                outputUID: safeDefaults.outputUID,
                systemOutputUID: Policy.hiddenMirrorUID
            )
        case .defaultOutputLegacyBlackHoleVisible:
            mutatedDefaults = DefaultSnapshot(
                inputUID: safeDefaults.inputUID,
                outputUID: Policy.legacyVisibleUID,
                systemOutputUID: safeDefaults.systemOutputUID
            )
        case .defaultOutputLegacyBlackHoleHidden:
            mutatedDefaults = DefaultSnapshot(
                inputUID: safeDefaults.inputUID,
                outputUID: Policy.legacyHiddenUID,
                systemOutputUID: safeDefaults.systemOutputUID
            )
        case .defaultSystemOutputLegacyBlackHoleVisible:
            mutatedDefaults = DefaultSnapshot(
                inputUID: safeDefaults.inputUID,
                outputUID: safeDefaults.outputUID,
                systemOutputUID: Policy.legacyVisibleUID
            )
        case .defaultSystemOutputLegacyBlackHoleHidden:
            mutatedDefaults = DefaultSnapshot(
                inputUID: safeDefaults.inputUID,
                outputUID: safeDefaults.outputUID,
                systemOutputUID: Policy.legacyHiddenUID
            )
        }

        let expectedFailure = mutation.expectedFailureCode
        if mutation != .identity,
           DefaultRouteSafety.failureCode(mutatedDefaults)
                != expectedFailure {
            return "default_route_safety_self_test_failed"
        }
        let sequence = [
            healthy,
            RouteContinuityObservation(
                inputQueueMatches: true,
                outputQueueMatches: true,
                defaults: mutatedDefaults,
                defaultNotificationCount: 0,
                devices: mutatedDevices
            ),
        ]
        var observedFailure: String?
        for observation in sequence {
            if let failure = RouteContinuityValidator.failureCode(
                expectedDevices: expectedDevices,
                expectedDefaults: safeDefaults,
                observation: observation
            ) {
                observedFailure = failure
                break
            }
        }
        guard observedFailure == expectedFailure else {
            return "route_continuity_self_test_failed"
        }
        return expectedFailure
    }
}
private struct RouteEvidence { var captureUIDMatches: Bool; var physicalOutputValidated: Bool; var challengeNonceMatches: Bool; var captureQueueReadbackMatches: Bool; var physicalOutputQueueReadbackMatches: Bool; var defaultInputEqual: Bool; var defaultOutputEqual: Bool; var defaultSystemOutputEqual: Bool; var defaultNotificationCount: Int }
private struct SignalStats { let rms: Double; let peak: Int; let clippedRatio: Double; let nonSilentRatio: Double }
private struct SignalSummary { let channels: [SignalStats]; let nonSilentFrameRatio: Double; let clippedRatio: Double; let longestSilentGapMs: Double }
private struct SpectralObservation { let centerSeconds: Double; let powers: [[Double]]; let rms: [Double] }
private struct SymbolAccumulator { var powers = Array(repeating: 0.0, count: Policy.frequencies.count); var rmsSum = 0.0; var count = 0 }
private struct ChannelDetection { let channel: Int; let symbolCount: Int; let matchedSymbolCount: Int; let matchRatio: Double; let normalizedCorrelation: Double; let discriminationMargin: Double; let envelopeCorrelation: Double; let lagSeconds: Double; let score: Double; static func zero(channel: Int) -> ChannelDetection { ChannelDetection(channel: channel, symbolCount: 0, matchedSymbolCount: 0, matchRatio: 0, normalizedCorrelation: 0, discriminationMargin: 0, envelopeCorrelation: 0, lagSeconds: -1, score: 0) } }
private enum Evaluator {}
private extension Evaluator { static func summarizeSignal(_ samples: [Int16]) -> SignalSummary { let frameCount = samples.count / Policy.captureChannels; var squareSums = Array(repeating: 0.0, count: Policy.captureChannels); var peaks = Array(repeating: 0, count: Policy.captureChannels); var clipped = Array(repeating: 0, count: Policy.captureChannels); var nonSilent = Array(repeating: 0, count: Policy.captureChannels); var nonSilentFrames = 0; var currentSilentRun = 0; var longestSilentRun = 0; if frameCount > 0 { for frame in 0..<frameCount { var frameNonSilent = false; for channel in 0..<Policy.captureChannels { let sample = samples[frame * Policy.captureChannels + channel]; let magnitude = Int(abs(Int32(sample))); squareSums[channel] += Double(sample) * Double(sample); peaks[channel] = max(peaks[channel], magnitude); if magnitude >= Policy.clippedMagnitude { clipped[channel] += 1 }; if magnitude >= Policy.nonSilentThreshold { nonSilent[channel] += 1; frameNonSilent = true } }; if frameNonSilent { nonSilentFrames += 1; longestSilentRun = max(longestSilentRun, currentSilentRun); currentSilentRun = 0 } else { currentSilentRun += 1 } }; longestSilentRun = max(longestSilentRun, currentSilentRun) }; let channels = (0..<Policy.captureChannels).map { channel in SignalStats(rms: frameCount > 0 ? sqrt(squareSums[channel] / Double(frameCount)) : 0, peak: peaks[channel], clippedRatio: frameCount > 0 ? Double(clipped[channel]) / Double(frameCount) : 0, nonSilentRatio: frameCount > 0 ? Double(nonSilent[channel]) / Double(frameCount) : 0) }; let clippedTotal = clipped.reduce(0, +); return SignalSummary(channels: channels, nonSilentFrameRatio: frameCount > 0 ? Double(nonSilentFrames) / Double(frameCount) : 0, clippedRatio: frameCount > 0 ? Double(clippedTotal) / Double(frameCount * Policy.captureChannels) : 0, longestSilentGapMs: Double(longestSilentRun) * 1_000.0 / Policy.sampleRate) }; static func maximumCallbackGapMs(_ window: EvaluationWindow) -> Double { let times = window.callbackEndTimes.sorted(); guard !times.isEmpty else { return max(0, window.endUptime - window.startUptime) * 1_000.0 }; var previous = window.startUptime; var maximumGap = 0.0; for raw in times { let time = min(window.endUptime, max(window.startUptime, raw)); maximumGap = max(maximumGap, time - previous); previous = max(previous, time) }; maximumGap = max(maximumGap, window.endUptime - previous); return maximumGap * 1_000.0 }; static func progressEvidence(_ window: EvaluationWindow) -> ([ProgressEvidence], Int) { let observations = window.progress.sorted { $0.uptime < $1.uptime }; var records: [ProgressEvidence] = []; var advancingCount = 0; var previous: ProgressObservation?; for observation in observations { let callbackDelta: UInt64; let frameDelta: UInt64; if let previous { callbackDelta = observation.callbackCount >= previous.callbackCount ? observation.callbackCount - previous.callbackCount : 0; frameDelta = observation.capturedFrameCount >= previous.capturedFrameCount ? observation.capturedFrameCount - previous.capturedFrameCount : 0 } else { callbackDelta = 0; frameDelta = 0 }; let advancing = callbackDelta > 0 && frameDelta > 0; if advancing { advancingCount += 1 }; records.append(ProgressEvidence(elapsedSeconds: min(Policy.proofSeconds, max(0, observation.uptime - window.startUptime)), callbackCount: observation.callbackCount, capturedFrameCount: observation.capturedFrameCount, callbackDelta: callbackDelta, frameDelta: frameDelta, advancing: advancing)); previous = observation }; if records.count > Policy.maximumProgressRecords, let first = records.first { records = [first] + Array(records.suffix(Policy.maximumProgressRecords - 1)) }; return (records, advancingCount) } }
private extension Evaluator { static func spectralObservations(_ samples: [Int16]) -> [SpectralObservation] { let frameCount = samples.count / Policy.captureChannels; guard frameCount >= Policy.analysisBlockFrames else { return [] }; let block = Policy.analysisBlockFrames; let window = (0..<block).map { 0.5 - 0.5 * cos(2.0 * Double.pi * Double($0) / Double(block - 1)) }; let coefficients = Policy.frequencies.map { 2.0 * cos(2.0 * Double.pi * $0 / Policy.sampleRate) }; var observations: [SpectralObservation] = []; for start in stride(from: 0, through: frameCount - block, by: Policy.analysisHopFrames) { var channelPowers = Array(repeating: Array(repeating: 0.0, count: Policy.frequencies.count), count: Policy.captureChannels); var channelRMS = Array(repeating: 0.0, count: Policy.captureChannels); for channel in 0..<Policy.captureChannels { var squareSum = 0.0; for index in 0..<block { let sample = Double(samples[(start + index) * Policy.captureChannels + channel]); squareSum += sample * sample }; channelRMS[channel] = sqrt(squareSum / Double(block)); for frequencyIndex in 0..<Policy.frequencies.count { let coefficient = coefficients[frequencyIndex]; var q1 = 0.0; var q2 = 0.0; for index in 0..<block { let input = Double(samples[(start + index) * Policy.captureChannels + channel]) * window[index] / 32_768.0; let q0 = input + coefficient * q1 - q2; q2 = q1; q1 = q0 }; channelPowers[channel][frequencyIndex] = max(0, q1 * q1 + q2 * q2 - coefficient * q1 * q2) } }; observations.append(SpectralObservation(centerSeconds: Double(start + block / 2) / Policy.sampleRate, powers: channelPowers, rms: channelRMS)) }; return observations } }
private extension Evaluator { static func pearson(_ first: [Double], _ second: [Double]) -> Double { guard first.count == second.count, first.count >= 3 else { return 0 }; let firstMean = first.reduce(0, +) / Double(first.count); let secondMean = second.reduce(0, +) / Double(second.count); var numerator = 0.0; var firstEnergy = 0.0; var secondEnergy = 0.0; for index in first.indices { let a = first[index] - firstMean; let b = second[index] - secondMean; numerator += a * b; firstEnergy += a * a; secondEnergy += b * b }; let denominator = sqrt(firstEnergy * secondEnergy); return denominator > 1.0e-12 ? max(-1, min(1, numerator / denominator)) : 0 }; static func detect(channel: Int, observations: [SpectralObservation], plan: ChallengePlan, relativeWindowStart: Double) -> ChannelDetection { var best: ChannelDetection?; let stepCount = Int(floor((Policy.maximumLagSeconds - Policy.minimumLagSeconds) / Policy.lagStepSeconds)); for step in 0...stepCount { let lag = Policy.minimumLagSeconds + Double(step) * Policy.lagStepSeconds; var groups: [Int: SymbolAccumulator] = [:]; for observation in observations { let challengeTime = relativeWindowStart + observation.centerSeconds - lag; guard challengeTime >= 0 else { continue }; let symbolIndex = Int(floor(challengeTime / Policy.symbolSeconds)); guard symbolIndex >= 0, symbolIndex < plan.symbols.count else { continue }; let phase = challengeTime - Double(symbolIndex) * Policy.symbolSeconds; guard phase >= Policy.analysisEdgeGuardSeconds, phase <= Policy.symbolSeconds - Policy.analysisEdgeGuardSeconds, observation.powers.count > channel else { continue }; var accumulator = groups[symbolIndex] ?? SymbolAccumulator(); for frequencyIndex in 0..<Policy.frequencies.count { accumulator.powers[frequencyIndex] += observation.powers[channel][frequencyIndex] }; accumulator.rmsSum += observation.rms[channel]; accumulator.count += 1; groups[symbolIndex] = accumulator }; guard groups.count >= Policy.minimumCandidateSymbols else { continue }; let indices = groups.keys.sorted(); var matches = 0; var correlationSum = 0.0; var marginSum = 0.0; var expectedEnvelope: [Double] = []; var observedEnvelope: [Double] = []; for symbolIndex in indices { guard let accumulator = groups[symbolIndex], accumulator.count > 0 else { continue }; let expectedFrequency = plan.symbols[symbolIndex].frequencyIndex; var winner = 0; for frequencyIndex in 1..<accumulator.powers.count where accumulator.powers[frequencyIndex] > accumulator.powers[winner] { winner = frequencyIndex }; if winner == expectedFrequency { matches += 1 }; let expectedPower = accumulator.powers[expectedFrequency]; var alternativePower = 0.0; for frequencyIndex in 0..<accumulator.powers.count where frequencyIndex != expectedFrequency { alternativePower = max(alternativePower, accumulator.powers[frequencyIndex]) }; let denominator = max(1.0e-18, expectedPower + alternativePower); correlationSum += expectedPower / denominator; marginSum += (expectedPower - alternativePower) / denominator; expectedEnvelope.append(log(Policy.outputAmplitudes[plan.symbols[symbolIndex].amplitudeIndex])); observedEnvelope.append(log(max(1.0, accumulator.rmsSum / Double(accumulator.count)))) }; let symbolCount = indices.count; let matchRatio = Double(matches) / Double(symbolCount); let normalizedCorrelation = correlationSum / Double(symbolCount); let discriminationMargin = marginSum / Double(symbolCount); let envelopeCorrelation = pearson(expectedEnvelope, observedEnvelope); let score = matchRatio + 0.25 * max(0, discriminationMargin) + 0.10 * normalizedCorrelation + 0.02 * max(0, envelopeCorrelation); let candidate = ChannelDetection(channel: channel, symbolCount: symbolCount, matchedSymbolCount: matches, matchRatio: matchRatio, normalizedCorrelation: normalizedCorrelation, discriminationMargin: discriminationMargin, envelopeCorrelation: envelopeCorrelation, lagSeconds: lag, score: score); if best == nil || candidate.score > best!.score || (abs(candidate.score - best!.score) < 1.0e-9 && candidate.lagSeconds < best!.lagSeconds) { best = candidate } }; return best ?? .zero(channel: channel) } }
private extension Evaluator { static func evaluate(runNonce: String, plan: ChallengePlan, challengeStartUptime: Double, window: EvaluationWindow, route: RouteEvidence, forcedFailures: [String]) -> ProbeResult { let frameCount = window.samples.count / Policy.captureChannels; let captureSeconds = Double(frameCount) / Policy.sampleRate; let frameDensity = Double(frameCount) / (Policy.proofSeconds * Policy.sampleRate); let signal = summarizeSignal(window.samples); let maxCallbackGapMs = maximumCallbackGapMs(window); let progress = progressEvidence(window); let spectral = spectralObservations(window.samples); let relativeWindowStart = window.startUptime - challengeStartUptime; let detections = (0..<Policy.captureChannels).map { detect(channel: $0, observations: spectral, plan: plan, relativeWindowStart: relativeWindowStart) }; let best = detections.max { $0.score < $1.score } ?? .zero(channel: 0); let channelEvidence = (0..<Policy.captureChannels).map { channel in let stats = signal.channels[channel]; let detection = detections[channel]; return ChannelEvidence(channel: channel, rms: stats.rms, peak: stats.peak, clippedRatio: stats.clippedRatio, nonSilentRatio: stats.nonSilentRatio, challengeSymbolCount: detection.symbolCount, matchedSymbolCount: detection.matchedSymbolCount, matchRatio: detection.matchRatio, normalizedCorrelation: detection.normalizedCorrelation, discriminationMargin: detection.discriminationMargin, envelopeCorrelation: detection.envelopeCorrelation) }; let bestStats = signal.channels[best.channel]; let recognizedChannel = best.symbolCount > 0 && bestStats.peak >= Policy.minimumPeak && bestStats.nonSilentRatio >= Policy.minimumNonSilentRatio ? best.channel : -1; let aggregatePeak = signal.channels.map(\.peak).max() ?? 0; var reasons: [String] = []; func add(_ code: String) { if reasons.count < Policy.maximumFailureReasons, !reasons.contains(code) { reasons.append(code) } }; for failure in forcedFailures { add(failure) }; if !route.captureUIDMatches { add("capture_uid_mismatch") }; if !route.physicalOutputValidated { add("physical_output_not_validated") }; if !route.challengeNonceMatches || runNonce != plan.nonce { add("stale_or_mismatched_nonce") }; if !route.captureQueueReadbackMatches || !route.physicalOutputQueueReadbackMatches { add("queue_device_readback_mismatch") }; if frameDensity < Policy.minimumFrameDensity || frameDensity > Policy.maximumFrameDensity { add("frame_density_out_of_range") }; if progress.1 < 2 { add("insufficient_progress_observations") }; if maxCallbackGapMs > Policy.maximumCallbackGapMs { add("callback_or_timestamp_stall") }; if signal.longestSilentGapMs > Policy.maximumSilentGapMs { add("long_non_silent_gap") }; if signal.nonSilentFrameRatio < Policy.minimumNonSilentRatio { add("near_silence") }; if aggregatePeak < Policy.minimumPeak { add("peak_too_low") }; if aggregatePeak >= Policy.clippedMagnitude { add("peak_too_high") }; if signal.clippedRatio >= Policy.maximumClippedRatio { add("clipped_pcm") }; if recognizedChannel < 0 { add("no_recognized_channel") }; if best.symbolCount < Policy.minimumSymbols { add("insufficient_challenge_symbols") }; if best.matchRatio < Policy.minimumMatchRatio { add("challenge_symbol_match_low") }; if best.normalizedCorrelation < Policy.minimumNormalizedCorrelation { add("challenge_correlation_low") }; if best.discriminationMargin < Policy.minimumDiscriminationMargin { add("challenge_discrimination_low") }; if !route.defaultInputEqual { add("default_input_changed") }; if !route.defaultOutputEqual { add("default_output_changed") }; if !route.defaultSystemOutputEqual { add("default_system_output_changed") }; if route.defaultNotificationCount != 0 { add("default_change_notification_observed") }; let status = reasons.isEmpty ? "passed" : "failed"; return ProbeResult(schema: Policy.schema, status: status, runNonce: runNonce, challengeAlgorithm: Policy.algorithm, challengeVersion: Policy.algorithmVersion, canonicalCaptureUID: Policy.captureUID, captureUIDMatches: route.captureUIDMatches, physicalOutputValidated: route.physicalOutputValidated, challengeNonceMatches: route.challengeNonceMatches && runNonce == plan.nonce, queueReadbackMatches: route.captureQueueReadbackMatches && route.physicalOutputQueueReadbackMatches, captureQueueReadbackMatches: route.captureQueueReadbackMatches, physicalOutputQueueReadbackMatches: route.physicalOutputQueueReadbackMatches, format: AudioFormatEvidence(sampleRate: Policy.sampleRateInt, channels: Policy.captureChannels, signedInt16: true, interleaved: true), proofWindowSeconds: Policy.proofSeconds, captureSeconds: captureSeconds, callbackCount: UInt64(window.callbackEndTimes.count), capturedFrameCount: UInt64(frameCount), totalCallbackCount: window.totalCallbackCount, totalCapturedFrameCount: window.totalCapturedFrameCount, frameDensity: frameDensity, maxCallbackGapMs: maxCallbackGapMs, longestNonSilentGapMs: signal.longestSilentGapMs, nonSilentFrameRatio: signal.nonSilentFrameRatio, aggregateClippedRatio: signal.clippedRatio, progressObservationCount: window.progress.count, advancingProgressObservationCount: progress.1, progressSnapshots: progress.0, channels: channelEvidence, recognizedChannel: recognizedChannel, symbolCount: best.symbolCount, matchedSymbolCount: best.matchedSymbolCount, matchRatio: best.matchRatio, normalizedCorrelation: best.normalizedCorrelation, discriminationMargin: best.discriminationMargin, envelopeCorrelation: best.envelopeCorrelation, detectedLagMs: best.lagSeconds >= 0 ? best.lagSeconds * 1_000.0 : -1, defaultInputBeforeAfterEqual: route.defaultInputEqual, defaultOutputBeforeAfterEqual: route.defaultOutputEqual, defaultSystemOutputBeforeAfterEqual: route.defaultSystemOutputEqual, defaultChangeNotificationCount: max(0, route.defaultNotificationCount), failureCode: reasons.first ?? "none", failureReasons: reasons) } }
private enum SyntheticCase: Equatable {
    case healthy, allZero, nearSilent, wrongNonce, unrelatedPattern
    case repeatedSymbol, insufficientFrames, longStall, clippedPCM
    case badPrefixHealthyTail, wrongCaptureUID, wrongReadback
    case defaultChanged, defaultsRestoredNotification, staleNonce
    case tooFewProgress, outputGenerator, physicalOutputPolicy
    case routeMutation, digitalDelayedLoop
    case defaultOutputCanonicalBlackHole
    case defaultOutputHiddenMirrorBlackHole
    case defaultSystemOutputCanonicalBlackHole
    case defaultSystemOutputHiddenMirrorBlackHole
    case defaultOutputLegacyBlackHoleVisible
    case defaultOutputLegacyBlackHoleHidden
    case defaultSystemOutputLegacyBlackHoleVisible
    case defaultSystemOutputLegacyBlackHoleHidden

    static func parse(_ value: String) -> SyntheticCase? {
        switch value {
        case "healthy": return .healthy
        case "all-zero": return .allZero
        case "near-silent", "all-zero-near-silent": return .nearSilent
        case "wrong-nonce": return .wrongNonce
        case "unrelated-pattern": return .unrelatedPattern
        case "repeated-symbol", "frozen-symbol": return .repeatedSymbol
        case "insufficient-frames": return .insufficientFrames
        case "long-stall", "long-callback-stall": return .longStall
        case "clipped-pcm": return .clippedPCM
        case "bad-prefix-healthy-tail": return .badPrefixHealthyTail
        case "wrong-capture-uid": return .wrongCaptureUID
        case "wrong-readback", "wrong-capture-uid-readback": return .wrongReadback
        case "default-changed": return .defaultChanged
        case "defaults-restored-notification": return .defaultsRestoredNotification
        case "stale-nonce", "mismatched-nonce": return .staleNonce
        case "too-few-progress": return .tooFewProgress
        case "output-generator": return .outputGenerator
        case "physical-output-policy": return .physicalOutputPolicy
        case "route-mutation": return .routeMutation
        case "digital-delayed-loop": return .digitalDelayedLoop
        case "default-output-virtual-microphone-input",
             "default-output-canonical-blackhole":
            return .defaultOutputCanonicalBlackHole
        case "default-output-virtual-microphone-writer",
             "default-output-hidden-mirror-blackhole":
            return .defaultOutputHiddenMirrorBlackHole
        case "default-system-output-virtual-microphone-input",
             "default-system-output-canonical-blackhole":
            return .defaultSystemOutputCanonicalBlackHole
        case "default-system-output-virtual-microphone-writer",
             "default-system-output-hidden-mirror-blackhole":
            return .defaultSystemOutputHiddenMirrorBlackHole
        case "default-output-legacy-blackhole-visible":
            return .defaultOutputLegacyBlackHoleVisible
        case "default-output-legacy-blackhole-hidden":
            return .defaultOutputLegacyBlackHoleHidden
        case "default-system-output-legacy-blackhole-visible":
            return .defaultSystemOutputLegacyBlackHoleVisible
        case "default-system-output-legacy-blackhole-hidden":
            return .defaultSystemOutputLegacyBlackHoleHidden
        default: return nil
        }
    }

    static let usageNames =
        "healthy|all-zero|near-silent|wrong-nonce|unrelated-pattern|repeated-symbol|insufficient-frames|long-stall|clipped-pcm|bad-prefix-healthy-tail|wrong-capture-uid|wrong-readback|default-changed|defaults-restored-notification|stale-nonce|too-few-progress|output-generator|physical-output-policy|route-mutation|digital-delayed-loop|default-output-virtual-microphone-input|default-output-virtual-microphone-writer|default-system-output-virtual-microphone-input|default-system-output-virtual-microphone-writer|default-output-legacy-blackhole-visible|default-output-legacy-blackhole-hidden|default-system-output-legacy-blackhole-visible|default-system-output-legacy-blackhole-hidden"

    var routeMutation: SyntheticRouteMutation? {
        switch self {
        case .routeMutation:
            return .identity
        case .defaultOutputCanonicalBlackHole:
            return .defaultOutputCanonicalBlackHole
        case .defaultOutputHiddenMirrorBlackHole:
            return .defaultOutputHiddenMirrorBlackHole
        case .defaultSystemOutputCanonicalBlackHole:
            return .defaultSystemOutputCanonicalBlackHole
        case .defaultSystemOutputHiddenMirrorBlackHole:
            return .defaultSystemOutputHiddenMirrorBlackHole
        case .defaultOutputLegacyBlackHoleVisible:
            return .defaultOutputLegacyBlackHoleVisible
        case .defaultOutputLegacyBlackHoleHidden:
            return .defaultOutputLegacyBlackHoleHidden
        case .defaultSystemOutputLegacyBlackHoleVisible:
            return .defaultSystemOutputLegacyBlackHoleVisible
        case .defaultSystemOutputLegacyBlackHoleHidden:
            return .defaultSystemOutputLegacyBlackHoleHidden
        default:
            return nil
        }
    }
}
private struct SyntheticFixture { let plan: ChallengePlan; let challengeStartUptime: Double; let window: EvaluationWindow; let route: RouteEvidence }
private enum SyntheticFactory { static func make(test: SyntheticCase, nonce: String) -> SyntheticFixture { let planCount = 128; let expectedPlan = ChallengePlan(nonce: nonce, symbolCount: planCount); var signalPlan = expectedPlan; if test == .wrongNonce { signalPlan = ChallengePlan(nonce: nonce + ":wrong-pattern", symbolCount: planCount) } else if test == .repeatedSymbol { signalPlan = expectedPlan.frozen() }; let windowStart = 10_000.0; let windowEnd = windowStart + Policy.proofSeconds; let challengeStart = windowStart - 0.12; let syntheticLag = 0.28; let onsetFrames = Int((syntheticLag - (windowStart - challengeStart)) * Policy.sampleRate); let totalFrames = Int(Policy.proofSeconds * Policy.sampleRate); let generator = ChallengeGenerator(plan: signalPlan); var noiseGenerator = SplitMix64(seed: ChallengePlan.seed(for: nonce + ":noise")); var samples: [Int16] = []; samples.reserveCapacity(totalFrames * Policy.captureChannels); for frame in 0..<totalFrames { var base = 0.0; if frame >= onsetFrames { if test == .unrelatedPattern { let time = Double(frame - onsetFrames) / Policy.sampleRate; base = 0.19 * sin(2.0 * Double.pi * 1_379.0 * time) + 0.05 * sin(2.0 * Double.pi * 2_731.0 * time) } else { base = generator.nextNormalized() } }; if test == .nearSilent { base *= 0.005 }; let badPrefix = test == .badPrefixHealthyTail && frame < Int(1.2 * Policy.sampleRate); if test == .allZero || badPrefix { samples.append(0) } else if test == .clippedPCM { let value: Int16 = frame.isMultiple(of: 2) ? 32_767 : -32_767; samples.append(value) } else { let noise0 = Double(Int64(noiseGenerator.next() % 61) - 30) / 32_767.0; samples.append(AudioSupport.quantize(base + noise0)) } }; let availableFrames = test == .insufficientFrames ? Int(Double(totalFrames) * 0.60) : totalFrames; var chunks: [CaptureChunk] = []; var callbackIndex = 0; var frame = 0; var timestampOffset = 0.0; while frame < availableFrames { let count = min(Policy.bufferFrames, availableFrames - frame); let firstSample = frame * Policy.captureChannels; let lastSample = (frame + count) * Policy.captureChannels; if test == .longStall { if callbackIndex == 200 { timestampOffset += 0.25 } else if callbackIndex > 200 && callbackIndex <= 250 { timestampOffset -= 0.005 } }; let end = windowStart + Double(frame + count) / Policy.sampleRate + timestampOffset; chunks.append(CaptureChunk(samples: Array(samples[firstSample..<lastSample]), endUptime: end, frameCount: count)); callbackIndex += 1; frame += count }; var progress: [ProgressObservation] = [ProgressObservation(uptime: windowStart, callbackCount: 0, capturedFrameCount: 0)]; var progressTime = windowStart + Policy.progressIntervalSeconds; while progressTime <= windowEnd + 0.0001 { let eligible = chunks.filter { $0.endUptime <= progressTime }; progress.append(ProgressObservation(uptime: progressTime, callbackCount: UInt64(eligible.count), capturedFrameCount: UInt64(eligible.reduce(0) { $0 + $1.frameCount }))); progressTime += Policy.progressIntervalSeconds }; if test == .tooFewProgress { progress = [ProgressObservation(uptime: windowStart, callbackCount: 0, capturedFrameCount: 0), ProgressObservation(uptime: windowEnd - 0.1, callbackCount: UInt64(chunks.count), capturedFrameCount: UInt64(chunks.reduce(0) { $0 + $1.frameCount }))] }; var route = RouteEvidence(captureUIDMatches: true, physicalOutputValidated: true, challengeNonceMatches: true, captureQueueReadbackMatches: true, physicalOutputQueueReadbackMatches: true, defaultInputEqual: true, defaultOutputEqual: true, defaultSystemOutputEqual: true, defaultNotificationCount: 0); if test == .wrongCaptureUID { route.captureUIDMatches = false }; if test == .wrongReadback { route.captureQueueReadbackMatches = false }; if test == .defaultChanged { route.defaultInputEqual = false }; if test == .defaultsRestoredNotification { route.defaultNotificationCount = 1 }; if test == .staleNonce { route.challengeNonceMatches = false }; let totalCaptured = UInt64(chunks.reduce(0) { $0 + $1.frameCount }); let snapshot = CaptureSnapshot(chunks: chunks, progress: progress, totalCallbackCount: UInt64(chunks.count), totalCapturedFrameCount: totalCaptured); return SyntheticFixture(plan: expectedPlan, challengeStartUptime: challengeStart, window: snapshot.window(endingAt: windowEnd, duration: Policy.proofSeconds), route: route) } }
private struct RunOptions { let nonce: String; let physicalOutputUID: String; let resultPath: String; let timeout: Double }
private struct SelfTestOptions { let nonce: String; let test: SyntheticCase; let resultPath: String }
private enum ProbeCommand { case run(RunOptions); case selfTest(SelfTestOptions) }
private enum CLI { static let usage = "Usage:\n  physical-blackhole-microphone-probe run --nonce <fresh-nonsecret-token> --physical-output-uid <runtime-only-uid> --result <json-path> --timeout-seconds <8...120>\n  physical-blackhole-microphone-probe self-test --case <\(SyntheticCase.usageNames)> --nonce <fresh-nonsecret-token> --result <json-path>\n\nThe run command pins only queue-local CurrentDevice properties. It never changes the default input, default output, or system-output device. The physical output UID is accepted only at runtime and is never serialized.\n"; static func parse() throws -> ProbeCommand { let arguments = Array(CommandLine.arguments.dropFirst()); guard let subcommand = arguments.first else { throw ProbeError(code: "usage") }; let options = try parsePairs(Array(arguments.dropFirst())); switch subcommand { case "run": guard Set(options.keys) == Set(["--nonce", "--physical-output-uid", "--result", "--timeout-seconds"]), let nonce = options["--nonce"], let physicalUID = options["--physical-output-uid"], let result = options["--result"], let timeoutText = options["--timeout-seconds"], let timeout = Double(timeoutText), timeout.isFinite, timeout >= Policy.minimumTimeoutSeconds, timeout <= Policy.maximumTimeoutSeconds else { throw ProbeError(code: "usage") }; try validateNonce(nonce); try validatePhysicalUID(physicalUID); try validateResultPath(result); return .run(RunOptions(nonce: nonce, physicalOutputUID: physicalUID, resultPath: result, timeout: timeout)); case "self-test": guard Set(options.keys) == Set(["--case", "--nonce", "--result"]), let caseText = options["--case"], let test = SyntheticCase.parse(caseText), let nonce = options["--nonce"], let result = options["--result"] else { throw ProbeError(code: "usage") }; try validateNonce(nonce); try validateResultPath(result); return .selfTest(SelfTestOptions(nonce: nonce, test: test, resultPath: result)); default: throw ProbeError(code: "usage") } }; private static func parsePairs(_ arguments: [String]) throws -> [String: String] { guard arguments.count.isMultiple(of: 2) else { throw ProbeError(code: "usage") }; var result: [String: String] = [:]; var index = 0; while index < arguments.count { let key = arguments[index]; let value = arguments[index + 1]; guard key.hasPrefix("--"), result[key] == nil, !value.isEmpty else { throw ProbeError(code: "usage") }; result[key] = value; index += 2 }; return result }; private static func validateNonce(_ nonce: String) throws { guard nonce.utf8.count >= 8, nonce.utf8.count <= 128 else { throw ProbeError(code: "usage") }; for byte in nonce.utf8 { let allowed = (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 45 || byte == 46 || byte == 58 || byte == 95; guard allowed else { throw ProbeError(code: "usage") } } }; private static func validatePhysicalUID(_ uid: String) throws { guard uid != Policy.captureUID, !uid.isEmpty, uid.utf8.count <= 512, uid.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }) else { throw ProbeError(code: "usage") } }; private static func validateResultPath(_ path: String) throws { guard !path.isEmpty, path.utf8.count <= 4_096 else { throw ProbeError(code: "usage") } } }
private enum AtomicResultWriter { static func prepare(_ url: URL) throws { let directory = url.deletingLastPathComponent(); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); var isDirectory: ObjCBool = false; if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) { guard !isDirectory.boolValue else { throw ProbeError(code: "result_path_is_directory") }; try FileManager.default.removeItem(at: url) } }; static func write(_ result: ProbeResult, to url: URL) throws { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; let data = try encoder.encode(result); let directory = url.deletingLastPathComponent(); let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp"); defer { try? FileManager.default.removeItem(at: temporary) }; try data.write(to: temporary, options: []); let fileDescriptor = temporary.path.withCString { Darwin.open($0, O_RDONLY) }; if fileDescriptor >= 0 { _ = Darwin.fsync(fileDescriptor); _ = Darwin.close(fileDescriptor) }; let renameStatus = temporary.path.withCString { source in url.path.withCString { destination in Darwin.rename(source, destination) } }; guard renameStatus == 0 else { throw ProbeError(code: "result_atomic_rename_failed") }; let directoryDescriptor = directory.path.withCString { Darwin.open($0, O_RDONLY) }; if directoryDescriptor >= 0 { _ = Darwin.fsync(directoryDescriptor); _ = Darwin.close(directoryDescriptor) } } }
private final class SignalLatch: @unchecked Sendable { private let lock = NSLock(); private var value: Int32 = 0; func record(_ signalNumber: Int32) { lock.lock(); if value == 0 { value = signalNumber }; lock.unlock() }; func current() -> Int32 { lock.lock(); defer { lock.unlock() }; return value } }
private final class SignalMonitor { private let latch = SignalLatch(); private let queue = DispatchQueue(label: "opensteamer.physical-blackhole-microphone.signal"); private var sources: [any DispatchSourceSignal] = []; init() { for signalNumber in [SIGINT, SIGTERM, SIGHUP] { let capturedSignal = signalNumber; _ = Darwin.signal(capturedSignal, SIG_IGN); let source = DispatchSource.makeSignalSource(signal: capturedSignal, queue: queue); source.setEventHandler { [latch, capturedSignal] in latch.record(capturedSignal) }; source.resume(); sources.append(source) } }; func receivedSignal() -> Int32 { latch.current() }; deinit { for source in sources { source.cancel() } } }
private enum RealRunner {}
private extension RealRunner {
    static func run(
        _ options: RunOptions,
        signalMonitor: SignalMonitor
    ) -> ProbeResult {
        let planSymbols = Int(ceil(
            (options.timeout + Policy.maximumLagSeconds
                + Policy.proofSeconds + 4.0) / Policy.symbolSeconds
        )) + Policy.frequencies.count
        let plan = ChallengePlan(
            nonce: options.nonce,
            symbolCount: planSymbols
        )
        let store = CaptureStore(retention: Policy.retentionSeconds)
        let inputFailure = QueueFailureLatch()
        let outputFailure = QueueFailureLatch()
        var inputSession: InputQueueSession?
        var outputSession: OutputQueueSession?
        var defaultGuard: DefaultDeviceGuard?
        var beforeDefaults: DefaultSnapshot?
        var route = RouteEvidence(
            captureUIDMatches: false,
            physicalOutputValidated: false,
            challengeNonceMatches: true,
            captureQueueReadbackMatches: false,
            physicalOutputQueueReadbackMatches: false,
            defaultInputEqual: false,
            defaultOutputEqual: false,
            defaultSystemOutputEqual: false,
            defaultNotificationCount: 0
        )
        var forcedFailures: [String] = []
        var selectedEnd = ProcessInfo.processInfo.systemUptime
        var challengeStart = selectedEnd
        var routeObservationCount = 0

        // This is an operational controlled-host prerequisite, not cryptographic proof that a
        // same-user tap could never have existed. Refuse to open either queue without it.
        if ProcessInfo.processInfo.environment[
            "OPENSTEAMER_CONTROLLED_HOST_NO_AUDIO_TAPS_ACK"
        ] != Policy.controlledHostNoAudioTapsConfirmation {
            forcedFailures.append(
                "controlled_host_no_audio_taps_not_acknowledged"
            )
        } else {
            do {
                let expectedDevices = try DeviceResolver.validate(
                    physicalOutputUID: options.physicalOutputUID
                )
                route.captureUIDMatches = true
                route.physicalOutputValidated = true

                let guardObject = DefaultDeviceGuard()
                defaultGuard = guardObject
                try guardObject.install()
                let expectedDefaults = try guardObject.snapshot()
                beforeDefaults = expectedDefaults
                if let unsafeDefault = DefaultRouteSafety.failureCode(
                    expectedDefaults
                ) {
                    throw ProbeError(code: unsafeDefault)
                }

                let capture = InputQueueSession(
                    store: store,
                    failureLatch: inputFailure
                )
                inputSession = capture
                try capture.start(uid: Policy.captureUID)
                route.captureQueueReadbackMatches = capture.readbackMatches

                let output = OutputQueueSession(
                    plan: plan,
                    failureLatch: outputFailure
                )
                outputSession = output
                try output.start(uid: options.physicalOutputUID)
                route.physicalOutputQueueReadbackMatches =
                    output.readbackMatches
                challengeStart = output.startUptime
                selectedEnd = challengeStart
                store.recordProgress(at: challengeStart)

                var nextProgress =
                    challengeStart + Policy.progressIntervalSeconds
                var nextEvaluation =
                    challengeStart + Policy.proofSeconds
                let deadline = challengeStart + options.timeout

                while true {
                    let now = ProcessInfo.processInfo.systemUptime
                    selectedEnd = now
                    if signalMonitor.receivedSignal() != 0 {
                        forcedFailures.append("interrupted")
                        break
                    }
                    if now >= nextProgress {
                        store.recordProgress(at: now)
                        nextProgress =
                            now + Policy.progressIntervalSeconds
                    }
                    if inputFailure.hasFailure()
                        || outputFailure.hasFailure() {
                        forcedFailures.append(
                            "audio_queue_runtime_failure"
                        )
                        break
                    }

                    if let routeFailure =
                        RouteContinuityValidator.failureCode(
                            expectedDevices: expectedDevices,
                            inputSession: capture,
                            outputSession: output,
                            defaultGuard: guardObject,
                            expectedDefaults: expectedDefaults
                        ) {
                        route.captureQueueReadbackMatches =
                            capture.currentDeviceMatches(
                                Policy.captureUID
                            )
                        route.physicalOutputQueueReadbackMatches =
                            output.currentDeviceMatches(
                                PhysicalOutputPolicy.reviewedOutputUID
                            )
                        forcedFailures.append(routeFailure)
                        break
                    }
                    routeObservationCount += 1

                    if now >= nextEvaluation {
                        let snapshot = store.snapshot()
                        var provisionalRoute = route
                        provisionalRoute.defaultInputEqual = true
                        provisionalRoute.defaultOutputEqual = true
                        provisionalRoute.defaultSystemOutputEqual = true
                        provisionalRoute.defaultNotificationCount = 0
                        let candidateWindow = snapshot.window(
                            endingAt: now,
                            duration: Policy.proofSeconds
                        )
                        let continuityFailures =
                            routeObservationCount >= 60
                                ? []
                                : [
                                    "insufficient_route_continuity_observations"
                                ]
                        let candidate = Evaluator.evaluate(
                            runNonce: options.nonce,
                            plan: plan,
                            challengeStartUptime: challengeStart,
                            window: candidateWindow,
                            route: provisionalRoute,
                            forcedFailures: continuityFailures
                        )
                        if candidate.status == "passed" {
                            break
                        }
                        nextEvaluation =
                            now + Policy.evaluationIntervalSeconds
                    }
                    if now >= deadline {
                        forcedFailures.append("timeout")
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            } catch let error as ProbeError {
                forcedFailures.append(error.code)
                selectedEnd = ProcessInfo.processInfo.systemUptime
            } catch {
                forcedFailures.append("unexpected_runtime_failure")
                selectedEnd = ProcessInfo.processInfo.systemUptime
            }
        }

        if let inputSession {
            route.captureQueueReadbackMatches =
                route.captureQueueReadbackMatches
                    && inputSession.currentDeviceMatches(
                        Policy.captureUID
                    )
        }
        if let outputSession {
            route.physicalOutputQueueReadbackMatches =
                route.physicalOutputQueueReadbackMatches
                    && outputSession.currentDeviceMatches(
                        PhysicalOutputPolicy.reviewedOutputUID
                    )
        }
        let outputStopped = outputSession?.stop() ?? true
        let inputStopped = inputSession?.stop() ?? true
        if !outputStopped || !inputStopped {
            forcedFailures.append("audio_queue_teardown_failure")
        }
        if inputFailure.hasFailure() || outputFailure.hasFailure() {
            forcedFailures.append("audio_queue_runtime_failure")
        }
        if routeObservationCount < 60 {
            forcedFailures.append(
                "insufficient_route_continuity_observations"
            )
        }
        store.recordProgress(at: ProcessInfo.processInfo.systemUptime)
        if let defaultGuard {
            Thread.sleep(forTimeInterval: 0.15)
            if let beforeDefaults {
                do {
                    let afterDefaults = try defaultGuard.snapshot()
                    if let unsafeDefault = DefaultRouteSafety.failureCode(
                        afterDefaults
                    ) {
                        forcedFailures.append(unsafeDefault)
                    }
                    route.defaultInputEqual =
                        beforeDefaults.inputUID
                            == afterDefaults.inputUID
                    route.defaultOutputEqual =
                        beforeDefaults.outputUID
                            == afterDefaults.outputUID
                    route.defaultSystemOutputEqual =
                        beforeDefaults.systemOutputUID
                            == afterDefaults.systemOutputUID
                } catch {
                    forcedFailures.append(
                        "default_after_snapshot_failed"
                    )
                }
            } else {
                forcedFailures.append(
                    "default_before_snapshot_unavailable"
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
            let listenerRemoved = defaultGuard.remove()
            route.defaultNotificationCount =
                defaultGuard.notificationCount()
            if !listenerRemoved {
                forcedFailures.append(
                    "default_device_listener_remove_failed"
                )
            }
        } else {
            forcedFailures.append("default_guard_unavailable")
        }
        let finalWindow = store.snapshot().window(
            endingAt: selectedEnd,
            duration: Policy.proofSeconds
        )
        return Evaluator.evaluate(
            runNonce: options.nonce,
            plan: plan,
            challengeStartUptime: challengeStart,
            window: finalWindow,
            route: route,
            forcedFailures: forcedFailures
        )
    }
}
private enum ProbeProgram {
    static func main() -> Int32 {
        let command: ProbeCommand
        do {
            command = try CLI.parse()
        } catch {
            FileHandle.standardError.write(Data(CLI.usage.utf8))
            return 64
        }
        switch command {
        case .run(let options):
            let resultURL = URL(fileURLWithPath: options.resultPath)
            do {
                try AtomicResultWriter.prepare(resultURL)
                let signalMonitor = SignalMonitor()
                let result = RealRunner.run(options, signalMonitor: signalMonitor)
                try AtomicResultWriter.write(result, to: resultURL)
                return result.status == "passed" ? 0 : 1
            } catch {
                return 74
            }
        case .selfTest(let options):
            let resultURL = URL(fileURLWithPath: options.resultPath)
            do {
                try AtomicResultWriter.prepare(resultURL)
                let fixture = SyntheticFactory.make(test: options.test, nonce: options.nonce)
                var forcedFailures: [String] = []
                if options.test == .outputGenerator,
                   !OutputGeneratorSelfTest.passes(nonce: options.nonce) {
                    forcedFailures.append("output_generator_self_test_failed")
                }
                if options.test == .physicalOutputPolicy,
                   !PhysicalOutputPolicy.selfTestPasses() {
                    forcedFailures.append("physical_output_policy_self_test_failed")
                }
                if let routeMutation = options.test.routeMutation {
                    forcedFailures.append(
                        RouteContinuitySelfTest.failureCode(
                            for: routeMutation
                        )
                    )
                }
                if options.test == .digitalDelayedLoop {
                    // The waveform is intentionally otherwise valid. It must still fail because
                    // endpoint metadata cannot cryptographically distinguish a same-user digital
                    // loop from the reviewed acoustic path.
                    forcedFailures.append(
                        "controlled_host_no_audio_taps_not_acknowledged"
                    )
                }
                let result = Evaluator.evaluate(
                    runNonce: options.nonce,
                    plan: fixture.plan,
                    challengeStartUptime: fixture.challengeStartUptime,
                    window: fixture.window,
                    route: fixture.route,
                    forcedFailures: forcedFailures
                )
                try AtomicResultWriter.write(result, to: resultURL)
                return result.status == "passed" ? 0 : 1
            } catch {
                return 74
            }
        }
    }
}

private struct DefaultUIDSnapshotEvidence: Codable {
    let schema: String
    let role: String
    let observedAtMonotonicNs: UInt64
    let inputUIDFingerprint: String
    let outputUIDFingerprint: String
    let systemOutputUIDFingerprint: String
    let inputIsCanonicalBlackHole: Bool
    let inputIsHiddenMirrorBlackHole: Bool
    let defaultOutputIsForbiddenBlackHole: Bool
    let defaultSystemOutputIsForbiddenBlackHole: Bool
    let inputTransportClass: String
}

private enum DefaultUIDSnapshotProgram {
    static func runIfRequested() -> Int32? {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "snapshot-default-uids" else {
            return nil
        }
        do {
            let values = try parsePairs(Array(arguments.dropFirst()))
            guard Set(values.keys) == Set(["--role", "--result"]),
                  let role = values["--role"],
                  ["before", "healthy", "after"].contains(role),
                  let resultPath = values["--result"],
                  !resultPath.isEmpty else {
                throw ProbeError(code: "usage")
            }

            let inputUID = try CoreAudioReader.defaultUID(
                selector: kAudioHardwarePropertyDefaultInputDevice
            )
            let outputUID = try CoreAudioReader.defaultUID(
                selector: kAudioHardwarePropertyDefaultOutputDevice
            )
            let systemOutputUID = try CoreAudioReader.defaultUID(
                selector: kAudioHardwarePropertyDefaultSystemOutputDevice
            )
            let evidence = DefaultUIDSnapshotEvidence(
                schema: "opensteamer.default-input-snapshot.v3",
                role: role,
                observedAtMonotonicNs: UInt64(
                    max(
                        1,
                        ProcessInfo.processInfo.systemUptime
                            * 1_000_000_000
                    )
                ),
                inputUIDFingerprint: fingerprint(inputUID),
                outputUIDFingerprint: fingerprint(outputUID),
                systemOutputUIDFingerprint:
                    fingerprint(systemOutputUID),
                inputIsCanonicalBlackHole:
                    inputUID == Policy.captureUID,
                inputIsHiddenMirrorBlackHole:
                    inputUID == Policy.hiddenMirrorUID
                        || inputUID == Policy.legacyHiddenUID,
                defaultOutputIsForbiddenBlackHole:
                    outputUID == Policy.captureUID
                        || outputUID == Policy.hiddenMirrorUID
                        || outputUID == Policy.legacyVisibleUID
                        || outputUID == Policy.legacyHiddenUID,
                defaultSystemOutputIsForbiddenBlackHole:
                    systemOutputUID == Policy.captureUID
                        || systemOutputUID == Policy.hiddenMirrorUID
                        || systemOutputUID == Policy.legacyVisibleUID
                        || systemOutputUID == Policy.legacyHiddenUID,
                inputTransportClass:
                    try CoreAudioReader.defaultTransportClass(
                        selector:
                            kAudioHardwarePropertyDefaultInputDevice
                    )
            )
            try write(
                evidence,
                to: URL(fileURLWithPath: resultPath)
            )
            return 0
        } catch {
            return 74
        }
    }

    private static func parsePairs(
        _ arguments: [String]
    ) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else {
            throw ProbeError(code: "usage")
        }
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            let value = arguments[index + 1]
            guard key.hasPrefix("--"),
                  values[key] == nil,
                  !value.isEmpty else {
                throw ProbeError(code: "usage")
            }
            values[key] = value
            index += 2
        }
        return values
    }

    private static func fingerprint(
        _ value: String
    ) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func write(
        _ evidence: DefaultUIDSnapshotEvidence,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(evidence)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(url.lastPathComponent).\(getpid()).tmp"
            )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        let renameStatus = temporary.path.withCString { source in
            url.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renameStatus == 0 else {
            throw ProbeError(code: "result_atomic_rename_failed")
        }
    }
}

private enum BlackHoleMeasurePolicy {
    static let schema = "opensteamer.blackhole-input-measurement.v1"
    static let mode = "analysis-only"
    // This deliberately remains a legacy two-channel diagnostic. The
    // repo-owned virtual-microphone proof below has an independent mono ABI.
    static let captureUID = Policy.legacyVisibleUID
    static let channels = 2
    static let minimumDurationSeconds = 8.0
    static let maximumDurationSeconds = 30.0
    static let telemetryWindowSeconds = 1.0
    static let telemetryWindowFrames = Policy.sampleRateInt
    static let maximumTelemetryWindows = 30
    static let callbackGapThresholdMs = 25.0
    static let minimumElapsedDurationRatio = 0.95
    static let minimumCapturedDurationRatio = 0.95
    static let minimumFrameDensity = 0.95
    static let maximumFrameDensity = 1.05
    static let firstCallbackTimeoutSeconds = 2.0
    static let sampleTimeContinuityToleranceFrames = 0.5
    static let normalizedSilenceFloorDB = -160.0
    // Metric ABI: activity is magnitude >= 128 and clipping is magnitude >= 32760.
    static let activeMagnitude = 128
    static let clippedMagnitude = 32_760
    static let maximumFailureReasons = 20
    static let maximumSpectralObservations = 640
}

private struct BlackHoleMeasureChannelEvidence: Codable {
    let channel: Int
    let rmsNormalized: Double
    let rmsDBFS: Double
    let peakNormalized: Double
    let peakDBFS: Double
    let dcMeanNormalized: Double
    let zeroSampleFraction: Double
    let clippingFraction: Double
    let activeFrameFraction: Double
    let repeatedBlockCount: UInt64
    let longestRepeatedBlockRun: UInt64
}

private struct BlackHoleMeasureStereoEvidence: Codable {
    let leftRightCorrelation: Double
    let channelRMSDifferenceDB: Double
    let sumRMSNormalized: Double
    let sumRMSDBFS: Double
    let differenceRMSNormalized: Double
    let differenceRMSDBFS: Double
    let oneSidedFrameFraction: Double
}

private struct BlackHoleMeasureCadenceEvidence: Codable {
    let callbackCount: UInt64
    let frameCount: UInt64
    let firstCallbackMonotonicNs: UInt64
    let lastCallbackMonotonicNs: UInt64
    let minimumCallbackGapMs: Double
    let meanCallbackGapMs: Double
    let maximumCallbackGapMs: Double
    let callbackGapOver25MsCount: UInt64
    let nonMonotonicCallbackCount: UInt64
    let sampleTimeValidCount: UInt64
    let sampleTimeMissingCount: UInt64
    let firstSampleTime: Double
    let lastSampleTime: Double
    let nonMonotonicSampleTimeCount: UInt64
    let sampleFrameDiscontinuityCount: UInt64
    let hostTimeValidCount: UInt64
    let hostTimeMissingCount: UInt64
    let firstHostTime: UInt64
    let lastHostTime: UInt64
    let nonMonotonicHostTimeCount: UInt64
    let minimumFramesPerCallback: UInt64
    let maximumFramesPerCallback: UInt64
}

private struct BlackHoleMeasureWindowEvidence: Codable {
    let sequence: Int
    let startMonotonicNs: UInt64
    let endMonotonicNs: UInt64
    let sourceStartFrame: UInt64
    let sourceEndFrame: UInt64
    let complete: Bool
    let channels: [BlackHoleMeasureChannelEvidence]
    let stereo: BlackHoleMeasureStereoEvidence
    let cadence: BlackHoleMeasureCadenceEvidence
}

private struct BlackHoleMeasureAggregateEvidence: Codable {
    let channels: [BlackHoleMeasureChannelEvidence]
    let stereo: BlackHoleMeasureStereoEvidence
    let cadence: BlackHoleMeasureCadenceEvidence
}

private struct BlackHoleTaggedChannelEvidence: Codable {
    let channel: Int
    let symbolCount: Int
    let matchedSymbolCount: Int
    let matchRatio: Double
    let normalizedCorrelation: Double
    let discriminationMargin: Double
    let envelopeCorrelation: Double
    let detectedLagMs: Double
}

private struct BlackHoleTaggedChallengeEvidence: Codable {
    let enabled: Bool
    let externallyInjected: Bool
    let algorithm: String
    let version: Int
    let tagFingerprint: String
    let recognized: Bool
    let recognizedChannel: Int
    let channels: [BlackHoleTaggedChannelEvidence]
}

private struct BlackHoleMeasureResult: Codable {
    let schema: String
    let status: String
    let mode: String
    let canonicalCaptureUID: String
    let captureUIDMatches: Bool
    let queueReadbackMatches: Bool
    let rawPCMRetained: Bool
    let rawPCMPersisted: Bool
    let outputOpened: Bool
    let defaultsMutated: Bool
    let format: AudioFormatEvidence
    let requestedDurationSeconds: Double
    let elapsedSeconds: Double
    let capturedAudioSeconds: Double
    let capturedDurationRatio: Double
    let frameDensity: Double
    let measurementStartMonotonicNs: UInt64
    let measurementEndMonotonicNs: UInt64
    let callbackCount: UInt64
    let capturedFrameCount: UInt64
    let telemetryWindowSeconds: Double
    let telemetryWindowLimit: Int
    let telemetryWindows: [BlackHoleMeasureWindowEvidence]
    let aggregate: BlackHoleMeasureAggregateEvidence
    let taggedChallenge: BlackHoleTaggedChallengeEvidence
    let defaultInputBeforeAfterEqual: Bool
    let defaultOutputBeforeAfterEqual: Bool
    let defaultSystemOutputBeforeAfterEqual: Bool
    let defaultChangeNotificationCount: Int
    let failureCode: String
    let failureReasons: [String]
}

private enum BlackHoleMeasureMath {
    static func normalized(_ sample: Int16) -> Double {
        Double(sample) / 32_768.0
    }

    static func dBFS(_ normalizedMagnitude: Double) -> Double {
        guard normalizedMagnitude.isFinite,
              normalizedMagnitude > 0 else {
            return BlackHoleMeasurePolicy.normalizedSilenceFloorDB
        }
        return max(
            BlackHoleMeasurePolicy.normalizedSilenceFloorDB,
            20.0 * log10(normalizedMagnitude)
        )
    }

    static func monotonicNanoseconds(_ uptime: Double) -> UInt64 {
        UInt64(max(0, min(Double(UInt64.max), uptime * 1_000_000_000.0)))
    }

    static func hostTimeNanoseconds(_ hostTime: UInt64) -> UInt64 {
        hostTime == 0 ? 0 : AudioConvertHostTimeToNanos(hostTime)
    }

    static func hostTimeDeltaMilliseconds(_ delta: UInt64) -> Double {
        Double(AudioConvertHostTimeToNanos(delta)) / 1_000_000.0
    }
}

private struct BlackHoleMeasureCallbackTimestamp {
    let sampleTime: Double
    let hostTime: UInt64
    let sampleTimeValid: Bool
    let hostTimeValid: Bool

    init(_ timestamp: AudioTimeStamp) {
        sampleTime = timestamp.mSampleTime
        hostTime = timestamp.mHostTime
        sampleTimeValid = timestamp.mFlags.contains(.sampleTimeValid)
            && timestamp.mSampleTime.isFinite
        hostTimeValid = timestamp.mFlags.contains(.hostTimeValid)
            && timestamp.mHostTime != 0
    }

    init(sampleTime: Double?, hostTime: UInt64?) {
        self.sampleTime = sampleTime ?? 0
        self.hostTime = hostTime ?? 0
        sampleTimeValid = sampleTime?.isFinite == true
        hostTimeValid = hostTime != nil && hostTime != 0
    }
}

private struct BlackHoleMeasureChannelAccumulator {
    var sampleCount: UInt64 = 0
    var sampleSum = 0.0
    var squareSum = 0.0
    var peakMagnitude = 0
    var zeroSampleCount: UInt64 = 0
    var clippedSampleCount: UInt64 = 0
    var activeSampleCount: UInt64 = 0
    var repeatedBlockCount: UInt64 = 0
    var longestRepeatedBlockRun: UInt64 = 0

    mutating func add(_ sample: Int16) {
        let value = Double(sample)
        let magnitude = Int(abs(Int32(sample)))
        sampleCount &+= 1
        sampleSum += value
        squareSum += value * value
        peakMagnitude = max(peakMagnitude, magnitude)
        if sample == 0 { zeroSampleCount &+= 1 }
        if magnitude >= BlackHoleMeasurePolicy.clippedMagnitude {
            clippedSampleCount &+= 1
        }
        if magnitude >= BlackHoleMeasurePolicy.activeMagnitude {
            activeSampleCount &+= 1
        }
    }

    mutating func recordRepeatedBlock(_ repeated: Bool, run: UInt64) {
        guard repeated else { return }
        repeatedBlockCount &+= 1
        longestRepeatedBlockRun = max(longestRepeatedBlockRun, run)
    }

    func evidence(channel: Int) -> BlackHoleMeasureChannelEvidence {
        let count = Double(sampleCount)
        let rms = sampleCount > 0
            ? sqrt(max(0, squareSum / count)) / 32_768.0
            : 0
        let peak = Double(peakMagnitude) / 32_768.0
        return BlackHoleMeasureChannelEvidence(
            channel: channel,
            rmsNormalized: rms,
            rmsDBFS: BlackHoleMeasureMath.dBFS(rms),
            peakNormalized: peak,
            peakDBFS: BlackHoleMeasureMath.dBFS(peak),
            dcMeanNormalized: sampleCount > 0
                ? (sampleSum / count) / 32_768.0
                : 0,
            zeroSampleFraction: sampleCount > 0
                ? Double(zeroSampleCount) / count
                : 0,
            clippingFraction: sampleCount > 0
                ? Double(clippedSampleCount) / count
                : 0,
            activeFrameFraction: sampleCount > 0
                ? Double(activeSampleCount) / count
                : 0,
            repeatedBlockCount: repeatedBlockCount,
            longestRepeatedBlockRun: longestRepeatedBlockRun
        )
    }
}

private struct BlackHoleMeasureStereoAccumulator {
    var frameCount: UInt64 = 0
    var leftSum = 0.0
    var rightSum = 0.0
    var leftSquareSum = 0.0
    var rightSquareSum = 0.0
    var crossSum = 0.0
    var sumSquareSum = 0.0
    var differenceSquareSum = 0.0
    var oneSidedFrameCount: UInt64 = 0

    mutating func add(left: Int16, right: Int16) {
        let leftValue = Double(left)
        let rightValue = Double(right)
        frameCount &+= 1
        leftSum += leftValue
        rightSum += rightValue
        leftSquareSum += leftValue * leftValue
        rightSquareSum += rightValue * rightValue
        crossSum += leftValue * rightValue
        let sum = (leftValue + rightValue) * 0.5
        let difference = (leftValue - rightValue) * 0.5
        sumSquareSum += sum * sum
        differenceSquareSum += difference * difference
        let leftActive = abs(Int32(left)) >= BlackHoleMeasurePolicy.activeMagnitude
        let rightActive = abs(Int32(right)) >= BlackHoleMeasurePolicy.activeMagnitude
        if leftActive != rightActive { oneSidedFrameCount &+= 1 }
    }

    func evidence() -> BlackHoleMeasureStereoEvidence {
        let count = Double(frameCount)
        let leftEnergy = frameCount > 0
            ? max(0, leftSquareSum / count)
            : 0
        let rightEnergy = frameCount > 0
            ? max(0, rightSquareSum / count)
            : 0
        let leftRMS = sqrt(leftEnergy) / 32_768.0
        let rightRMS = sqrt(rightEnergy) / 32_768.0
        let sumRMS = frameCount > 0
            ? sqrt(max(0, sumSquareSum / count)) / 32_768.0
            : 0
        let differenceRMS = frameCount > 0
            ? sqrt(max(0, differenceSquareSum / count)) / 32_768.0
            : 0
        let correlation: Double
        if frameCount > 1 {
            let covariance = crossSum - (leftSum * rightSum / count)
            let leftVariance = max(
                0,
                leftSquareSum - (leftSum * leftSum / count)
            )
            let rightVariance = max(
                0,
                rightSquareSum - (rightSum * rightSum / count)
            )
            let denominator = sqrt(leftVariance * rightVariance)
            correlation = denominator > 1.0e-12
                ? max(-1, min(1, covariance / denominator))
                : 0
        } else {
            correlation = 0
        }
        let leftDB = BlackHoleMeasureMath.dBFS(leftRMS)
        let rightDB = BlackHoleMeasureMath.dBFS(rightRMS)
        return BlackHoleMeasureStereoEvidence(
            leftRightCorrelation: correlation,
            channelRMSDifferenceDB: abs(leftDB - rightDB),
            sumRMSNormalized: sumRMS,
            sumRMSDBFS: BlackHoleMeasureMath.dBFS(sumRMS),
            differenceRMSNormalized: differenceRMS,
            differenceRMSDBFS: BlackHoleMeasureMath.dBFS(differenceRMS),
            oneSidedFrameFraction: frameCount > 0
                ? Double(oneSidedFrameCount) / count
                : 0
        )
    }
}

private struct BlackHoleMeasureCadenceAccumulator {
    private static let longGapHostTicks = AudioConvertNanosToHostTime(
        UInt64(BlackHoleMeasurePolicy.callbackGapThresholdMs * 1_000_000.0)
    )

    var callbackCount: UInt64 = 0
    var frameCount: UInt64 = 0
    var sampleTimeValidCount: UInt64 = 0
    var sampleTimeMissingCount: UInt64 = 0
    var firstSampleTime = 0.0
    var lastSampleTime = 0.0
    var nonMonotonicSampleTimeCount: UInt64 = 0
    var sampleFrameDiscontinuityCount: UInt64 = 0
    var previousSampleTime: Double?
    var previousSampleFrameCount = 0
    var hostTimeValidCount: UInt64 = 0
    var hostTimeMissingCount: UInt64 = 0
    var firstHostTime: UInt64 = 0
    var lastHostTime: UInt64 = 0
    var nonMonotonicHostTimeCount: UInt64 = 0
    var previousHostTime: UInt64?
    var gapCount: UInt64 = 0
    var gapSumHostTicks: UInt64 = 0
    var minimumGapHostTicks = UInt64.max
    var maximumGapHostTicks: UInt64 = 0
    var longGapCount: UInt64 = 0
    var minimumFramesPerCallback = UInt64.max
    var maximumFramesPerCallback: UInt64 = 0
    var lastCallbackFrameCount: UInt64 = 0

    static func prepare() {
        _ = longGapHostTicks
    }

    mutating func record(
        frameCount callbackFrames: Int,
        timestamp: BlackHoleMeasureCallbackTimestamp
    ) {
        let frames = UInt64(max(0, callbackFrames))
        callbackCount &+= 1
        frameCount &+= frames
        lastCallbackFrameCount = frames
        minimumFramesPerCallback = min(minimumFramesPerCallback, frames)
        maximumFramesPerCallback = max(maximumFramesPerCallback, frames)

        if timestamp.sampleTimeValid {
            sampleTimeValidCount &+= 1
            if sampleTimeValidCount == 1 {
                firstSampleTime = timestamp.sampleTime
            }
            if let previousSampleTime {
                if timestamp.sampleTime <= previousSampleTime {
                    nonMonotonicSampleTimeCount &+= 1
                }
                let expected = previousSampleTime
                    + Double(previousSampleFrameCount)
                if abs(timestamp.sampleTime - expected)
                    > BlackHoleMeasurePolicy
                        .sampleTimeContinuityToleranceFrames {
                    sampleFrameDiscontinuityCount &+= 1
                }
            }
            lastSampleTime = timestamp.sampleTime
            previousSampleTime = timestamp.sampleTime
            previousSampleFrameCount = callbackFrames
        } else {
            sampleTimeMissingCount &+= 1
        }

        if timestamp.hostTimeValid {
            hostTimeValidCount &+= 1
            if hostTimeValidCount == 1 {
                firstHostTime = timestamp.hostTime
            }
            if let previousHostTime {
                if timestamp.hostTime <= previousHostTime {
                    nonMonotonicHostTimeCount &+= 1
                } else {
                    let gap = timestamp.hostTime - previousHostTime
                    gapCount &+= 1
                    gapSumHostTicks &+= gap
                    minimumGapHostTicks = min(minimumGapHostTicks, gap)
                    maximumGapHostTicks = max(maximumGapHostTicks, gap)
                    if gap > Self.longGapHostTicks {
                        longGapCount &+= 1
                    }
                }
            }
            lastHostTime = timestamp.hostTime
            previousHostTime = timestamp.hostTime
        } else {
            hostTimeMissingCount &+= 1
        }
    }

    func evidence() -> BlackHoleMeasureCadenceEvidence {
        let minimumGapMs = gapCount > 0
            ? BlackHoleMeasureMath.hostTimeDeltaMilliseconds(
                minimumGapHostTicks
            )
            : 0
        let maximumGapMs = gapCount > 0
            ? BlackHoleMeasureMath.hostTimeDeltaMilliseconds(
                maximumGapHostTicks
            )
            : 0
        let meanGapMs = gapCount > 0
            ? BlackHoleMeasureMath.hostTimeDeltaMilliseconds(
                gapSumHostTicks
            ) / Double(gapCount)
            : 0
        return BlackHoleMeasureCadenceEvidence(
            callbackCount: callbackCount,
            frameCount: frameCount,
            firstCallbackMonotonicNs:
                BlackHoleMeasureMath.hostTimeNanoseconds(firstHostTime),
            lastCallbackMonotonicNs:
                BlackHoleMeasureMath.hostTimeNanoseconds(lastHostTime),
            minimumCallbackGapMs: minimumGapMs,
            meanCallbackGapMs: meanGapMs,
            maximumCallbackGapMs: maximumGapMs,
            callbackGapOver25MsCount: longGapCount,
            nonMonotonicCallbackCount:
                nonMonotonicSampleTimeCount &+ nonMonotonicHostTimeCount,
            sampleTimeValidCount: sampleTimeValidCount,
            sampleTimeMissingCount: sampleTimeMissingCount,
            firstSampleTime: firstSampleTime,
            lastSampleTime: lastSampleTime,
            nonMonotonicSampleTimeCount: nonMonotonicSampleTimeCount,
            sampleFrameDiscontinuityCount: sampleFrameDiscontinuityCount,
            hostTimeValidCount: hostTimeValidCount,
            hostTimeMissingCount: hostTimeMissingCount,
            firstHostTime: firstHostTime,
            lastHostTime: lastHostTime,
            nonMonotonicHostTimeCount: nonMonotonicHostTimeCount,
            minimumFramesPerCallback: callbackCount > 0
                ? minimumFramesPerCallback
                : 0,
            maximumFramesPerCallback: maximumFramesPerCallback
        )
    }

    var measurementEndMonotonicNs: UInt64 {
        guard lastHostTime != 0 else { return 0 }
        let lastStart = BlackHoleMeasureMath.hostTimeNanoseconds(lastHostTime)
        let duration = UInt64(
            (Double(lastCallbackFrameCount) / Policy.sampleRate)
                * 1_000_000_000.0
        )
        return lastStart &+ duration
    }
}

private struct BlackHoleMeasureWindowAccumulator {
    var initialized = false
    var sequence = 0
    var sourceStartFrame: UInt64 = 0
    var sourceEndFrame: UInt64 = 0
    var left = BlackHoleMeasureChannelAccumulator()
    var right = BlackHoleMeasureChannelAccumulator()
    var stereo = BlackHoleMeasureStereoAccumulator()
    var cadence = BlackHoleMeasureCadenceAccumulator()

    mutating func initialize(sequence: Int) {
        guard !initialized else { return }
        initialized = true
        self.sequence = sequence
        sourceStartFrame = UInt64(
            sequence * BlackHoleMeasurePolicy.telemetryWindowFrames
        )
    }

    mutating func add(left leftSample: Int16, right rightSample: Int16) {
        left.add(leftSample)
        right.add(rightSample)
        stereo.add(left: leftSample, right: rightSample)
        sourceEndFrame &+= 1
    }

    mutating func recordCallback(
        frameCount: Int,
        timestamp: BlackHoleMeasureCallbackTimestamp,
        leftRepeated: Bool,
        rightRepeated: Bool,
        leftRepeatRun: UInt64,
        rightRepeatRun: UInt64
    ) {
        cadence.record(
            frameCount: frameCount,
            timestamp: timestamp
        )
        left.recordRepeatedBlock(leftRepeated, run: leftRepeatRun)
        right.recordRepeatedBlock(rightRepeated, run: rightRepeatRun)
    }

    func evidence(startMonotonicNs: UInt64) -> BlackHoleMeasureWindowEvidence {
        let windowStart = startMonotonicNs &+ UInt64(
            (Double(sourceStartFrame) / Policy.sampleRate)
                * 1_000_000_000.0
        )
        let actualEndFrame = sourceStartFrame + stereo.frameCount
        let windowEnd = startMonotonicNs &+ UInt64(
            (Double(actualEndFrame) / Policy.sampleRate)
                * 1_000_000_000.0
        )
        return BlackHoleMeasureWindowEvidence(
            sequence: sequence,
            startMonotonicNs:
                windowStart,
            endMonotonicNs:
                windowEnd,
            sourceStartFrame: sourceStartFrame,
            sourceEndFrame: actualEndFrame,
            complete: stereo.frameCount
                == UInt64(BlackHoleMeasurePolicy.telemetryWindowFrames),
            channels: [left.evidence(channel: 0), right.evidence(channel: 1)],
            stereo: stereo.evidence(),
            cadence: cadence.evidence()
        )
    }
}

private struct BlackHoleFixedSpectralObservation {
    var centerFrame: UInt64 = 0
    var leftQ1 = SIMD8<Double>(repeating: 0)
    var leftQ2 = SIMD8<Double>(repeating: 0)
    var rightQ1 = SIMD8<Double>(repeating: 0)
    var rightQ2 = SIMD8<Double>(repeating: 0)
    var leftSquareSum = 0.0
    var rightSquareSum = 0.0

    func observation() -> SpectralObservation {
        var leftPowers = Array(repeating: 0.0, count: 8)
        var rightPowers = Array(repeating: 0.0, count: 8)
        for index in 0..<8 {
            let coefficient = BlackHoleStreamingSpectralAccumulator
                .coefficient(at: index)
            leftPowers[index] = max(
                0,
                leftQ1[index] * leftQ1[index]
                    + leftQ2[index] * leftQ2[index]
                    - coefficient * leftQ1[index] * leftQ2[index]
            )
            rightPowers[index] = max(
                0,
                rightQ1[index] * rightQ1[index]
                    + rightQ2[index] * rightQ2[index]
                    - coefficient * rightQ1[index] * rightQ2[index]
            )
        }
        return SpectralObservation(
            centerSeconds: Double(centerFrame) / Policy.sampleRate,
            powers: [leftPowers, rightPowers],
            rms: [
                sqrt(
                    max(
                        0,
                        leftSquareSum / Double(Policy.analysisBlockFrames)
                    )
                ),
                sqrt(
                    max(
                        0,
                        rightSquareSum / Double(Policy.analysisBlockFrames)
                    )
                ),
            ]
        )
    }
}

private struct BlackHoleStreamingSpectralAccumulator {
    private static let coefficients = SIMD8<Double>(
        2.0 * cos(2.0 * Double.pi * Policy.frequencies[0] / Policy.sampleRate),
        2.0 * cos(2.0 * Double.pi * Policy.frequencies[1] / Policy.sampleRate),
        2.0 * cos(2.0 * Double.pi * Policy.frequencies[2] / Policy.sampleRate),
        2.0 * cos(2.0 * Double.pi * Policy.frequencies[3] / Policy.sampleRate),
        2.0 * cos(2.0 * Double.pi * Policy.frequencies[4] / Policy.sampleRate),
        2.0 * cos(2.0 * Double.pi * Policy.frequencies[5] / Policy.sampleRate),
        2.0 * cos(2.0 * Double.pi * Policy.frequencies[6] / Policy.sampleRate),
        2.0 * cos(2.0 * Double.pi * Policy.frequencies[7] / Policy.sampleRate)
    )
    private static let hannWindow = (0..<Policy.analysisBlockFrames).map {
        0.5 - 0.5 * cos(
            2.0 * Double.pi * Double($0)
                / Double(Policy.analysisBlockFrames - 1)
        )
    }

    private(set) var active = false
    private var startFrame: UInt64 = 0
    private var localFrame = 0
    private var leftSquareSum = 0.0
    private var rightSquareSum = 0.0
    private var leftQ1 = SIMD8<Double>(repeating: 0)
    private var leftQ2 = SIMD8<Double>(repeating: 0)
    private var rightQ1 = SIMD8<Double>(repeating: 0)
    private var rightQ2 = SIMD8<Double>(repeating: 0)

    mutating func begin(at sourceFrame: UInt64) {
        active = true
        startFrame = sourceFrame
        localFrame = 0
        leftSquareSum = 0
        rightSquareSum = 0
        leftQ1 = .zero
        leftQ2 = .zero
        rightQ1 = .zero
        rightQ2 = .zero
    }

    static func prepare() {
        _ = coefficients[0]
        _ = hannWindow.count
    }

    static func coefficient(at index: Int) -> Double {
        coefficients[index]
    }

    /// Tagged measurement only: the real-time side performs a fixed eight-bin
    /// Goertzel scalar recurrence per channel and retains only its bounded terminal
    /// state. Power, RMS, logarithms, correlations, and tag decisions run later,
    /// after AudioQueue teardown; no PCM is retained.
    mutating func ingest(
        left: Int16,
        right: Int16
    ) -> BlackHoleFixedSpectralObservation? {
        guard active else { return nil }
        let window = Self.hannWindow[localFrame]
        let normalizedLeft = Double(left) / 32_768.0
        let normalizedRight = Double(right) / 32_768.0
        leftSquareSum += normalizedLeft * normalizedLeft
        rightSquareSum += normalizedRight * normalizedRight
        for frequencyIndex in 0..<8 {
            let coefficient = Self.coefficients[frequencyIndex]
            let nextLeft = normalizedLeft * window
                + coefficient * leftQ1[frequencyIndex]
                - leftQ2[frequencyIndex]
            leftQ2[frequencyIndex] = leftQ1[frequencyIndex]
            leftQ1[frequencyIndex] = nextLeft
            let nextRight = normalizedRight * window
                + coefficient * rightQ1[frequencyIndex]
                - rightQ2[frequencyIndex]
            rightQ2[frequencyIndex] = rightQ1[frequencyIndex]
            rightQ1[frequencyIndex] = nextRight
        }
        localFrame += 1
        guard localFrame == Policy.analysisBlockFrames else { return nil }
        active = false
        return BlackHoleFixedSpectralObservation(
            centerFrame: startFrame
                + UInt64(Policy.analysisBlockFrames / 2),
            leftQ1: leftQ1,
            leftQ2: leftQ2,
            rightQ1: rightQ1,
            rightQ2: rightQ2,
            leftSquareSum: leftSquareSum,
            rightSquareSum: rightSquareSum
        )
    }
}

private final class BlackHoleScalarMeasurementCollector: @unchecked Sendable {
    private let collectsTaggedChallenge: Bool
    private var queueStartMonotonicNs: UInt64 = 0
    private var windows = Array(
        repeating: BlackHoleMeasureWindowAccumulator(),
        count: BlackHoleMeasurePolicy.maximumTelemetryWindows
    )
    private var aggregate = BlackHoleMeasureWindowAccumulator()
    private var totalFrameCount: UInt64 = 0
    private var totalCallbackCount: UInt64 = 0
    private var previousBlockFrameCount = 0
    private var previousLeftHash: UInt64?
    private var previousRightHash: UInt64?
    private var leftRepeatRun: UInt64 = 0
    private var rightRepeatRun: UInt64 = 0
    private var spectralA = BlackHoleStreamingSpectralAccumulator()
    private var spectralB = BlackHoleStreamingSpectralAccumulator()
    private var spectralObservations = Array(
        repeating: BlackHoleFixedSpectralObservation(),
        count: BlackHoleMeasurePolicy.maximumSpectralObservations
    )
    private var spectralObservationCount = 0

    init(collectsTaggedChallenge: Bool) {
        self.collectsTaggedChallenge = collectsTaggedChallenge
        aggregate.initialize(sequence: 0)
        BlackHoleMeasureCadenceAccumulator.prepare()
        if collectsTaggedChallenge {
            BlackHoleStreamingSpectralAccumulator.prepare()
        }
    }

    func armForQueueStart(monotonicNs: UInt64) {
        precondition(totalCallbackCount == 0)
        queueStartMonotonicNs = monotonicNs
    }

    func ingest(
        samples: UnsafeBufferPointer<Int16>,
        timestamp: BlackHoleMeasureCallbackTimestamp
    ) {
        let safeSampleCount = samples.count
            - samples.count % BlackHoleMeasurePolicy.channels
        let callbackFrames = safeSampleCount / BlackHoleMeasurePolicy.channels
        guard callbackFrames > 0 else {
            totalCallbackCount &+= 1
            aggregate.recordCallback(
                frameCount: 0,
                timestamp: timestamp,
                leftRepeated: false,
                rightRepeated: false,
                leftRepeatRun: 0,
                rightRepeatRun: 0
            )
            return
        }

        var leftHash: UInt64 = 14_695_981_039_346_656_037
        var rightHash: UInt64 = 14_695_981_039_346_656_037
        for frame in 0..<callbackFrames {
            let base = frame * BlackHoleMeasurePolicy.channels
            leftHash ^= UInt64(UInt16(bitPattern: samples[base]))
            leftHash &*= 1_099_511_628_211
            rightHash ^= UInt64(UInt16(bitPattern: samples[base + 1]))
            rightHash &*= 1_099_511_628_211
        }
        leftHash ^= UInt64(callbackFrames)
        rightHash ^= UInt64(callbackFrames)
        let leftRepeated = previousBlockFrameCount == callbackFrames
            && previousLeftHash == leftHash
        let rightRepeated = previousBlockFrameCount == callbackFrames
            && previousRightHash == rightHash
        leftRepeatRun = leftRepeated ? leftRepeatRun &+ 1 : 0
        rightRepeatRun = rightRepeated ? rightRepeatRun &+ 1 : 0

        let callbackStartFrame = totalFrameCount
        for frame in 0..<callbackFrames {
            let sourceFrame = totalFrameCount
            let base = frame * BlackHoleMeasurePolicy.channels
            let left = samples[base]
            let right = samples[base + 1]
            let windowIndex = Int(sourceFrame)
                / BlackHoleMeasurePolicy.telemetryWindowFrames
            if windowIndex < windows.count {
                windows[windowIndex].initialize(sequence: windowIndex)
                windows[windowIndex].add(left: left, right: right)
            }
            aggregate.add(left: left, right: right)
            ingestSpectral(left: left, right: right, sourceFrame: sourceFrame)
            totalFrameCount &+= 1
        }

        let callbackEndFrame = totalFrameCount - 1
        let firstWindow = Int(callbackStartFrame)
            / BlackHoleMeasurePolicy.telemetryWindowFrames
        let lastWindow = Int(callbackEndFrame)
            / BlackHoleMeasurePolicy.telemetryWindowFrames
        if firstWindow < windows.count {
            let firstWindowEnd = UInt64(
                (firstWindow + 1)
                    * BlackHoleMeasurePolicy.telemetryWindowFrames
            )
            let firstFrames = Int(
                min(totalFrameCount, firstWindowEnd) - callbackStartFrame
            )
            windows[firstWindow].recordCallback(
                frameCount: firstFrames,
                timestamp: timestamp,
                leftRepeated: leftRepeated,
                rightRepeated: rightRepeated,
                leftRepeatRun: leftRepeatRun,
                rightRepeatRun: rightRepeatRun
            )
        }
        if lastWindow != firstWindow, lastWindow < windows.count {
            let lastWindowStart = UInt64(
                lastWindow * BlackHoleMeasurePolicy.telemetryWindowFrames
            )
            windows[lastWindow].recordCallback(
                frameCount: Int(totalFrameCount - lastWindowStart),
                timestamp: timestamp,
                leftRepeated: false,
                rightRepeated: false,
                leftRepeatRun: 0,
                rightRepeatRun: 0
            )
        }
        aggregate.recordCallback(
            frameCount: callbackFrames,
            timestamp: timestamp,
            leftRepeated: leftRepeated,
            rightRepeated: rightRepeated,
            leftRepeatRun: leftRepeatRun,
            rightRepeatRun: rightRepeatRun
        )
        totalCallbackCount &+= 1
        previousBlockFrameCount = callbackFrames
        previousLeftHash = leftHash
        previousRightHash = rightHash
    }

    func snapshot() -> (
        windows: [BlackHoleMeasureWindowEvidence],
        aggregate: BlackHoleMeasureAggregateEvidence,
        observations: [SpectralObservation],
        callbackCount: UInt64,
        frameCount: UInt64,
        measurementStartMonotonicNs: UInt64,
        measurementEndMonotonicNs: UInt64
    ) {
        let cadence = aggregate.cadence.evidence()
        let measurementStart = cadence.firstCallbackMonotonicNs != 0
            ? cadence.firstCallbackMonotonicNs
            : queueStartMonotonicNs
        let measurementEnd = aggregate.cadence.measurementEndMonotonicNs
        let evidence = windows.compactMap { window in
            window.initialized
                ? window.evidence(startMonotonicNs: measurementStart)
                : nil
        }
        return (
            windows: evidence,
            aggregate: BlackHoleMeasureAggregateEvidence(
                channels: [
                    aggregate.left.evidence(channel: 0),
                    aggregate.right.evidence(channel: 1),
                ],
                stereo: aggregate.stereo.evidence(),
                cadence: cadence
            ),
            observations: spectralObservations[..<spectralObservationCount]
                .map { $0.observation() },
            callbackCount: totalCallbackCount,
            frameCount: totalFrameCount,
            measurementStartMonotonicNs: measurementStart,
            measurementEndMonotonicNs: measurementEnd
        )
    }

    private func ingestSpectral(
        left: Int16,
        right: Int16,
        sourceFrame: UInt64
    ) {
        guard collectsTaggedChallenge else { return }
        if sourceFrame % UInt64(Policy.analysisHopFrames) == 0 {
            if !spectralA.active {
                spectralA.begin(at: sourceFrame)
            } else if !spectralB.active {
                spectralB.begin(at: sourceFrame)
            }
        }
        if let observation = spectralA.ingest(left: left, right: right) {
            appendSpectral(observation)
        }
        if let observation = spectralB.ingest(left: left, right: right) {
            appendSpectral(observation)
        }
    }

    private func appendSpectral(
        _ observation: BlackHoleFixedSpectralObservation
    ) {
        guard spectralObservationCount
                < BlackHoleMeasurePolicy.maximumSpectralObservations else {
            return
        }
        spectralObservations[spectralObservationCount] = observation
        spectralObservationCount += 1
    }
}

private final class BlackHoleMeasureLockFreeCallbackGate: @unchecked Sendable {
    private static let acceptingBit: Int32 = 1 << 30
    private static let inFlightMask: Int32 = acceptingBit - 1
    private var state: Int32 = 0

    func activate() {
        precondition(
            OSAtomicCompareAndSwap32Barrier(
                0,
                Self.acceptingBit,
                &state
            )
        )
    }

    /// One atomic increment both observes admission and acquires the in-flight
    /// lease, so teardown cannot miss a callback between a separate check and
    /// increment. A post-stop callback immediately returns its temporary count.
    func begin() -> Bool {
        let admittedState = OSAtomicIncrement32Barrier(&state)
        guard admittedState & Self.acceptingBit != 0 else {
            _ = OSAtomicDecrement32Barrier(&state)
            return false
        }
        return true
    }

    func end() {
        _ = OSAtomicDecrement32Barrier(&state)
    }

    func stopAccepting() {
        while true {
            let current = OSAtomicAdd32Barrier(0, &state)
            guard current & Self.acceptingBit != 0 else { return }
            if OSAtomicCompareAndSwap32Barrier(
                current,
                current & ~Self.acceptingBit,
                &state
            ) {
                return
            }
        }
    }

    /// Control-thread-only bounded polling. The AudioQueue callback never waits,
    /// locks, sleeps, allocates, or invokes this method.
    func waitUntilIdle() {
        while OSAtomicAdd32Barrier(0, &state) & Self.inFlightMask != 0 {
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
}

private final class BlackHoleMeasureQueueFailureLatch: @unchecked Sendable {
    private var failed: Int32 = 0

    func record(_ status: OSStatus) {
        guard status != noErr else { return }
        recordFailure()
    }

    func recordFailure() {
        _ = OSAtomicCompareAndSwap32Barrier(0, 1, &failed)
    }

    func hasFailure() -> Bool {
        OSAtomicAdd32Barrier(0, &failed) != 0
    }
}

private enum BlackHoleMeasureInputBufferContract {
    static func validatedSamples(
        in buffer: AudioQueueBufferRef,
        channels: Int = BlackHoleMeasurePolicy.channels
    ) -> UnsafeBufferPointer<Int16>? {
        guard channels > 0 else { return nil }
        let bytesPerFrame = channels * MemoryLayout<Int16>.size
        let byteCount = Int(buffer.pointee.mAudioDataByteSize)
        let byteCapacity = Int(buffer.pointee.mAudioDataBytesCapacity)
        guard byteCount > 0,
              byteCount <= byteCapacity,
              byteCount.isMultiple(of: bytesPerFrame) else {
            return nil
        }
        let audioData = buffer.pointee.mAudioData
        return UnsafeBufferPointer(
            start: audioData.assumingMemoryBound(to: Int16.self),
            count: byteCount / MemoryLayout<Int16>.size
        )
    }
}

private enum BlackHoleMeasureInputBufferContractSelfTest {
    static func passes() -> Bool {
        withBuffer(capacity: 16, byteCount: 16) {
            BlackHoleMeasureInputBufferContract.validatedSamples(in: $0)?
                .count == 8
        }
            && withBuffer(capacity: 16, byteCount: 0) {
                BlackHoleMeasureInputBufferContract.validatedSamples(in: $0)
                    == nil
            }
            && withBuffer(capacity: 16, byteCount: 2) {
                BlackHoleMeasureInputBufferContract.validatedSamples(in: $0)
                    == nil
            }
            && withBuffer(capacity: 16, byteCount: 20) {
                BlackHoleMeasureInputBufferContract.validatedSamples(in: $0)
                    == nil
            }
    }

    private static func withBuffer<Result>(
        capacity: UInt32,
        byteCount: UInt32,
        _ body: (AudioQueueBufferRef) -> Result
    ) -> Result {
        let sampleCapacity = max(
            1,
            (Int(capacity) + MemoryLayout<Int16>.stride - 1)
                / MemoryLayout<Int16>.stride
        )
        let samples = UnsafeMutablePointer<Int16>.allocate(
            capacity: sampleCapacity
        )
        samples.initialize(repeating: 0, count: sampleCapacity)
        defer {
            samples.deinitialize(count: sampleCapacity)
            samples.deallocate()
        }
        var buffer = AudioQueueBuffer(
            mAudioDataBytesCapacity: capacity,
            mAudioData: UnsafeMutableRawPointer(samples),
            mAudioDataByteSize: byteCount,
            mUserData: nil,
            mPacketDescriptionCapacity: 0,
            mPacketDescriptions: nil,
            mPacketDescriptionCount: 0
        )
        return withUnsafeMutablePointer(to: &buffer, body)
    }
}

private final class BlackHoleMeasureInputCallbackContext: @unchecked Sendable {
    let collector: BlackHoleScalarMeasurementCollector
    let failureLatch: BlackHoleMeasureQueueFailureLatch
    private let lifecycle = BlackHoleMeasureLockFreeCallbackGate()
    private var receivedFirstCallback: Int32 = 0

    init(
        collector: BlackHoleScalarMeasurementCollector,
        failureLatch: BlackHoleMeasureQueueFailureLatch
    ) {
        self.collector = collector
        self.failureLatch = failureLatch
    }

    func activate() { lifecycle.activate() }
    func stopAccepting() { lifecycle.stopAccepting() }
    func waitUntilIdle() { lifecycle.waitUntilIdle() }
    func hasReceivedFirstCallback() -> Bool {
        OSAtomicAdd32Barrier(0, &receivedFirstCallback) != 0
    }

    func handle(
        queue: AudioQueueRef,
        buffer: AudioQueueBufferRef,
        timestamp: BlackHoleMeasureCallbackTimestamp
    ) {
        guard lifecycle.begin() else { return }
        defer { lifecycle.end() }
        guard let samples =
                BlackHoleMeasureInputBufferContract.validatedSamples(
                    in: buffer,
                    channels: MirrorLoopbackPolicy.captureChannels
                ) else {
            failureLatch.recordFailure()
            return
        }
        collector.ingest(samples: samples, timestamp: timestamp)
        _ = OSAtomicCompareAndSwap32Barrier(
            0,
            1,
            &receivedFirstCallback
        )
        failureLatch.record(AudioQueueEnqueueBuffer(queue, buffer, 0, nil))
    }
}

private func blackHoleMeasureInputCallback(
    _ userData: UnsafeMutableRawPointer?,
    _ queue: AudioQueueRef,
    _ buffer: AudioQueueBufferRef,
    _ startTime: UnsafePointer<AudioTimeStamp>,
    _ packetCount: UInt32,
    _ packetDescriptions: UnsafePointer<AudioStreamPacketDescription>?
) {
    guard let userData else { return }
    Unmanaged<BlackHoleMeasureInputCallbackContext>
        .fromOpaque(userData)
        .takeUnretainedValue()
        .handle(
            queue: queue,
            buffer: buffer,
            timestamp: BlackHoleMeasureCallbackTimestamp(startTime.pointee)
        )
}

private final class BlackHoleMeasureInputQueueSession {
    private let context: BlackHoleMeasureInputCallbackContext
    private var queue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef] = []
    private var retainedContext:
        Unmanaged<BlackHoleMeasureInputCallbackContext>?
    private var started = false
    private var teardownFailed = false
    private(set) var readbackMatches = false

    init(
        collector: BlackHoleScalarMeasurementCollector,
        failureLatch: BlackHoleMeasureQueueFailureLatch
    ) {
        context = BlackHoleMeasureInputCallbackContext(
            collector: collector,
            failureLatch: failureLatch
        )
    }

    func start() throws {
        guard queue == nil else { return }
        context.activate()
        var description = AudioSupport.format(
            channels: BlackHoleMeasurePolicy.channels
        )
        var created: AudioQueueRef?
        let retained = Unmanaged.passRetained(context)
        let createStatus = AudioQueueNewInput(
            &description,
            blackHoleMeasureInputCallback,
            retained.toOpaque(),
            nil,
            nil,
            0,
            &created
        )
        guard createStatus == noErr, let created else {
            context.stopAccepting()
            context.waitUntilIdle()
            retained.release()
            throw ProbeError(code: "measure_capture_queue_create_failed")
        }
        retainedContext = retained
        queue = created
        do {
            let pinned = try AudioSupport.pinCurrentDevice(
                BlackHoleMeasurePolicy.captureUID,
                queue: created,
                failureCode: "measure_capture_queue_device_set_failed"
            )
            guard pinned else {
                throw ProbeError(
                    code: "measure_capture_queue_device_readback_mismatch"
                )
            }
            let byteCount = UInt32(
                Policy.bufferFrames * BlackHoleMeasurePolicy.channels
                    * MemoryLayout<Int16>.size
            )
            for _ in 0..<Policy.bufferCount {
                var buffer: AudioQueueBufferRef?
                guard AudioQueueAllocateBuffer(
                    created,
                    byteCount,
                    &buffer
                ) == noErr,
                let buffer else {
                    throw ProbeError(
                        code: "measure_capture_queue_buffer_allocation_failed"
                    )
                }
                buffers.append(buffer)
                guard AudioQueueEnqueueBuffer(created, buffer, 0, nil)
                        == noErr else {
                    throw ProbeError(
                        code: "measure_capture_queue_buffer_enqueue_failed"
                    )
                }
            }
            let requestedStartUptime = ProcessInfo.processInfo.systemUptime
            context.collector.armForQueueStart(
                monotonicNs: BlackHoleMeasureMath.monotonicNanoseconds(
                    requestedStartUptime
                )
            )
            guard AudioQueueStart(created, nil) == noErr else {
                throw ProbeError(code: "measure_capture_queue_start_failed")
            }
            started = true
            readbackMatches = currentDeviceMatches()
            guard readbackMatches else {
                throw ProbeError(
                    code: "measure_capture_queue_device_readback_mismatch"
                )
            }
        } catch {
            _ = stop()
            throw error
        }
    }

    func currentDeviceMatches() -> Bool {
        guard let queue else { return false }
        return AudioSupport.currentDevice(queue) == BlackHoleMeasurePolicy.captureUID
    }

    func hasReceivedFirstCallback() -> Bool {
        context.hasReceivedFirstCallback()
    }

    func stop() -> Bool {
        guard let queue else { return !teardownFailed }
        context.stopAccepting()
        var stopStatus: OSStatus = noErr
        if started {
            stopStatus = AudioQueueStop(queue, true)
            started = false
        }
        context.waitUntilIdle()
        let disposeStatus = AudioQueueDispose(queue, true)
        context.waitUntilIdle()
        // AudioQueueDispose is terminal once it returns, including when it
        // reports an error. Retaining the queue/context would make deinit call
        // dispose a second time on an already-terminal queue.
        self.queue = nil
        buffers.removeAll(keepingCapacity: false)
        retainedContext?.release()
        retainedContext = nil
        if stopStatus != noErr || disposeStatus != noErr {
            teardownFailed = true
        }
        return !teardownFailed
    }

    deinit { _ = stop() }
}

private enum CanonicalBlackHoleMeasureResolver {
    static func validate() throws -> DeviceIdentity {
        let matches = try CoreAudioReader.allDevices().filter {
            CoreAudioReader.uid($0) == BlackHoleMeasurePolicy.captureUID
        }
        guard matches.count == 1 else {
            throw ProbeError(code: "canonical_capture_device_not_found")
        }
        let identity = try CoreAudioReader.identity(matches[0])
        guard identity.objectClass == UInt32(kAudioDeviceClassID),
              identity.alive,
              identity.inputChannels >= BlackHoleMeasurePolicy.channels else {
            throw ProbeError(code: "canonical_capture_device_has_no_usable_input")
        }
        return identity
    }
}

private struct BlackHoleMeasureOptions {
    let durationSeconds: Double
    let resultPath: String
    let taggedChallengeNonce: String?
}

private enum BlackHoleMeasureSyntheticCase: String {
    case dualMonoTagged = "dual-mono-tagged"
    case leftOnlyTagged = "left-only-tagged"
    case antiPhaseTagged = "anti-phase-tagged"
    case wrongTag = "wrong-tag"
    case allZero = "all-zero"
    case dcClipped = "dc-clipped"
    case dcOffset = "dc-offset"
    case noise = "noise"
    case nearClip = "near-clip"
    case frozenBlocks = "frozen-blocks"
    case cadenceGap = "cadence-gap"
    case shortCapture = "short-capture"
    case startupDelay = "startup-delay"
    case nonmonotonicSampleTime = "nonmonotonic-sample-time"
    case nonmonotonicHostTime = "nonmonotonic-host-time"
    case sampleTimeGap = "sample-time-gap"
}

private enum BlackHoleMeasureResultBuilder {
    static func make(
        options: BlackHoleMeasureOptions,
        collector: BlackHoleScalarMeasurementCollector,
        elapsedSeconds: Double,
        captureUIDMatches: Bool,
        queueReadbackMatches: Bool,
        defaults: (
            inputEqual: Bool,
            outputEqual: Bool,
            systemOutputEqual: Bool,
            notificationCount: Int
        ),
        forcedFailures: [String]
    ) -> BlackHoleMeasureResult {
        let snapshot = collector.snapshot()
        let challenge = taggedChallengeEvidence(
            nonce: options.taggedChallengeNonce,
            durationSeconds: options.durationSeconds,
            observations: snapshot.observations
        )
        var reasons: [String] = []
        func add(_ code: String) {
            if reasons.count < BlackHoleMeasurePolicy.maximumFailureReasons,
               !reasons.contains(code) {
                reasons.append(code)
            }
        }
        forcedFailures.forEach(add)
        let capturedAudioSeconds =
            Double(snapshot.frameCount) / Policy.sampleRate
        let capturedDurationRatio = options.durationSeconds > 0
            ? capturedAudioSeconds / options.durationSeconds
            : 0
        let frameDensity = elapsedSeconds > 0
            ? capturedAudioSeconds / elapsedSeconds
            : 0
        if !captureUIDMatches { add("capture_uid_mismatch") }
        if !queueReadbackMatches { add("queue_device_readback_mismatch") }
        if snapshot.callbackCount == 0 || snapshot.frameCount == 0 {
            add("no_audio_callbacks")
        }
        if elapsedSeconds
            < options.durationSeconds
                * BlackHoleMeasurePolicy.minimumElapsedDurationRatio {
            add("insufficient_measurement_duration")
        }
        if capturedDurationRatio
            < BlackHoleMeasurePolicy.minimumCapturedDurationRatio {
            add("insufficient_capture_duration")
        }
        if frameDensity < BlackHoleMeasurePolicy.minimumFrameDensity
            || frameDensity > BlackHoleMeasurePolicy.maximumFrameDensity {
            add("frame_density_out_of_range")
        }
        let cadence = snapshot.aggregate.cadence
        if cadence.callbackGapOver25MsCount != 0 {
            add("callback_gap_over_25ms")
        }
        if cadence.sampleTimeMissingCount != 0 {
            add("sample_timestamp_missing")
        }
        if cadence.hostTimeMissingCount != 0 {
            add("host_timestamp_missing")
        }
        if cadence.nonMonotonicSampleTimeCount != 0 {
            add("nonmonotonic_sample_timestamp")
        }
        if cadence.nonMonotonicHostTimeCount != 0 {
            add("nonmonotonic_host_timestamp")
        }
        if cadence.sampleFrameDiscontinuityCount != 0 {
            add("sample_timestamp_discontinuity")
        }
        if !defaults.inputEqual { add("default_input_changed") }
        if !defaults.outputEqual { add("default_output_changed") }
        if !defaults.systemOutputEqual { add("default_system_output_changed") }
        if defaults.notificationCount != 0 {
            add("default_change_notification_observed")
        }
        if challenge.enabled, !challenge.recognized {
            add("tagged_challenge_not_recognized")
        }
        let status: String
        if !reasons.isEmpty {
            status = "failed"
        } else if challenge.enabled {
            status = "passed"
        } else {
            status = "completed"
        }
        return BlackHoleMeasureResult(
            schema: BlackHoleMeasurePolicy.schema,
            status: status,
            mode: BlackHoleMeasurePolicy.mode,
            canonicalCaptureUID: BlackHoleMeasurePolicy.captureUID,
            captureUIDMatches: captureUIDMatches,
            queueReadbackMatches: queueReadbackMatches,
            rawPCMRetained: false,
            rawPCMPersisted: false,
            outputOpened: false,
            defaultsMutated: false,
            format: AudioFormatEvidence(
                sampleRate: Policy.sampleRateInt,
                channels: BlackHoleMeasurePolicy.channels,
                signedInt16: true,
                interleaved: true
            ),
            requestedDurationSeconds: options.durationSeconds,
            elapsedSeconds: max(0, elapsedSeconds),
            capturedAudioSeconds: capturedAudioSeconds,
            capturedDurationRatio: capturedDurationRatio,
            frameDensity: frameDensity,
            measurementStartMonotonicNs:
                snapshot.measurementStartMonotonicNs,
            measurementEndMonotonicNs:
                snapshot.measurementEndMonotonicNs,
            callbackCount: snapshot.callbackCount,
            capturedFrameCount: snapshot.frameCount,
            telemetryWindowSeconds:
                BlackHoleMeasurePolicy.telemetryWindowSeconds,
            telemetryWindowLimit:
                BlackHoleMeasurePolicy.maximumTelemetryWindows,
            telemetryWindows: snapshot.windows,
            aggregate: snapshot.aggregate,
            taggedChallenge: challenge,
            defaultInputBeforeAfterEqual: defaults.inputEqual,
            defaultOutputBeforeAfterEqual: defaults.outputEqual,
            defaultSystemOutputBeforeAfterEqual: defaults.systemOutputEqual,
            defaultChangeNotificationCount: max(0, defaults.notificationCount),
            failureCode: reasons.first ?? "none",
            failureReasons: reasons
        )
    }

    private static func taggedChallengeEvidence(
        nonce: String?,
        durationSeconds: Double,
        observations: [SpectralObservation]
    ) -> BlackHoleTaggedChallengeEvidence {
        guard let nonce else {
            return BlackHoleTaggedChallengeEvidence(
                enabled: false,
                externallyInjected: false,
                algorithm: "none",
                version: 0,
                tagFingerprint: "",
                recognized: false,
                recognizedChannel: -1,
                channels: []
            )
        }
        let symbolCount = Int(ceil(
            (durationSeconds + Policy.maximumLagSeconds + 2.0)
                / Policy.symbolSeconds
        )) + Policy.frequencies.count
        let plan = ChallengePlan(nonce: nonce, symbolCount: symbolCount)
        let detections = (0..<BlackHoleMeasurePolicy.channels).map {
            Evaluator.detect(
                channel: $0,
                observations: observations,
                plan: plan,
                relativeWindowStart: 0
            )
        }
        let best = detections.max { $0.score < $1.score }
            ?? .zero(channel: 0)
        let recognized = best.symbolCount >= Policy.minimumSymbols
            && best.matchRatio >= Policy.minimumMatchRatio
            && best.normalizedCorrelation
                >= Policy.minimumNormalizedCorrelation
            && best.discriminationMargin
                >= Policy.minimumDiscriminationMargin
        let channelEvidence = detections.map {
            BlackHoleTaggedChannelEvidence(
                channel: $0.channel,
                symbolCount: $0.symbolCount,
                matchedSymbolCount: $0.matchedSymbolCount,
                matchRatio: $0.matchRatio,
                normalizedCorrelation: $0.normalizedCorrelation,
                discriminationMargin: $0.discriminationMargin,
                envelopeCorrelation: $0.envelopeCorrelation,
                detectedLagMs: $0.lagSeconds >= 0
                    ? $0.lagSeconds * 1_000.0
                    : -1
            )
        }
        return BlackHoleTaggedChallengeEvidence(
            enabled: true,
            externallyInjected: true,
            algorithm: Policy.algorithm,
            version: Policy.algorithmVersion,
            tagFingerprint: SHA256.hash(data: Data(nonce.utf8))
                .map { String(format: "%02x", $0) }
                .joined(),
            recognized: recognized,
            recognizedChannel: recognized ? best.channel : -1,
            channels: channelEvidence
        )
    }
}

private enum BlackHoleMeasureRunner {
    static func run(
        options: BlackHoleMeasureOptions,
        signalMonitor: SignalMonitor
    ) -> BlackHoleMeasureResult {
        let collector = BlackHoleScalarMeasurementCollector(
            collectsTaggedChallenge: options.taggedChallengeNonce != nil
        )
        let failureLatch = BlackHoleMeasureQueueFailureLatch()
        var session: BlackHoleMeasureInputQueueSession?
        var defaultGuard: DefaultDeviceGuard?
        var expectedDefaults: DefaultSnapshot?
        var expectedIdentity: DeviceIdentity?
        var captureUIDMatches = false
        var queueReadbackMatches = false
        var failures: [String] = []
        var measurementWallStart: Double?

        do {
            let identity = try CanonicalBlackHoleMeasureResolver.validate()
            expectedIdentity = identity
            captureUIDMatches = true
            let guardObject = DefaultDeviceGuard()
            defaultGuard = guardObject
            try guardObject.install()
            expectedDefaults = try guardObject.snapshot()
            let input = BlackHoleMeasureInputQueueSession(
                collector: collector,
                failureLatch: failureLatch
            )
            session = input
            try input.start()
            queueReadbackMatches = input.readbackMatches

            let firstCallbackDeadline = ProcessInfo.processInfo.systemUptime
                + BlackHoleMeasurePolicy.firstCallbackTimeoutSeconds
            while !input.hasReceivedFirstCallback(),
                  ProcessInfo.processInfo.systemUptime < firstCallbackDeadline {
                if signalMonitor.receivedSignal() != 0 {
                    failures.append("interrupted")
                    break
                }
                if failureLatch.hasFailure() {
                    failures.append("audio_queue_runtime_failure")
                    break
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            if failures.isEmpty, !input.hasReceivedFirstCallback() {
                failures.append("first_audio_callback_timeout")
            }

            if failures.isEmpty {
                let measurementStart = ProcessInfo.processInfo.systemUptime
                measurementWallStart = measurementStart
                let deadline = measurementStart + options.durationSeconds
                while ProcessInfo.processInfo.systemUptime < deadline {
                    if signalMonitor.receivedSignal() != 0 {
                        failures.append("interrupted")
                        break
                    }
                    if failureLatch.hasFailure() {
                        failures.append("audio_queue_runtime_failure")
                        break
                    }
                    guard input.currentDeviceMatches() else {
                        queueReadbackMatches = false
                        failures.append(
                            "queue_device_changed_during_measurement"
                        )
                        break
                    }
                    guard try guardObject.snapshot()
                            == expectedDefaults else {
                        failures.append(
                            "default_route_changed_during_measurement"
                        )
                        break
                    }
                    guard guardObject.notificationCount() == 0 else {
                        failures.append(
                            "default_change_notification_observed"
                        )
                        break
                    }
                    guard try CanonicalBlackHoleMeasureResolver.validate()
                            == identity else {
                        captureUIDMatches = false
                        failures.append(
                            "route_identity_changed_during_measurement"
                        )
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        } catch let error as ProbeError {
            failures.append(error.code)
        } catch {
            failures.append("unexpected_runtime_failure")
        }

        let elapsed = measurementWallStart.map {
            ProcessInfo.processInfo.systemUptime - $0
        } ?? 0
        queueReadbackMatches = queueReadbackMatches
            && (session?.currentDeviceMatches() ?? false)
        if session?.stop() == false {
            failures.append("audio_queue_teardown_failure")
        }
        if failureLatch.hasFailure() {
            failures.append("audio_queue_runtime_failure")
        }
        var defaultEvidence = (
            inputEqual: false,
            outputEqual: false,
            systemOutputEqual: false,
            notificationCount: 0
        )
        if let defaultGuard, let expectedDefaults {
            do {
                let after = try defaultGuard.snapshot()
                defaultEvidence.inputEqual =
                    after.inputUID == expectedDefaults.inputUID
                defaultEvidence.outputEqual =
                    after.outputUID == expectedDefaults.outputUID
                defaultEvidence.systemOutputEqual =
                    after.systemOutputUID
                        == expectedDefaults.systemOutputUID
            } catch {
                failures.append("default_after_snapshot_failed")
            }
            let listenerRemoved = defaultGuard.remove()
            // Removal synchronously drains the listener queue, so this final
            // read cannot miss a notification that was already queued at the
            // measurement/teardown boundary.
            defaultEvidence.notificationCount =
                defaultGuard.notificationCount()
            if !listenerRemoved {
                failures.append("default_device_listener_remove_failed")
            }
        } else {
            failures.append("default_guard_unavailable")
        }
        if let expectedIdentity {
            do {
                let finalIdentity =
                    try CanonicalBlackHoleMeasureResolver.validate()
                captureUIDMatches = captureUIDMatches
                    && finalIdentity == expectedIdentity
            } catch {
                captureUIDMatches = false
                failures.append("route_identity_changed_during_measurement")
            }
        }
        return BlackHoleMeasureResultBuilder.make(
            options: options,
            collector: collector,
            elapsedSeconds: elapsed,
            captureUIDMatches: captureUIDMatches,
            queueReadbackMatches: queueReadbackMatches,
            defaults: defaultEvidence,
            forcedFailures: failures
        )
    }
}

private enum BlackHoleMeasureSyntheticFactory {
    static func make(
        test: BlackHoleMeasureSyntheticCase,
        nonce: String
    ) -> (BlackHoleMeasureOptions, BlackHoleScalarMeasurementCollector) {
        let duration = BlackHoleMeasurePolicy.minimumDurationSeconds
        let startUptime = 10_000.0
        let startupDelay = test == .startupDelay ? 1.75 : 0
        let tagged = [
            BlackHoleMeasureSyntheticCase.dualMonoTagged,
            .leftOnlyTagged,
            .antiPhaseTagged,
            .wrongTag,
        ].contains(test)
        let collector = BlackHoleScalarMeasurementCollector(
            collectsTaggedChallenge: tagged
        )
        collector.armForQueueStart(
            monotonicNs: BlackHoleMeasureMath.monotonicNanoseconds(startUptime)
        )
        let options = BlackHoleMeasureOptions(
            durationSeconds: duration,
            resultPath: "/dev/null",
            taggedChallengeNonce: tagged ? nonce : nil
        )
        let signalNonce = test == .wrongTag ? nonce + ":wrong" : nonce
        let plan = ChallengePlan(nonce: signalNonce, symbolCount: 64)
        let generator = ChallengeGenerator(plan: plan)
        let totalFrames = test == .shortCapture
            ? Int(duration * Policy.sampleRate * 0.5)
            : Int(duration * Policy.sampleRate)
        let onsetFrames = Int(0.28 * Policy.sampleRate)
        var callbackStart = 0
        var timestampOffset = 0.0
        var callbackIndex = 0
        var noiseGenerator = SplitMix64(
            seed: ChallengePlan.seed(for: nonce + ":measure-noise")
        )
        while callbackStart < totalFrames {
            let callbackFrames = min(
                Policy.bufferFrames,
                totalFrames - callbackStart
            )
            var samples = Array(
                repeating: Int16(0),
                count: callbackFrames * BlackHoleMeasurePolicy.channels
            )
            for localFrame in 0..<callbackFrames {
                let frame = callbackStart + localFrame
                let base = localFrame * BlackHoleMeasurePolicy.channels
                let challengeValue: Int16
                if frame < onsetFrames {
                    challengeValue = 0
                } else {
                    challengeValue = AudioSupport.quantize(
                        generator.nextNormalized()
                    )
                }
                switch test {
                case .dualMonoTagged, .wrongTag:
                    samples[base] = challengeValue
                    samples[base + 1] = challengeValue
                case .leftOnlyTagged:
                    samples[base] = challengeValue
                    samples[base + 1] = 0
                case .antiPhaseTagged:
                    samples[base] = challengeValue
                    samples[base + 1] = Int16(
                        max(
                            Int32(Int16.min),
                            min(Int32(Int16.max), -Int32(challengeValue))
                        )
                    )
                case .allZero:
                    break
                case .dcClipped:
                    samples[base] = 32_767
                    samples[base + 1] = 32_767
                case .dcOffset:
                    samples[base] = 4_096
                    samples[base + 1] = 4_096
                case .noise:
                    let left = Int32(noiseGenerator.next() % 12_001) - 6_000
                    let right = Int32(noiseGenerator.next() % 12_001) - 6_000
                    samples[base] = Int16(left)
                    samples[base + 1] = Int16(right)
                case .nearClip:
                    let value: Int16 = frame.isMultiple(of: 2)
                        ? 32_759
                        : -32_759
                    samples[base] = value
                    samples[base + 1] = value
                case .frozenBlocks:
                    let phase = Double(localFrame)
                        * 2.0 * Double.pi * 1_000.0 / Policy.sampleRate
                    let value = AudioSupport.quantize(0.2 * sin(phase))
                    samples[base] = value
                    samples[base + 1] = value
                case .cadenceGap, .shortCapture, .startupDelay,
                     .nonmonotonicSampleTime, .nonmonotonicHostTime,
                     .sampleTimeGap:
                    let phase = Double(frame)
                        * 2.0 * Double.pi * 1_379.0 / Policy.sampleRate
                    let value = AudioSupport.quantize(0.15 * sin(phase))
                    samples[base] = value
                    samples[base + 1] = value
                }
            }
            if test == .cadenceGap, callbackStart == 200 * Policy.bufferFrames {
                timestampOffset += 0.20
            }
            var sampleTime = Double(callbackStart)
            if test == .nonmonotonicSampleTime, callbackIndex == 200 {
                sampleTime -= Double(Policy.bufferFrames)
            } else if test == .sampleTimeGap, callbackIndex >= 200 {
                sampleTime += Double(Policy.bufferFrames)
            }
            var callbackStartSeconds = startUptime + startupDelay
                + Double(callbackStart) / Policy.sampleRate
                + timestampOffset
            if test == .nonmonotonicHostTime, callbackIndex == 200 {
                callbackStartSeconds -= Double(Policy.bufferFrames)
                    / Policy.sampleRate
            }
            let hostTime = AudioConvertNanosToHostTime(
                BlackHoleMeasureMath.monotonicNanoseconds(
                    callbackStartSeconds
                )
            )
            samples.withUnsafeBufferPointer {
                collector.ingest(
                    samples: $0,
                    timestamp: BlackHoleMeasureCallbackTimestamp(
                        sampleTime: sampleTime,
                        hostTime: hostTime
                    )
                )
            }
            callbackStart += callbackFrames
            callbackIndex += 1
        }
        return (options, collector)
    }
}

private enum BlackHoleMeasureWriter {
    static func write(_ result: BlackHoleMeasureResult, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) {
            guard !isDirectory.boolValue else {
                throw ProbeError(code: "result_path_is_directory")
            }
            try FileManager.default.removeItem(at: url)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp"
            )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try encoder.encode(result).write(to: temporary)
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_RDONLY)
        }
        if descriptor >= 0 {
            _ = Darwin.fsync(descriptor)
            _ = Darwin.close(descriptor)
        }
        let renameStatus = temporary.path.withCString { source in
            url.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renameStatus == 0 else {
            throw ProbeError(code: "result_atomic_rename_failed")
        }
    }
}

private enum BlackHoleMeasureProgram {
    static let usage = """
    Usage:
      physical-blackhole-microphone-probe measure --duration-seconds <8...30> --result <json-path> [--tagged-challenge-nonce <fresh-nonsecret-token>]
      physical-blackhole-microphone-probe measure-self-test --case <dual-mono-tagged|left-only-tagged|anti-phase-tagged|wrong-tag|all-zero|dc-clipped|dc-offset|noise|near-clip|frozen-blocks|cadence-gap|short-capture|startup-delay|nonmonotonic-sample-time|nonmonotonic-host-time|sample-time-gap> --nonce <fresh-nonsecret-token> --result <json-path>

    The measure command opens only BlackHole input by its stable UID. It never opens an output queue or mutates any default device. The optional tagged challenge must be injected externally; the nonce itself is not written to the result. Only bounded scalar summaries are retained.
    """

    static func runIfRequested() -> Int32? {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first,
              command == "measure" || command == "measure-self-test" else {
            return nil
        }
        do {
            let pairs = try parsePairs(Array(arguments.dropFirst()))
            switch command {
            case "measure":
                let allowedKeys = Set([
                    "--duration-seconds",
                    "--result",
                    "--tagged-challenge-nonce",
                ])
                guard Set(pairs.keys).isSubset(of: allowedKeys),
                      Set(pairs.keys).isSuperset(of: [
                        "--duration-seconds",
                        "--result",
                      ]),
                      let durationText = pairs["--duration-seconds"],
                      let duration = Double(durationText),
                      duration.isFinite,
                      duration >= BlackHoleMeasurePolicy.minimumDurationSeconds,
                      duration <= BlackHoleMeasurePolicy.maximumDurationSeconds,
                      let resultPath = pairs["--result"] else {
                    throw ProbeError(code: "usage")
                }
                try validateResultPath(resultPath)
                if let nonce = pairs["--tagged-challenge-nonce"] {
                    try validateNonce(nonce)
                }
                let options = BlackHoleMeasureOptions(
                    durationSeconds: duration,
                    resultPath: resultPath,
                    taggedChallengeNonce:
                        pairs["--tagged-challenge-nonce"]
                )
                let result = BlackHoleMeasureRunner.run(
                    options: options,
                    signalMonitor: SignalMonitor()
                )
                try BlackHoleMeasureWriter.write(
                    result,
                    to: URL(fileURLWithPath: resultPath)
                )
                return result.status == "failed" ? 1 : 0
            case "measure-self-test":
                guard Set(pairs.keys) == Set([
                    "--case",
                    "--nonce",
                    "--result",
                ]),
                let caseName = pairs["--case"],
                let test = BlackHoleMeasureSyntheticCase(rawValue: caseName),
                let nonce = pairs["--nonce"],
                let resultPath = pairs["--result"] else {
                    throw ProbeError(code: "usage")
                }
                try validateNonce(nonce)
                try validateResultPath(resultPath)
                guard BlackHoleMeasureInputBufferContractSelfTest.passes()
                        else {
                    throw ProbeError(
                        code: "measure_input_buffer_contract_self_test_failed"
                    )
                }
                let fixture = BlackHoleMeasureSyntheticFactory.make(
                    test: test,
                    nonce: nonce
                )
                let result = BlackHoleMeasureResultBuilder.make(
                    options: BlackHoleMeasureOptions(
                        durationSeconds: fixture.0.durationSeconds,
                        resultPath: resultPath,
                        taggedChallengeNonce:
                            fixture.0.taggedChallengeNonce
                    ),
                    collector: fixture.1,
                    elapsedSeconds: fixture.0.durationSeconds,
                    captureUIDMatches: true,
                    queueReadbackMatches: true,
                    defaults: (
                        inputEqual: true,
                        outputEqual: true,
                        systemOutputEqual: true,
                        notificationCount: 0
                    ),
                    forcedFailures: []
                )
                try BlackHoleMeasureWriter.write(
                    result,
                    to: URL(fileURLWithPath: resultPath)
                )
                return result.status == "failed" ? 1 : 0
            default:
                throw ProbeError(code: "usage")
            }
        } catch let error as ProbeError where error.code == "usage" {
            FileHandle.standardError.write(Data(usage.utf8))
            return 64
        } catch {
            return 74
        }
    }

    private static func parsePairs(
        _ arguments: [String]
    ) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else {
            throw ProbeError(code: "usage")
        }
        var pairs: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            let value = arguments[index + 1]
            guard key.hasPrefix("--"), pairs[key] == nil, !value.isEmpty else {
                throw ProbeError(code: "usage")
            }
            pairs[key] = value
            index += 2
        }
        return pairs
    }

    private static func validateNonce(_ nonce: String) throws {
        guard nonce.utf8.count >= 8, nonce.utf8.count <= 128 else {
            throw ProbeError(code: "usage")
        }
        for byte in nonce.utf8 {
            let allowed = (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45 || byte == 46 || byte == 58 || byte == 95
            guard allowed else { throw ProbeError(code: "usage") }
        }
    }

    private static func validateResultPath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 4_096 else {
            throw ProbeError(code: "usage")
        }
    }
}
// MARK: - Deterministic repo-owned virtual-microphone loopback oracle

private enum MirrorLoopbackPolicy {
    static let schema = "opensteamer.virtual-microphone-mirror-loopback.v2"
    static let projectionSchema =
        "opensteamer.facetime-timestamp-projection.v1"
    static let algorithm = "nonce-splitmix64-mono-sentinel-prbs"
    static let algorithmVersion = 2
    static let visibleUID = Policy.captureUID
    static let hiddenUID = Policy.hiddenMirrorUID
    static let modelUID = Policy.modelUID
    static let clockDomain = Policy.clockDomain
    static let sampleRate = 48_000
    static let consumerSampleRate = 24_000
    static let captureChannels = 1
    static let challengeFrames = 96_000
    static let sentinelFrames = 256
    static let syntheticPrefixFrames = 480
    static let maximumAlignmentFrames = 48_000
    static let postRollFrames = queueBufferCount * callbackFrames
    static let maximumRetainedFrames =
        challengeFrames + maximumAlignmentFrames + postRollFrames
    static let callbackFrames = 480
    static let queueBufferCount = 4
    static let minimumReadyInputCallbacks = 2
    static let inputReadinessDeadlineSeconds = 1.0
    static let realDeadlineSeconds = 8.0
    static let runningStateRestoreDeadlineSeconds = 1.0
    static let maximumRestartInitialFrame: UInt64 = 48_000
    static let minimumProductionHeadroomSeconds = 60.0
    static let maximumHostDeltaErrorNs: UInt64 = 1_000_000
    static let maximumHeadroomSeconds = 86_400.0
    static let maximumFailureReasons = 32
}

private struct MirrorLoopbackFormatEvidence: Codable, Equatable {
    let sampleRate: Double
    let formatID: String
    let formatFlags: UInt32
    let floatingPoint: Bool
    let signedInteger: Bool
    let packed: Bool
    let nativeEndian: Bool
    let interleaved: Bool
    let bytesPerPacket: Int
    let framesPerPacket: Int
    let bytesPerFrame: Int
    let channelsPerFrame: Int
    let bitsPerChannel: Int
    let reserved: UInt32

    static let canonical = MirrorLoopbackFormatEvidence(
        sampleRate: Double(MirrorLoopbackPolicy.sampleRate),
        formatID: "lpcm",
        formatFlags: kAudioFormatFlagIsSignedInteger
            | kAudioFormatFlagIsPacked,
        floatingPoint: false,
        signedInteger: true,
        packed: true,
        nativeEndian: true,
        interleaved: true,
        bytesPerPacket: 2,
        framesPerPacket: 1,
        bytesPerFrame: 2,
        channelsPerFrame: MirrorLoopbackPolicy.captureChannels,
        bitsPerChannel: 16,
        reserved: 0
    )

    static let canonicalDeviceFloat = MirrorLoopbackFormatEvidence(
        sampleRate: Double(MirrorLoopbackPolicy.sampleRate),
        formatID: "lpcm",
        formatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        floatingPoint: true,
        signedInteger: false,
        packed: true,
        nativeEndian: true,
        interleaved: true,
        bytesPerPacket: 4,
        framesPerPacket: 1,
        bytesPerFrame: 4,
        channelsPerFrame: MirrorLoopbackPolicy.captureChannels,
        bitsPerChannel: 32,
        reserved: 0
    )

    static let unavailable = MirrorLoopbackFormatEvidence(
        sampleRate: 0,
        formatID: "unavailable",
        formatFlags: 0,
        floatingPoint: false,
        signedInteger: false,
        packed: false,
        nativeEndian: false,
        interleaved: false,
        bytesPerPacket: 0,
        framesPerPacket: 0,
        bytesPerFrame: 0,
        channelsPerFrame: 0,
        bitsPerChannel: 0,
        reserved: 0
    )
}

private struct MirrorLoopbackChallengeEvidence: Codable {
    let algorithm: String
    let version: Int
    let nonceFingerprint: String
    let frameCount: Int
    let sampleCount: Int
    let sentinelFrameCount: Int
    let expectedPCMHash: String
    let capturedAlignedPCMHash: String
}

private struct MirrorLoopbackEndpointEvidence: Codable {
    let expectedUID: String
    let resolvedUID: String
    let objectID: UInt32
    let translatedByExactUID: Bool
    let alive: Bool
    let hidden: Bool
    let inputChannels: Int
    let outputChannels: Int
    let nominalSampleRate: Double
    let modelUIDFingerprint: String
    let modelUIDMatchesExpected: Bool
    let clockDomain: UInt32
}

private struct MirrorLoopbackEndpointPairEvidence: Codable {
    let visible: MirrorLoopbackEndpointEvidence
    let hidden: MirrorLoopbackEndpointEvidence
    let objectIDsDistinct: Bool
    let modelUIDsMatch: Bool
    let clockDomainsMatch: Bool
    let deviceChangeNotificationCount: Int
}

private struct MirrorLoopbackQueueContractEvidence: Codable {
    let requestedFormat: MirrorLoopbackFormatEvidence
    let captureReadbackFormat: MirrorLoopbackFormatEvidence
    let writerReadbackFormat: MirrorLoopbackFormatEvidence
    let captureDeviceVirtualFormat: MirrorLoopbackFormatEvidence
    let captureDevicePhysicalFormat: MirrorLoopbackFormatEvidence
    let writerDeviceVirtualFormat: MirrorLoopbackFormatEvidence
    let writerDevicePhysicalFormat: MirrorLoopbackFormatEvidence
    let captureQueueUIDReadback: String
    let writerQueueUIDReadback: String
    let visibleInputMuted: Bool
    let hiddenOutputMuted: Bool
    let visibleInputVolumeScalar: Double
    let hiddenOutputVolumeScalar: Double
    let writerQueueVolumeScalar: Double
    let captureQueueUIDMatches: Bool
    let writerQueueUIDMatches: Bool
    let captureFormatMatches: Bool
    let writerFormatMatches: Bool
    let captureDeviceFormatMatches: Bool
    let writerDeviceFormatMatches: Bool
    let signalControlsMatch: Bool
    let writerQueueVolumeMatches: Bool
    let writerPrimingFrameCount: Int
    let writerCallbackCount: Int
    let writerSubmittedChallengeFrameCount: Int
    let writerChallengeFullySubmitted: Bool
}

private struct MirrorLoopbackPCMEvidence: Codable {
    let retainedSampleLimit: Int
    let capturedSampleCount: Int
    let totalObservedSampleCount: Int
    let rawCaptureCallbackCount: Int
    let capturedOverflow: Bool
    let comparisonAvailable: Bool
    let alignmentCount: Int
    let alignedStartFrame: Int
    let nonzeroSampleCount: Int
    let absolutePeak: Int
    let rootMeanSquare: Double
    let retainedPCMHash: String
    let comparedFrameCount: Int
    let matchedFrameCount: Int
    let mismatchSampleCount: Int
    let missingFrameCount: Int
    let requiredPostRollFrameCount: Int
    let capturedPostRollFrameCount: Int
    let postRollNonzeroSampleCount: Int
    let postRollAbsolutePeak: Int
    let postRollSilenceMatches: Bool
    let unexpectedTrailingFrameCount: Int
    let exactPCMMatches: Bool
    let signedInt16Compatible: Bool
}

private struct MirrorLoopbackProjectionEvidence: Codable {
    let schema: String
    let sourceSampleRate: Int
    let consumerSampleRate: Int
    let ratioNumerator: Int
    let ratioDenominator: Int
    let rounding: String
    let signedMinimum: Int64
    let signedMaximum: Int64
    let projectedFirstFrame: UInt64
    let projectedLastFrame: UInt64
    let claimedProjectedLastFrame: UInt64
    let claimMatchesCalculation: Bool
    let requiredHeadroomSeconds: Double
    let requiredHeadroomFrames: UInt64
    let remainingHeadroomFrames: Int64
    let signed32Compatible: Bool
    let headroomSatisfied: Bool
}

private struct MirrorLoopbackTimestampEvidence: Codable {
    let alignedEvidenceAvailable: Bool
    let callbackCount: Int
    let rawCaptureCallbackCount: Int
    let rawCapturedFrameCount: Int
    let timestampFrameCount: UInt64
    let sampleTimeValidCount: Int
    let sampleTimeMissingCount: Int
    let hostTimeValidCount: Int
    let hostTimeMissingCount: Int
    let nonIntegralSampleTimeCount: Int
    let nonMonotonicSampleTimeCount: Int
    let sampleFrameDiscontinuityCount: Int
    let nonMonotonicHostTimeCount: Int
    let hostDeltaMismatchCount: Int
    let maximumHostDeltaErrorNs: UInt64
    let firstRawSampleFrame: UInt64
    let lastRawSampleFrame: UInt64
    let lastRawSampleFrameExclusive: UInt64
    let measuredSourceSampleRate: Double
    let sourceSampleRateMatches: Bool
    let deviceTimePairCount: Int
    let deviceTimeSampleFlagMissingCount: Int
    let deviceTimeHostFlagMissingCount: Int
    let nonIntegralDeviceSampleTimeCount: Int
    let nonAdvancingDeviceTimeCount: Int
    let deviceTimeRateMismatchCount: Int
    let mirrorDeviceTimeMismatchCount: Int
    let projection: MirrorLoopbackProjectionEvidence
}

private struct MirrorLoopbackDefaultsEvidence: Codable {
    let beforeFingerprint: String
    let afterFingerprint: String
    let inputBeforeAfterEqual: Bool
    let outputBeforeAfterEqual: Bool
    let systemOutputBeforeAfterEqual: Bool
    let notificationCount: Int
    let mutated: Bool
    let hiddenEndpointNeverDefault: Bool
    let virtualEndpointsNeverOutputDefault: Bool
}

private struct MirrorLoopbackTeardownEvidence: Codable {
    let cleanupEvidenceComplete: Bool
    let queuesOpened: Bool
    let inputStopStatus: Int32
    let outputStopStatus: Int32
    let inputDisposeStatus: Int32
    let outputDisposeStatus: Int32
    let callbackGatesDrained: Bool
    let postCloseCallbackCount: Int
    let runningStateRestored: Bool
    let defaultListenerInstalled: Bool
    let deviceListenerInstalled: Bool
    let listenersRemoved: Bool
    let contextsReleased: Bool
}

private struct MirrorLoopbackRestartCycleEvidence: Codable {
    let startOrder: String
    let quiescentBefore: Bool
    let quiescentAfter: Bool
    let initialVisibleSampleFrame: UInt64
    let initialHiddenSampleFrame: UInt64
    let finalVisibleSampleFrame: UInt64
    let finalHiddenSampleFrame: UInt64
    let nearZeroSharedClock: Bool
    let timelinesAdvanced: Bool
    let queuesStoppedAndDisposed: Bool
}

private struct MirrorLoopbackLifecycleEvidence: Codable {
    let requiredStartOrders: [String]
    let cycles: [MirrorLoopbackRestartCycleEvidence]
    // Core Audio exposes sample/host time but not the plug-in's
    // zero-timestamp seed. This oracle therefore never claims seed identity.
    let zeroTimestampSeedObservableViaPublicAPI: Bool
    let seedChangeClaimed: Bool
}

private struct MirrorLoopbackResult: Codable {
    let schema: String
    let status: String
    let mode: String
    let realQueuePathImplemented: Bool
    let challenge: MirrorLoopbackChallengeEvidence
    let endpointPair: MirrorLoopbackEndpointPairEvidence
    let queueContract: MirrorLoopbackQueueContractEvidence
    let pcm: MirrorLoopbackPCMEvidence
    let timestamps: MirrorLoopbackTimestampEvidence
    let defaults: MirrorLoopbackDefaultsEvidence
    let lifecycle: MirrorLoopbackLifecycleEvidence
    let teardown: MirrorLoopbackTeardownEvidence
    let failureCode: String
    let failureReasons: [String]
}

private enum MirrorLoopbackPCM {
    static func challenge(nonce: String) -> [Int16] {
        var generator = SplitMix64(
            seed: ChallengePlan.seed(for: nonce + ":mirror:mono")
        )
        var samples: [Int16] = []
        samples.reserveCapacity(MirrorLoopbackPolicy.challengeFrames)
        for frame in 0..<MirrorLoopbackPolicy.challengeFrames {
            if frame < MirrorLoopbackPolicy.sentinelFrames {
                let code = Int32((frame * 257 + 73) % 8_001)
                samples.append(Int16(12_000 + code))
            } else {
                var sample = Int16(
                    Int32(generator.next() % 48_001) - 24_000
                )
                if sample == 0 { sample = 1 }
                samples.append(sample)
            }
        }
        return samples
    }

    static func hash<C: Collection>(_ samples: C) -> String
    where C.Element == Int16 {
        var data = Data(capacity: samples.count * MemoryLayout<UInt16>.size)
        for sample in samples {
            var word = UInt16(bitPattern: sample).littleEndian
            withUnsafeBytes(of: &word) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

private struct MirrorLoopbackTimestampRecord {
    var sampleTime: Double
    var hostTimeNs: UInt64
    var frameCount: Int
    var sampleTimeValid: Bool
    var hostTimeValid: Bool
}

private struct MirrorLoopbackDeviceTimeObservation {
    var sampleTime: Double
    var hostTimeNs: UInt64
    var sampleTimeValid: Bool
    var hostTimeValid: Bool
}

private struct MirrorLoopbackDeviceTimePair {
    var visible: MirrorLoopbackDeviceTimeObservation
    var hidden: MirrorLoopbackDeviceTimeObservation
}

private struct MirrorLoopbackProjectionClaim {
    var sourceSampleRate: Int
    var consumerSampleRate: Int
    var ratioNumerator: Int
    var ratioDenominator: Int
    var rounding: String
    var projectedLastFrame: UInt64
}

private struct MirrorLoopbackFixture {
    var visible: MirrorLoopbackEndpointEvidence
    var hidden: MirrorLoopbackEndpointEvidence
    var modelUIDsMatch: Bool
    var deviceChangeNotificationCount: Int
    var requestedFormat: MirrorLoopbackFormatEvidence
    var captureReadbackFormat: MirrorLoopbackFormatEvidence
    var writerReadbackFormat: MirrorLoopbackFormatEvidence
    var captureDeviceVirtualFormat: MirrorLoopbackFormatEvidence
    var captureDevicePhysicalFormat: MirrorLoopbackFormatEvidence
    var writerDeviceVirtualFormat: MirrorLoopbackFormatEvidence
    var writerDevicePhysicalFormat: MirrorLoopbackFormatEvidence
    var captureQueueUIDReadback: String
    var writerQueueUIDReadback: String
    var visibleInputMuted: Bool
    var hiddenOutputMuted: Bool
    var visibleInputVolumeScalar: Double
    var hiddenOutputVolumeScalar: Double
    var writerQueueVolumeScalar: Double
    var writerPrimingFrameCount: Int
    var writerCallbackCount: Int
    var writerSubmittedChallengeFrameCount: Int
    var captureBufferContractValidated: Bool
    var captured: [Int16]
    var totalObservedFrameCount: Int
    var rawCaptureCallbackCount: Int
    var captureOverflow: Bool
    var timestamps: [MirrorLoopbackTimestampRecord]
    var deviceTimePairs: [MirrorLoopbackDeviceTimePair]
    var projectionClaim: MirrorLoopbackProjectionClaim
    var defaultsBefore: DefaultSnapshot
    var defaultsAfter: DefaultSnapshot
    var defaultNotificationCount: Int
    var lifecycle: MirrorLoopbackLifecycleEvidence
    var teardown: MirrorLoopbackTeardownEvidence
}

private enum MirrorLoopbackMath {
    static func projected24kFrame(_ raw48kFrame: UInt64) -> UInt64 {
        // ceil(raw * 24_000 / 48_000), written without overflowing raw * rate.
        raw48kFrame / 2 + (raw48kFrame.isMultiple(of: 2) ? 0 : 1)
    }

    static func requiredHeadroomFrames(seconds: Double) -> UInt64 {
        UInt64(ceil(seconds * Double(MirrorLoopbackPolicy.consumerSampleRate)))
    }

    static func exactFrame(_ value: Double) -> UInt64? {
        guard value.isFinite,
              value >= 0,
              // Double(UInt64.max) rounds up to the first unrepresentable
              // UInt64 value (2^64), so the bound must be strict.
              value < 18_446_744_073_709_551_616.0,
              value.rounded() == value else {
            return nil
        }
        return UInt64(value)
    }
}

private enum MirrorLoopbackEvaluator {
    static func evaluate(
        nonce: String,
        requiredHeadroomSeconds: Double,
        fixture: MirrorLoopbackFixture,
        mode: String = "synthetic-self-test",
        realQueuePathImplemented: Bool = false,
        forcedFailureReasons: [String] = []
    ) -> MirrorLoopbackResult {
        let expected = MirrorLoopbackPCM.challenge(nonce: nonce)
        let expectedFrames = expected.count / MirrorLoopbackPolicy.captureChannels
        let retainedSampleLimit = MirrorLoopbackPolicy.maximumRetainedFrames
            * MirrorLoopbackPolicy.captureChannels
        let capturedOverflow = fixture.captureOverflow
            || fixture.captured.count > retainedSampleLimit
        let retained = Array(fixture.captured.prefix(retainedSampleLimit))
        let capturedFrames = retained.count / MirrorLoopbackPolicy.captureChannels
        let requestedFormatMatches = fixture.requestedFormat
            == MirrorLoopbackFormatEvidence.canonical
        let captureFormatMatches = fixture.captureReadbackFormat
            == MirrorLoopbackFormatEvidence.canonical
        let writerFormatMatches = fixture.writerReadbackFormat
            == MirrorLoopbackFormatEvidence.canonical
        let captureDeviceFormatMatches = fixture.captureDeviceVirtualFormat
            == MirrorLoopbackFormatEvidence.canonicalDeviceFloat
            && fixture.captureDevicePhysicalFormat
                == MirrorLoopbackFormatEvidence.canonicalDeviceFloat
        let writerDeviceFormatMatches = fixture.writerDeviceVirtualFormat
            == MirrorLoopbackFormatEvidence.canonicalDeviceFloat
            && fixture.writerDevicePhysicalFormat
                == MirrorLoopbackFormatEvidence.canonicalDeviceFloat
        let signedInt16Compatible = requestedFormatMatches
            && captureFormatMatches
            && fixture.captureBufferContractValidated
            && fixture.rawCaptureCallbackCount > 0
        let totalObservedFrames = max(
            capturedFrames,
            max(0, fixture.totalObservedFrameCount)
        )
        var nonzeroSamples = 0
        var absolutePeak = 0
        var squareSum = 0.0
        for sample in retained {
            let magnitude = abs(Int(sample))
            if sample != 0 { nonzeroSamples += 1 }
            absolutePeak = max(absolutePeak, magnitude)
            squareSum += Double(sample) * Double(sample)
        }
        let rootMeanSquare = retained.isEmpty
            ? 0 : sqrt(squareSum / Double(retained.count))
        let sentinelSamples = MirrorLoopbackPolicy.sentinelFrames
            * MirrorLoopbackPolicy.captureChannels

        func alignments() -> [Int] {
            guard retained.count.isMultiple(
                    of: MirrorLoopbackPolicy.captureChannels
                  ), retained.count >= sentinelSamples else {
                return []
            }
            let latest = min(
                MirrorLoopbackPolicy.maximumAlignmentFrames,
                capturedFrames - MirrorLoopbackPolicy.sentinelFrames
            )
            guard latest >= 0 else { return [] }
            var matches: [Int] = []
            for startFrame in 0...latest {
                var matchesSentinel = true
                for frame in 0..<MirrorLoopbackPolicy.sentinelFrames {
                    if retained[startFrame + frame] != expected[frame] {
                        matchesSentinel = false
                        break
                    }
                }
                if matchesSentinel { matches.append(startFrame) }
            }
            return matches
        }

        let normalAlignments = alignments()
        let comparisonAvailable = normalAlignments.count == 1
        let alignedStart = normalAlignments.count == 1
            ? normalAlignments[0]
            : -1
        var comparedFrames = 0
        var matchedFrames = 0
        var mismatchSamples = 0
        var missingFrames = expectedFrames
        var capturedPostRollFrames = 0
        var postRollNonzeroSamples = 0
        var postRollAbsolutePeak = 0
        var unexpectedTrailingFrames = 0
        var alignedHash = MirrorLoopbackPCM.hash([Int16]())
        if alignedStart >= 0 {
            let availableFrames = max(0, capturedFrames - alignedStart)
            comparedFrames = min(expectedFrames, availableFrames)
            missingFrames = max(0, expectedFrames - comparedFrames)
            let firstSample = alignedStart * MirrorLoopbackPolicy.captureChannels
            let comparedSamples = comparedFrames
                * MirrorLoopbackPolicy.captureChannels
            alignedHash = MirrorLoopbackPCM.hash(
                retained[firstSample..<(firstSample + comparedSamples)]
            )
            for frame in 0..<comparedFrames {
                let matches = retained[firstSample + frame]
                    == expected[frame]
                if matches { matchedFrames += 1 } else { mismatchSamples += 1 }
            }
            let availablePostRollFrames = max(
                0,
                availableFrames - expectedFrames
            )
            capturedPostRollFrames = min(
                MirrorLoopbackPolicy.postRollFrames,
                availablePostRollFrames
            )
            let postRollStartSample = firstSample
                + expectedFrames * MirrorLoopbackPolicy.captureChannels
            for frame in 0..<capturedPostRollFrames {
                let base = postRollStartSample
                    + frame * MirrorLoopbackPolicy.captureChannels
                var frameIsNonzero = false
                for channel in 0..<MirrorLoopbackPolicy.captureChannels {
                    let sample = retained[base + channel]
                    if sample != 0 {
                        postRollNonzeroSamples += 1
                        frameIsNonzero = true
                    }
                    postRollAbsolutePeak = max(
                        postRollAbsolutePeak,
                        abs(Int(sample))
                    )
                }
                if frameIsNonzero { unexpectedTrailingFrames += 1 }
            }
        }
        let postRollSilenceMatches = capturedPostRollFrames
                == MirrorLoopbackPolicy.postRollFrames
            && postRollNonzeroSamples == 0
        let exactPCMMatches = !capturedOverflow
            && normalAlignments.count == 1
            && comparedFrames == expectedFrames
            && matchedFrames == expectedFrames
            && mismatchSamples == 0
            && missingFrames == 0
        let pcm = MirrorLoopbackPCMEvidence(
            retainedSampleLimit: retainedSampleLimit,
            capturedSampleCount: fixture.captured.count,
            totalObservedSampleCount:
                totalObservedFrames * MirrorLoopbackPolicy.captureChannels,
            rawCaptureCallbackCount: max(0, fixture.rawCaptureCallbackCount),
            capturedOverflow: capturedOverflow,
            comparisonAvailable: comparisonAvailable,
            alignmentCount: normalAlignments.count,
            alignedStartFrame: alignedStart,
            nonzeroSampleCount: nonzeroSamples,
            absolutePeak: absolutePeak,
            rootMeanSquare: rootMeanSquare,
            retainedPCMHash: MirrorLoopbackPCM.hash(retained),
            comparedFrameCount: comparedFrames,
            matchedFrameCount: matchedFrames,
            mismatchSampleCount: mismatchSamples,
            missingFrameCount: missingFrames,
            requiredPostRollFrameCount: MirrorLoopbackPolicy.postRollFrames,
            capturedPostRollFrameCount: capturedPostRollFrames,
            postRollNonzeroSampleCount: postRollNonzeroSamples,
            postRollAbsolutePeak: postRollAbsolutePeak,
            postRollSilenceMatches: postRollSilenceMatches,
            unexpectedTrailingFrameCount: unexpectedTrailingFrames,
            exactPCMMatches: exactPCMMatches,
            signedInt16Compatible: signedInt16Compatible
        )

        let timestampEvidence = evaluateTimestamps(
            fixture.timestamps,
            alignedEvidenceAvailable: comparisonAvailable,
            rawCaptureCallbackCount: max(0, fixture.rawCaptureCallbackCount),
            rawCapturedFrameCount: totalObservedFrames,
            deviceTimePairs: fixture.deviceTimePairs,
            claim: fixture.projectionClaim,
            requiredHeadroomSeconds: requiredHeadroomSeconds
        )
        let signalControlsMatch = !fixture.visibleInputMuted
            && !fixture.hiddenOutputMuted
            && fixture.visibleInputVolumeScalar == 1.0
            && fixture.hiddenOutputVolumeScalar == 1.0
        let writerQueueVolumeMatches =
            fixture.writerQueueVolumeScalar == 1.0
        let writerChallengeFullySubmitted =
            fixture.writerSubmittedChallengeFrameCount
                == MirrorLoopbackPolicy.challengeFrames
        let queueContract = MirrorLoopbackQueueContractEvidence(
            requestedFormat: fixture.requestedFormat,
            captureReadbackFormat: fixture.captureReadbackFormat,
            writerReadbackFormat: fixture.writerReadbackFormat,
            captureDeviceVirtualFormat: fixture.captureDeviceVirtualFormat,
            captureDevicePhysicalFormat: fixture.captureDevicePhysicalFormat,
            writerDeviceVirtualFormat: fixture.writerDeviceVirtualFormat,
            writerDevicePhysicalFormat: fixture.writerDevicePhysicalFormat,
            captureQueueUIDReadback: fixture.captureQueueUIDReadback,
            writerQueueUIDReadback: fixture.writerQueueUIDReadback,
            visibleInputMuted: fixture.visibleInputMuted,
            hiddenOutputMuted: fixture.hiddenOutputMuted,
            visibleInputVolumeScalar: fixture.visibleInputVolumeScalar,
            hiddenOutputVolumeScalar: fixture.hiddenOutputVolumeScalar,
            writerQueueVolumeScalar: fixture.writerQueueVolumeScalar,
            captureQueueUIDMatches: fixture.captureQueueUIDReadback
                == MirrorLoopbackPolicy.visibleUID,
            writerQueueUIDMatches: fixture.writerQueueUIDReadback
                == MirrorLoopbackPolicy.hiddenUID,
            captureFormatMatches: requestedFormatMatches
                && captureFormatMatches,
            writerFormatMatches: requestedFormatMatches
                && writerFormatMatches,
            captureDeviceFormatMatches: captureDeviceFormatMatches,
            writerDeviceFormatMatches: writerDeviceFormatMatches,
            signalControlsMatch: signalControlsMatch,
            writerQueueVolumeMatches: writerQueueVolumeMatches,
            writerPrimingFrameCount: max(0, fixture.writerPrimingFrameCount),
            writerCallbackCount: max(0, fixture.writerCallbackCount),
            writerSubmittedChallengeFrameCount:
                max(0, fixture.writerSubmittedChallengeFrameCount),
            writerChallengeFullySubmitted: writerChallengeFullySubmitted
        )
        let endpointPair = MirrorLoopbackEndpointPairEvidence(
            visible: fixture.visible,
            hidden: fixture.hidden,
            objectIDsDistinct: fixture.visible.objectID
                != fixture.hidden.objectID,
            modelUIDsMatch: fixture.modelUIDsMatch,
            clockDomainsMatch: fixture.visible.clockDomain
                == fixture.hidden.clockDomain,
            deviceChangeNotificationCount:
                max(0, fixture.deviceChangeNotificationCount)
        )

        let defaultsEqual = fixture.defaultsBefore == fixture.defaultsAfter
        let hiddenNeverDefault = [
            fixture.defaultsBefore.inputUID,
            fixture.defaultsBefore.outputUID,
            fixture.defaultsBefore.systemOutputUID,
            fixture.defaultsAfter.inputUID,
            fixture.defaultsAfter.outputUID,
            fixture.defaultsAfter.systemOutputUID,
        ].allSatisfy {
            $0 != MirrorLoopbackPolicy.hiddenUID
                && $0 != Policy.legacyHiddenUID
        }
        let virtualEndpointsNeverOutputDefault = [
            fixture.defaultsBefore.outputUID,
            fixture.defaultsBefore.systemOutputUID,
            fixture.defaultsAfter.outputUID,
            fixture.defaultsAfter.systemOutputUID,
        ].allSatisfy {
            $0 != MirrorLoopbackPolicy.visibleUID
                && $0 != MirrorLoopbackPolicy.hiddenUID
                && $0 != Policy.legacyVisibleUID
                && $0 != Policy.legacyHiddenUID
        }
        let defaults = MirrorLoopbackDefaultsEvidence(
            beforeFingerprint: defaultFingerprint(fixture.defaultsBefore),
            afterFingerprint: defaultFingerprint(fixture.defaultsAfter),
            inputBeforeAfterEqual: fixture.defaultsBefore.inputUID
                == fixture.defaultsAfter.inputUID,
            outputBeforeAfterEqual: fixture.defaultsBefore.outputUID
                == fixture.defaultsAfter.outputUID,
            systemOutputBeforeAfterEqual:
                fixture.defaultsBefore.systemOutputUID
                    == fixture.defaultsAfter.systemOutputUID,
            notificationCount: max(0, fixture.defaultNotificationCount),
            mutated: !defaultsEqual || fixture.defaultNotificationCount != 0,
            hiddenEndpointNeverDefault: hiddenNeverDefault,
            virtualEndpointsNeverOutputDefault:
                virtualEndpointsNeverOutputDefault
        )

        var reasons: [String] = []
        func add(_ reason: String) {
            if reasons.count < MirrorLoopbackPolicy.maximumFailureReasons,
               !reasons.contains(reason) {
                reasons.append(reason)
            }
        }
        for reason in forcedFailureReasons { add(reason) }
        if !queueContract.captureDeviceFormatMatches
            || !queueContract.writerDeviceFormatMatches {
            add("device_stream_format_mismatch")
        }
        if fixture.visibleInputMuted || fixture.hiddenOutputMuted {
            add("signal_path_muted")
        }
        if fixture.visibleInputVolumeScalar != 1.0
            || fixture.hiddenOutputVolumeScalar != 1.0 {
            add("device_volume_not_unity")
        }
        if !queueContract.writerQueueVolumeMatches {
            add("writer_queue_volume_mismatch")
        }
        if fixture.rawCaptureCallbackCount
            < MirrorLoopbackPolicy.minimumReadyInputCallbacks {
            add("input_capture_not_ready")
        }
        if fixture.writerPrimingFrameCount
            < MirrorLoopbackPolicy.queueBufferCount
                * MirrorLoopbackPolicy.callbackFrames {
            add("writer_silence_priming_incomplete")
        }
        if fixture.writerCallbackCount <= 0
            || !writerChallengeFullySubmitted {
            add("writer_challenge_not_submitted")
        }
        if normalAlignments.isEmpty {
            add("challenge_alignment_not_found")
        } else if normalAlignments.count != 1 {
            add("challenge_alignment_not_unique")
        }
        if capturedOverflow { add("captured_pcm_overflow") }
        if comparisonAvailable && !exactPCMMatches {
            add("exact_pcm_mismatch")
        }
        if comparisonAvailable,
           capturedPostRollFrames < MirrorLoopbackPolicy.postRollFrames {
            add("post_roll_incomplete")
        }
        if comparisonAvailable && postRollNonzeroSamples != 0 {
            add("post_roll_not_silent")
        }
        if comparisonAvailable {
            if timestampEvidence.sampleTimeMissingCount != 0
                || timestampEvidence.hostTimeMissingCount != 0 {
                add("timestamp_flags_missing")
            }
            if timestampEvidence.nonIntegralSampleTimeCount != 0 {
                add("nonintegral_sample_timestamp")
            }
            if timestampEvidence.nonMonotonicSampleTimeCount != 0 {
                add("nonmonotonic_sample_timestamp")
            }
            if timestampEvidence.sampleFrameDiscontinuityCount != 0 {
                add("sample_timestamp_discontinuity")
            }
            if timestampEvidence.nonMonotonicHostTimeCount != 0 {
                add("nonmonotonic_host_timestamp")
            }
            // AudioQueue callback host cadence reflects delivery scheduling,
            // so its 1 ms residual threshold is retained as telemetry. The
            // end-to-end sample/host slope owns the source clock verdict.
            if !timestampEvidence.sourceSampleRateMatches {
                add("host_sample_clock_mismatch")
            }
            if timestampEvidence.timestampFrameCount
                != UInt64(MirrorLoopbackPolicy.challengeFrames) {
                add("timestamp_frame_count_mismatch")
            }
        }
        if timestampEvidence.deviceTimePairCount != 2 {
            add("device_time_observation_count_mismatch")
        }
        if timestampEvidence.deviceTimeSampleFlagMissingCount != 0
            || timestampEvidence.deviceTimeHostFlagMissingCount != 0 {
            add("device_time_flags_missing")
        }
        if timestampEvidence.nonIntegralDeviceSampleTimeCount != 0 {
            add("nonintegral_device_sample_time")
        }
        if timestampEvidence.nonAdvancingDeviceTimeCount != 0 {
            add("device_time_not_advancing")
        }
        if timestampEvidence.deviceTimeRateMismatchCount != 0 {
            add("device_time_rate_mismatch")
        }
        if timestampEvidence.mirrorDeviceTimeMismatchCount != 0 {
            add("mirror_device_time_mismatch")
        }
        if !timestampEvidence.projection.claimMatchesCalculation {
            add("projection_evidence_mismatch")
        }
        if !timestampEvidence.projection.signed32Compatible {
            add("projected_sample_time_exceeds_signed32")
        }
        if !timestampEvidence.projection.headroomSatisfied {
            add("insufficient_signed32_headroom")
        }
        if fixture.visible.expectedUID != MirrorLoopbackPolicy.visibleUID
            || fixture.visible.resolvedUID != MirrorLoopbackPolicy.visibleUID
            || !fixture.visible.translatedByExactUID
            || fixture.visible.hidden
            || !fixture.visible.alive
            || fixture.visible.inputChannels
                != MirrorLoopbackPolicy.captureChannels
            || fixture.visible.outputChannels != 0
            || fixture.visible.nominalSampleRate
                != Double(MirrorLoopbackPolicy.sampleRate) {
            add("visible_endpoint_identity_mismatch")
        }
        if fixture.hidden.expectedUID != MirrorLoopbackPolicy.hiddenUID
            || fixture.hidden.resolvedUID != MirrorLoopbackPolicy.hiddenUID
            || !fixture.hidden.translatedByExactUID
            || !fixture.hidden.hidden
            || !fixture.hidden.alive
            || fixture.hidden.inputChannels != 0
            || fixture.hidden.outputChannels
                != MirrorLoopbackPolicy.captureChannels
            || fixture.hidden.nominalSampleRate
                != Double(MirrorLoopbackPolicy.sampleRate) {
            add("hidden_endpoint_identity_mismatch")
        }
        if fixture.visible.objectID == fixture.hidden.objectID
            || !fixture.modelUIDsMatch
            || !fixture.visible.modelUIDMatchesExpected
            || !fixture.hidden.modelUIDMatchesExpected {
            add("mirror_endpoint_pair_mismatch")
        }
        if fixture.visible.clockDomain != MirrorLoopbackPolicy.clockDomain
            || fixture.hidden.clockDomain != MirrorLoopbackPolicy.clockDomain
            || fixture.visible.clockDomain != fixture.hidden.clockDomain {
            add("clock_domain_mismatch")
        }
        if fixture.deviceChangeNotificationCount != 0 {
            add("device_change_notification_observed")
        }
        if !queueContract.captureQueueUIDMatches
            || !queueContract.writerQueueUIDMatches {
            add("queue_device_readback_mismatch")
        }
        if !queueContract.captureFormatMatches
            || !queueContract.writerFormatMatches {
            add("queue_format_readback_mismatch")
        }
        if !signedInt16Compatible {
            add("capture_buffer_contract_unproven")
        }
        if !defaultsEqual { add("default_route_changed") }
        if fixture.defaultNotificationCount != 0 {
            add("default_change_notification_observed")
        }
        if !hiddenNeverDefault { add("hidden_endpoint_became_default") }
        if !virtualEndpointsNeverOutputDefault {
            add("virtual_endpoint_became_output_default")
        }
        let lifecycle = fixture.lifecycle
        if lifecycle.requiredStartOrders != ["visible-first", "hidden-first"]
            || lifecycle.cycles.map(\.startOrder)
                != lifecycle.requiredStartOrders
            || lifecycle.cycles.count != 2
            || lifecycle.cycles.contains(where: {
                !$0.quiescentBefore || !$0.quiescentAfter
                    || !$0.queuesStoppedAndDisposed
            }) {
            add("restart_lifecycle_incomplete")
        }
        if lifecycle.cycles.contains(where: { !$0.nearZeroSharedClock }) {
            add("restart_clock_not_near_zero")
        }
        if lifecycle.cycles.contains(where: { !$0.timelinesAdvanced }) {
            add("restart_timeline_not_advancing")
        }
        if lifecycle.zeroTimestampSeedObservableViaPublicAPI
            || lifecycle.seedChangeClaimed {
            add("zero_timestamp_seed_claim_exceeds_public_api")
        }
        let teardown = fixture.teardown
        if !teardown.cleanupEvidenceComplete {
            add("cleanup_evidence_incomplete")
        }
        if teardown.inputStopStatus != noErr
            || teardown.outputStopStatus != noErr
            || teardown.inputDisposeStatus != noErr
            || teardown.outputDisposeStatus != noErr {
            add("audio_queue_teardown_failure")
        }
        // AudioQueueStop/Dispose may synchronously deliver terminal callbacks.
        // Once the gates are closed those callbacks are rejected before they
        // can inspect PCM or mutate the positive buffer-contract proof, so a
        // nonzero count is diagnostic evidence rather than a teardown error.
        if !teardown.callbackGatesDrained
            || teardown.postCloseCallbackCount < 0 {
            add("callback_gate_teardown_failure")
        }
        if !teardown.runningStateRestored {
            add("device_running_state_not_restored")
        }
        if !teardown.listenersRemoved {
            add("listener_remove_failed")
        }
        if !teardown.contextsReleased {
            add("callback_context_not_released")
        }

        return MirrorLoopbackResult(
            schema: MirrorLoopbackPolicy.schema,
            status: reasons.isEmpty ? "passed" : "failed",
            mode: mode,
            realQueuePathImplemented: realQueuePathImplemented,
            challenge: MirrorLoopbackChallengeEvidence(
                algorithm: MirrorLoopbackPolicy.algorithm,
                version: MirrorLoopbackPolicy.algorithmVersion,
                nonceFingerprint: MirrorLoopbackPCM.fingerprint(nonce),
                frameCount: expectedFrames,
                sampleCount: expected.count,
                sentinelFrameCount: MirrorLoopbackPolicy.sentinelFrames,
                expectedPCMHash: MirrorLoopbackPCM.hash(expected),
                capturedAlignedPCMHash: alignedHash
            ),
            endpointPair: endpointPair,
            queueContract: queueContract,
            pcm: pcm,
            timestamps: timestampEvidence,
            defaults: defaults,
            lifecycle: lifecycle,
            teardown: teardown,
            failureCode: reasons.first ?? "none",
            failureReasons: reasons
        )
    }

    private static func defaultFingerprint(_ value: DefaultSnapshot) -> String {
        MirrorLoopbackPCM.fingerprint(
            value.inputUID + "\u{0}" + value.outputUID + "\u{0}"
                + value.systemOutputUID
        )
    }

    private static func evaluateTimestamps(
        _ records: [MirrorLoopbackTimestampRecord],
        alignedEvidenceAvailable: Bool,
        rawCaptureCallbackCount: Int,
        rawCapturedFrameCount: Int,
        deviceTimePairs: [MirrorLoopbackDeviceTimePair],
        claim: MirrorLoopbackProjectionClaim,
        requiredHeadroomSeconds: Double
    ) -> MirrorLoopbackTimestampEvidence {
        var sampleValid = 0
        var sampleMissing = 0
        var hostValid = 0
        var hostMissing = 0
        var nonIntegral = 0
        var nonMonotonicSample = 0
        var sampleDiscontinuity = 0
        var nonMonotonicHost = 0
        var hostMismatch = 0
        var maximumHostError: UInt64 = 0
        var timestampFrames: UInt64 = 0
        var firstSample: UInt64?
        var lastSampleStart: UInt64?
        var firstHost: UInt64?
        var lastHost: UInt64?
        var previousSample: UInt64?
        var previousFrames = 0
        var previousHost: UInt64?

        for record in records {
            let frames = max(0, record.frameCount)
            timestampFrames &+= UInt64(frames)
            var exactSample: UInt64?
            if record.sampleTimeValid {
                sampleValid += 1
                exactSample = MirrorLoopbackMath.exactFrame(record.sampleTime)
                if exactSample == nil { nonIntegral += 1 }
            } else {
                sampleMissing += 1
            }
            if let exactSample {
                if firstSample == nil { firstSample = exactSample }
                if let previousSample {
                    if exactSample <= previousSample {
                        nonMonotonicSample += 1
                    }
                    if exactSample != previousSample + UInt64(previousFrames) {
                        sampleDiscontinuity += 1
                    }
                }
                previousSample = exactSample
                previousFrames = frames
                lastSampleStart = exactSample
            }

            if record.hostTimeValid {
                hostValid += 1
                if firstHost == nil { firstHost = record.hostTimeNs }
                if let previousHost {
                    if record.hostTimeNs <= previousHost {
                        nonMonotonicHost += 1
                    } else {
                        let observed = record.hostTimeNs - previousHost
                        let expected = UInt64(
                            (Double(previousFrames) * 1_000_000_000.0
                                / Double(MirrorLoopbackPolicy.sampleRate))
                                .rounded()
                        )
                        let error = observed >= expected
                            ? observed - expected
                            : expected - observed
                        maximumHostError = max(maximumHostError, error)
                        if error > MirrorLoopbackPolicy
                            .maximumHostDeltaErrorNs {
                            hostMismatch += 1
                        }
                    }
                }
                previousHost = record.hostTimeNs
                lastHost = record.hostTimeNs
            } else {
                hostMissing += 1
            }
        }

        var deviceSampleFlagsMissing = 0
        var deviceHostFlagsMissing = 0
        var nonIntegralDeviceSample = 0
        var nonAdvancingDeviceTime = 0
        var deviceRateMismatch = 0
        var mirrorDeviceTimeMismatch = 0
        var exactDevicePairs: [(visible: UInt64?, hidden: UInt64?)] = []
        exactDevicePairs.reserveCapacity(deviceTimePairs.count)
        for pair in deviceTimePairs {
            func exact(
                _ observation: MirrorLoopbackDeviceTimeObservation
            ) -> UInt64? {
                guard observation.sampleTimeValid else {
                    deviceSampleFlagsMissing += 1
                    return nil
                }
                guard let frame = MirrorLoopbackMath.exactFrame(
                    observation.sampleTime
                ) else {
                    nonIntegralDeviceSample += 1
                    return nil
                }
                return frame
            }
            if !pair.visible.hostTimeValid { deviceHostFlagsMissing += 1 }
            if !pair.hidden.hostTimeValid { deviceHostFlagsMissing += 1 }
            let visibleFrame = exact(pair.visible)
            let hiddenFrame = exact(pair.hidden)
            exactDevicePairs.append(
                (visible: visibleFrame, hidden: hiddenFrame)
            )
            if let visibleFrame, let hiddenFrame,
               pair.visible.hostTimeValid, pair.hidden.hostTimeValid {
                let sampleDelta = Double(hiddenFrame)
                    - Double(visibleFrame)
                let hostDeltaFrames = (
                    Double(pair.hidden.hostTimeNs)
                        - Double(pair.visible.hostTimeNs)
                ) * Double(MirrorLoopbackPolicy.sampleRate)
                    / 1_000_000_000.0
                if abs(sampleDelta - hostDeltaFrames) > 4.0 {
                    mirrorDeviceTimeMismatch += 1
                }
            }
        }

        if let firstPair = deviceTimePairs.first,
           let lastPair = deviceTimePairs.last,
           let firstExact = exactDevicePairs.first,
           let lastExact = exactDevicePairs.last {
            func evaluateAdvance(
                first: MirrorLoopbackDeviceTimeObservation,
                last: MirrorLoopbackDeviceTimeObservation,
                firstFrame: UInt64?,
                lastFrame: UInt64?
            ) {
                guard let firstFrame, let lastFrame,
                      first.hostTimeValid, last.hostTimeValid else { return }
                guard lastFrame > firstFrame,
                      last.hostTimeNs > first.hostTimeNs else {
                    nonAdvancingDeviceTime += 1
                    return
                }
                let measuredRate = Double(lastFrame - firstFrame)
                    * 1_000_000_000.0
                    / Double(last.hostTimeNs - first.hostTimeNs)
                if abs(
                    measuredRate - Double(MirrorLoopbackPolicy.sampleRate)
                ) > 1.0 {
                    deviceRateMismatch += 1
                }
            }
            evaluateAdvance(
                first: firstPair.visible,
                last: lastPair.visible,
                firstFrame: firstExact.visible,
                lastFrame: lastExact.visible
            )
            evaluateAdvance(
                first: firstPair.hidden,
                last: lastPair.hidden,
                firstFrame: firstExact.hidden,
                lastFrame: lastExact.hidden
            )
        }

        let firstDeviceFrames = exactDevicePairs.first.map {
            [$0.visible, $0.hidden].compactMap { $0 }
        } ?? []
        let lastDeviceFrames = exactDevicePairs.last.map {
            [$0.visible, $0.hidden].compactMap { $0 }
        } ?? []
        let firstRaw = firstDeviceFrames.min() ?? 0
        // The later explicit device-time read, not callback-relative time,
        // owns the FaceTime signed-32 projection decision.
        let lastRaw = lastDeviceFrames.max() ?? 0
        let lastExclusive = lastRaw == UInt64.max ? UInt64.max : lastRaw + 1
        let projectedFirst = MirrorLoopbackMath.projected24kFrame(firstRaw)
        let projectedLast = MirrorLoopbackMath.projected24kFrame(lastRaw)
        let requiredFrames = MirrorLoopbackMath.requiredHeadroomFrames(
            seconds: requiredHeadroomSeconds
        )
        let signedMaximum = Int64(Int32.max)
        let remaining = projectedLast <= UInt64(Int64.max)
            ? signedMaximum - Int64(projectedLast)
            : Int64.min
        let signedCompatible = projectedLast <= UInt64(Int32.max)
        let headroomSatisfied = signedCompatible
            && UInt64(max(0, remaining)) >= requiredFrames
        let claimMatches = claim.sourceSampleRate
                == MirrorLoopbackPolicy.sampleRate
            && claim.consumerSampleRate
                == MirrorLoopbackPolicy.consumerSampleRate
            && claim.ratioNumerator == 1
            && claim.ratioDenominator == 2
            && claim.rounding == "conservative-ceiling"
            && claim.projectedLastFrame == projectedLast

        var measuredRate = 0.0
        var sourceRateMatches = false
        if let firstSample, let lastSampleStart,
           let firstHost, let lastHost,
           lastSampleStart > firstSample, lastHost > firstHost {
            measuredRate = Double(lastSampleStart - firstSample)
                * 1_000_000_000.0 / Double(lastHost - firstHost)
            sourceRateMatches = abs(
                measuredRate - Double(MirrorLoopbackPolicy.sampleRate)
            ) <= 1.0
        }

        return MirrorLoopbackTimestampEvidence(
            alignedEvidenceAvailable: alignedEvidenceAvailable,
            callbackCount: records.count,
            rawCaptureCallbackCount: rawCaptureCallbackCount,
            rawCapturedFrameCount: rawCapturedFrameCount,
            timestampFrameCount: timestampFrames,
            sampleTimeValidCount: sampleValid,
            sampleTimeMissingCount: sampleMissing,
            hostTimeValidCount: hostValid,
            hostTimeMissingCount: hostMissing,
            nonIntegralSampleTimeCount: nonIntegral,
            nonMonotonicSampleTimeCount: nonMonotonicSample,
            sampleFrameDiscontinuityCount: sampleDiscontinuity,
            nonMonotonicHostTimeCount: nonMonotonicHost,
            hostDeltaMismatchCount: hostMismatch,
            maximumHostDeltaErrorNs: maximumHostError,
            firstRawSampleFrame: firstRaw,
            lastRawSampleFrame: lastRaw,
            lastRawSampleFrameExclusive: lastExclusive,
            measuredSourceSampleRate: measuredRate,
            sourceSampleRateMatches: sourceRateMatches,
            deviceTimePairCount: deviceTimePairs.count,
            deviceTimeSampleFlagMissingCount: deviceSampleFlagsMissing,
            deviceTimeHostFlagMissingCount: deviceHostFlagsMissing,
            nonIntegralDeviceSampleTimeCount: nonIntegralDeviceSample,
            nonAdvancingDeviceTimeCount: nonAdvancingDeviceTime,
            deviceTimeRateMismatchCount: deviceRateMismatch,
            mirrorDeviceTimeMismatchCount: mirrorDeviceTimeMismatch,
            projection: MirrorLoopbackProjectionEvidence(
                schema: MirrorLoopbackPolicy.projectionSchema,
                sourceSampleRate: MirrorLoopbackPolicy.sampleRate,
                consumerSampleRate:
                    MirrorLoopbackPolicy.consumerSampleRate,
                ratioNumerator: 1,
                ratioDenominator: 2,
                rounding: "conservative-ceiling",
                signedMinimum: Int64(Int32.min),
                signedMaximum: signedMaximum,
                projectedFirstFrame: projectedFirst,
                projectedLastFrame: projectedLast,
                claimedProjectedLastFrame: claim.projectedLastFrame,
                claimMatchesCalculation: claimMatches,
                requiredHeadroomSeconds: requiredHeadroomSeconds,
                requiredHeadroomFrames: requiredFrames,
                remainingHeadroomFrames: remaining,
                signed32Compatible: signedCompatible,
                headroomSatisfied: headroomSatisfied
            )
        )
    }
}

private enum MirrorLoopbackSyntheticCase: String, CaseIterable {
    case healthy
    case capturedOverflow = "captured-overflow"
    case liveStyleOverflow = "live-style-overflow"
    case capBoundaryPass = "cap-boundary-pass"
    case capBoundaryFail = "cap-boundary-fail"
    case capturedAgedClock = "captured-aged-clock"
    case headroomBoundaryPass = "headroom-boundary-pass"
    case headroomBoundaryFail = "headroom-boundary-fail"
    case wrongProjection = "wrong-projection"
    case wrongRounding = "wrong-rounding"
    case droppedFrame = "dropped-frame"
    case duplicatedFrame = "duplicated-frame"
    case bitFlip = "bit-flip"
    case gainChange = "gain-change"
    case silence
    case shortCapture = "short-capture"
    case timestampFlags = "timestamp-flags"
    case deviceTimeFlags = "device-time-flags"
    case frozenDeviceTime = "frozen-device-time"
    case divergentDeviceTime = "divergent-device-time"
    case nonintegralSampleTime = "nonintegral-sample-time"
    case unrepresentableSampleTime = "unrepresentable-sample-time"
    case sampleTimeRegression = "sample-time-regression"
    case sampleTimeGap = "sample-time-gap"
    case hostTimeRegression = "host-time-regression"
    case transientHostSchedulingJitter =
        "transient-host-scheduling-jitter"
    case hostTimeMismatch = "host-time-mismatch"
    case format
    case fractionalFormat = "fractional-format"
    case extraFormatFlag = "extra-format-flag"
    case reservedFormat = "reserved-format"
    case deviceFormat = "device-format"
    case physicalDeviceFormat = "physical-device-format"
    case writerPhysicalDeviceFormat = "writer-physical-device-format"
    case stereoFormat = "stereo-format"
    case fractionalNominalRate = "fractional-nominal-rate"
    case wrongRole = "wrong-role"
    case clockDomain = "clock-domain"
    case controlMute = "control-mute"
    case deviceVolume = "device-volume"
    case queueVolume = "queue-volume"
    case inputNotReady = "input-not-ready"
    case bufferContract = "buffer-contract"
    case writerNoProgress = "writer-no-progress"
    case postRollNoise = "post-roll-noise"
    case visibleUID = "visible-uid"
    case hiddenUID = "hidden-uid"
    case queueUID = "queue-uid"
    case defaultMutation = "default-mutation"
    case defaultNotification = "default-notification"
    case hiddenDefault = "hidden-default"
    case legacyOutputDefault = "legacy-output-default"
    case deviceNotification = "device-notification"
    case teardownStop = "teardown-stop"
    case teardownDispose = "teardown-dispose"
    case teardownGate = "teardown-gate"
    case teardownPostClose = "teardown-post-close"
    case cleanupEvidence = "cleanup-evidence"
    case listenerRemove = "listener-remove"
    case runningState = "running-state"
}

private enum MirrorLoopbackSyntheticFactory {
    static func make(
        test: MirrorLoopbackSyntheticCase,
        nonce: String,
        requiredHeadroomSeconds: Double
    ) -> MirrorLoopbackFixture {
        let challenge = MirrorLoopbackPCM.challenge(nonce: nonce)
        var captured = Array(
            repeating: Int16(0),
            count: MirrorLoopbackPolicy.syntheticPrefixFrames
                * MirrorLoopbackPolicy.captureChannels
        )
        captured.append(contentsOf: challenge)
        captured.append(
            contentsOf: Array(
                repeating: Int16(0),
                count: MirrorLoopbackPolicy.postRollFrames
                    * MirrorLoopbackPolicy.captureChannels
            )
        )
        let modelFingerprint = MirrorLoopbackPCM.fingerprint(
            MirrorLoopbackPolicy.modelUID
        )
        let visible = MirrorLoopbackEndpointEvidence(
            expectedUID: MirrorLoopbackPolicy.visibleUID,
            resolvedUID: MirrorLoopbackPolicy.visibleUID,
            objectID: 101,
            translatedByExactUID: true,
            alive: true,
            hidden: false,
            inputChannels: 1,
            outputChannels: 0,
            nominalSampleRate: Double(MirrorLoopbackPolicy.sampleRate),
            modelUIDFingerprint: modelFingerprint,
            modelUIDMatchesExpected: true,
            clockDomain: MirrorLoopbackPolicy.clockDomain
        )
        let hidden = MirrorLoopbackEndpointEvidence(
            expectedUID: MirrorLoopbackPolicy.hiddenUID,
            resolvedUID: MirrorLoopbackPolicy.hiddenUID,
            objectID: 202,
            translatedByExactUID: true,
            alive: true,
            hidden: true,
            inputChannels: 0,
            outputChannels: 1,
            nominalSampleRate: Double(MirrorLoopbackPolicy.sampleRate),
            modelUIDFingerprint: modelFingerprint,
            modelUIDMatchesExpected: true,
            clockDomain: MirrorLoopbackPolicy.clockDomain
        )
        let callbackCount = MirrorLoopbackPolicy.challengeFrames
            / MirrorLoopbackPolicy.callbackFrames
        var timestamps: [MirrorLoopbackTimestampRecord] = []
        timestamps.reserveCapacity(callbackCount)
        let baseSample: UInt64 = 4_000_000_000
        let baseHost: UInt64 = 1_000_000_000
        let callbackHostDelta = UInt64(
            MirrorLoopbackPolicy.callbackFrames * 1_000_000_000
                / MirrorLoopbackPolicy.sampleRate
        )
        for callback in 0..<callbackCount {
            timestamps.append(
                MirrorLoopbackTimestampRecord(
                    sampleTime: Double(
                        baseSample + UInt64(
                            callback * MirrorLoopbackPolicy.callbackFrames
                        )
                    ),
                    hostTimeNs: baseHost
                        + UInt64(callback) * callbackHostDelta,
                    frameCount: MirrorLoopbackPolicy.callbackFrames,
                    sampleTimeValid: true,
                    hostTimeValid: true
                )
            )
        }
        let defaults = DefaultSnapshot(
            inputUID: MirrorLoopbackPolicy.visibleUID,
            outputUID: "BuiltInSpeakerDevice",
            systemOutputUID: "BuiltInSpeakerDevice"
        )
        let teardown = MirrorLoopbackTeardownEvidence(
            cleanupEvidenceComplete: true,
            queuesOpened: true,
            inputStopStatus: noErr,
            outputStopStatus: noErr,
            inputDisposeStatus: noErr,
            outputDisposeStatus: noErr,
            callbackGatesDrained: true,
            postCloseCallbackCount: 0,
            runningStateRestored: true,
            defaultListenerInstalled: true,
            deviceListenerInstalled: true,
            listenersRemoved: true,
            contextsReleased: true
        )
        let firstDeviceTime = MirrorLoopbackDeviceTimePair(
            visible: MirrorLoopbackDeviceTimeObservation(
                sampleTime: Double(baseSample),
                hostTimeNs: baseHost,
                sampleTimeValid: true,
                hostTimeValid: true
            ),
            hidden: MirrorLoopbackDeviceTimeObservation(
                sampleTime: Double(baseSample),
                hostTimeNs: baseHost,
                sampleTimeValid: true,
                hostTimeValid: true
            )
        )
        let lastDeviceTime = MirrorLoopbackDeviceTimePair(
            visible: MirrorLoopbackDeviceTimeObservation(
                sampleTime: Double(
                    baseSample
                        + UInt64(MirrorLoopbackPolicy.challengeFrames)
                ),
                hostTimeNs: baseHost + 2_000_000_000,
                sampleTimeValid: true,
                hostTimeValid: true
            ),
            hidden: MirrorLoopbackDeviceTimeObservation(
                sampleTime: Double(
                    baseSample
                        + UInt64(MirrorLoopbackPolicy.challengeFrames)
                ),
                hostTimeNs: baseHost + 2_000_000_000,
                sampleTimeValid: true,
                hostTimeValid: true
            )
        )
        let lifecycle = MirrorLoopbackLifecycleEvidence(
            requiredStartOrders: ["visible-first", "hidden-first"],
            cycles: ["visible-first", "hidden-first"].enumerated().map {
                index, order in
                let initial = UInt64((index + 1) * 480)
                return MirrorLoopbackRestartCycleEvidence(
                    startOrder: order,
                    quiescentBefore: true,
                    quiescentAfter: true,
                    initialVisibleSampleFrame: initial,
                    initialHiddenSampleFrame: initial,
                    finalVisibleSampleFrame: initial + 960,
                    finalHiddenSampleFrame: initial + 960,
                    nearZeroSharedClock: true,
                    timelinesAdvanced: true,
                    queuesStoppedAndDisposed: true
                )
            },
            zeroTimestampSeedObservableViaPublicAPI: false,
            seedChangeClaimed: false
        )
        var fixture = MirrorLoopbackFixture(
            visible: visible,
            hidden: hidden,
            modelUIDsMatch: true,
            deviceChangeNotificationCount: 0,
            requestedFormat: .canonical,
            captureReadbackFormat: .canonical,
            writerReadbackFormat: .canonical,
            captureDeviceVirtualFormat: .canonicalDeviceFloat,
            captureDevicePhysicalFormat: .canonicalDeviceFloat,
            writerDeviceVirtualFormat: .canonicalDeviceFloat,
            writerDevicePhysicalFormat: .canonicalDeviceFloat,
            captureQueueUIDReadback: MirrorLoopbackPolicy.visibleUID,
            writerQueueUIDReadback: MirrorLoopbackPolicy.hiddenUID,
            visibleInputMuted: false,
            hiddenOutputMuted: false,
            visibleInputVolumeScalar: 1.0,
            hiddenOutputVolumeScalar: 1.0,
            writerQueueVolumeScalar: 1.0,
            writerPrimingFrameCount:
                MirrorLoopbackPolicy.queueBufferCount
                    * MirrorLoopbackPolicy.callbackFrames,
            writerCallbackCount: callbackCount,
            writerSubmittedChallengeFrameCount:
                MirrorLoopbackPolicy.challengeFrames,
            captureBufferContractValidated: true,
            captured: captured,
            totalObservedFrameCount:
                captured.count / MirrorLoopbackPolicy.captureChannels,
            rawCaptureCallbackCount:
                (captured.count / MirrorLoopbackPolicy.captureChannels
                    + MirrorLoopbackPolicy.callbackFrames - 1)
                    / MirrorLoopbackPolicy.callbackFrames,
            captureOverflow: false,
            timestamps: timestamps,
            deviceTimePairs: [firstDeviceTime, lastDeviceTime],
            projectionClaim: MirrorLoopbackProjectionClaim(
                sourceSampleRate: MirrorLoopbackPolicy.sampleRate,
                consumerSampleRate:
                    MirrorLoopbackPolicy.consumerSampleRate,
                ratioNumerator: 1,
                ratioDenominator: 2,
                rounding: "conservative-ceiling",
                projectedLastFrame: 0
            ),
            defaultsBefore: defaults,
            defaultsAfter: defaults,
            defaultNotificationCount: 0,
            lifecycle: lifecycle,
            teardown: teardown
        )

        func setLastRawFrame(_ lastRaw: UInt64) {
            let totalFrames = UInt64(MirrorLoopbackPolicy.challengeFrames)
            let firstRaw = lastRaw - (totalFrames - 1)
            for index in fixture.timestamps.indices {
                fixture.timestamps[index].sampleTime = Double(
                    firstRaw + UInt64(
                        index * MirrorLoopbackPolicy.callbackFrames
                    )
                )
            }
            let firstDeviceRaw = lastRaw - totalFrames
            fixture.deviceTimePairs[0].visible.sampleTime =
                Double(firstDeviceRaw)
            fixture.deviceTimePairs[0].hidden.sampleTime =
                Double(firstDeviceRaw)
            fixture.deviceTimePairs[1].visible.sampleTime = Double(lastRaw)
            fixture.deviceTimePairs[1].hidden.sampleTime = Double(lastRaw)
        }

        func replacingFormat(
            _ value: MirrorLoopbackFormatEvidence,
            sampleRate: Double? = nil,
            formatFlags: UInt32? = nil,
            bytesPerPacket: Int? = nil,
            bytesPerFrame: Int? = nil,
            channelsPerFrame: Int? = nil,
            reserved: UInt32? = nil
        ) -> MirrorLoopbackFormatEvidence {
            MirrorLoopbackFormatEvidence(
                sampleRate: sampleRate ?? value.sampleRate,
                formatID: value.formatID,
                formatFlags: formatFlags ?? value.formatFlags,
                floatingPoint: value.floatingPoint,
                signedInteger: value.signedInteger,
                packed: value.packed,
                nativeEndian: value.nativeEndian,
                interleaved: value.interleaved,
                bytesPerPacket: bytesPerPacket ?? value.bytesPerPacket,
                framesPerPacket: value.framesPerPacket,
                bytesPerFrame: bytesPerFrame ?? value.bytesPerFrame,
                channelsPerFrame:
                    channelsPerFrame ?? value.channelsPerFrame,
                bitsPerChannel: value.bitsPerChannel,
                reserved: reserved ?? value.reserved
            )
        }

        switch test {
        case .healthy:
            break
        case .capturedOverflow:
            fixture.captured.append(
                contentsOf: Array(
                    repeating: Int16(1),
                    count: (MirrorLoopbackPolicy.maximumAlignmentFrames
                        - MirrorLoopbackPolicy.syntheticPrefixFrames + 1)
                )
            )
        case .liveStyleOverflow:
            fixture.captured.append(
                contentsOf: Array(
                    repeating: Int16(1),
                    count: (MirrorLoopbackPolicy.maximumAlignmentFrames
                        - MirrorLoopbackPolicy.syntheticPrefixFrames)
                )
            )
            fixture.captureOverflow = true
            fixture.totalObservedFrameCount =
                MirrorLoopbackPolicy.maximumRetainedFrames
                    + MirrorLoopbackPolicy.callbackFrames
        case .capBoundaryPass:
            setLastRawFrame(UInt64(Int32.max) * 2)
        case .capBoundaryFail:
            setLastRawFrame(UInt64(Int32.max) * 2 + 1)
        case .capturedAgedClock:
            setLastRawFrame(6_687_779_444)
        case .headroomBoundaryPass:
            let required = MirrorLoopbackMath.requiredHeadroomFrames(
                seconds: requiredHeadroomSeconds
            )
            setLastRawFrame((UInt64(Int32.max) - required) * 2)
        case .headroomBoundaryFail:
            let required = MirrorLoopbackMath.requiredHeadroomFrames(
                seconds: requiredHeadroomSeconds
            )
            setLastRawFrame((UInt64(Int32.max) - required + 1) * 2)
        case .wrongProjection, .wrongRounding:
            break
        case .droppedFrame:
            let index = (MirrorLoopbackPolicy.syntheticPrefixFrames
                + MirrorLoopbackPolicy.sentinelFrames + 100)
            fixture.captured.remove(at: index)
        case .duplicatedFrame:
            let index = (MirrorLoopbackPolicy.syntheticPrefixFrames
                + MirrorLoopbackPolicy.sentinelFrames + 100)
            fixture.captured.insert(
                fixture.captured[index],
                at: index
            )
        case .bitFlip:
            let index = (MirrorLoopbackPolicy.syntheticPrefixFrames
                + MirrorLoopbackPolicy.sentinelFrames + 100)
            fixture.captured[index] = Int16(
                bitPattern: UInt16(bitPattern: fixture.captured[index]) ^ 1
            )
        case .gainChange:
            for index in fixture.captured.indices {
                fixture.captured[index] = Int16(
                    Int32(fixture.captured[index]) / 2
                )
            }
        case .silence:
            fixture.captured = Array(
                repeating: 0,
                count: fixture.captured.count
            )
        case .shortCapture:
            fixture.captured.removeLast(
                MirrorLoopbackPolicy.postRollFrames
                    + MirrorLoopbackPolicy.callbackFrames
            )
        case .timestampFlags:
            fixture.timestamps[10].sampleTimeValid = false
            fixture.timestamps[10].hostTimeValid = false
        case .deviceTimeFlags:
            fixture.deviceTimePairs[0].visible.sampleTimeValid = false
            fixture.deviceTimePairs[0].hidden.hostTimeValid = false
        case .frozenDeviceTime:
            fixture.deviceTimePairs[1].visible.sampleTime =
                fixture.deviceTimePairs[0].visible.sampleTime
            fixture.deviceTimePairs[1].hidden.sampleTime =
                fixture.deviceTimePairs[0].hidden.sampleTime
        case .divergentDeviceTime:
            for index in fixture.deviceTimePairs.indices {
                fixture.deviceTimePairs[index].hidden.sampleTime += 1_000
            }
        case .nonintegralSampleTime:
            fixture.timestamps[10].sampleTime += 0.5
        case .unrepresentableSampleTime:
            fixture.timestamps[10].sampleTime =
                18_446_744_073_709_551_616.0
            fixture.deviceTimePairs[1].visible.sampleTime =
                18_446_744_073_709_551_616.0
        case .sampleTimeRegression:
            fixture.timestamps[10].sampleTime =
                fixture.timestamps[9].sampleTime
        case .sampleTimeGap:
            for index in 10..<fixture.timestamps.count {
                fixture.timestamps[index].sampleTime += Double(
                    MirrorLoopbackPolicy.callbackFrames
                )
            }
        case .hostTimeRegression:
            fixture.timestamps[10].hostTimeNs =
                fixture.timestamps[9].hostTimeNs - 1
        case .transientHostSchedulingJitter:
            fixture.timestamps[10].hostTimeNs += 7_000_000
        case .hostTimeMismatch:
            for index in 10..<fixture.timestamps.count {
                fixture.timestamps[index].hostTimeNs += 5_000_000
            }
        case .format:
            fixture.captureReadbackFormat = replacingFormat(
                fixture.captureReadbackFormat,
                sampleRate: 44_100
            )
        case .fractionalFormat:
            fixture.captureReadbackFormat = replacingFormat(
                fixture.captureReadbackFormat,
                sampleRate: 48_000.25
            )
        case .extraFormatFlag:
            fixture.captureReadbackFormat = replacingFormat(
                fixture.captureReadbackFormat,
                formatFlags: fixture.captureReadbackFormat.formatFlags
                    | kAudioFormatFlagIsAlignedHigh
            )
        case .reservedFormat:
            fixture.captureReadbackFormat = replacingFormat(
                fixture.captureReadbackFormat,
                reserved: 1
            )
        case .deviceFormat:
            fixture.captureDeviceVirtualFormat = replacingFormat(
                fixture.captureDeviceVirtualFormat,
                sampleRate: 44_100
            )
        case .physicalDeviceFormat:
            fixture.captureDevicePhysicalFormat = replacingFormat(
                fixture.captureDevicePhysicalFormat,
                sampleRate: 44_100
            )
        case .writerPhysicalDeviceFormat:
            fixture.writerDevicePhysicalFormat = replacingFormat(
                fixture.writerDevicePhysicalFormat,
                sampleRate: 44_100
            )
        case .stereoFormat:
            fixture.captureReadbackFormat = replacingFormat(
                fixture.captureReadbackFormat,
                bytesPerPacket: 4,
                bytesPerFrame: 4,
                channelsPerFrame: 2
            )
        case .fractionalNominalRate:
            fixture.visible = MirrorLoopbackEndpointEvidence(
                expectedUID: fixture.visible.expectedUID,
                resolvedUID: fixture.visible.resolvedUID,
                objectID: fixture.visible.objectID,
                translatedByExactUID: fixture.visible.translatedByExactUID,
                alive: fixture.visible.alive,
                hidden: fixture.visible.hidden,
                inputChannels: fixture.visible.inputChannels,
                outputChannels: fixture.visible.outputChannels,
                nominalSampleRate: 48_000.25,
                modelUIDFingerprint: fixture.visible.modelUIDFingerprint,
                modelUIDMatchesExpected:
                    fixture.visible.modelUIDMatchesExpected,
                clockDomain: fixture.visible.clockDomain
            )
        case .wrongRole:
            fixture.visible = MirrorLoopbackEndpointEvidence(
                expectedUID: fixture.visible.expectedUID,
                resolvedUID: fixture.visible.resolvedUID,
                objectID: fixture.visible.objectID,
                translatedByExactUID: fixture.visible.translatedByExactUID,
                alive: fixture.visible.alive,
                hidden: fixture.visible.hidden,
                inputChannels: 1,
                outputChannels: 1,
                nominalSampleRate: fixture.visible.nominalSampleRate,
                modelUIDFingerprint: fixture.visible.modelUIDFingerprint,
                modelUIDMatchesExpected:
                    fixture.visible.modelUIDMatchesExpected,
                clockDomain: fixture.visible.clockDomain
            )
        case .clockDomain:
            fixture.hidden = MirrorLoopbackEndpointEvidence(
                expectedUID: fixture.hidden.expectedUID,
                resolvedUID: fixture.hidden.resolvedUID,
                objectID: fixture.hidden.objectID,
                translatedByExactUID: fixture.hidden.translatedByExactUID,
                alive: fixture.hidden.alive,
                hidden: fixture.hidden.hidden,
                inputChannels: fixture.hidden.inputChannels,
                outputChannels: fixture.hidden.outputChannels,
                nominalSampleRate: fixture.hidden.nominalSampleRate,
                modelUIDFingerprint: fixture.hidden.modelUIDFingerprint,
                modelUIDMatchesExpected:
                    fixture.hidden.modelUIDMatchesExpected,
                clockDomain: MirrorLoopbackPolicy.clockDomain &+ 1
            )
        case .controlMute:
            fixture.visibleInputMuted = true
        case .deviceVolume:
            fixture.visibleInputVolumeScalar = 0.841_040_5
        case .queueVolume:
            fixture.writerQueueVolumeScalar = 0.5
        case .inputNotReady:
            fixture.rawCaptureCallbackCount = 0
        case .bufferContract:
            fixture.captureBufferContractValidated = false
        case .writerNoProgress:
            fixture.writerCallbackCount = 0
            fixture.writerSubmittedChallengeFrameCount = 0
        case .postRollNoise:
            let postRollStart = (
                MirrorLoopbackPolicy.syntheticPrefixFrames
                    + MirrorLoopbackPolicy.challengeFrames
            ) * MirrorLoopbackPolicy.captureChannels
            fixture.captured[postRollStart] = 1_337
        case .visibleUID:
            fixture.visible = MirrorLoopbackEndpointEvidence(
                expectedUID: fixture.visible.expectedUID,
                resolvedUID: "wrong-visible",
                objectID: fixture.visible.objectID,
                translatedByExactUID: true,
                alive: fixture.visible.alive,
                hidden: fixture.visible.hidden,
                inputChannels: fixture.visible.inputChannels,
                outputChannels: fixture.visible.outputChannels,
                nominalSampleRate: fixture.visible.nominalSampleRate,
                modelUIDFingerprint: fixture.visible.modelUIDFingerprint,
                modelUIDMatchesExpected:
                    fixture.visible.modelUIDMatchesExpected,
                clockDomain: fixture.visible.clockDomain
            )
        case .hiddenUID:
            fixture.hidden = MirrorLoopbackEndpointEvidence(
                expectedUID: fixture.hidden.expectedUID,
                resolvedUID: "wrong-hidden",
                objectID: fixture.hidden.objectID,
                translatedByExactUID: true,
                alive: fixture.hidden.alive,
                hidden: fixture.hidden.hidden,
                inputChannels: fixture.hidden.inputChannels,
                outputChannels: fixture.hidden.outputChannels,
                nominalSampleRate: fixture.hidden.nominalSampleRate,
                modelUIDFingerprint: fixture.hidden.modelUIDFingerprint,
                modelUIDMatchesExpected:
                    fixture.hidden.modelUIDMatchesExpected,
                clockDomain: fixture.hidden.clockDomain
            )
        case .queueUID:
            fixture.writerQueueUIDReadback = MirrorLoopbackPolicy.visibleUID
        case .defaultMutation:
            fixture.defaultsAfter = DefaultSnapshot(
                inputUID: fixture.defaultsBefore.inputUID,
                outputUID: "USB-output",
                systemOutputUID: fixture.defaultsBefore.systemOutputUID
            )
        case .defaultNotification:
            fixture.defaultNotificationCount = 1
        case .hiddenDefault:
            fixture.defaultsAfter = DefaultSnapshot(
                inputUID: MirrorLoopbackPolicy.hiddenUID,
                outputUID: fixture.defaultsBefore.outputUID,
                systemOutputUID: fixture.defaultsBefore.systemOutputUID
            )
        case .legacyOutputDefault:
            let legacyDefault = DefaultSnapshot(
                inputUID: fixture.defaultsBefore.inputUID,
                outputUID: Policy.legacyVisibleUID,
                systemOutputUID: fixture.defaultsBefore.systemOutputUID
            )
            fixture.defaultsBefore = legacyDefault
            fixture.defaultsAfter = legacyDefault
        case .deviceNotification:
            fixture.deviceChangeNotificationCount = 1
        case .teardownStop:
            fixture.teardown = replacingTeardown(
                fixture.teardown,
                inputStopStatus: -1
            )
        case .teardownDispose:
            fixture.teardown = replacingTeardown(
                fixture.teardown,
                outputDisposeStatus: -1
            )
        case .teardownGate:
            fixture.teardown = replacingTeardown(
                fixture.teardown,
                callbackGatesDrained: false,
                postCloseCallbackCount: 1
            )
        case .teardownPostClose:
            fixture.teardown = replacingTeardown(
                fixture.teardown,
                callbackGatesDrained: true,
                postCloseCallbackCount: 1
            )
        case .cleanupEvidence:
            fixture.teardown = replacingTeardown(
                fixture.teardown,
                cleanupEvidenceComplete: false
            )
        case .listenerRemove:
            fixture.teardown = replacingTeardown(
                fixture.teardown,
                listenersRemoved: false
            )
        case .runningState:
            fixture.teardown = replacingTeardown(
                fixture.teardown,
                runningStateRestored: false
            )
        }

        fixture.totalObservedFrameCount = max(
            fixture.totalObservedFrameCount,
            fixture.captured.count / MirrorLoopbackPolicy.captureChannels
        )
        if test != .inputNotReady {
            fixture.rawCaptureCallbackCount = max(
                fixture.rawCaptureCallbackCount,
                (fixture.totalObservedFrameCount
                    + MirrorLoopbackPolicy.callbackFrames - 1)
                    / MirrorLoopbackPolicy.callbackFrames
            )
        }

        let last = fixture.deviceTimePairs.last.map {
            [$0.visible.sampleTime, $0.hidden.sampleTime]
                .compactMap(MirrorLoopbackMath.exactFrame)
                .max() ?? 0
        } ?? 0
        fixture.projectionClaim.projectedLastFrame =
            MirrorLoopbackMath.projected24kFrame(last)
        if test == .wrongProjection {
            fixture.projectionClaim.projectedLastFrame &+= 1
        } else if test == .wrongRounding {
            fixture.projectionClaim.rounding = "floor"
            fixture.projectionClaim.projectedLastFrame = last / 2
        }
        return fixture
    }

    private static func replacingTeardown(
        _ value: MirrorLoopbackTeardownEvidence,
        cleanupEvidenceComplete: Bool? = nil,
        inputStopStatus: Int32? = nil,
        outputDisposeStatus: Int32? = nil,
        callbackGatesDrained: Bool? = nil,
        postCloseCallbackCount: Int? = nil,
        runningStateRestored: Bool? = nil,
        listenersRemoved: Bool? = nil
    ) -> MirrorLoopbackTeardownEvidence {
        MirrorLoopbackTeardownEvidence(
            cleanupEvidenceComplete:
                cleanupEvidenceComplete ?? value.cleanupEvidenceComplete,
            queuesOpened: value.queuesOpened,
            inputStopStatus: inputStopStatus ?? value.inputStopStatus,
            outputStopStatus: value.outputStopStatus,
            inputDisposeStatus: value.inputDisposeStatus,
            outputDisposeStatus:
                outputDisposeStatus ?? value.outputDisposeStatus,
            callbackGatesDrained:
                callbackGatesDrained ?? value.callbackGatesDrained,
            postCloseCallbackCount:
                postCloseCallbackCount ?? value.postCloseCallbackCount,
            runningStateRestored:
                runningStateRestored ?? value.runningStateRestored,
            defaultListenerInstalled: value.defaultListenerInstalled,
            deviceListenerInstalled: value.deviceListenerInstalled,
            listenersRemoved: listenersRemoved ?? value.listenersRemoved,
            contextsReleased: value.contextsReleased
        )
    }
}

private struct MirrorLoopbackResolvedEndpoint {
    let evidence: MirrorLoopbackEndpointEvidence
    let modelUID: String
}

private enum MirrorLoopbackExactUIDTranslator {
    static func resolve(
        exactUID: String,
        expectedHidden: Bool
    ) throws -> MirrorLoopbackResolvedEndpoint {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier: CFString = exactUID as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(
                CoreAudioReader.systemObject,
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw ProbeError(code: "mirror_exact_uid_translation_failed")
        }
        guard CoreAudioReader.uid(deviceID) == exactUID else {
            throw ProbeError(code: "mirror_exact_uid_readback_mismatch")
        }
        let alive = try uint32(
            deviceID,
            selector: kAudioDevicePropertyDeviceIsAlive
        ) != 0
        let hidden = try uint32(
            deviceID,
            selector: kAudioDevicePropertyIsHidden
        ) != 0
        guard hidden == expectedHidden else {
            throw ProbeError(code: "mirror_endpoint_visibility_mismatch")
        }
        let nominalRate = try double(
            deviceID,
            selector: kAudioDevicePropertyNominalSampleRate
        )
        let modelUID = try string(
            deviceID,
            selector: kAudioDevicePropertyModelUID
        )
        let clockDomain = try uint32(
            deviceID,
            selector: kAudioDevicePropertyClockDomain
        )
        return MirrorLoopbackResolvedEndpoint(
            evidence: MirrorLoopbackEndpointEvidence(
                expectedUID: exactUID,
                resolvedUID: exactUID,
                objectID: deviceID,
                translatedByExactUID: true,
                alive: alive,
                hidden: hidden,
                inputChannels: try CoreAudioReader.channelCount(
                    deviceID,
                    scope: kAudioObjectPropertyScopeInput
                ),
                outputChannels: try CoreAudioReader.channelCount(
                    deviceID,
                    scope: kAudioObjectPropertyScopeOutput
                ),
                nominalSampleRate: nominalRate,
                modelUIDFingerprint:
                    MirrorLoopbackPCM.fingerprint(modelUID),
                modelUIDMatchesExpected:
                    modelUID == MirrorLoopbackPolicy.modelUID,
                clockDomain: clockDomain
            ),
            modelUID: modelUID
        )
    }

    private static func uint32(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &value
        ) == noErr,
        size == UInt32(MemoryLayout<UInt32>.size) else {
            throw ProbeError(code: "mirror_endpoint_property_failed")
        }
        return value
    }

    private static func double(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &value
        ) == noErr,
        size == UInt32(MemoryLayout<Double>.size),
        value.isFinite else {
            throw ProbeError(code: "mirror_endpoint_property_failed")
        }
        return value
    }

    private static func string(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard withUnsafeMutablePointer(to: &value, {
            AudioObjectGetPropertyData(
                deviceID, &address, 0, nil, &size, $0
            )
        }) == noErr else {
            throw ProbeError(code: "mirror_endpoint_property_failed")
        }
        let result = value as String
        guard !result.isEmpty else {
            throw ProbeError(code: "mirror_endpoint_property_failed")
        }
        return result
    }
}

private enum MirrorLoopbackQueueSupport {
    static func requestedDescription() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: Double(MirrorLoopbackPolicy.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: UInt32(MirrorLoopbackPolicy.captureChannels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }

    static func readbackFormat(
        _ queue: AudioQueueRef
    ) throws -> MirrorLoopbackFormatEvidence {
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioQueueGetProperty(
            queue,
            kAudioQueueProperty_StreamDescription,
            &description,
            &size
        ) == noErr,
        size == UInt32(MemoryLayout<AudioStreamBasicDescription>.size) else {
            throw ProbeError(code: "mirror_queue_format_readback_failed")
        }
        return evidence(description)
    }

    static func deviceStreamFormats(
        _ deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) throws -> (
        virtual: MirrorLoopbackFormatEvidence,
        physical: MirrorLoopbackFormatEvidence
    ) {
        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamsSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID, &streamsAddress, 0, nil, &streamsSize
        ) == noErr,
        streamsSize == UInt32(MemoryLayout<AudioStreamID>.size) else {
            throw ProbeError(code: "mirror_device_stream_inventory_failed")
        }
        var streamID = AudioStreamID(kAudioObjectUnknown)
        guard AudioObjectGetPropertyData(
            deviceID,
            &streamsAddress,
            0,
            nil,
            &streamsSize,
            &streamID
        ) == noErr,
        streamID != kAudioObjectUnknown else {
            throw ProbeError(code: "mirror_device_stream_inventory_failed")
        }
        return (
            virtual: try streamFormat(
                streamID,
                selector: kAudioStreamPropertyVirtualFormat
            ),
            physical: try streamFormat(
                streamID,
                selector: kAudioStreamPropertyPhysicalFormat
            )
        )
    }

    private static func streamFormat(
        _ streamID: AudioStreamID,
        selector: AudioObjectPropertySelector
    ) throws -> MirrorLoopbackFormatEvidence {
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var formatSize = UInt32(
            MemoryLayout<AudioStreamBasicDescription>.size
        )
        guard AudioObjectGetPropertyData(
            streamID,
            &formatAddress,
            0,
            nil,
            &formatSize,
            &description
        ) == noErr,
        formatSize == UInt32(
            MemoryLayout<AudioStreamBasicDescription>.size
        ) else {
            throw ProbeError(code: "mirror_device_stream_format_failed")
        }
        return evidence(description)
    }

    static func mute(
        _ deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            throw ProbeError(code: "mirror_device_mute_readback_unavailable")
        }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &value
        ) == noErr,
        size == UInt32(MemoryLayout<UInt32>.size) else {
            throw ProbeError(code: "mirror_device_mute_readback_failed")
        }
        return value != 0
    }

    static func volumeScalar(
        _ deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            throw ProbeError(code: "mirror_device_volume_readback_unavailable")
        }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &value
        ) == noErr,
        size == UInt32(MemoryLayout<Float32>.size),
        value.isFinite else {
            throw ProbeError(code: "mirror_device_volume_readback_failed")
        }
        return Double(value)
    }

    static func queueVolumeScalar(_ queue: AudioQueueRef) throws -> Double {
        var value: AudioQueueParameterValue = 0
        guard AudioQueueGetParameter(
            queue, kAudioQueueParam_Volume, &value
        ) == noErr,
        value.isFinite else {
            throw ProbeError(code: "mirror_writer_queue_volume_readback_failed")
        }
        return Double(value)
    }

    private static func evidence(
        _ description: AudioStreamBasicDescription
    ) -> MirrorLoopbackFormatEvidence {
        let flags = description.mFormatFlags
        return MirrorLoopbackFormatEvidence(
            sampleRate: description.mSampleRate.isFinite
                ? description.mSampleRate : 0,
            formatID: description.mFormatID == kAudioFormatLinearPCM
                ? "lpcm" : String(format: "0x%08x", description.mFormatID),
            formatFlags: flags,
            floatingPoint: flags & kAudioFormatFlagIsFloat != 0,
            signedInteger: flags & kAudioFormatFlagIsSignedInteger != 0,
            packed: flags & kAudioFormatFlagIsPacked != 0,
            nativeEndian: flags & kAudioFormatFlagIsBigEndian == 0,
            interleaved: flags & kAudioFormatFlagIsNonInterleaved == 0,
            bytesPerPacket: Int(description.mBytesPerPacket),
            framesPerPacket: Int(description.mFramesPerPacket),
            bytesPerFrame: Int(description.mBytesPerFrame),
            channelsPerFrame: Int(description.mChannelsPerFrame),
            bitsPerChannel: Int(description.mBitsPerChannel),
            reserved: description.mReserved
        )
    }

    static func deviceTime(
        _ queue: AudioQueueRef
    ) throws -> MirrorLoopbackDeviceTimeObservation {
        var timestamp = AudioTimeStamp()
        guard AudioQueueDeviceGetCurrentTime(queue, &timestamp) == noErr else {
            throw ProbeError(code: "mirror_device_time_read_failed")
        }
        return MirrorLoopbackDeviceTimeObservation(
            sampleTime: timestamp.mSampleTime,
            hostTimeNs: timestamp.mHostTime == 0
                ? 0 : AudioConvertHostTimeToNanos(timestamp.mHostTime),
            sampleTimeValid: timestamp.mFlags.contains(.sampleTimeValid)
                && timestamp.mSampleTime.isFinite,
            hostTimeValid: timestamp.mFlags.contains(.hostTimeValid)
                && timestamp.mHostTime != 0
        )
    }
}

private struct MirrorLoopbackRawTimestampRecord {
    let captureStartFrame: Int
    let timestamp: BlackHoleMeasureCallbackTimestamp
    let frameCount: Int
}

/// AudioQueue input callbacks are serialized. The control thread observes only
/// the atomic completion flag until the queue is stopped and the callback gate
/// is drained, after which it may take this collector's immutable snapshot.
private final class MirrorLoopbackCaptureCollector: @unchecked Sendable {
    private let challenge: [Int16]
    private let retainedSampleLimit =
        MirrorLoopbackPolicy.maximumRetainedFrames
            * MirrorLoopbackPolicy.captureChannels
    private var captured: [Int16] = []
    private var rawTimestamps: [MirrorLoopbackRawTimestampRecord] = []
    private var totalObservedFrames = 0
    private var lastAlignmentCandidate = -1
    private var alignedStartFrame: Int?
    private var secondAlignmentDetected = false
    private var overflow = false
    private var completeFlag: Int32 = 0

    init(challenge: [Int16]) {
        self.challenge = challenge
        captured.reserveCapacity(retainedSampleLimit)
        rawTimestamps.reserveCapacity(
            MirrorLoopbackPolicy.maximumRetainedFrames
                / MirrorLoopbackPolicy.callbackFrames + 4
        )
    }

    func ingest(
        samples: UnsafeBufferPointer<Int16>,
        timestamp: BlackHoleMeasureCallbackTimestamp
    ) {
        let safeSampleCount = samples.count
            - samples.count % MirrorLoopbackPolicy.captureChannels
        let frames = safeSampleCount / MirrorLoopbackPolicy.captureChannels
        guard frames > 0 else { return }
        if OSAtomicAdd32Barrier(0, &completeFlag) != 0 { return }

        let callbackStart = totalObservedFrames
        totalObservedFrames += frames
        rawTimestamps.append(
            MirrorLoopbackRawTimestampRecord(
                captureStartFrame: callbackStart,
                timestamp: timestamp,
                frameCount: frames
            )
        )

        let remaining = max(0, retainedSampleLimit - captured.count)
        let accepted = min(remaining, safeSampleCount)
        if accepted > 0 {
            captured.append(contentsOf: samples.prefix(accepted))
        }
        let truncatedAtRetentionLimit = accepted != safeSampleCount
        scanForSentinel()

        // Completion intentionally precedes the truncation failure: a sentinel
        // at maximumAlignmentFrames plus the full challenge and post-roll ends
        // exactly at the retention cap and must complete without false overflow.
        if let alignedStartFrame,
           captured.count / MirrorLoopbackPolicy.captureChannels
                >= alignedStartFrame + MirrorLoopbackPolicy.challengeFrames
                    + MirrorLoopbackPolicy.postRollFrames {
            let boundedEndFrame = alignedStartFrame
                + MirrorLoopbackPolicy.challengeFrames
                + MirrorLoopbackPolicy.postRollFrames
            let boundedEndSample = boundedEndFrame
                * MirrorLoopbackPolicy.captureChannels
            captured.removeSubrange(
                boundedEndSample..<captured.count
            )
            _ = OSAtomicCompareAndSwap32Barrier(0, 1, &completeFlag)
        } else if truncatedAtRetentionLimit {
            overflow = true
            _ = OSAtomicCompareAndSwap32Barrier(0, 1, &completeFlag)
        }
    }

    func isComplete() -> Bool {
        OSAtomicAdd32Barrier(0, &completeFlag) != 0
    }

    func snapshot() -> (
        captured: [Int16],
        timestamps: [MirrorLoopbackTimestampRecord],
        totalObservedFrameCount: Int,
        rawCaptureCallbackCount: Int,
        overflow: Bool,
        secondAlignmentDetected: Bool
    ) {
        let timestamps = alignedStartFrame.map {
            challengeTimestampRecords(alignedStartFrame: $0)
        } ?? []
        return (
            captured: captured,
            timestamps: timestamps,
            totalObservedFrameCount: totalObservedFrames,
            rawCaptureCallbackCount: rawTimestamps.count,
            overflow: overflow,
            secondAlignmentDetected: secondAlignmentDetected
        )
    }

    private func scanForSentinel() {
        let sentinelFrames = MirrorLoopbackPolicy.sentinelFrames
        let capturedFrames = captured.count / MirrorLoopbackPolicy.captureChannels
        let maximumCandidate = min(
            MirrorLoopbackPolicy.maximumAlignmentFrames,
            capturedFrames - sentinelFrames
        )
        guard maximumCandidate > lastAlignmentCandidate else { return }
        let sentinelSamples = sentinelFrames
            * MirrorLoopbackPolicy.captureChannels
        for candidate in (lastAlignmentCandidate + 1)...maximumCandidate {
            let start = candidate * MirrorLoopbackPolicy.captureChannels
            var matches = true
            for offset in 0..<sentinelSamples
            where captured[start + offset] != challenge[offset] {
                matches = false
                break
            }
            guard matches else { continue }
            if let alignedStartFrame {
                if alignedStartFrame != candidate {
                    secondAlignmentDetected = true
                }
            } else {
                alignedStartFrame = candidate
            }
        }
        lastAlignmentCandidate = maximumCandidate
    }

    private func challengeTimestampRecords(
        alignedStartFrame: Int
    ) -> [MirrorLoopbackTimestampRecord] {
        let challengeEnd = alignedStartFrame
            + MirrorLoopbackPolicy.challengeFrames
        var selected: [MirrorLoopbackTimestampRecord] = []
        selected.reserveCapacity(rawTimestamps.count)
        for raw in rawTimestamps {
            let rawEnd = raw.captureStartFrame + raw.frameCount
            let overlapStart = max(raw.captureStartFrame, alignedStartFrame)
            let overlapEnd = min(rawEnd, challengeEnd)
            guard overlapEnd > overlapStart else { continue }
            let offsetFrames = overlapStart - raw.captureStartFrame
            let frameCount = overlapEnd - overlapStart
            let sampleTime = raw.timestamp.sampleTimeValid
                ? raw.timestamp.sampleTime + Double(offsetFrames) : 0
            let hostTimeNs: UInt64
            if raw.timestamp.hostTimeValid {
                let rawHostNs = BlackHoleMeasureMath.hostTimeNanoseconds(
                    raw.timestamp.hostTime
                )
                let offsetNs = UInt64(
                    (Double(offsetFrames) * 1_000_000_000.0
                        / Double(MirrorLoopbackPolicy.sampleRate)).rounded()
                )
                hostTimeNs = rawHostNs <= UInt64.max - offsetNs
                    ? rawHostNs + offsetNs : UInt64.max
            } else {
                hostTimeNs = 0
            }
            selected.append(
                MirrorLoopbackTimestampRecord(
                    sampleTime: sampleTime,
                    hostTimeNs: hostTimeNs,
                    frameCount: frameCount,
                    sampleTimeValid: raw.timestamp.sampleTimeValid,
                    hostTimeValid: raw.timestamp.hostTimeValid
                )
            )
        }
        return selected
    }
}

private final class MirrorLoopbackInputContext: @unchecked Sendable {
    let collector: MirrorLoopbackCaptureCollector
    let failureLatch: BlackHoleMeasureQueueFailureLatch
    private let gate = BlackHoleMeasureLockFreeCallbackGate()
    private var postCloseCallbackCount: Int32 = 0
    private var callbackCount: Int32 = 0
    private var capturedFrameCount: Int32 = 0
    private var malformedBufferCount: Int32 = 0

    init(
        collector: MirrorLoopbackCaptureCollector,
        failureLatch: BlackHoleMeasureQueueFailureLatch
    ) {
        self.collector = collector
        self.failureLatch = failureLatch
    }

    func activate() { gate.activate() }
    func stopAccepting() { gate.stopAccepting() }
    func waitUntilIdle() { gate.waitUntilIdle() }
    func postCloseCallbacks() -> Int {
        Int(OSAtomicAdd32Barrier(0, &postCloseCallbackCount))
    }
    func readiness() -> (callbackCount: Int, capturedFrameCount: Int) {
        (
            Int(OSAtomicAdd32Barrier(0, &callbackCount)),
            Int(OSAtomicAdd32Barrier(0, &capturedFrameCount))
        )
    }

    /// Positive callback-format evidence is independent of a later enqueue
    /// failure while AudioQueueStop drains the queue. A malformed callback is
    /// sticky and invalidates this proof even if earlier callbacks were valid.
    func captureBufferContractValidated() -> Bool {
        OSAtomicAdd32Barrier(0, &callbackCount) > 0
            && OSAtomicAdd32Barrier(0, &malformedBufferCount) == 0
    }

    func handle(
        buffer: AudioQueueBufferRef,
        timestamp: BlackHoleMeasureCallbackTimestamp,
        enqueue: () -> OSStatus
    ) {
        guard gate.begin() else {
            _ = OSAtomicIncrement32Barrier(&postCloseCallbackCount)
            return
        }
        defer { gate.end() }
        guard let samples =
                BlackHoleMeasureInputBufferContract.validatedSamples(
                    in: buffer
                ) else {
            _ = OSAtomicIncrement32Barrier(&malformedBufferCount)
            failureLatch.recordFailure()
            return
        }
        _ = OSAtomicIncrement32Barrier(&callbackCount)
        _ = OSAtomicAdd32Barrier(
            Int32(samples.count / MirrorLoopbackPolicy.captureChannels),
            &capturedFrameCount
        )
        collector.ingest(samples: samples, timestamp: timestamp)
        failureLatch.record(enqueue())
    }

    func handle(
        queue: AudioQueueRef,
        buffer: AudioQueueBufferRef,
        timestamp: BlackHoleMeasureCallbackTimestamp
    ) {
        handle(buffer: buffer, timestamp: timestamp) {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
    }
}

private func mirrorLoopbackInputCallback(
    _ userData: UnsafeMutableRawPointer?,
    _ queue: AudioQueueRef,
    _ buffer: AudioQueueBufferRef,
    _ startTime: UnsafePointer<AudioTimeStamp>,
    _ packetCount: UInt32,
    _ packetDescriptions: UnsafePointer<AudioStreamPacketDescription>?
) {
    guard let userData else { return }
    Unmanaged<MirrorLoopbackInputContext>.fromOpaque(userData)
        .takeUnretainedValue()
        .handle(
            queue: queue,
            buffer: buffer,
            timestamp: BlackHoleMeasureCallbackTimestamp(startTime.pointee)
        )
}

private final class MirrorLoopbackInputQueueSession {
    private let context: MirrorLoopbackInputContext
    private var queue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef] = []
    private var retainedContext: Unmanaged<MirrorLoopbackInputContext>?
    private var started = false
    private(set) var readbackUID = ""
    private(set) var readbackFormat = MirrorLoopbackFormatEvidence.unavailable
    private(set) var stopStatus: OSStatus = noErr
    private(set) var disposeStatus: OSStatus = noErr
    private(set) var contextsReleased = false

    init(
        collector: MirrorLoopbackCaptureCollector,
        failureLatch: BlackHoleMeasureQueueFailureLatch
    ) {
        context = MirrorLoopbackInputContext(
            collector: collector,
            failureLatch: failureLatch
        )
    }

    func start() throws {
        guard queue == nil else { return }
        context.activate()
        var description = MirrorLoopbackQueueSupport.requestedDescription()
        var created: AudioQueueRef?
        let retained = Unmanaged.passRetained(context)
        let status = AudioQueueNewInput(
            &description,
            mirrorLoopbackInputCallback,
            retained.toOpaque(),
            nil,
            nil,
            0,
            &created
        )
        guard status == noErr, let created else {
            context.stopAccepting()
            context.waitUntilIdle()
            retained.release()
            contextsReleased = true
            throw ProbeError(code: "mirror_input_queue_create_failed")
        }
        queue = created
        retainedContext = retained
        do {
            guard try AudioSupport.pinCurrentDevice(
                MirrorLoopbackPolicy.visibleUID,
                queue: created,
                failureCode: "mirror_input_queue_device_set_failed"
            ) else {
                throw ProbeError(code: "mirror_input_queue_uid_mismatch")
            }
            let byteCount = UInt32(
                MirrorLoopbackPolicy.callbackFrames
                    * MirrorLoopbackPolicy.captureChannels
                    * MemoryLayout<Int16>.size
            )
            for _ in 0..<MirrorLoopbackPolicy.queueBufferCount {
                var buffer: AudioQueueBufferRef?
                guard AudioQueueAllocateBuffer(
                    created, byteCount, &buffer
                ) == noErr, let buffer else {
                    throw ProbeError(code: "mirror_input_buffer_allocate_failed")
                }
                buffers.append(buffer)
                guard AudioQueueEnqueueBuffer(created, buffer, 0, nil)
                        == noErr else {
                    throw ProbeError(code: "mirror_input_buffer_enqueue_failed")
                }
            }
            guard AudioQueueStart(created, nil) == noErr else {
                throw ProbeError(code: "mirror_input_queue_start_failed")
            }
            started = true
            readbackUID = AudioSupport.currentDevice(created) ?? ""
            readbackFormat = try MirrorLoopbackQueueSupport.readbackFormat(
                created
            )
            guard readbackUID == MirrorLoopbackPolicy.visibleUID else {
                throw ProbeError(code: "mirror_input_queue_uid_mismatch")
            }
        } catch {
            stop()
            throw error
        }
    }

    func currentDeviceMatches() -> Bool {
        guard let queue else { return false }
        return AudioSupport.currentDevice(queue)
            == MirrorLoopbackPolicy.visibleUID
    }

    func readiness() -> (callbackCount: Int, capturedFrameCount: Int) {
        context.readiness()
    }

    func captureBufferContractValidated() -> Bool {
        context.captureBufferContractValidated()
    }

    func currentDeviceTime() throws -> MirrorLoopbackDeviceTimeObservation {
        guard let queue else {
            throw ProbeError(code: "mirror_input_queue_not_running")
        }
        return try MirrorLoopbackQueueSupport.deviceTime(queue)
    }

    func stop() {
        guard let queue else { return }
        // Close admission first: AudioQueueStop(true) can synchronously invoke
        // an empty terminal callback, which must not revoke positive PCM proof.
        context.stopAccepting()
        context.waitUntilIdle()
        if started { stopStatus = AudioQueueStop(queue, true) }
        started = false
        context.waitUntilIdle()
        disposeStatus = AudioQueueDispose(queue, true)
        context.waitUntilIdle()
        // AudioQueueDispose is terminal once it returns, even on error.
        self.queue = nil
        buffers.removeAll(keepingCapacity: false)
        retainedContext?.release()
        retainedContext = nil
        contextsReleased = true
    }

    var postCloseCallbackCount: Int { context.postCloseCallbacks() }
    deinit { stop() }
}

private final class MirrorLoopbackOutputContext: @unchecked Sendable {
    private let challenge: [Int16]
    private let failureLatch: BlackHoleMeasureQueueFailureLatch
    private let gate = BlackHoleMeasureLockFreeCallbackGate()
    private var cursor = 0
    private var challengeEnabled: Int32 = 0
    private var primingFrameCount: Int32 = 0
    private var callbackCount: Int32 = 0
    private var submittedChallengeFrameCount: Int32 = 0
    private var postCloseCallbackCount: Int32 = 0

    init(
        challenge: [Int16],
        failureLatch: BlackHoleMeasureQueueFailureLatch
    ) {
        self.challenge = challenge
        self.failureLatch = failureLatch
    }

    func activate() { gate.activate() }
    func stopAccepting() { gate.stopAccepting() }
    func waitUntilIdle() { gate.waitUntilIdle() }
    func enableChallenge() {
        _ = OSAtomicCompareAndSwap32Barrier(0, 1, &challengeEnabled)
    }
    func postCloseCallbacks() -> Int {
        Int(OSAtomicAdd32Barrier(0, &postCloseCallbackCount))
    }
    func progress() -> (
        primingFrameCount: Int,
        callbackCount: Int,
        submittedChallengeFrameCount: Int
    ) {
        (
            Int(OSAtomicAdd32Barrier(0, &primingFrameCount)),
            Int(OSAtomicAdd32Barrier(0, &callbackCount)),
            Int(OSAtomicAdd32Barrier(0, &submittedChallengeFrameCount))
        )
    }

    func fillPrimingSilence(_ buffer: AudioQueueBufferRef) -> Bool {
        let frames = MirrorLoopbackPolicy.callbackFrames
        let sampleCount = frames * MirrorLoopbackPolicy.captureChannels
        let byteCount = sampleCount * MemoryLayout<Int16>.size
        guard byteCount <= Int(buffer.pointee.mAudioDataBytesCapacity) else {
            buffer.pointee.mAudioDataByteSize = 0
            failureLatch.recordFailure()
            return false
        }
        buffer.pointee.mAudioData
            .assumingMemoryBound(to: Int16.self)
            .initialize(repeating: 0, count: sampleCount)
        buffer.pointee.mAudioDataByteSize = UInt32(byteCount)
        _ = OSAtomicAdd32Barrier(Int32(frames), &primingFrameCount)
        return true
    }

    private func fillChallenge(_ buffer: AudioQueueBufferRef) -> Bool {
        let sampleCount = min(
            MirrorLoopbackPolicy.callbackFrames
                * MirrorLoopbackPolicy.captureChannels,
            challenge.count - cursor
        )
        guard sampleCount > 0 else {
            buffer.pointee.mAudioDataByteSize = 0
            return false
        }
        let byteCount = sampleCount * MemoryLayout<Int16>.size
        guard byteCount <= Int(buffer.pointee.mAudioDataBytesCapacity) else {
            buffer.pointee.mAudioDataByteSize = 0
            failureLatch.recordFailure()
            return false
        }
        let destination = buffer.pointee.mAudioData
            .assumingMemoryBound(to: Int16.self)
        challenge.withUnsafeBufferPointer { source in
            destination.update(
                from: source.baseAddress!.advanced(by: cursor),
                count: sampleCount
            )
        }
        cursor += sampleCount
        _ = OSAtomicAdd32Barrier(
            Int32(sampleCount / MirrorLoopbackPolicy.captureChannels),
            &submittedChallengeFrameCount
        )
        buffer.pointee.mAudioDataByteSize = UInt32(byteCount)
        return true
    }

    func handle(
        buffer: AudioQueueBufferRef,
        enqueue: () -> OSStatus
    ) {
        guard gate.begin() else {
            _ = OSAtomicIncrement32Barrier(&postCloseCallbackCount)
            return
        }
        defer { gate.end() }
        _ = OSAtomicIncrement32Barrier(&callbackCount)
        let filled = OSAtomicAdd32Barrier(0, &challengeEnabled) == 0
            ? fillPrimingSilence(buffer)
            : fillChallenge(buffer)
        guard filled else { return }
        failureLatch.record(enqueue())
    }

    func handle(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        handle(buffer: buffer) {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
    }
}

/// Exercises the callback-owned collector and silence-gated writer directly;
/// evaluator-only fixtures cannot catch capped-overflow or startup-order bugs.
private enum MirrorLoopbackLiveSeamSelfTest {
    static func passes(nonce: String) -> Bool {
        let challenge = MirrorLoopbackPCM.challenge(nonce: nonce)
        guard CoreAudioReader.channelCountParserSelfTestPasses(),
              CoreAudioReader.deviceInventorySizeSelfTestPasses(),
              collectorAcceptsSplitSentinel(challenge: challenge),
              collectorCarriesCappedOverflow(challenge: challenge),
              collectorRetainsNonSilentPostRoll(challenge: challenge),
              inputBufferContractProofSurvivesEnqueueFailure(
                challenge: challenge
              ),
              stopInducedEmptyInputCallbackIsRejected(
                challenge: challenge
              ),
              writerWithholdsChallengeUntilEnabled(challenge: challenge) else {
            return false
        }
        return true
    }

    private static func inputBufferContractProofSurvivesEnqueueFailure(
        challenge: [Int16]
    ) -> Bool {
        let collector = MirrorLoopbackCaptureCollector(challenge: challenge)
        let queueFailure = BlackHoleMeasureQueueFailureLatch()
        let context = MirrorLoopbackInputContext(
            collector: collector,
            failureLatch: queueFailure
        )
        context.activate()
        defer {
            context.stopAccepting()
            context.waitUntilIdle()
        }
        let byteCount = MirrorLoopbackPolicy.callbackFrames
            * MirrorLoopbackPolicy.captureChannels * MemoryLayout<Int16>.size
        return withBuffer(byteCount: byteCount) { buffer in
            buffer.pointee.mAudioDataByteSize = UInt32(byteCount)
            context.handle(
                buffer: buffer,
                timestamp: BlackHoleMeasureCallbackTimestamp(
                    sampleTime: 1_000,
                    hostTime: 1
                )
            ) {
                OSStatus(-1)
            }
            guard queueFailure.hasFailure(),
                  context.captureBufferContractValidated() else {
                return false
            }

            // A malformed mono buffer must invalidate the otherwise sticky
            // positive proof and must never reach the enqueue closure.
            buffer.pointee.mAudioDataByteSize = 1
            var malformedWasEnqueued = false
            context.handle(
                buffer: buffer,
                timestamp: BlackHoleMeasureCallbackTimestamp(
                    sampleTime: 1_480,
                    hostTime: 2
                )
            ) {
                malformedWasEnqueued = true
                return noErr
            }
            return !malformedWasEnqueued
                && !context.captureBufferContractValidated()
        }
    }

    /// Models the empty callback AudioQueueStop(true) may synchronously issue.
    /// Closing and draining the gate first must classify it as post-close,
    /// bypass enqueue, and preserve prior exact-buffer evidence.
    private static func stopInducedEmptyInputCallbackIsRejected(
        challenge: [Int16]
    ) -> Bool {
        let collector = MirrorLoopbackCaptureCollector(challenge: challenge)
        let queueFailure = BlackHoleMeasureQueueFailureLatch()
        let context = MirrorLoopbackInputContext(
            collector: collector,
            failureLatch: queueFailure
        )
        context.activate()
        let byteCount = MirrorLoopbackPolicy.callbackFrames
            * MirrorLoopbackPolicy.captureChannels * MemoryLayout<Int16>.size
        return withBuffer(byteCount: byteCount) { buffer in
            buffer.pointee.mAudioDataByteSize = UInt32(byteCount)
            var validEnqueueCount = 0
            context.handle(
                buffer: buffer,
                timestamp: BlackHoleMeasureCallbackTimestamp(
                    sampleTime: 1_000,
                    hostTime: 1
                )
            ) {
                validEnqueueCount += 1
                return noErr
            }
            guard validEnqueueCount == 1,
                  context.captureBufferContractValidated(),
                  !queueFailure.hasFailure() else {
                context.stopAccepting()
                context.waitUntilIdle()
                return false
            }

            context.stopAccepting()
            context.waitUntilIdle()
            buffer.pointee.mAudioDataByteSize = 0
            var terminalWasEnqueued = false
            context.handle(
                buffer: buffer,
                timestamp: BlackHoleMeasureCallbackTimestamp(
                    sampleTime: 1_480,
                    hostTime: 2
                )
            ) {
                terminalWasEnqueued = true
                return noErr
            }
            return !terminalWasEnqueued
                && context.postCloseCallbacks() == 1
                && context.captureBufferContractValidated()
                && !queueFailure.hasFailure()
        }
    }

    private static func collectorAcceptsSplitSentinel(
        challenge: [Int16]
    ) -> Bool {
        let collector = MirrorLoopbackCaptureCollector(challenge: challenge)
        let prefixFrames = 123
        let splitFrames = 100
        var first = Array(
            repeating: Int16(0),
            count: prefixFrames * MirrorLoopbackPolicy.captureChannels
        )
        first.append(
            contentsOf: challenge.prefix(
                splitFrames * MirrorLoopbackPolicy.captureChannels
            )
        )
        ingest(
            first,
            into: collector,
            sampleTime: 1_000,
            hostTime: 1
        )
        ingest(
            Array(
                challenge.dropFirst(
                    splitFrames * MirrorLoopbackPolicy.captureChannels
                )
            ),
            into: collector,
            sampleTime: Double(
                1_000 + first.count / MirrorLoopbackPolicy.captureChannels
            ),
            hostTime: 2
        )
        guard !collector.isComplete() else { return false }
        ingest(
            Array(
                repeating: Int16(0),
                count: MirrorLoopbackPolicy.postRollFrames
                    * MirrorLoopbackPolicy.captureChannels
            ),
            into: collector,
            sampleTime: Double(
                1_000 + prefixFrames
                    + MirrorLoopbackPolicy.challengeFrames
            ),
            hostTime: 3
        )
        let snapshot = collector.snapshot()
        return collector.isComplete()
            && !snapshot.overflow
            && snapshot.rawCaptureCallbackCount == 3
            && snapshot.totalObservedFrameCount
                == prefixFrames + MirrorLoopbackPolicy.challengeFrames
                    + MirrorLoopbackPolicy.postRollFrames
            && snapshot.timestamps.reduce(0) { $0 + $1.frameCount }
                == MirrorLoopbackPolicy.challengeFrames
    }

    private static func collectorCarriesCappedOverflow(
        challenge: [Int16]
    ) -> Bool {
        let collector = MirrorLoopbackCaptureCollector(challenge: challenge)
        let callback = Array(
            repeating: Int16(0),
            count: MirrorLoopbackPolicy.callbackFrames
                * MirrorLoopbackPolicy.captureChannels
        )
        let callbackCount = MirrorLoopbackPolicy.maximumRetainedFrames
            / MirrorLoopbackPolicy.callbackFrames + 1
        for index in 0..<callbackCount {
            ingest(
                callback,
                into: collector,
                sampleTime: Double(
                    index * MirrorLoopbackPolicy.callbackFrames
                ),
                hostTime: UInt64(index + 1)
            )
        }
        let snapshot = collector.snapshot()
        return snapshot.overflow
            && snapshot.captured.count
                == MirrorLoopbackPolicy.maximumRetainedFrames
                    * MirrorLoopbackPolicy.captureChannels
            && snapshot.rawCaptureCallbackCount == callbackCount
            && snapshot.totalObservedFrameCount
                > MirrorLoopbackPolicy.maximumRetainedFrames
    }

    private static func collectorRetainsNonSilentPostRoll(
        challenge: [Int16]
    ) -> Bool {
        let collector = MirrorLoopbackCaptureCollector(challenge: challenge)
        var capture = challenge
        capture.append(
            contentsOf: Array(
                repeating: Int16(0),
                count: MirrorLoopbackPolicy.postRollFrames
                    * MirrorLoopbackPolicy.captureChannels
            )
        )
        let firstPostRollSample = challenge.count
        capture[firstPostRollSample] = 1_337
        ingest(
            capture,
            into: collector,
            sampleTime: 2_000,
            hostTime: 4
        )
        let snapshot = collector.snapshot()
        return collector.isComplete()
            && !snapshot.overflow
            && snapshot.captured.count == capture.count
            && snapshot.captured[firstPostRollSample] == 1_337
            && snapshot.totalObservedFrameCount
                == MirrorLoopbackPolicy.challengeFrames
                    + MirrorLoopbackPolicy.postRollFrames
    }

    private static func writerWithholdsChallengeUntilEnabled(
        challenge: [Int16]
    ) -> Bool {
        let failureLatch = BlackHoleMeasureQueueFailureLatch()
        let context = MirrorLoopbackOutputContext(
            challenge: challenge,
            failureLatch: failureLatch
        )
        context.activate()
        defer {
            context.stopAccepting()
            context.waitUntilIdle()
        }
        let byteCount = MirrorLoopbackPolicy.callbackFrames
            * MirrorLoopbackPolicy.captureChannels * MemoryLayout<Int16>.size
        return withBuffer(byteCount: byteCount) { buffer in
            guard context.fillPrimingSilence(buffer),
                  samples(in: buffer).allSatisfy({ $0 == 0 }) else {
                return false
            }
            var enqueueCount = 0
            context.handle(buffer: buffer) {
                enqueueCount += 1
                return noErr
            }
            guard samples(in: buffer).allSatisfy({ $0 == 0 }),
                  context.progress().submittedChallengeFrameCount == 0 else {
                return false
            }
            context.enableChallenge()
            context.handle(buffer: buffer) {
                enqueueCount += 1
                return noErr
            }
            let progress = context.progress()
            return enqueueCount == 2
                && progress.primingFrameCount
                    == 2 * MirrorLoopbackPolicy.callbackFrames
                && progress.callbackCount == 2
                && progress.submittedChallengeFrameCount
                    == MirrorLoopbackPolicy.callbackFrames
                && Array(samples(in: buffer))
                    == Array(
                        challenge.prefix(
                            MirrorLoopbackPolicy.callbackFrames
                                * MirrorLoopbackPolicy.captureChannels
                        )
                    )
                && !failureLatch.hasFailure()
        }
    }

    private static func ingest(
        _ samples: [Int16],
        into collector: MirrorLoopbackCaptureCollector,
        sampleTime: Double,
        hostTime: UInt64
    ) {
        samples.withUnsafeBufferPointer {
            collector.ingest(
                samples: $0,
                timestamp: BlackHoleMeasureCallbackTimestamp(
                    sampleTime: sampleTime,
                    hostTime: hostTime
                )
            )
        }
    }

    private static func samples(
        in buffer: AudioQueueBufferRef
    ) -> UnsafeBufferPointer<Int16> {
        UnsafeBufferPointer(
            start: buffer.pointee.mAudioData.assumingMemoryBound(
                to: Int16.self
            ),
            count: Int(buffer.pointee.mAudioDataByteSize)
                / MemoryLayout<Int16>.size
        )
    }

    private static func withBuffer<Result>(
        byteCount: Int,
        _ body: (AudioQueueBufferRef) -> Result
    ) -> Result {
        let samples = UnsafeMutablePointer<Int16>.allocate(
            capacity: byteCount / MemoryLayout<Int16>.size
        )
        samples.initialize(
            repeating: 0,
            count: byteCount / MemoryLayout<Int16>.size
        )
        defer {
            samples.deinitialize(
                count: byteCount / MemoryLayout<Int16>.size
            )
            samples.deallocate()
        }
        var buffer = AudioQueueBuffer(
            mAudioDataBytesCapacity: UInt32(byteCount),
            mAudioData: UnsafeMutableRawPointer(samples),
            mAudioDataByteSize: 0,
            mUserData: nil,
            mPacketDescriptionCapacity: 0,
            mPacketDescriptions: nil,
            mPacketDescriptionCount: 0
        )
        return withUnsafeMutablePointer(to: &buffer, body)
    }
}

private func mirrorLoopbackOutputCallback(
    _ userData: UnsafeMutableRawPointer?,
    _ queue: AudioQueueRef,
    _ buffer: AudioQueueBufferRef
) {
    guard let userData else { return }
    Unmanaged<MirrorLoopbackOutputContext>.fromOpaque(userData)
        .takeUnretainedValue().handle(queue: queue, buffer: buffer)
}

private final class MirrorLoopbackOutputQueueSession {
    private let context: MirrorLoopbackOutputContext
    private var queue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef] = []
    private var retainedContext: Unmanaged<MirrorLoopbackOutputContext>?
    private var started = false
    private(set) var readbackUID = ""
    private(set) var readbackFormat = MirrorLoopbackFormatEvidence.unavailable
    private(set) var readbackQueueVolumeScalar = -1.0
    private(set) var stopStatus: OSStatus = noErr
    private(set) var disposeStatus: OSStatus = noErr
    private(set) var contextsReleased = false

    init(
        challenge: [Int16],
        failureLatch: BlackHoleMeasureQueueFailureLatch
    ) {
        context = MirrorLoopbackOutputContext(
            challenge: challenge,
            failureLatch: failureLatch
        )
    }

    func start() throws {
        guard queue == nil else { return }
        context.activate()
        var description = MirrorLoopbackQueueSupport.requestedDescription()
        var created: AudioQueueRef?
        let retained = Unmanaged.passRetained(context)
        let status = AudioQueueNewOutput(
            &description,
            mirrorLoopbackOutputCallback,
            retained.toOpaque(),
            nil,
            nil,
            0,
            &created
        )
        guard status == noErr, let created else {
            context.stopAccepting()
            context.waitUntilIdle()
            retained.release()
            contextsReleased = true
            throw ProbeError(code: "mirror_output_queue_create_failed")
        }
        queue = created
        retainedContext = retained
        do {
            guard try AudioSupport.pinCurrentDevice(
                MirrorLoopbackPolicy.hiddenUID,
                queue: created,
                failureCode: "mirror_output_queue_device_set_failed"
            ) else {
                throw ProbeError(code: "mirror_output_queue_uid_mismatch")
            }
            let prestartQueueVolume = try MirrorLoopbackQueueSupport
                .queueVolumeScalar(created)
            guard prestartQueueVolume == 1.0 else {
                throw ProbeError(code: "mirror_writer_queue_volume_not_unity")
            }
            let byteCount = UInt32(
                MirrorLoopbackPolicy.callbackFrames
                    * MirrorLoopbackPolicy.captureChannels
                    * MemoryLayout<Int16>.size
            )
            for _ in 0..<MirrorLoopbackPolicy.queueBufferCount {
                var buffer: AudioQueueBufferRef?
                guard AudioQueueAllocateBuffer(
                    created, byteCount, &buffer
                ) == noErr, let buffer else {
                    throw ProbeError(code: "mirror_output_buffer_allocate_failed")
                }
                buffers.append(buffer)
                guard context.fillPrimingSilence(buffer) else {
                    throw ProbeError(code: "mirror_output_silence_prime_failed")
                }
                guard AudioQueueEnqueueBuffer(created, buffer, 0, nil)
                        == noErr else {
                    throw ProbeError(code: "mirror_output_buffer_enqueue_failed")
                }
            }
            guard AudioQueueStart(created, nil) == noErr else {
                throw ProbeError(code: "mirror_output_queue_start_failed")
            }
            started = true
            readbackUID = AudioSupport.currentDevice(created) ?? ""
            readbackFormat = try MirrorLoopbackQueueSupport.readbackFormat(
                created
            )
            readbackQueueVolumeScalar = try MirrorLoopbackQueueSupport
                .queueVolumeScalar(created)
            guard readbackUID == MirrorLoopbackPolicy.hiddenUID else {
                throw ProbeError(code: "mirror_output_queue_uid_mismatch")
            }
            guard readbackQueueVolumeScalar == 1.0 else {
                throw ProbeError(code: "mirror_writer_queue_volume_not_unity")
            }
            context.enableChallenge()
        } catch {
            stop()
            throw error
        }
    }

    func currentDeviceMatches() -> Bool {
        guard let queue else { return false }
        return AudioSupport.currentDevice(queue)
            == MirrorLoopbackPolicy.hiddenUID
    }

    func progress() -> (
        primingFrameCount: Int,
        callbackCount: Int,
        submittedChallengeFrameCount: Int
    ) {
        context.progress()
    }

    func currentDeviceTime() throws -> MirrorLoopbackDeviceTimeObservation {
        guard let queue else {
            throw ProbeError(code: "mirror_output_queue_not_running")
        }
        return try MirrorLoopbackQueueSupport.deviceTime(queue)
    }

    func stop() {
        guard let queue else { return }
        // Stop callbacks must observe a closed gate and cannot refill buffers
        // or mutate writer progress while AudioQueueStop/Dispose tears down.
        context.stopAccepting()
        context.waitUntilIdle()
        if started { stopStatus = AudioQueueStop(queue, true) }
        started = false
        context.waitUntilIdle()
        disposeStatus = AudioQueueDispose(queue, true)
        context.waitUntilIdle()
        // AudioQueueDispose is terminal once it returns, even on error.
        self.queue = nil
        buffers.removeAll(keepingCapacity: false)
        retainedContext?.release()
        retainedContext = nil
        contextsReleased = true
    }

    var postCloseCallbackCount: Int { context.postCloseCallbacks() }
    deinit { stop() }
}

private final class MirrorLoopbackDeviceListenerGuard: @unchecked Sendable {
    private struct Registration {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
    }

    private let context = DefaultDeviceListenerContext()
    private let queue = DispatchQueue(
        label: "opensteamer.virtual-microphone-loopback.device-listener"
    )
    private var block: AudioObjectPropertyListenerBlock?
    private var registrations: [Registration] = []

    func install(deviceIDs: [AudioDeviceID]) throws {
        guard block == nil, registrations.isEmpty else { return }
        let context = context
        let listener: AudioObjectPropertyListenerBlock = {
            [context] count, _ in context.recordNotification(Int(count))
        }
        block = listener
        let addresses = [
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyIsHidden,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyModelUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyClockDomain,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
        ]
        for deviceID in deviceIDs {
            for storedAddress in addresses {
                var address = storedAddress
                guard AudioObjectAddPropertyListenerBlock(
                    deviceID, &address, queue, listener
                ) == noErr else {
                    _ = remove()
                    throw ProbeError(
                        code: "mirror_device_listener_install_failed"
                    )
                }
                registrations.append(
                    Registration(objectID: deviceID, address: storedAddress)
                )
            }
        }
    }

    func notificationCount() -> Int { context.notificationCount() }

    func remove() -> Bool {
        guard let block else { return registrations.isEmpty }
        var remaining: [Registration] = []
        for registration in registrations {
            var address = registration.address
            if AudioObjectRemovePropertyListenerBlock(
                registration.objectID, &address, queue, block
            ) != noErr {
                remaining.append(registration)
            }
        }
        queue.sync {}
        registrations = remaining
        if registrations.isEmpty { self.block = nil }
        return registrations.isEmpty
    }

    deinit { _ = remove() }
}

private enum MirrorLoopbackRunningState {
    static func isRunning(_ deviceID: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &value
        ) == noErr,
        size == UInt32(MemoryLayout<UInt32>.size) else {
            throw ProbeError(code: "mirror_running_state_read_failed")
        }
        return value != 0
    }

    static func bothStopped(
        visible: AudioDeviceID,
        hidden: AudioDeviceID
    ) throws -> Bool {
        try !isRunning(visible) && !isRunning(hidden)
    }

    static func waitUntilBothStopped(
        visible: AudioDeviceID,
        hidden: AudioDeviceID
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime
            + MirrorLoopbackPolicy.runningStateRestoreDeadlineSeconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if (try? bothStopped(visible: visible, hidden: hidden)) == true {
                return true
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return (try? bothStopped(visible: visible, hidden: hidden)) == true
    }
}

private enum MirrorLoopbackRestartVerifier {
    static func exerciseBothStartOrders(
        nonce: String,
        visible: AudioDeviceID,
        hidden: AudioDeviceID
    ) throws -> MirrorLoopbackLifecycleEvidence {
        let orders = ["visible-first", "hidden-first"]
        let cycles = try orders.map {
            try exercise(
                order: $0,
                nonce: nonce + ":restart:" + $0,
                visible: visible,
                hidden: hidden
            )
        }
        return MirrorLoopbackLifecycleEvidence(
            requiredStartOrders: orders,
            cycles: cycles,
            zeroTimestampSeedObservableViaPublicAPI: false,
            seedChangeClaimed: false
        )
    }

    private static func exercise(
        order: String,
        nonce: String,
        visible: AudioDeviceID,
        hidden: AudioDeviceID
    ) throws -> MirrorLoopbackRestartCycleEvidence {
        let quiescentBefore = MirrorLoopbackRunningState.waitUntilBothStopped(
            visible: visible,
            hidden: hidden
        )
        guard quiescentBefore else {
            throw ProbeError(code: "mirror_endpoints_not_quiescent")
        }

        let challenge = MirrorLoopbackPCM.challenge(nonce: nonce)
        let collector = MirrorLoopbackCaptureCollector(challenge: challenge)
        let inputFailure = BlackHoleMeasureQueueFailureLatch()
        let outputFailure = BlackHoleMeasureQueueFailureLatch()
        let input = MirrorLoopbackInputQueueSession(
            collector: collector,
            failureLatch: inputFailure
        )
        let output = MirrorLoopbackOutputQueueSession(
            challenge: challenge,
            failureLatch: outputFailure
        )
        var stopped = false
        defer {
            if !stopped {
                output.stop()
                input.stop()
            }
        }

        switch order {
        case "visible-first":
            try input.start()
            try output.start()
        case "hidden-first":
            try output.start()
            try input.start()
        default:
            throw ProbeError(code: "mirror_restart_order_invalid")
        }
        guard input.readbackFormat == .canonical,
              output.readbackFormat == .canonical,
              input.currentDeviceMatches(),
              output.currentDeviceMatches(),
              !inputFailure.hasFailure(),
              !outputFailure.hasFailure() else {
            throw ProbeError(code: "mirror_restart_queue_contract_failed")
        }

        let initial = try timePair(input: input, output: output)
        Thread.sleep(forTimeInterval: 0.030)
        let final = try timePair(input: input, output: output)
        output.stop()
        input.stop()
        stopped = true
        let quiescentAfter = MirrorLoopbackRunningState.waitUntilBothStopped(
            visible: visible,
            hidden: hidden
        )

        guard let initialVisible = MirrorLoopbackMath.exactFrame(
                initial.visible.sampleTime
              ),
              let initialHidden = MirrorLoopbackMath.exactFrame(
                initial.hidden.sampleTime
              ),
              let finalVisible = MirrorLoopbackMath.exactFrame(
                final.visible.sampleTime
              ),
              let finalHidden = MirrorLoopbackMath.exactFrame(
                final.hidden.sampleTime
              ),
              initial.visible.sampleTimeValid,
              initial.visible.hostTimeValid,
              initial.hidden.sampleTimeValid,
              initial.hidden.hostTimeValid,
              final.visible.sampleTimeValid,
              final.visible.hostTimeValid,
              final.hidden.sampleTimeValid,
              final.hidden.hostTimeValid else {
            throw ProbeError(code: "mirror_restart_timestamp_unavailable")
        }

        let nearZero = initialVisible
                <= MirrorLoopbackPolicy.maximumRestartInitialFrame
            && initialHidden
                <= MirrorLoopbackPolicy.maximumRestartInitialFrame
            && sharedClock(initial.visible, initial.hidden)
        let advanced = finalVisible > initialVisible
            && finalHidden > initialHidden
            && sharedClock(final.visible, final.hidden)
        let queuesStoppedAndDisposed = input.stopStatus == noErr
            && output.stopStatus == noErr
            && input.disposeStatus == noErr
            && output.disposeStatus == noErr
            && input.contextsReleased
            && output.contextsReleased

        return MirrorLoopbackRestartCycleEvidence(
            startOrder: order,
            quiescentBefore: quiescentBefore,
            quiescentAfter: quiescentAfter,
            initialVisibleSampleFrame: initialVisible,
            initialHiddenSampleFrame: initialHidden,
            finalVisibleSampleFrame: finalVisible,
            finalHiddenSampleFrame: finalHidden,
            nearZeroSharedClock: nearZero,
            timelinesAdvanced: advanced,
            queuesStoppedAndDisposed: queuesStoppedAndDisposed
        )
    }

    private static func timePair(
        input: MirrorLoopbackInputQueueSession,
        output: MirrorLoopbackOutputQueueSession
    ) throws -> MirrorLoopbackDeviceTimePair {
        MirrorLoopbackDeviceTimePair(
            visible: try input.currentDeviceTime(),
            hidden: try output.currentDeviceTime()
        )
    }

    private static func sharedClock(
        _ visible: MirrorLoopbackDeviceTimeObservation,
        _ hidden: MirrorLoopbackDeviceTimeObservation
    ) -> Bool {
        guard let visibleFrame = MirrorLoopbackMath.exactFrame(
                visible.sampleTime
              ),
              let hiddenFrame = MirrorLoopbackMath.exactFrame(
                hidden.sampleTime
              ) else {
            return false
        }
        let sampleDelta = Double(hiddenFrame) - Double(visibleFrame)
        let hostDeltaFrames = (
            Double(hidden.hostTimeNs) - Double(visible.hostTimeNs)
        ) * Double(MirrorLoopbackPolicy.sampleRate) / 1_000_000_000.0
        return abs(sampleDelta - hostDeltaFrames) <= 4.0
    }
}

/// This app-level oracle cannot observe the AudioServerPlugIn zero-timestamp
/// seed. It exercises both endpoint start orders and verifies a fresh near-zero
/// shared public timeline after each quiescent restart, but it deliberately
/// makes no claim that the unobservable seed changed. Driver-core tests own
/// that internal seed invariant.
private enum MirrorLoopbackRealRunner {
    static func run(
        nonce: String,
        requiredHeadroomSeconds: Double
    ) throws -> MirrorLoopbackResult {
        let visible = try MirrorLoopbackExactUIDTranslator.resolve(
            exactUID: MirrorLoopbackPolicy.visibleUID,
            expectedHidden: false
        )
        let hidden = try MirrorLoopbackExactUIDTranslator.resolve(
            exactUID: MirrorLoopbackPolicy.hiddenUID,
            expectedHidden: true
        )
        guard visible.evidence.alive, !visible.evidence.hidden,
              hidden.evidence.alive, hidden.evidence.hidden,
              visible.evidence.objectID != hidden.evidence.objectID,
              visible.modelUID == hidden.modelUID,
              visible.modelUID == MirrorLoopbackPolicy.modelUID,
              visible.evidence.inputChannels == 1,
              visible.evidence.outputChannels == 0,
              hidden.evidence.inputChannels == 0,
              hidden.evidence.outputChannels == 1,
              visible.evidence.clockDomain == MirrorLoopbackPolicy.clockDomain,
              hidden.evidence.clockDomain == MirrorLoopbackPolicy.clockDomain,
              visible.evidence.nominalSampleRate
                == Double(MirrorLoopbackPolicy.sampleRate),
              hidden.evidence.nominalSampleRate
                == Double(MirrorLoopbackPolicy.sampleRate) else {
            throw ProbeError(code: "mirror_endpoint_pair_preflight_failed")
        }

        let defaultGuard = DefaultDeviceGuard()
        try defaultGuard.install()
        defer { _ = defaultGuard.remove() }
        let deviceGuard = MirrorLoopbackDeviceListenerGuard()
        try deviceGuard.install(
            deviceIDs: [
                visible.evidence.objectID,
                hidden.evidence.objectID,
            ]
        )
        defer { _ = deviceGuard.remove() }
        let defaultsBefore = try defaultGuard.snapshot()
        guard DefaultRouteSafety.failureCode(defaultsBefore) == nil,
              defaultsBefore.inputUID != MirrorLoopbackPolicy.hiddenUID else {
            throw ProbeError(code: "mirror_unsafe_default_route_preflight")
        }

        guard try MirrorLoopbackRunningState.bothStopped(
            visible: visible.evidence.objectID,
            hidden: hidden.evidence.objectID
        ) else {
            throw ProbeError(code: "mirror_endpoints_not_quiescent")
        }
        Thread.sleep(forTimeInterval: 0.050)
        guard try MirrorLoopbackRunningState.bothStopped(
            visible: visible.evidence.objectID,
            hidden: hidden.evidence.objectID
        ) else {
            throw ProbeError(code: "mirror_endpoints_not_quiescent")
        }

        let captureDeviceFormats = try MirrorLoopbackQueueSupport
            .deviceStreamFormats(
                visible.evidence.objectID,
                scope: kAudioObjectPropertyScopeInput
            )
        let writerDeviceFormats = try MirrorLoopbackQueueSupport
            .deviceStreamFormats(
                hidden.evidence.objectID,
                scope: kAudioObjectPropertyScopeOutput
            )
        guard captureDeviceFormats.virtual == .canonicalDeviceFloat,
              captureDeviceFormats.physical == .canonicalDeviceFloat,
              writerDeviceFormats.virtual == .canonicalDeviceFloat,
              writerDeviceFormats.physical == .canonicalDeviceFloat else {
            throw ProbeError(code: "mirror_device_stream_format_mismatch")
        }
        let visibleInputMuted = try MirrorLoopbackQueueSupport.mute(
            visible.evidence.objectID,
            scope: kAudioObjectPropertyScopeInput
        )
        let hiddenOutputMuted = try MirrorLoopbackQueueSupport.mute(
            hidden.evidence.objectID,
            scope: kAudioObjectPropertyScopeOutput
        )
        let visibleInputVolumeScalar = try MirrorLoopbackQueueSupport
            .volumeScalar(
                visible.evidence.objectID,
                scope: kAudioObjectPropertyScopeInput
            )
        let hiddenOutputVolumeScalar = try MirrorLoopbackQueueSupport
            .volumeScalar(
                hidden.evidence.objectID,
                scope: kAudioObjectPropertyScopeOutput
            )
        let lifecycle = try MirrorLoopbackRestartVerifier
            .exerciseBothStartOrders(
                nonce: nonce,
                visible: visible.evidence.objectID,
                hidden: hidden.evidence.objectID
            )
        guard defaultGuard.notificationCount() == 0,
              try defaultGuard.snapshot() == defaultsBefore,
              deviceGuard.notificationCount() == 0,
              try MirrorLoopbackRunningState.bothStopped(
                visible: visible.evidence.objectID,
                hidden: hidden.evidence.objectID
              ) else {
            throw ProbeError(code: "mirror_restart_lifecycle_changed_route")
        }

        let challenge = MirrorLoopbackPCM.challenge(nonce: nonce)
        let collector = MirrorLoopbackCaptureCollector(challenge: challenge)
        let inputFailure = BlackHoleMeasureQueueFailureLatch()
        let outputFailure = BlackHoleMeasureQueueFailureLatch()
        let input = MirrorLoopbackInputQueueSession(
            collector: collector,
            failureLatch: inputFailure
        )
        let output = MirrorLoopbackOutputQueueSession(
            challenge: challenge,
            failureLatch: outputFailure
        )
        defer {
            output.stop()
            input.stop()
        }
        let signalMonitor = SignalMonitor()
        try input.start()
        let inputReadyDeadline = ProcessInfo.processInfo.systemUptime
            + MirrorLoopbackPolicy.inputReadinessDeadlineSeconds
        while ProcessInfo.processInfo.systemUptime < inputReadyDeadline {
            let readiness = input.readiness()
            if readiness.callbackCount
                    >= MirrorLoopbackPolicy.minimumReadyInputCallbacks,
               readiness.capturedFrameCount
                    >= MirrorLoopbackPolicy.minimumReadyInputCallbacks
                        * MirrorLoopbackPolicy.callbackFrames {
                break
            }
            if signalMonitor.receivedSignal() != 0 {
                throw ProbeError(code: "interrupted")
            }
            if inputFailure.hasFailure() {
                throw ProbeError(code: "mirror_input_readiness_runtime_failure")
            }
            if !input.currentDeviceMatches() {
                throw ProbeError(code: "mirror_input_device_changed_before_challenge")
            }
            if defaultGuard.notificationCount() != 0
                || (try? defaultGuard.snapshot()) != defaultsBefore {
                throw ProbeError(code: "default_route_changed_before_challenge")
            }
            if deviceGuard.notificationCount() != 0 {
                throw ProbeError(code: "route_identity_changed_before_challenge")
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        let inputReadiness = input.readiness()
        guard inputReadiness.callbackCount
                >= MirrorLoopbackPolicy.minimumReadyInputCallbacks,
              inputReadiness.capturedFrameCount
                >= MirrorLoopbackPolicy.minimumReadyInputCallbacks
                    * MirrorLoopbackPolicy.callbackFrames else {
            throw ProbeError(code: "mirror_input_readiness_timeout")
        }
        try output.start()

        func readDeviceTimePair() throws -> MirrorLoopbackDeviceTimePair {
            MirrorLoopbackDeviceTimePair(
                visible: try input.currentDeviceTime(),
                hidden: try output.currentDeviceTime()
            )
        }
        var deviceTimePairs = [try readDeviceTimePair()]

        var forcedFailures: [String] = []
        let deadline = ProcessInfo.processInfo.systemUptime
            + MirrorLoopbackPolicy.realDeadlineSeconds
        while !collector.isComplete()
            && ProcessInfo.processInfo.systemUptime < deadline {
            if signalMonitor.receivedSignal() != 0 {
                forcedFailures.append("interrupted")
                break
            }
            if inputFailure.hasFailure() || outputFailure.hasFailure() {
                forcedFailures.append("audio_queue_runtime_failure")
                break
            }
            if !input.currentDeviceMatches()
                || !output.currentDeviceMatches() {
                forcedFailures.append("queue_device_changed_during_proof")
                break
            }
            if defaultGuard.notificationCount() != 0
                || (try? defaultGuard.snapshot()) != defaultsBefore {
                forcedFailures.append("default_route_changed_during_proof")
                break
            }
            if deviceGuard.notificationCount() != 0 {
                forcedFailures.append("route_identity_changed_during_proof")
                break
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        if !collector.isComplete() && forcedFailures.isEmpty {
            forcedFailures.append("mirror_loopback_deadline_exceeded")
        }
        do {
            deviceTimePairs.append(try readDeviceTimePair())
        } catch let error as ProbeError {
            forcedFailures.append(error.code)
        } catch {
            forcedFailures.append("mirror_device_time_read_failed")
        }

        output.stop()
        input.stop()
        let defaultsAfter = try defaultGuard.snapshot()
        let defaultListenersRemoved = defaultGuard.remove()
        let deviceListenersRemoved = deviceGuard.remove()
        let defaultsNotifications = defaultGuard.notificationCount()
        let deviceNotifications = deviceGuard.notificationCount()
        let runningRestored = MirrorLoopbackRunningState.waitUntilBothStopped(
            visible: visible.evidence.objectID,
            hidden: hidden.evidence.objectID
        )
        let snapshot = collector.snapshot()
        let writerProgress = output.progress()
        let lastRawFrame: UInt64 = deviceTimePairs.last.map { pair in
            [pair.visible.sampleTime, pair.hidden.sampleTime]
                .compactMap(MirrorLoopbackMath.exactFrame)
                .max() ?? 0
        } ?? 0
        let fixture = MirrorLoopbackFixture(
            visible: visible.evidence,
            hidden: hidden.evidence,
            modelUIDsMatch: visible.modelUID == hidden.modelUID,
            deviceChangeNotificationCount: deviceNotifications,
            requestedFormat: .canonical,
            captureReadbackFormat: input.readbackFormat,
            writerReadbackFormat: output.readbackFormat,
            captureDeviceVirtualFormat: captureDeviceFormats.virtual,
            captureDevicePhysicalFormat: captureDeviceFormats.physical,
            writerDeviceVirtualFormat: writerDeviceFormats.virtual,
            writerDevicePhysicalFormat: writerDeviceFormats.physical,
            captureQueueUIDReadback: input.readbackUID,
            writerQueueUIDReadback: output.readbackUID,
            visibleInputMuted: visibleInputMuted,
            hiddenOutputMuted: hiddenOutputMuted,
            visibleInputVolumeScalar: visibleInputVolumeScalar,
            hiddenOutputVolumeScalar: hiddenOutputVolumeScalar,
            writerQueueVolumeScalar: output.readbackQueueVolumeScalar,
            writerPrimingFrameCount: writerProgress.primingFrameCount,
            writerCallbackCount: writerProgress.callbackCount,
            writerSubmittedChallengeFrameCount:
                writerProgress.submittedChallengeFrameCount,
            captureBufferContractValidated:
                input.captureBufferContractValidated(),
            captured: snapshot.captured,
            totalObservedFrameCount: snapshot.totalObservedFrameCount,
            rawCaptureCallbackCount: snapshot.rawCaptureCallbackCount,
            captureOverflow: snapshot.overflow,
            timestamps: snapshot.timestamps,
            deviceTimePairs: deviceTimePairs,
            projectionClaim: MirrorLoopbackProjectionClaim(
                sourceSampleRate: MirrorLoopbackPolicy.sampleRate,
                consumerSampleRate: MirrorLoopbackPolicy.consumerSampleRate,
                ratioNumerator: 1,
                ratioDenominator: 2,
                rounding: "conservative-ceiling",
                projectedLastFrame:
                    MirrorLoopbackMath.projected24kFrame(lastRawFrame)
            ),
            defaultsBefore: defaultsBefore,
            defaultsAfter: defaultsAfter,
            defaultNotificationCount: defaultsNotifications,
            lifecycle: lifecycle,
            teardown: MirrorLoopbackTeardownEvidence(
                cleanupEvidenceComplete: true,
                queuesOpened: true,
                inputStopStatus: input.stopStatus,
                outputStopStatus: output.stopStatus,
                inputDisposeStatus: input.disposeStatus,
                outputDisposeStatus: output.disposeStatus,
                callbackGatesDrained: true,
                postCloseCallbackCount: input.postCloseCallbackCount
                    + output.postCloseCallbackCount,
                runningStateRestored: runningRestored,
                defaultListenerInstalled: true,
                deviceListenerInstalled: true,
                listenersRemoved: defaultListenersRemoved
                    && deviceListenersRemoved,
                contextsReleased: input.contextsReleased
                    && output.contextsReleased
            )
        )
        return MirrorLoopbackEvaluator.evaluate(
            nonce: nonce,
            requiredHeadroomSeconds: requiredHeadroomSeconds,
            fixture: fixture,
            mode: "real-dual-audioqueue",
            realQueuePathImplemented: true,
            forcedFailureReasons: forcedFailures
        )
    }
}

private enum MirrorLoopbackFailureBuilder {
    static func make(
        nonce: String,
        requiredHeadroomSeconds: Double,
        failureCode: String
    ) -> MirrorLoopbackResult {
        var failures = [failureCode]
        let emptyEndpoint = { (uid: String) in
            MirrorLoopbackEndpointEvidence(
                expectedUID: uid,
                resolvedUID: "",
                objectID: 0,
                translatedByExactUID: false,
                alive: false,
                hidden: false,
                inputChannels: 0,
                outputChannels: 0,
                nominalSampleRate: 0,
                modelUIDFingerprint: "",
                modelUIDMatchesExpected: false,
                clockDomain: 0
            )
        }
        var visible = emptyEndpoint(MirrorLoopbackPolicy.visibleUID)
        var hidden = emptyEndpoint(MirrorLoopbackPolicy.hiddenUID)
        var modelsMatch = false
        do {
            let visibleResolved = try MirrorLoopbackExactUIDTranslator.resolve(
                exactUID: MirrorLoopbackPolicy.visibleUID,
                expectedHidden: false
            )
            let hiddenResolved = try MirrorLoopbackExactUIDTranslator.resolve(
                exactUID: MirrorLoopbackPolicy.hiddenUID,
                expectedHidden: true
            )
            visible = visibleResolved.evidence
            hidden = hiddenResolved.evidence
            modelsMatch = visibleResolved.modelUID == hiddenResolved.modelUID
        } catch let error as ProbeError {
            failures.append(error.code)
        } catch {
            failures.append("mirror_endpoint_preflight_failed")
        }

        let defaultGuard = DefaultDeviceGuard()
        var defaultsBefore = DefaultSnapshot(
            inputUID: "unavailable",
            outputUID: "unavailable",
            systemOutputUID: "unavailable"
        )
        var defaultsAfter = defaultsBefore
        do {
            defaultsBefore = try defaultGuard.snapshot()
            defaultsAfter = try defaultGuard.snapshot()
        } catch {
            failures.append("default_device_snapshot_failed")
        }
        let hiddenNeverDefault = [
            defaultsBefore.inputUID,
            defaultsBefore.outputUID,
            defaultsBefore.systemOutputUID,
            defaultsAfter.inputUID,
            defaultsAfter.outputUID,
            defaultsAfter.systemOutputUID,
        ].allSatisfy {
            $0 != MirrorLoopbackPolicy.hiddenUID
                && $0 != Policy.legacyHiddenUID
        }
        let virtualEndpointsNeverOutput = [
            defaultsBefore.outputUID,
            defaultsBefore.systemOutputUID,
            defaultsAfter.outputUID,
            defaultsAfter.systemOutputUID,
        ].allSatisfy {
            $0 != MirrorLoopbackPolicy.visibleUID
                && $0 != MirrorLoopbackPolicy.hiddenUID
                && $0 != Policy.legacyVisibleUID
                && $0 != Policy.legacyHiddenUID
        }
        let runningStateRestored = visible.objectID != 0
            && hidden.objectID != 0
            && MirrorLoopbackRunningState.waitUntilBothStopped(
                visible: visible.objectID,
                hidden: hidden.objectID
            )
        let expected = MirrorLoopbackPCM.challenge(nonce: nonce)
        let projection = MirrorLoopbackProjectionEvidence(
            schema: MirrorLoopbackPolicy.projectionSchema,
            sourceSampleRate: MirrorLoopbackPolicy.sampleRate,
            consumerSampleRate: MirrorLoopbackPolicy.consumerSampleRate,
            ratioNumerator: 1,
            ratioDenominator: 2,
            rounding: "conservative-ceiling",
            signedMinimum: Int64(Int32.min),
            signedMaximum: Int64(Int32.max),
            projectedFirstFrame: 0,
            projectedLastFrame: 0,
            claimedProjectedLastFrame: 0,
            claimMatchesCalculation: false,
            requiredHeadroomSeconds: requiredHeadroomSeconds,
            requiredHeadroomFrames:
                MirrorLoopbackMath.requiredHeadroomFrames(
                    seconds: requiredHeadroomSeconds
                ),
            remainingHeadroomFrames: Int64(Int32.max),
            signed32Compatible: false,
            headroomSatisfied: false
        )
        return MirrorLoopbackResult(
            schema: MirrorLoopbackPolicy.schema,
            status: "failed",
            mode: "real-dual-audioqueue",
            realQueuePathImplemented: true,
            challenge: MirrorLoopbackChallengeEvidence(
                algorithm: MirrorLoopbackPolicy.algorithm,
                version: MirrorLoopbackPolicy.algorithmVersion,
                nonceFingerprint: MirrorLoopbackPCM.fingerprint(nonce),
                frameCount: MirrorLoopbackPolicy.challengeFrames,
                sampleCount: expected.count,
                sentinelFrameCount: MirrorLoopbackPolicy.sentinelFrames,
                expectedPCMHash: MirrorLoopbackPCM.hash(expected),
                capturedAlignedPCMHash: ""
            ),
            endpointPair: MirrorLoopbackEndpointPairEvidence(
                visible: visible,
                hidden: hidden,
                objectIDsDistinct: visible.objectID != 0
                    && hidden.objectID != 0
                    && visible.objectID != hidden.objectID,
                modelUIDsMatch: modelsMatch,
                clockDomainsMatch: visible.clockDomain
                    == hidden.clockDomain,
                deviceChangeNotificationCount: 0
            ),
            queueContract: MirrorLoopbackQueueContractEvidence(
                requestedFormat: .canonical,
                captureReadbackFormat: .unavailable,
                writerReadbackFormat: .unavailable,
                captureDeviceVirtualFormat: .unavailable,
                captureDevicePhysicalFormat: .unavailable,
                writerDeviceVirtualFormat: .unavailable,
                writerDevicePhysicalFormat: .unavailable,
                captureQueueUIDReadback: "",
                writerQueueUIDReadback: "",
                visibleInputMuted: false,
                hiddenOutputMuted: false,
                visibleInputVolumeScalar: -1,
                hiddenOutputVolumeScalar: -1,
                writerQueueVolumeScalar: -1,
                captureQueueUIDMatches: false,
                writerQueueUIDMatches: false,
                captureFormatMatches: false,
                writerFormatMatches: false,
                captureDeviceFormatMatches: false,
                writerDeviceFormatMatches: false,
                signalControlsMatch: false,
                writerQueueVolumeMatches: false,
                writerPrimingFrameCount: 0,
                writerCallbackCount: 0,
                writerSubmittedChallengeFrameCount: 0,
                writerChallengeFullySubmitted: false
            ),
            pcm: MirrorLoopbackPCMEvidence(
                retainedSampleLimit:
                    MirrorLoopbackPolicy.maximumRetainedFrames,
                capturedSampleCount: 0,
                totalObservedSampleCount: 0,
                rawCaptureCallbackCount: 0,
                capturedOverflow: false,
                comparisonAvailable: false,
                alignmentCount: 0,
                alignedStartFrame: -1,
                nonzeroSampleCount: 0,
                absolutePeak: 0,
                rootMeanSquare: 0,
                retainedPCMHash: MirrorLoopbackPCM.hash([Int16]()),
                comparedFrameCount: 0,
                matchedFrameCount: 0,
                mismatchSampleCount: 0,
                missingFrameCount: MirrorLoopbackPolicy.challengeFrames,
                requiredPostRollFrameCount:
                    MirrorLoopbackPolicy.postRollFrames,
                capturedPostRollFrameCount: 0,
                postRollNonzeroSampleCount: 0,
                postRollAbsolutePeak: 0,
                postRollSilenceMatches: false,
                unexpectedTrailingFrameCount: 0,
                exactPCMMatches: false,
                signedInt16Compatible: false
            ),
            timestamps: MirrorLoopbackTimestampEvidence(
                alignedEvidenceAvailable: false,
                callbackCount: 0,
                rawCaptureCallbackCount: 0,
                rawCapturedFrameCount: 0,
                timestampFrameCount: 0,
                sampleTimeValidCount: 0,
                sampleTimeMissingCount: 0,
                hostTimeValidCount: 0,
                hostTimeMissingCount: 0,
                nonIntegralSampleTimeCount: 0,
                nonMonotonicSampleTimeCount: 0,
                sampleFrameDiscontinuityCount: 0,
                nonMonotonicHostTimeCount: 0,
                hostDeltaMismatchCount: 0,
                maximumHostDeltaErrorNs: 0,
                firstRawSampleFrame: 0,
                lastRawSampleFrame: 0,
                lastRawSampleFrameExclusive: 0,
                measuredSourceSampleRate: 0,
                sourceSampleRateMatches: false,
                deviceTimePairCount: 0,
                deviceTimeSampleFlagMissingCount: 0,
                deviceTimeHostFlagMissingCount: 0,
                nonIntegralDeviceSampleTimeCount: 0,
                nonAdvancingDeviceTimeCount: 0,
                deviceTimeRateMismatchCount: 0,
                mirrorDeviceTimeMismatchCount: 0,
                projection: projection
            ),
            defaults: MirrorLoopbackDefaultsEvidence(
                beforeFingerprint: MirrorLoopbackPCM.fingerprint(
                    defaultsBefore.inputUID + "\u{0}"
                        + defaultsBefore.outputUID + "\u{0}"
                        + defaultsBefore.systemOutputUID
                ),
                afterFingerprint: MirrorLoopbackPCM.fingerprint(
                    defaultsAfter.inputUID + "\u{0}"
                        + defaultsAfter.outputUID + "\u{0}"
                        + defaultsAfter.systemOutputUID
                ),
                inputBeforeAfterEqual:
                    defaultsBefore.inputUID == defaultsAfter.inputUID,
                outputBeforeAfterEqual:
                    defaultsBefore.outputUID == defaultsAfter.outputUID,
                systemOutputBeforeAfterEqual:
                    defaultsBefore.systemOutputUID
                        == defaultsAfter.systemOutputUID,
                notificationCount: 0,
                mutated: defaultsBefore != defaultsAfter,
                hiddenEndpointNeverDefault: hiddenNeverDefault,
                virtualEndpointsNeverOutputDefault:
                    virtualEndpointsNeverOutput
            ),
            lifecycle: MirrorLoopbackLifecycleEvidence(
                requiredStartOrders: ["visible-first", "hidden-first"],
                cycles: [],
                zeroTimestampSeedObservableViaPublicAPI: false,
                seedChangeClaimed: false
            ),
            teardown: MirrorLoopbackTeardownEvidence(
                // The explicit real-runner defers have completed before this
                // builder runs, but a thrown setup call did not preserve its
                // per-queue/listener statuses. Never manufacture success.
                cleanupEvidenceComplete: false,
                queuesOpened: false,
                inputStopStatus: -1,
                outputStopStatus: -1,
                inputDisposeStatus: -1,
                outputDisposeStatus: -1,
                callbackGatesDrained: false,
                postCloseCallbackCount: -1,
                runningStateRestored: runningStateRestored,
                defaultListenerInstalled: false,
                deviceListenerInstalled: false,
                listenersRemoved: false,
                contextsReleased: false
            ),
            failureCode: failures[0],
            failureReasons: Array(
                failures.prefix(MirrorLoopbackPolicy.maximumFailureReasons)
            )
        )
    }
}

private enum MirrorLoopbackWriter {
    static func write(_ result: MirrorLoopbackResult, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) {
            guard !isDirectory.boolValue else {
                throw ProbeError(code: "result_path_is_directory")
            }
            try FileManager.default.removeItem(at: url)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp"
            )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try encoder.encode(result).write(to: temporary)
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_RDONLY)
        }
        if descriptor >= 0 {
            _ = Darwin.fsync(descriptor)
            _ = Darwin.close(descriptor)
        }
        let renameStatus = temporary.path.withCString { source in
            url.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renameStatus == 0 else {
            throw ProbeError(code: "result_atomic_rename_failed")
        }
    }
}

private enum MirrorLoopbackProgram {
    static let usage = """
    Usage:
      physical-blackhole-microphone-probe mirror-loopback --nonce <fresh-nonsecret-token> --required-headroom-seconds <60...86400> --result <json-path>
      physical-blackhole-microphone-probe mirror-loopback-self-test --case <case> --nonce <fresh-nonsecret-token> --required-headroom-seconds <0...86400> --result <json-path>

    mirror-loopback requires both exact repo-owned virtual-microphone endpoints to be quiescent. It exercises complete visible-first and hidden-first restart lifecycles, then opens queue-local writer-output and visible-input AudioQueues for one bounded mono challenge. It never changes a default device and fails closed on any role, model, clock-domain, format, timestamp, PCM, default-route, lifecycle, or teardown mismatch. The public API cannot expose the zero-timestamp seed, so the artifact reports near-zero shared restart clocks without claiming seed identity.
    """

    static func runIfRequested() -> Int32? {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first,
              command == "mirror-loopback"
                || command == "mirror-loopback-self-test" else {
            return nil
        }
        do {
            let pairs = try parsePairs(Array(arguments.dropFirst()))
            let expectedKeys: Set<String> = command == "mirror-loopback"
                ? ["--nonce", "--required-headroom-seconds", "--result"]
                : [
                    "--case", "--nonce", "--required-headroom-seconds",
                    "--result",
                ]
            guard Set(pairs.keys) == expectedKeys,
                  let nonce = pairs["--nonce"],
                  let resultPath = pairs["--result"],
                  let headroomText = pairs["--required-headroom-seconds"],
                  let requiredHeadroomSeconds = Double(headroomText),
                  requiredHeadroomSeconds.isFinite,
                  requiredHeadroomSeconds >= (command == "mirror-loopback"
                    ? MirrorLoopbackPolicy.minimumProductionHeadroomSeconds
                    : 0),
                  requiredHeadroomSeconds
                    <= MirrorLoopbackPolicy.maximumHeadroomSeconds else {
                throw ProbeError(code: "usage")
            }
            try validateNonce(nonce)
            try validateResultPath(resultPath)
            let result: MirrorLoopbackResult
            if command == "mirror-loopback-self-test" {
                guard MirrorLoopbackLiveSeamSelfTest.passes(nonce: nonce) else {
                    throw ProbeError(code: "mirror_live_seam_self_test_failed")
                }
                guard let caseName = pairs["--case"],
                      let test = MirrorLoopbackSyntheticCase(
                        rawValue: caseName
                      ) else {
                    throw ProbeError(code: "usage")
                }
                let fixture = MirrorLoopbackSyntheticFactory.make(
                    test: test,
                    nonce: nonce,
                    requiredHeadroomSeconds: requiredHeadroomSeconds
                )
                result = MirrorLoopbackEvaluator.evaluate(
                    nonce: nonce,
                    requiredHeadroomSeconds: requiredHeadroomSeconds,
                    fixture: fixture
                )
            } else {
                do {
                    result = try MirrorLoopbackRealRunner.run(
                        nonce: nonce,
                        requiredHeadroomSeconds: requiredHeadroomSeconds
                    )
                } catch let error as ProbeError {
                    result = MirrorLoopbackFailureBuilder.make(
                        nonce: nonce,
                        requiredHeadroomSeconds: requiredHeadroomSeconds,
                        failureCode: error.code
                    )
                } catch {
                    result = MirrorLoopbackFailureBuilder.make(
                        nonce: nonce,
                        requiredHeadroomSeconds: requiredHeadroomSeconds,
                        failureCode: "mirror_loopback_internal_failure"
                    )
                }
            }
            try MirrorLoopbackWriter.write(
                result,
                to: URL(fileURLWithPath: resultPath)
            )
            switch result.status {
            case "passed": return 0
            default: return 1
            }
        } catch let error as ProbeError where error.code == "usage" {
            FileHandle.standardError.write(Data(usage.utf8))
            return 64
        } catch {
            return 74
        }
    }

    private static func parsePairs(
        _ arguments: [String]
    ) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else {
            throw ProbeError(code: "usage")
        }
        var result: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            let value = arguments[index + 1]
            guard key.hasPrefix("--"), result[key] == nil,
                  !value.isEmpty else {
                throw ProbeError(code: "usage")
            }
            result[key] = value
            index += 2
        }
        return result
    }

    private static func validateNonce(_ nonce: String) throws {
        guard nonce.utf8.count >= 8, nonce.utf8.count <= 128 else {
            throw ProbeError(code: "usage")
        }
        for byte in nonce.utf8 {
            let allowed = (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45 || byte == 46 || byte == 58 || byte == 95
            guard allowed else { throw ProbeError(code: "usage") }
        }
    }

    private static func validateResultPath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 4_096 else {
            throw ProbeError(code: "usage")
        }
    }
}

if let status = DefaultUIDSnapshotProgram.runIfRequested() {
    Darwin.exit(status)
}
if let status = MirrorLoopbackProgram.runIfRequested() {
    Darwin.exit(status)
}
if let status = BlackHoleMeasureProgram.runIfRequested() {
    Darwin.exit(status)
}
Darwin.exit(ProbeProgram.main())
