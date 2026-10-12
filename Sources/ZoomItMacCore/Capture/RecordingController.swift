import AVFoundation
import AppKit
@preconcurrency import ScreenCaptureKit

/// Wraps a CMSampleBuffer so it can be handed from capture callbacks to the
/// writer queue. CMSampleBuffer is immutable once delivered and the writer
/// serialises all access.
struct SampleBufferBox: @unchecked Sendable {
    let buffer: CMSampleBuffer
}

private let recordingSyntheticFrameDuration = CMTime(value: 1, timescale: 10)

struct RecordingImageFrame: @unchecked Sendable {
    let image: CGImage
    let presentationTime: CMTime
    let duration: CMTime

    init(image: CGImage, presentationTime: CMTime, duration: CMTime = recordingSyntheticFrameDuration) {
        self.image = image
        self.presentationTime = presentationTime
        self.duration = duration
    }
}

/// Owns the AVAssetWriter and serialises all sample appends on its own queue so
/// it can safely receive buffers from the ScreenCaptureKit and microphone
/// capture callbacks (which run on background queues).
final class RecordingEngine: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "com.zoomitmac.recorder")
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let micInput: AVAssetWriterInput?
    private let videoSettings: [String: Any]
    private let width: Int
    private let height: Int
    private var sourceStartTime: CMTime?
    private var sessionStarted = false
    private var hasVideoSample = false
    private var systemAudioStarted = false
    private var micStarted = false
    private var lastVideoPresentationTime: CMTime?
    private var lastVideoDuration = recordingSyntheticFrameDuration
    private var finished = false
    private var failureReported = false
    private let permitsFallback: Bool
    private let onFailure: (@Sendable (Error) -> Void)?
    private let pendingImageLock = NSLock()
    private var imagePending = false

    init(url: URL, width: Int, height: Int, systemAudio: Bool, microphone: Bool, permitsFallback: Bool = true, onFailure: (@Sendable (Error) -> Void)? = nil) throws {
        self.url = url
        self.permitsFallback = permitsFallback
        self.onFailure = onFailure
        self.width = width
        self.height = height
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        if !permitsFallback {
            settings[AVVideoColorPropertiesKey] = RecordingColorSpace.videoProperties
        }
        videoSettings = settings
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        if writer.canAdd(videoInput) { writer.add(videoInput) }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 128_000
        ]
        if systemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            systemAudioInput = writer.canAdd(input) ? input : nil
            if let systemAudioInput { writer.add(systemAudioInput) }
        } else {
            systemAudioInput = nil
        }
        if microphone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            micInput = writer.canAdd(input) ? input : nil
            if let micInput { writer.add(micInput) }
        } else {
            micInput = nil
        }
    }

    func startWriting() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.writer.startWriting() { continuation.resume() }
                else { continuation.resume(throwing: self.writer.error ?? ScreenCaptureError.recordingFailed) }
            }
        }
    }

    /// The pump may publish at most one pending full-size composition. It drops
    /// obsolete frames when encoding falls behind instead of growing a queue.
    @discardableResult
    func appendVideoImageBounded(_ frame: RecordingImageFrame) -> Bool {
        pendingImageLock.lock()
        guard !imagePending else { pendingImageLock.unlock(); return false }
        imagePending = true
        pendingImageLock.unlock()
        queue.async {
            defer {
                self.pendingImageLock.lock()
                self.imagePending = false
                self.pendingImageLock.unlock()
            }
            guard !self.finished else { return }
            guard self.writer.status == .writing else { self.reportFailureIfNeeded(); return }
            guard let buffer = self.makeSampleBuffer(from: frame.image,
                presentationTime: self.monotonicVideoPresentationTime(for: frame.presentationTime), duration: frame.duration) else {
                self.reportFailure(ScreenCaptureError.recordingFailed)
                return
            }
            self.appendVideoOnQueue(buffer)
            self.reportFailureIfNeeded()
        }
        return true
    }

    private func reportFailureIfNeeded() {
        if writer.status == .failed { reportFailure(writer.error ?? ScreenCaptureError.recordingFailed) }
    }

    private func reportFailure(_ error: Error) {
        guard !failureReported else { return }
        failureReported = true
        onFailure?(error)
    }

    func appendVideo(_ box: SampleBufferBox) {
        queue.async {
            guard !self.finished, self.writer.status == .writing,
                  let sampleBuffer = self.retimedVideoSampleBuffer(box.buffer) else { return }
            self.appendVideoOnQueue(sampleBuffer)
        }
    }

    func appendVideoImage(_ frame: RecordingImageFrame) {
        queue.async {
            guard !self.finished, self.writer.status == .writing else { return }
            let presentationTime = self.monotonicVideoPresentationTime(for: frame.presentationTime)
            guard let sampleBuffer = self.makeSampleBuffer(from: frame.image, presentationTime: presentationTime, duration: frame.duration) else { return }
            self.appendVideoOnQueue(sampleBuffer)
        }
    }

    func appendVideoImageIfNeeded(_ frame: RecordingImageFrame) {
        queue.async {
            guard !self.hasVideoSample, !self.finished, self.writer.status == .writing else { return }
            let presentationTime = self.monotonicVideoPresentationTime(for: frame.presentationTime)
            guard let sampleBuffer = self.makeSampleBuffer(from: frame.image, presentationTime: presentationTime, duration: frame.duration) else { return }
            self.appendVideoOnQueue(sampleBuffer)
        }
    }

    func appendVideoImageAtEnd(_ frame: RecordingImageFrame) {
        queue.async {
            guard !self.finished, self.writer.status == .writing else { return }
            let presentationTime = self.monotonicVideoPresentationTime(for: frame.presentationTime)
            guard let sampleBuffer = self.makeSampleBuffer(
                from: frame.image,
                presentationTime: presentationTime,
                duration: frame.duration
            ) else { return }
            self.appendVideoOnQueue(sampleBuffer)
        }
    }

    func appendBlackVideoFrameIfNeeded(presentationTime: CMTime) {
        queue.async {
            guard !self.hasVideoSample, !self.finished, self.writer.status == .writing,
                  let image = self.makeBlackImage(),
                  let sampleBuffer = self.makeSampleBuffer(from: image, presentationTime: self.monotonicVideoPresentationTime(for: presentationTime), duration: recordingSyntheticFrameDuration) else { return }
            self.appendVideoOnQueue(sampleBuffer)
        }
    }

    func waitForQueuedAppends() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    func appendSystemAudio(_ box: SampleBufferBox) {
        queue.async {
            guard self.sessionStarted, !self.finished, self.writer.status == .writing,
                  let input = self.systemAudioInput, input.isReadyForMoreMediaData else { return }
            // Avoid creating an entirely-silent track by dropping leading silent
            // buffers until the first real audio; once audio has started, append
            // every buffer (including later silence) so the timeline stays
            // continuous. Dropping silent buffers mid-stream punches gaps that
            // the AAC encoder turns into pops.
            if !self.systemAudioStarted {
                guard self.hasNonZeroAudioSamples(box.buffer) else { return }
                self.systemAudioStarted = true
            }
            guard let sampleBuffer = self.retimedAudioSampleBuffer(box.buffer) else { return }
            input.append(sampleBuffer)
        }
    }

    func appendMicrophone(_ box: SampleBufferBox) {
        queue.async {
            guard self.sessionStarted, !self.finished, self.writer.status == .writing,
                  let input = self.micInput, input.isReadyForMoreMediaData else { return }
            if !self.micStarted {
                guard self.hasNonZeroAudioSamples(box.buffer) else { return }
                self.micStarted = true
            }
            let writerSource = self.limitedMicrophoneSampleBuffer(box.buffer) ?? box.buffer
            guard let sampleBuffer = self.retimedAudioSampleBuffer(writerSource) else { return }
            input.append(sampleBuffer)
        }
    }

    func finish(completion: @escaping @Sendable (URL?) -> Void) {
        queue.async {
            guard !self.finished, self.writer.status == .writing else {
                if self.permitsFallback { self.writeFallbackMovie(completion: completion) }
                else { completion(nil) }
                return
            }
            self.finished = true
            if let endTime = self.endSessionTime() {
                self.writer.endSession(atSourceTime: endTime)
            }
            self.videoInput.markAsFinished()
            self.systemAudioInput?.markAsFinished()
            self.micInput?.markAsFinished()
            let url = self.url
            self.writer.finishWriting {
                if self.writer.status == .completed {
                    completion(url)
                } else {
                    if self.permitsFallback { self.writeFallbackMovie(completion: completion) }
                    else { completion(nil) }
                }
            }
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.finished = true
                self.writer.cancelWriting()
                try? FileManager.default.removeItem(at: self.url)
                continuation.resume()
            }
        }
    }

    private func appendVideoOnQueue(_ sampleBuffer: CMSampleBuffer) {
        if !sessionStarted {
            sessionStarted = true
            writer.startSession(atSourceTime: .zero)
        }
        if videoInput.isReadyForMoreMediaData, videoInput.append(sampleBuffer) {
            hasVideoSample = true
            lastVideoPresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            lastVideoDuration = effectiveDuration(for: sampleBuffer)
        }
    }

    private func normalizedPresentationTime(for sourceTime: CMTime) -> CMTime {
        let validSourceTime = sourceTime.isValid && sourceTime.isNumeric ? sourceTime : (sourceStartTime ?? .zero)
        guard let start = sourceStartTime else {
            sourceStartTime = validSourceTime
            return .zero
        }
        let relativeTime = CMTimeSubtract(validSourceTime, start)
        if relativeTime.isValid, relativeTime.isNumeric, CMTimeCompare(relativeTime, .zero) >= 0 {
            return relativeTime
        }
        return .zero
    }

    private func nextVideoPresentationTime() -> CMTime {
        guard let lastVideoPresentationTime else { return .zero }
        return CMTimeAdd(lastVideoPresentationTime, lastVideoDuration)
    }

    private func monotonicVideoPresentationTime(for sourceTime: CMTime) -> CMTime {
        let normalizedTime = normalizedPresentationTime(for: sourceTime)
        guard let lastVideoPresentationTime else { return normalizedTime }
        return CMTimeCompare(normalizedTime, lastVideoPresentationTime) > 0 ? normalizedTime : nextVideoPresentationTime()
    }

    private func retimedVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        retimedSampleBuffer(sampleBuffer, presentationTime: monotonicVideoPresentationTime(for: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }

    private func retimedSampleBuffer(_ sampleBuffer: CMSampleBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: effectiveDuration(for: sampleBuffer),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var retimed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        ) == noErr else { return nil }
        return retimed
    }

    /// Retimes an audio buffer by shifting only its presentation timestamps onto
    /// the writer timeline while preserving the capture API's timing layout.
    private func retimedAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        let originalPresentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let newPresentation = normalizedPresentationTime(for: originalPresentation)
        let offset = CMTimeSubtract(newPresentation, originalPresentation)
        guard offset.isValid, offset.isNumeric else { return nil }

        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr, count > 0 else {
            return nil
        }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr else {
            return nil
        }
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = CMTimeAdd(timings[index].presentationTimeStamp, offset)
            }
            timings[index].decodeTimeStamp = .invalid
        }

        var retimed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timings.count,
            sampleTimingArray: &timings,
            sampleBufferOut: &retimed
        ) == noErr else { return nil }
        return retimed
    }

    private func limitedMicrophoneSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              streamDescription.mFormatID == kAudioFormatLinearPCM,
              streamDescription.mBitsPerChannel == 32,
              streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return sampleBuffer }

        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        guard byteCount > 0 else { return sampleBuffer }

        var data = Data(count: byteCount)
        let copyStatus = data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteCount, destination: baseAddress)
        }
        guard copyStatus == noErr else { return sampleBuffer }

        let knee: Float = 0.98
        var limited = false
        data.withUnsafeMutableBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Float.self)
            for index in samples.indices {
                let sample = samples[index]
                if !sample.isFinite {
                    samples[index] = 0
                    limited = true
                    continue
                }

                let magnitude = abs(sample)
                if magnitude > knee {
                    let excess = magnitude - knee
                    let softened = knee + (1 - knee) * (excess / (excess + 1))
                    samples[index] = sample < 0 ? -softened : softened
                    limited = true
                }
            }
        }
        guard limited else { return sampleBuffer }

        var limitedBlockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &limitedBlockBuffer
        ) == noErr, let limitedBlockBuffer else { return sampleBuffer }

        let replaceStatus = data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(with: baseAddress, blockBuffer: limitedBlockBuffer, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard replaceStatus == noErr else { return sampleBuffer }

        var timingCount: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingCount) == noErr, timingCount > 0 else {
            return sampleBuffer
        }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: timingCount)
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: timingCount, arrayToFill: &timings, entriesNeededOut: &timingCount) == noErr else {
            return sampleBuffer
        }

        var limitedSampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: limitedBlockBuffer,
            formatDescription: formatDescription,
            sampleCount: CMSampleBufferGetNumSamples(sampleBuffer),
            sampleTimingEntryCount: timings.count,
            sampleTimingArray: &timings,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &limitedSampleBuffer
        ) == noErr else { return sampleBuffer }

        return limitedSampleBuffer
    }

    private func hasNonZeroAudioSamples(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Audio,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return true }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return false }

        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: baseAddress
            )
        }
        guard status == noErr else { return true }
        return data.contains { $0 != 0 }
    }

    private func effectiveDuration(for sampleBuffer: CMSampleBuffer) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration.isNumeric, CMTimeCompare(duration, .zero) > 0 {
            return duration
        }
        return recordingSyntheticFrameDuration
    }

    private func endSessionTime() -> CMTime? {
        guard let lastVideoPresentationTime else { return nil }
        let endTime = CMTimeAdd(lastVideoPresentationTime, lastVideoDuration)
        return endTime.isValid && endTime.isNumeric ? endTime : nil
    }

    private func makeSampleBuffer(from image: CGImage, presentationTime: CMTime, duration: CMTime = .invalid) -> CMSampleBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: RecordingColorSpace.rgb,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        RecordingColorSpace.tag(pixelBuffer)

        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &description
        ) == noErr, let description else { return nil }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }

    private func makeBlackImage() -> CGImage? {
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func writeFallbackMovie(completion: @escaping @Sendable (URL?) -> Void) {
        try? FileManager.default.removeItem(at: url)
        do {
            let fallbackWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = false
            guard fallbackWriter.canAdd(input), let image = makeBlackImage() else {
                completion(nil)
                return
            }
            fallbackWriter.add(input)
            fallbackWriter.startWriting()
            fallbackWriter.startSession(atSourceTime: .zero)
            guard let sampleBuffer = makeSampleBuffer(
                from: image,
                presentationTime: .zero,
                duration: CMTime(value: 1, timescale: 10)
            ), input.append(sampleBuffer) else {
                fallbackWriter.cancelWriting()
                completion(nil)
                return
            }
            fallbackWriter.endSession(atSourceTime: recordingSyntheticFrameDuration)
            input.markAsFinished()
            nonisolated(unsafe) let writerForCompletion = fallbackWriter
            fallbackWriter.finishWriting {
                completion(writerForCompletion.status == .completed ? self.url : nil)
            }
        } catch {
            completion(nil)
        }
    }
}

/// Forwards ScreenCaptureKit video and system-audio buffers to the engine.
private final class RecordingStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let engine: RecordingEngine
    private let overlayFrameProvider: (@MainActor @Sendable () -> CGImage?)?
    private let stateLock = NSLock()
    private var overlayActive = false
    private var overlayFramePending = false
    private var lastOverlayProbeTime: CMTime?
    private var lastOverlayFrameTime: CMTime?

    private static let overlayFrameInterval = CMTime(value: 1, timescale: 10)
    private static let inactiveOverlayProbeInterval = CMTime(value: 1, timescale: 4)

    init(engine: RecordingEngine, overlayFrameProvider: (@MainActor @Sendable () -> CGImage?)?) {
        self.engine = engine
        self.overlayFrameProvider = overlayFrameProvider
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            // Skip frames that aren't complete (e.g. idle/blank) so only real
            // updates are encoded.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  statusRaw == SCFrameStatus.complete.rawValue else { return }
            let box = SampleBufferBox(buffer: sampleBuffer)
            guard let overlayFrameProvider else {
                engine.appendVideo(box)
                return
            }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            handleScreenFrame(box, presentationTime: presentationTime, overlayFrameProvider: overlayFrameProvider)
        case .audio:
            engine.appendSystemAudio(SampleBufferBox(buffer: sampleBuffer))
        default:
            // Microphone audio (ScreenCaptureKit, macOS 15+) shares the video
            // clock, so it aligns with the writer session.
            if #available(macOS 15.0, *), type == .microphone {
                engine.appendMicrophone(SampleBufferBox(buffer: sampleBuffer))
            }
        }
    }

    private func handleScreenFrame(
        _ box: SampleBufferBox,
        presentationTime: CMTime,
        overlayFrameProvider: @escaping @MainActor @Sendable () -> CGImage?
    ) {
        stateLock.lock()
        let isOverlayActive = overlayActive

        if !isOverlayActive {
            let shouldProbe = !overlayFramePending && shouldProbeInactiveOverlay(at: presentationTime)
            if shouldProbe {
                overlayFramePending = true
                lastOverlayProbeTime = presentationTime
            }
            stateLock.unlock()

            if shouldProbe {
                Task { @MainActor in
                    let image = overlayFrameProvider()
                    self.finishOverlayFrame(image: image, fallback: box, presentationTime: presentationTime)
                }
            } else {
                engine.appendVideo(box)
            }
            return
        }

        if overlayFramePending || shouldSkipOverlayFrame(at: presentationTime) {
            stateLock.unlock()
            return
        }

        overlayFramePending = true
        stateLock.unlock()

        Task { @MainActor in
            let image = overlayFrameProvider()
            self.finishOverlayFrame(image: image, fallback: box, presentationTime: presentationTime)
        }
    }

    private func shouldProbeInactiveOverlay(at presentationTime: CMTime) -> Bool {
        guard let lastOverlayProbeTime else { return true }
        return CMTimeCompare(CMTimeSubtract(presentationTime, lastOverlayProbeTime), Self.inactiveOverlayProbeInterval) >= 0
    }

    private func shouldSkipOverlayFrame(at presentationTime: CMTime) -> Bool {
        guard let lastOverlayFrameTime else { return false }
        return CMTimeCompare(CMTimeSubtract(presentationTime, lastOverlayFrameTime), Self.overlayFrameInterval) < 0
    }

    private func finishOverlayFrame(image: CGImage?, fallback: SampleBufferBox, presentationTime: CMTime) {
        if let image {
            engine.appendVideoImage(RecordingImageFrame(image: image, presentationTime: presentationTime))
        } else {
            engine.appendVideo(fallback)
        }

        stateLock.lock()
        overlayActive = image != nil
        overlayFramePending = false
        if image != nil {
            lastOverlayFrameTime = presentationTime
        }
        stateLock.unlock()
    }

    func waitForPendingOverlayFrame() async {
        guard overlayFrameProvider != nil else { return }
        for _ in 0..<60 {
            if !hasPendingOverlayFrame() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    func appendFinalOverlayFrameIfNeeded(presentationTime: CMTime) {
        guard let overlayFrameProvider, let image = overlayFrameProvider() else { return }
        engine.appendVideoImageIfNeeded(RecordingImageFrame(image: image, presentationTime: presentationTime))
    }

    private func hasPendingOverlayFrame() -> Bool {
        stateLock.lock()
        let pending = overlayFramePending
        stateLock.unlock()
        return pending
    }
}

/// Forwards microphone buffers to the engine.
private final class RecordingMicOutput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let engine: RecordingEngine

    init(engine: RecordingEngine) {
        self.engine = engine
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        engine.appendMicrophone(SampleBufferBox(buffer: sampleBuffer))
    }
}

/// Draws an orange border around the area being recorded (the whole view, or a
/// selected region). It lives in a click-through window excluded from capture so
/// it never appears in the recording.
@MainActor
private final class RecordingBorderView: NSView {
    /// The region being recorded in view points (top-left origin), or nil for
    /// the whole screen.
    var region: CGRect?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let lineWidth: CGFloat = 6
        // Inset by half the line width so the full stroke stays on screen.
        let rect = (region ?? bounds).insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        context.setStrokeColor(NSColor.systemOrange.cgColor)
        context.setLineWidth(lineWidth)
        context.stroke(rect)
    }
}

/// Records the screen (or a selected region) to an MP4 using ScreenCaptureKit
/// for video and optional system audio, plus an optional microphone via
/// AVCaptureSession, mirroring ZoomIt's recording feature.
@MainActor
final class RecordingController {
    private let captureService: ScreenCaptureService
    private let displayManager: DisplayManager
    private let permissionService: PermissionService
    private let settingsStore: SettingsStore

    private(set) var isRecording = false
    private(set) var sessionState = RecordingSessionState()
    private(set) var isolatedGeometry: RecordingCanvasGeometry?
    private(set) var isolatedSourceFrame: RecordingSourceFrame?
    var isolatedGeneration: UInt64 { sessionState.generation }
    var isIsolatedRecording: Bool { sessionState.scope?.isIsolated == true && isRecording }
    var isolatedOverlaySnapshotProvider: (@MainActor @Sendable () -> RecordingOverlaySnapshot?)?
    var onIsolatedSourceChanged: (@MainActor (RecordingSourceFrame?, RecordingCanvasGeometry?, UInt64) -> Void)?
    var onSessionStateChanged: (@MainActor (RecordingSessionState) -> Void)?
    private var pickerController: RecordingPickerController?
    private var sourceSession: RecordingSourceSession?
    private var frameTimer: Timer?
    private var isolatedTimeline = RecordingTimeline()
    private var sourceRevision: UInt64?
    private var selectedWindowID: CGWindowID?
    private var selectedProcessID: pid_t?
    private var selectedCaptureDisplayBounds: CGRect?
    private var lastIdentityProbe = Date.distantPast
    private let compositionQueue = DispatchQueue(label: "com.zoomitmac.recording.compositor")
    private var compositionPending = false
    private var compositionWaiter: CheckedContinuation<Void, Never>?
    private var isStartingRecording = false
    private var isStoppingRecording = false
    private var isFinalizingRecording = false
    private var onStateChange: ((Bool) -> Void)?
    /// Dismisses any obscuring overlay before recording results are presented,
    /// including error alerts as well as the editor and save dialog.
    var onWillPresentRecordingResult: (() -> Void)?

    private var stream: SCStream?
    private var streamOutput: RecordingStreamOutput?
    private var micOutput: RecordingMicOutput?
    private var captureSession: AVCaptureSession?
    private var engine: RecordingEngine?
    private var borderWindow: NSWindow?
    private var recordingDisplay: DisplayDescriptor?
    private var recordingSourceRect: CGRect?
    private let webcam: WebcamOverlayController
    private let sampleQueue = DispatchQueue(label: "com.zoomitmac.recorder.samples")
    private var clipEditor: VideoClipEditorController?
    var overlayFrameProvider: (@MainActor @Sendable (CGRect?) -> CGImage?)?

    init(
        captureService: ScreenCaptureService,
        displayManager: DisplayManager,
        permissionService: PermissionService,
        settingsStore: SettingsStore
    ) {
        self.captureService = captureService
        self.displayManager = displayManager
        self.permissionService = permissionService
        self.settingsStore = settingsStore
        self.webcam = WebcamOverlayController(permissionService: permissionService)
    }

    func toggle(scope: RecordingScope, onStateChange: @escaping (Bool) -> Void) {
        if isRecording && sessionState.canStop {
            stop()
            return
        }
        guard sessionState.canStart, !isFinalizingRecording, clipEditor == nil else { NSSound.beep(); return }
        self.onStateChange = onStateChange
        guard let generation = sessionState.begin(scope: scope) else { return }
        notifySessionState()
        if scope.isIsolated { selectIsolatedSource(scope: scope, generation: generation) }
        else { start(region: scope == .region) }
    }

    func stopIfRecording() {
        guard sessionState.canStop else { return }
        stop()
    }

    private func notifySessionState() { onSessionStateChanged?(sessionState) }

    private func transition(to phase: RecordingSessionState.Phase) {
        if sessionState.transition(to: phase, generation: sessionState.generation) { notifySessionState() }
    }

    private func selectIsolatedSource(scope: RecordingScope, generation: UInt64) {
        isStartingRecording = true
        let picker = RecordingPickerController(scope: scope)
        pickerController = picker
        picker.present { [weak self] result in
            guard let self, self.sessionState.generation == generation, self.sessionState.phase == .selecting else { return }
            switch result {
            case .success(nil):
                self.cleanup()
                self.transition(to: .idle)
            case .failure(let error):
                self.cleanup()
                self.transition(to: .idle)
                self.presentError(error)
            case .success(let filter?):
                self.transition(to: .starting)
                Task { @MainActor in
                    do {
                        try await self.startIsolatedStreaming(filter: filter, scope: scope, generation: generation)
                        guard self.sessionState.generation == generation, self.sessionState.phase == .starting else { return }
                        self.isStartingRecording = false
                        self.isRecording = true
                        self.transition(to: .recording)
                        self.onStateChange?(true)
                        self.startIsolatedFramePump(generation: generation)
                    } catch {
                        try? await self.stream?.stopCapture()
                        await self.engine?.cancel()
                        self.cleanup()
                        self.transition(to: .idle)
                        self.onStateChange?(false)
                        self.presentError(error)
                    }
                }
            }
        }
    }

    var webcamWindowNumberForScreenCaptureExclusion: Int? {
        webcam.windowNumber
    }

    private func start(region: Bool) {
        guard ScreenRecordingPrompt.ensureGranted(permissionService) else {
            transition(to: .idle)
            return
        }
        guard let display = displayManager.activeDisplay() else {
            transition(to: .idle)
            NSSound.beep()
            return
        }

        isStartingRecording = true

        if region {
            selectRegion(on: display) { [weak self] rect in
                guard let self else { return }
                guard let rect else {
                    self.isStartingRecording = false
                    self.transition(to: .idle)
                    return
                }
                self.beginCapture(display: display, sourceRect: rect)
            }
        } else {
            beginCapture(display: display, sourceRect: fullDisplaySourceRect(for: display))
        }
    }

    private func fullDisplaySourceRect(for display: DisplayDescriptor) -> CGRect {
        CGRect(origin: .zero, size: display.frame.size)
    }

    private func beginCapture(display: DisplayDescriptor, sourceRect: CGRect?) {
        recordingDisplay = display
        recordingSourceRect = sourceRect
        // Show the orange recording border first so it's part of our own windows
        // (excluded from capture) before the stream filter is built.
        showBorder(display: display, region: sourceRect)
        // Show the webcam picture-in-picture overlay (if enabled), positioned
        // inside the recorded area so it appears within the recording. When a
        // ZoomIt overlay is active, the webcam stays visually fixed and is
        // composited into overlay frames instead of being captured as screen
        // content.
        Task { @MainActor in
            do {
                await self.webcam.start(settings: self.settingsStore.load(), area: self.recordedArea(display: display, region: sourceRect))
                try await self.startStreaming(display: display, sourceRect: sourceRect)
                self.isStartingRecording = false
                self.isRecording = true
                self.transition(to: .recording)
                _ = self.sessionState.setAvailability(.available, generation: self.isolatedGeneration)
                self.notifySessionState()
                self.onStateChange?(true)
            } catch {
                self.isStartingRecording = false
                try? await self.stream?.stopCapture()
                await self.engine?.cancel()
                self.cleanup()
                self.transition(to: .idle)
                self.presentError(error)
                self.onStateChange?(false)
            }
        }
    }

    /// Shows a click-through orange border around the recorded area. The window
    /// is marked non-shareable so it never appears in the recording.
    private func showBorder(display: DisplayDescriptor, region: CGRect?) {
        let window = NSWindow(
            contentRect: display.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Sit above the zoom/draw overlay (also at `.screenSaver`) so the border
        // stays visible while zoomed and drawing. It's click-through and
        // non-shareable, so it neither blocks input nor appears in the recording.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false

        let view = RecordingBorderView(frame: CGRect(origin: .zero, size: display.frame.size))
        view.region = region
        window.contentView = view
        window.orderFrontRegardless()
        self.borderWindow = window
    }

    private func hideBorder() {
        borderWindow?.orderOut(nil)
        borderWindow = nil
    }

    /// The recorded area in global (bottom-left origin) screen coordinates: the
    /// region for a region recording, or the whole display otherwise. `region`
    /// is in display points with a top-left origin, so its Y is flipped.
    private func recordedArea(display: DisplayDescriptor, region: CGRect?) -> CGRect {
        guard let region else { return display.frame }
        return CGRect(
            x: display.frame.minX + region.minX,
            y: display.frame.minY + display.frame.height - region.maxY,
            width: region.width,
            height: region.height
        )
    }

    private func startStreaming(display: DisplayDescriptor, sourceRect: CGRect?) async throws {
        let settings = settingsStore.load()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw ScreenCaptureError.displayNotFound
        }

        // Capture the whole display, including ZoomIt's own zoom/draw overlays
        // so annotations made while recording are captured. The orange border
        // is kept out of the recording via its window's `sharingType = .none`.
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])

        let scale = display.scaleFactor
        let configuration = SCStreamConfiguration()
        let pixelWidth: Int
        let pixelHeight: Int
        if let sourceRect {
            configuration.sourceRect = sourceRect
            pixelWidth = Int(sourceRect.width * scale)
            pixelHeight = Int(sourceRect.height * scale)
        } else {
            pixelWidth = Int(display.frame.width * scale)
            pixelHeight = Int(display.frame.height * scale)
        }
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        let overlayFrameProvider = self.overlayFrameProvider
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: overlayFrameProvider == nil ? 60 : 30)
        configuration.queueDepth = 5

        let wantsSystemAudio = settings.recordSystemAudio
        if wantsSystemAudio {
            configuration.capturesAudio = true
        }
        // Only attempt the microphone when already authorized; requesting access
        // without a bundled usage description would crash the bare executable.
        let wantsMic = settings.recordMicrophone
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoomIt-\(UUID().uuidString).mp4")
        let engine = try RecordingEngine(
            url: url,
            width: pixelWidth,
            height: pixelHeight,
            systemAudio: wantsSystemAudio,
            microphone: wantsMic
        )
        try await engine.startWriting()
        self.engine = engine

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let output = RecordingStreamOutput(engine: engine, overlayFrameProvider: overlayFrameProvider.map { provider in
            { @MainActor @Sendable in
                guard let overlayImage = provider(sourceRect) else { return nil }
                guard let webcamFrame = self.webcam.recordingSnapshot() else { return overlayImage }
                return self.composite(webcamFrame, over: overlayImage, display: display, sourceRect: sourceRect)
            }
        })
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
        if wantsSystemAudio {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        self.streamOutput = output
        self.stream = stream

        if wantsMic, let device = AudioDevices.microphone(forID: settings.microphoneDeviceID) {
            try? setupMicrophone(device: device, engine: engine, windNoiseRemoval: settings.recordNoiseCancellation)
        }

        try await stream.startCapture()
    }

    private func startIsolatedStreaming(filter: SCContentFilter, scope: RecordingScope, generation: UInt64) async throws {
        guard let display = displayManager.activeDisplay() else { throw ScreenCaptureError.displayNotFound }
        // contentRect/pointPixelScale come from the actual authorized filter,
        // including opaque macOS 14 picker filters. Never infer a target ID.
        let geometry = try RecordingCanvasGeometry(logicalSize: filter.contentRect.size,
            pixelScale: CGFloat(filter.pointPixelScale), hostDisplayFrame: display.frame)
        isolatedGeometry = geometry
        isolatedTimeline = RecordingTimeline()
        sourceRevision = nil
        selectedWindowID = nil
        selectedProcessID = nil
        selectedCaptureDisplayBounds = nil
        if #available(macOS 15.2, *) {
            if scope == .window {
                selectedWindowID = filter.includedWindows.first?.windowID
                selectedProcessID = filter.includedWindows.first?.owningApplication?.processID
            } else {
                selectedProcessID = filter.includedApplications.first?.processID
                if let selectedDisplay = filter.includedDisplays.first {
                    selectedCaptureDisplayBounds = CGDisplayBounds(selectedDisplay.displayID)
                }
            }
        }
        let settings = settingsStore.load()
        await webcam.startIsolated(settings: settings, geometry: geometry)
        let wantsMic = settings.recordMicrophone && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZoomIt-\(UUID().uuidString).mp4")
        let engine = try RecordingEngine(url: url, width: geometry.outputWidth, height: geometry.outputHeight,
            systemAudio: settings.recordSystemAudio, microphone: wantsMic, permitsFallback: false,
            onFailure: { [weak self] error in
                Task { @MainActor in
                    guard let self, self.sessionState.generation == generation, self.sessionState.canStop else { return }
                    self.stop()
                    // Finalization reports the genuine writer failure once.
                    _ = error
                }
            })
        self.engine = engine
        try await engine.startWriting()
        let source = RecordingSourceSession(generation: generation, audioSink: { sample in
            engine.appendSystemAudio(SampleBufferBox(buffer: sample))
        })
        sourceSession = source
        let configuration = SCStreamConfiguration()
        configuration.width = geometry.outputWidth
        configuration.height = geometry.outputHeight
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.backgroundColor = source.backgroundColor // property is unowned(unsafe)
        configuration.showsCursor = true
        configuration.capturesAudio = settings.recordSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        let stream = SCStream(filter: filter, configuration: configuration, delegate: source)
        try stream.addStreamOutput(source, type: .screen, sampleHandlerQueue: source.queue)
        if settings.recordSystemAudio { try stream.addStreamOutput(source, type: .audio, sampleHandlerQueue: source.queue) }
        self.stream = stream
        pickerController?.bind(stream: stream)
        if wantsMic, let device = AudioDevices.microphone(forID: settings.microphoneDeviceID) {
            try? setupMicrophone(device: device, engine: engine, windNoiseRemoval: settings.recordNoiseCancellation)
        }
        try await stream.startCapture()
    }

    func updateIsolatedPresentationHost(frame: CGRect) {
        guard let old = isolatedGeometry,
              let geometry = try? RecordingCanvasGeometry(logicalSize: old.logicalSize, pixelScale: old.pixelScale,
                                                         hostDisplayFrame: frame) else { return }
        webcam.updateIsolatedPresentation(from: old, to: geometry)
        isolatedGeometry = geometry
    }

    private func startIsolatedFramePump(generation: UInt64) {
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sessionState.generation == generation, self.sessionState.canStop else { return }
                self.pumpIsolatedFrame()
            }
        }
        frameTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        pumpIsolatedFrame()
    }

    private func publishIsolatedSource() {
        guard let snapshot = sourceSession?.snapshot(), sourceRevision != snapshot.revision else { return }
        sourceRevision = snapshot.revision
        isolatedSourceFrame = snapshot.frame
        if sessionState.availability != snapshot.frame.availability {
            _ = sessionState.setAvailability(snapshot.frame.availability, generation: isolatedGeneration)
            notifySessionState()
        }
        onIsolatedSourceChanged?(isolatedSourceFrame, isolatedGeometry, isolatedGeneration)
        if snapshot.frame.availability == .ended, let nativeStream = stream {
            stream = nil
            Task { try? await nativeStream.stopCapture() }
        }
    }

    private func pumpIsolatedFrame() {
        publishIsolatedSource()
        checkIsolatedTargetIdentity()
        guard !compositionPending, let geometry = isolatedGeometry, let engine else { return }
        let source = isolatedSourceFrame
        let overlay = isolatedOverlaySnapshotProvider?()
        let webcam = webcam.isolatedRecordingSnapshot(geometry: geometry)
        let generation = isolatedGeneration
        let time = isolatedTimeline.nextPresentationTime(hostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        let duration = isolatedTimeline.frameDuration
        compositionPending = true
        compositionQueue.async { [weak self] in
            if let image = RecordingFrameRenderer.render(source: source, overlay: overlay, geometry: geometry,
                                                         webcam: webcam, generation: generation) {
                engine.appendVideoImageBounded(RecordingImageFrame(image: image, presentationTime: time, duration: duration))
            }
            Task { @MainActor in
                guard let self else { return }
                self.compositionPending = false
                let waiter = self.compositionWaiter
                self.compositionWaiter = nil
                waiter?.resume()
            }
        }
    }

    private func waitForIsolatedComposition() async {
        guard compositionPending else { return }
        await withCheckedContinuation { compositionWaiter = $0 }
    }

    private func checkIsolatedTargetIdentity(force: Bool = false) {
        // On newer systems use exact identities from the authorized filter.
        // Public window-list metadata reads no screen pixels and does not
        // initiate another blanket Screen Recording authorization request.
        guard sessionState.availability != .ended else { return }
        if let pid = selectedProcessID {
            guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else {
                sourceSession?.end()
                publishIsolatedSource()
                return
            }
            sourceSession?.setApplicationHidden(application.isHidden)
            publishIsolatedSource()
        }
        guard force || Date().timeIntervalSince(lastIdentityProbe) >= 1,
              selectedWindowID != nil || selectedCaptureDisplayBounds != nil else { return }
        lastIdentityProbe = Date()
        guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return }
        if let id = selectedWindowID {
            guard let window = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }) else {
                sourceSession?.end()
                publishIsolatedSource()
                return
            }
            if let visible = window[kCGWindowIsOnscreen as String] as? Bool { sourceSession?.setTargetVisible(visible) }
        } else if let pid = selectedProcessID, let displayBounds = selectedCaptureDisplayBounds {
            let visible = windows.contains { window in
                guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                      window[kCGWindowIsOnscreen as String] as? Bool == true,
                      let bounds = window[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                return rect.intersects(displayBounds)
            }
            sourceSession?.setTargetVisible(visible)
        }
        publishIsolatedSource()
    }

    private func composite(_ webcamFrame: WebcamRecordingFrame, over overlayImage: CGImage, display: DisplayDescriptor, sourceRect: CGRect?) -> CGImage {
        let width = overlayImage.width
        let height = overlayImage.height
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return overlayImage }

        context.interpolationQuality = .high
        context.draw(overlayImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let scale = CGFloat(width) / (sourceRect?.width ?? display.frame.width)
        let source = sourceRect ?? CGRect(origin: .zero, size: display.frame.size)
        let frame = webcamFrame.frame
        let x = (frame.minX - display.frame.minX - source.minX) * scale
        let topY = (display.frame.maxY - frame.maxY - source.minY) * scale
        let webcamWidth = frame.width * scale
        let webcamHeight = frame.height * scale
        let drawRect = CGRect(x: x, y: CGFloat(height) - topY - webcamHeight, width: webcamWidth, height: webcamHeight).integral
        guard drawRect.intersects(CGRect(x: 0, y: 0, width: width, height: height)) else { return overlayImage }

        context.saveGState()
        let clipped = drawRect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        let path = CGPath(roundedRect: clipped, cornerWidth: webcamFrame.cornerRadius * scale, cornerHeight: webcamFrame.cornerRadius * scale, transform: nil)
        context.addPath(path)
        context.clip()

        let imageSize = CGSize(width: webcamFrame.image.width, height: webcamFrame.image.height)
        let imageAspect = imageSize.width / imageSize.height
        let rectAspect = drawRect.width / drawRect.height
        var imageRect = drawRect
        if imageAspect > rectAspect {
            imageRect.size.width = drawRect.height * imageAspect
            imageRect.origin.x = drawRect.midX - imageRect.width / 2
        } else {
            imageRect.size.height = drawRect.width / imageAspect
            imageRect.origin.y = drawRect.midY - imageRect.height / 2
        }
        context.draw(webcamFrame.image, in: imageRect)
        context.restoreGState()

        return context.makeImage() ?? overlayImage
    }

    private func setupMicrophone(device: AVCaptureDevice, engine: RecordingEngine, windNoiseRemoval: Bool) throws {
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        if windNoiseRemoval {
            _ = AudioDevices.setWindNoiseRemoval(true, on: input)
        }
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureAudioDataOutput()
        let micOut = RecordingMicOutput(engine: engine)
        output.setSampleBufferDelegate(micOut, queue: sampleQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.startRunning()
        self.captureSession = session
        self.micOutput = micOut
    }

    private func stop() {
        guard isRecording, !isStoppingRecording, sessionState.canStop else { return }
        let generation = isolatedGeneration
        let isolated = isIsolatedRecording
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        frameTimer?.invalidate()
        frameTimer = nil
        var isolatedFinalImage: CGImage?
        if isolated {
            checkIsolatedTargetIdentity(force: true)
            publishIsolatedSource()
            if let geometry = isolatedGeometry {
                isolatedFinalImage = RecordingFrameRenderer.render(source: isolatedSourceFrame,
                    overlay: isolatedOverlaySnapshotProvider?(), geometry: geometry,
                    webcam: webcam.isolatedRecordingSnapshot(geometry: geometry), generation: generation)
            }
        }
        let finalImage = isolatedFinalImage.map { RecordingImageFrame(image: $0, presentationTime: stopTime,
                                                                     duration: isolatedTimeline.frameDuration) }
        isStoppingRecording = true
        isFinalizingRecording = true
        transition(to: .stopping)
        hideBorder()
        captureSession?.stopRunning()
        captureSession = nil
        micOutput = nil
        let engine = self.engine
        let stream = self.stream
        let streamOutput = self.streamOutput
        let recordingDisplay = self.recordingDisplay
        let recordingSourceRect = self.recordingSourceRect
        self.stream = nil
        self.streamOutput = nil
        self.recordingDisplay = nil
        self.recordingSourceRect = nil
        sourceSession?.invalidate()
        pickerController?.finish()
        pickerController = nil

        Task { @MainActor in
            try? await stream?.stopCapture()
            if isolated {
                await self.waitForIsolatedComposition()
                if let finalImage { engine?.appendVideoImageAtEnd(finalImage) }
            } else {
                await streamOutput?.waitForPendingOverlayFrame()
                streamOutput?.appendFinalOverlayFrameIfNeeded(presentationTime: stopTime)
                if let recordingDisplay,
                   let image = try? await self.captureFallbackFrame(display: recordingDisplay, sourceRect: recordingSourceRect) {
                    engine?.appendVideoImageAtEnd(RecordingImageFrame(image: image, presentationTime: CMClockGetTime(CMClockGetHostTimeClock())))
                }
            }
            engine?.appendBlackVideoFrameIfNeeded(presentationTime: stopTime)
            self.webcam.stop()
            await engine?.waitForQueuedAppends()
            guard let engine else {
                self.cleanup()
                self.transition(to: .idle)
                self.onStateChange?(false)
                self.presentError(ScreenCaptureError.recordingFailed)
                return
            }
            engine.finish { url in
                Task { @MainActor in
                    guard self.sessionState.generation == generation, self.sessionState.phase == .stopping else { return }
                    if url == nil { await engine.cancel() }
                    self.engine = nil
                    self.isRecording = false
                    self.isStoppingRecording = false
                    self.clearIsolatedSource()
                    self.onStateChange?(false)
                    if let url {
                        self.transition(to: .editing)
                        self.presentSave(tempURL: url)
                    } else {
                        self.isFinalizingRecording = false
                        self.transition(to: .idle)
                        self.presentError(ScreenCaptureError.recordingFailed)
                    }
                }
            }
        }
    }

    private func clearIsolatedSource() {
        sourceSession?.invalidate()
        sourceSession = nil
        isolatedSourceFrame = nil
        isolatedGeometry = nil
        sourceRevision = nil
        selectedWindowID = nil
        selectedProcessID = nil
        selectedCaptureDisplayBounds = nil
        onIsolatedSourceChanged?(nil, nil, isolatedGeneration)
    }

    private func captureFallbackFrame(display: DisplayDescriptor, sourceRect: CGRect?) async throws -> CGImage {
        let frame = try await captureService.captureDisplay(display)
        guard let sourceRect else { return frame.image }
        let scale = display.scaleFactor
        let pixelRect = CGRect(
            x: sourceRect.minX * scale,
            y: sourceRect.minY * scale,
            width: sourceRect.width * scale,
            height: sourceRect.height * scale
        ).integral
        return frame.image.cropping(to: pixelRect) ?? frame.image
    }

    private func presentSave(tempURL: URL) {
        // Dismiss any zoom overlay first so the editor isn't hidden behind it.
        onWillPresentRecordingResult?()
        DispatchQueue.main.async { [weak self] in
            self?.presentClipEditor(tempURL: tempURL)
        }
    }

    private func presentClipEditor(tempURL: URL) {
        // Show the clip editor (preview, trim, append) before saving, mirroring
        // ZoomIt on Windows. The editor exports an edited MP4, which we then
        // move to the chosen destination. It opens as a normal window with a
        // Dock tile, so the user can switch away and return to it as needed.
        let editor = VideoClipEditorController()
        self.clipEditor = editor
        editor.present(tempURL: tempURL, suggestedName: suggestedFilename(), onSave: { [weak self] editedURL in
            self?.clipEditor = nil
            if editedURL != tempURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
            self?.transition(to: .saving)
            self?.savePanel(for: editedURL)
        }, onCancel: { [weak self] in
            self?.clipEditor = nil
            self?.isFinalizingRecording = false
            self?.transition(to: .idle)
            try? FileManager.default.removeItem(at: tempURL)
        })
    }

    private func savePanel(for tempURL: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        while true {
            guard panel.runModal() == .OK, let destination = panel.url else {
                try? FileManager.default.removeItem(at: tempURL)
                break
            }
            do {
                if destination != tempURL {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                }
                break
            } catch {
                let alert = NSAlert(error: error)
                alert.addButton(withTitle: "Choose Another Location")
                alert.addButton(withTitle: "Discard Recording")
                if alert.runModal() == .alertSecondButtonReturn {
                    try? FileManager.default.removeItem(at: tempURL)
                    break
                }
            }
        }
        isFinalizingRecording = false
        transition(to: .idle)
    }

    private func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "ZoomIt \(formatter.string(from: Date())).mp4"
    }

    /// Opens an existing video file in the clip editor (trim, append, save),
    /// mirroring ZoomIt's standalone "Trim" workflow. The edited result is
    /// exported and the user picks where to save it.
    func openForTrim() {
        let open = NSOpenPanel()
        open.title = "Trim Video"
        open.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        open.canChooseDirectories = false
        open.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard open.runModal() == .OK, let url = open.url else { return }
        let editor = VideoClipEditorController()
        self.clipEditor = editor
        editor.present(tempURL: url, suggestedName: suggestedFilename(), onSave: { [weak self] editedURL in
            self?.clipEditor = nil
            self?.saveTrimmedClip(editedURL: editedURL, originalURL: url)
        }, onCancel: { [weak self] in
            self?.clipEditor = nil
        })
    }

    /// Action for saving a clip opened from an existing file (the Trim
    /// workflow). If the editor exported a new temp file, that temp is moved
    /// into place; if it returned the user's own original (no edits), the
    /// original is copied so it is preserved — matching Windows ZoomIt, which
    /// never deletes the source file.
    enum TrimSaveAction: Equatable { case move, copy }

    static func trimSaveAction(editedURL: URL, originalURL: URL) -> TrimSaveAction {
        editedURL == originalURL ? .copy : .move
    }

    /// Saves a clip that was opened from an existing file, always preserving the
    /// user's original source file.
    private func saveTrimmedClip(editedURL: URL, originalURL: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)

        let action = Self.trimSaveAction(editedURL: editedURL, originalURL: originalURL)
        if panel.runModal() == .OK, let destination = panel.url {
            if destination != originalURL {
                try? FileManager.default.removeItem(at: destination)
            }
            do {
                switch action {
                case .move:
                    // Move the exported temp file into place; original untouched.
                    if destination != editedURL {
                        try FileManager.default.moveItem(at: editedURL, to: destination)
                    }
                case .copy:
                    // No edits: copy the user's original, preserving the source.
                    if destination != editedURL {
                        try FileManager.default.copyItem(at: editedURL, to: destination)
                    }
                }
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        } else if action == .move {
            // Discard the temp export; never delete the user's original file.
            try? FileManager.default.removeItem(at: editedURL)
        }
    }

    private func selectRegion(on display: DisplayDescriptor, completion: @escaping (CGRect?) -> Void) {
        Task { @MainActor in
            do {
                let frame = try await captureService.captureDisplay(display)
                let window = SnipWindow(
                    contentRect: frame.display.frame,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                window.level = .screenSaver
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                window.backgroundColor = .clear
                window.isOpaque = false
                window.isReleasedWhenClosed = false

                let view = SnipSelectionView(
                    frame: CGRect(origin: .zero, size: frame.display.frame.size),
                    image: frame.image
                )
                var holder: NSWindow? = window
                var cursorLease: CrosshairCursorLease?
                view.onComplete = { rect in
                    cursorLease?.invalidate()
                    cursorLease = nil
                    holder?.orderOut(nil)
                    holder = nil
                    completion(rect)
                }
                window.contentView = view
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                window.makeFirstResponder(view)
                cursorLease = CrosshairCursorLease(window: window)
                cursorLease?.activate()
            } catch {
                completion(nil)
            }
        }
    }

    private func cleanup() {
        frameTimer?.invalidate()
        frameTimer = nil
        pickerController?.finish()
        pickerController = nil
        clearIsolatedSource()
        captureSession?.stopRunning()
        captureSession = nil
        micOutput = nil
        stream = nil
        streamOutput = nil
        engine = nil
        recordingDisplay = nil
        recordingSourceRect = nil
        isFinalizingRecording = false
        isStartingRecording = false
        isStoppingRecording = false
        hideBorder()
        webcam.stop()
        isRecording = false
    }

    private func presentError(_ error: Error) {
        onWillPresentRecordingResult?()
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
