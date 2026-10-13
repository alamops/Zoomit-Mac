import AppKit
import CoreImage
@preconcurrency import ScreenCaptureKit

/// One coalesced, immutable source slot. Capture callbacks never enqueue UI
/// renders; the recorder pulls this slot at its independent video cadence.
final class RecordingSourceSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Snapshot: @unchecked Sendable {
        let frame: RecordingSourceFrame
        let revision: UInt64
        let errorDescription: String?
    }
    private let lock = NSLock()
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let generation: UInt64
    private var policy = RecordingSourcePolicy()
    private var image: CGImage?
    private var contentRect: CGRect?
    private var timestamp = CMTime.invalid
    private var revision: UInt64 = 0
    private var errorDescription: String?
    private var acceptingFrames = true
    private var inactive = false
    private var targetHidden = false
    private var applicationHidden = false
    let backgroundColor = CGColor(gray: 0, alpha: 1)
    let queue = DispatchQueue(label: "com.zoomitmac.recording.isolated-source")
    let audioSink: @Sendable (CMSampleBuffer) -> Void

    init(generation: UInt64, audioSink: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.generation = generation
        self.audioSink = audioSink
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(frame: RecordingSourceFrame(image: image, presentationTime: timestamp,
                                                    availability: policy.availability, generation: generation,
                                                    contentRect: contentRect),
                        revision: revision, errorDescription: errorDescription)
    }

    /// Also serves deterministic lifecycle tests without needing native buffers.
    func consume(_ update: RecordingSourcePolicy.Update, image newImage: CGImage? = nil,
                 presentationTime: CMTime = .invalid, contentRect newContentRect: CGRect? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard acceptingFrames, policy.availability != .ended else { return }
        if case .idle = update { return }
        if case .complete = update, inactive || targetHidden || applicationHidden { return }
        if case .complete = update, newImage == nil { policy.consume(.suspended) }
        else { policy.consume(update) }
        image = policy.availability == .available ? newImage : nil
        contentRect = policy.availability == .available ? newContentRect : nil
        timestamp = presentationTime
        revision &+= 1
    }

    func end(error: Error? = nil) {
        lock.lock()
        defer { lock.unlock() }
        policy.consume(.stopped)
        image = nil
        contentRect = nil
        errorDescription = error?.localizedDescription
        revision &+= 1
    }

    /// Independent visibility latches prevent late complete callbacks or the
    /// native active callback from restoring a target still known to be hidden.
    func setTargetVisible(_ visible: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard acceptingFrames, policy.availability != .ended, targetHidden != !visible else { return }
        targetHidden = !visible
        if !visible {
            policy.consume(.suspended)
            image = nil
            contentRect = nil
            revision &+= 1
        }
    }

    func setApplicationHidden(_ hidden: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard acceptingFrames, policy.availability != .ended, applicationHidden != hidden else { return }
        applicationHidden = hidden
        if hidden {
            policy.consume(.suspended)
            image = nil
            contentRect = nil
            revision &+= 1
        }
    }

    func invalidate() {
        lock.lock()
        acceptingFrames = false
        image = nil
        contentRect = nil
        lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            lock.lock()
            let canAppend = acceptingFrames && policy.availability != .ended
            lock.unlock()
            if canAppend, sampleBuffer.isValid { audioSink(sampleBuffer) }
            return
        }
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        switch status {
        case .complete, .started:
            guard sampleBuffer.isValid, let buffer = sampleBuffer.imageBuffer else { return }
            let info = attachments[0]
            let footprint = Self.pixelContentRect(attachments: info,
                pixelSize: CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
            if info[.contentRect] != nil && footprint == nil {
                // Empty/invalid native content must invalidate frozen imagery.
                consume(.blank, presentationTime: time)
                return
            }
            // Copy out of IOSurface-backed capture storage before publishing.
            // createCGImage alone can retain a recyclable CVPixelBuffer surface.
            let source = CIImage(cvPixelBuffer: buffer)
            guard let rendered = context.createCGImage(source, from: source.extent),
                  let copy = CGContext(data: nil, width: rendered.width, height: rendered.height,
                                       bitsPerComponent: 8, bytesPerRow: rendered.width * 4,
                                       space: RecordingColorSpace.rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            copy.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
            guard let owned = copy.makeImage() else { return }
            consume(.complete, image: owned, presentationTime: time, contentRect: footprint)
        case .idle: consume(.idle, presentationTime: time)
        case .blank: consume(.blank, presentationTime: time)
        case .suspended: consume(.suspended, presentationTime: time)
        case .stopped: consume(.stopped, presentationTime: time)
        @unknown default: consume(.suspended, presentationTime: time)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { end(error: error) }

    /// contentRect is the already-scaled content footprint in surface points.
    /// scaleFactor converts surface points to pixels; contentScale describes the
    /// earlier original-content-to-surface resize and must not be applied again.
    static func pixelContentRect(attachments: [SCStreamFrameInfo: Any], pixelSize: CGSize) -> CGRect? {
        let rect: CGRect?
        if let value = attachments[.contentRect] as? CGRect { rect = value }
        else if let value = attachments[.contentRect] as? NSValue { rect = value.rectValue }
        else if let value = attachments[.contentRect] as? [String: Any] {
            rect = CGRect(dictionaryRepresentation: value as CFDictionary)
        } else { rect = nil }
        guard let rect, rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite, !rect.isEmpty, !rect.isNull else { return nil }
        let factor: CGFloat
        if let value = attachments[.scaleFactor] {
            guard let number = value as? NSNumber else { return nil }
            factor = CGFloat(number.doubleValue)
        } else { factor = 1 }
        guard factor.isFinite, factor > 0, pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let pixels = rect.applying(CGAffineTransform(scaleX: factor, y: factor))
            .intersection(CGRect(origin: .zero, size: pixelSize))
        return pixels.isNull || pixels.isEmpty ? nil : pixels
    }

    @available(macOS 15.2, *)
    func streamDidBecomeInactive(_ stream: SCStream) {
        lock.lock()
        inactive = true
        policy.consume(.suspended)
        image = nil
        contentRect = nil
        revision &+= 1
        lock.unlock()
    }

    @available(macOS 15.2, *)
    func streamDidBecomeActive(_ stream: SCStream) {
        lock.lock()
        inactive = false
        lock.unlock()
        // Only a new complete frame can re-establish authorized imagery.
    }
}
