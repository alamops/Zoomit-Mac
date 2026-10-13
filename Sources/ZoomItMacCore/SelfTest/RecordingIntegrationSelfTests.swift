import AppKit
import AVFoundation

@MainActor
enum RecordingIntegrationSelfTests {
    static func run() throws {
        try sourceRetentionAndVisibility()
        try terminalAndGenerationIsolation()
        let green = try RecordingSelfTests.pixelImage(width: 64, height: 48) { _, _ in (0, 255, 0) }
        let black = try RecordingSelfTests.pixelImage(width: 64, height: 48) { _, _ in (0, 0, 0) }
        // SelfTestRunner is synchronous. The writer/decoder runs off the main
        // actor; waiting here never blocks its queue or a capture callback.
        let outcome = WriterOutcome()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await writeAndDecode(green: green, black: black, noFirstSourceFrame: false)
                try await writeAndDecode(green: green, black: black, noFirstSourceFrame: true)
                try await cancellationRemovesTemporaryMovie()
                try await finalFrameWaitsForReadiness(green: green, black: black)
                try await finalFrameTimeoutFailsWithoutFallback(green: green, black: black)
                try await missingFinalFrameFailsWithoutFallback(green: green)
                try await cancellationInterruptsFinalFrameWait(green: green, black: black)
                outcome.store(.success(()))
            } catch { outcome.store(.failure(error)) }
            done.signal()
        }
        guard done.wait(timeout: .now() + 30) == .success else {
            throw SelfTestError.failure("Recording writer integration timed out")
        }
        try outcome.result().get()
    }

    private static func sourceRetentionAndVisibility() throws {
        let image = try RecordingSelfTests.pixelImage(width: 8, height: 8) { _, _ in (0, 255, 0) }
        let session = RecordingSourceSession(generation: 7, audioSink: { _ in })
        session.consume(.complete, image: image, presentationTime: CMTime(value: 10, timescale: 1))
        let complete = session.snapshot()
        try require(complete.frame.availability == .available && complete.frame.image != nil, "complete authorized source published")
        session.consume(.idle, presentationTime: CMTime(value: 11, timescale: 1))
        try require(session.snapshot().revision == complete.revision && session.snapshot().frame.image === complete.frame.image,
                    "stationary idle must retain last authorized image without a new revision")
        session.setTargetVisible(false)
        session.consume(.complete, image: image)
        try require(session.snapshot().frame.image == nil && session.snapshot().frame.availability == .unavailable,
                    "late complete cannot override minimized-window visibility")
        session.setApplicationHidden(true)
        session.setTargetVisible(true)
        session.consume(.complete, image: image)
        try require(session.snapshot().frame.image == nil, "restoring a window cannot override hidden-app latch")
        session.setApplicationHidden(false)
        try require(session.snapshot().frame.image == nil, "visibility alone must not resurrect old pixels")
        session.consume(.complete, image: image)
        try require(session.snapshot().frame.availability == .available, "new authorized frame restores source")
        session.consume(.blank)
        session.consume(.idle)
        try require(session.snapshot().frame.image == nil, "blank followed by idle must remain black")
        session.consume(.complete)
        try require(session.snapshot().frame.availability == .unavailable, "nil complete must never create available content")
        session.consume(.complete, image: image)
        session.setApplicationHidden(true)
        session.setTargetVisible(false)
        session.setApplicationHidden(false)
        session.consume(.complete, image: image)
        try require(session.snapshot().frame.image == nil, "unhiding app cannot override minimized-window latch")
    }

    private static func terminalAndGenerationIsolation() throws {
        let image = try RecordingSelfTests.pixelImage(width: 8, height: 8) { _, _ in (255, 0, 0) }
        let session = RecordingSourceSession(generation: 9, audioSink: { _ in })
        session.consume(.complete, image: image)
        session.end(error: NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "sharing withdrawn"]))
        let ended = session.snapshot()
        session.setApplicationHidden(false)
        session.setTargetVisible(true)
        session.consume(.complete, image: image)
        try require(session.snapshot().revision == ended.revision && session.snapshot().frame.availability == .ended,
                    "terminal source rejects all late updates and cannot retarget")
        try require(session.snapshot().errorDescription == "sharing withdrawn", "source-loss explanation retained")
        let geometry = try RecordingSelfTests.canvas(8, 8)
        let frozen = RecordingOverlaySnapshot(generation: 9, viewport: geometry.logicalBounds, frozenImage: image)
        guard let final = RecordingFrameRenderer.render(source: session.snapshot().frame, overlay: frozen, geometry: geometry, generation: 9) else {
            throw SelfTestError.failure("Recording final black render failed")
        }
        try require(try RecordingSelfTests.rgb(final, x: 4, y: 4) == [0, 0, 0], "finalization cannot resurrect frozen target")
        let next = RecordingSourceSession(generation: 10, audioSink: { _ in })
        next.consume(.complete, image: image)
        session.invalidate()
        session.consume(.complete, image: image)
        try require(next.snapshot().frame.generation == 10 && next.snapshot().frame.availability == .available,
                    "new session is independent from invalidated prior source")
    }

    nonisolated private static func writeAndDecode(green: CGImage, black: CGImage, noFirstSourceFrame: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-selftest-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RecordingEngine(url: url, width: 64, height: 48, systemAudio: false, microphone: false, permitsFallback: false)
        try await engine.startWriting()
        for index in 0..<30 {
            let image = !noFirstSourceFrame && index < 10 ? green : black
            let accepted = engine.appendVideoImageBounded(RecordingImageFrame(image: image, presentationTime: CMTime(value: Int64(300 + index), timescale: 30), duration: CMTime(value: 1, timescale: 30)))
            guard accepted else { throw SelfTestError.failure("Writer dropped fixture composition despite drained queue") }
            await engine.waitForQueuedAppends()
            try await Task.sleep(nanoseconds: 34_000_000)
        }
        engine.appendVideoImageAtEnd(RecordingImageFrame(image: black, presentationTime: CMTime(value: 330, timescale: 30), duration: CMTime(value: 1, timescale: 30)))
        await engine.waitForQueuedAppends()
        let finished: URL? = await withCheckedContinuation { continuation in engine.finish { continuation.resume(returning: $0) } }
        guard finished == url else { throw SelfTestError.failure("Real MP4 finalization returned no movie") }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0.95 && duration < 1.15 else { throw SelfTestError.failure("Black tail failed to advance movie duration: \(duration)") }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SelfTestError.failure("Writer produced no video track") }
        let size = try await track.load(.naturalSize)
        guard size == CGSize(width: 64, height: 48) else { throw SelfTestError.failure("Writer changed fixed dimensions: \(size)") }
        guard let description = try await track.load(.formatDescriptions).first else {
            throw SelfTestError.failure("Written MP4 lacks a video format description")
        }
        for (key, expected) in [(kCMFormatDescriptionExtension_ColorPrimaries, AVVideoColorPrimaries_ITU_R_709_2),
                                (kCMFormatDescriptionExtension_TransferFunction, AVVideoTransferFunction_ITU_R_709_2),
                                (kCMFormatDescriptionExtension_YCbCrMatrix, AVVideoYCbCrMatrix_ITU_R_709_2)] {
            guard CMFormatDescriptionGetExtension(description, extensionKey: key) as? String == expected else {
                throw SelfTestError.failure("Written MP4 has missing or inconsistent color metadata: \(key)")
            }
        }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard audio.isEmpty else { throw SelfTestError.failure("Disabled system/mic audio unexpectedly produced a track") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let first = try generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
        let tail = try generator.copyCGImage(at: CMTime(seconds: 0.8, preferredTimescale: 600), actualTime: nil)
        guard try average(tail).allSatisfy({ $0 < 12 }) else { throw SelfTestError.failure("Writer black tail contains old target pixels") }
        if noFirstSourceFrame {
            guard try average(first).allSatisfy({ $0 < 12 }) else { throw SelfTestError.failure("No-first-source-frame clip exposed fallback imagery") }
        } else {
            let color = try average(first)
            guard color[1] > 220 && color[0] < 20 && color[2] < 20 else { throw SelfTestError.failure("Writer did not encode the actual authorized image: \(color)") }
        }
    }

    nonisolated private static func cancellationRemovesTemporaryMovie() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-cancel-selftest-\(UUID().uuidString).mp4")
        let engine = try RecordingEngine(url: url, width: 64, height: 48, systemAudio: false, microphone: false, permitsFallback: false)
        try await engine.startWriting()
        engine.appendBlackVideoFrameIfNeeded(presentationTime: .zero)
        await engine.waitForQueuedAppends()
        await engine.cancel()
        guard !FileManager.default.fileExists(atPath: url.path) else { throw SelfTestError.failure("Cancelled writer leaked temporary movie") }
    }

    nonisolated private static func seedGreenVideo(_ engine: RecordingEngine, image: CGImage) async throws {
        try await engine.startWriting()
        for index in 0..<3 {
            engine.appendVideoImageBounded(RecordingImageFrame(image: image,
                presentationTime: CMTime(value: Int64(300 + index), timescale: 30), duration: CMTime(value: 1, timescale: 30)))
            await engine.waitForQueuedAppends()
            try await Task.sleep(nanoseconds: 34_000_000)
        }
    }

    nonisolated private static func finish(_ engine: RecordingEngine) async -> URL? {
        await withCheckedContinuation { continuation in engine.finish { continuation.resume(returning: $0) } }
    }

    nonisolated private static func finalFrameWaitsForReadiness(green: CGImage, black: CGImage) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("final-ready-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = FinalFrameProbe(readyOnAttempt: 4)
        let engine = try RecordingEngine(url: url, width: 64, height: 48, systemAudio: true, microphone: true,
            permitsFallback: false, onFailure: { probe.record($0) }, finalFrameTimeout: 1,
            finalFrameReadiness: { probe.isReady() })
        try await seedGreenVideo(engine, image: green)
        engine.appendVideoImageAtEnd(RecordingImageFrame(image: black,
            presentationTime: CMTime(value: 306, timescale: 30), duration: CMTime(value: 1, timescale: 30)))
        guard await finish(engine) == url, probe.snapshot().attempts >= 4, probe.snapshot().failures == 0 else {
            throw SelfTestError.failure("Required final frame did not survive temporary writer backpressure")
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let first = try generator.copyCGImage(at: CMTime(value: 1, timescale: 30), actualTime: nil)
        let last = try generator.copyCGImage(at: CMTime(value: 6, timescale: 30), actualTime: nil)
        guard try average(first)[1] > 220, try average(last).allSatisfy({ $0 < 12 }) else {
            throw SelfTestError.failure("Finalized MP4 must replace the last authorized green image with the required black Stop frame")
        }
    }

    nonisolated private static func finalFrameTimeoutFailsWithoutFallback(green: CGImage, black: CGImage) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("final-timeout-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = FinalFrameProbe(readyOnAttempt: nil)
        let engine = try RecordingEngine(url: url, width: 64, height: 48, systemAudio: false, microphone: false,
            permitsFallback: true, onFailure: { probe.record($0) }, finalFrameTimeout: 0.05,
            finalFrameReadiness: { probe.isReady() })
        try await seedGreenVideo(engine, image: green)
        engine.appendVideoImageAtEnd(RecordingImageFrame(image: black, presentationTime: CMTime(value: 306, timescale: 30)))
        let start = ProcessInfo.processInfo.systemUptime
        let result = await finish(engine)
        let evidence = probe.snapshot()
        guard result == nil, evidence.failures == 1, evidence.timedOut, evidence.attempts > 0,
              ProcessInfo.processInfo.systemUptime - start < 1,
              !FileManager.default.fileExists(atPath: url.path) else {
            throw SelfTestError.failure("Final-frame timeout must fail once, remain bounded, remove the partial clip, and never substitute a fallback movie")
        }
    }

    nonisolated private static func cancellationInterruptsFinalFrameWait(green: CGImage, black: CGImage) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("final-cancel-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = FinalFrameProbe(readyOnAttempt: nil)
        let engine = try RecordingEngine(url: url, width: 64, height: 48, systemAudio: false, microphone: false,
            permitsFallback: false, onFailure: { probe.record($0) }, finalFrameTimeout: 1,
            finalFrameReadiness: { probe.isReady() })
        try await seedGreenVideo(engine, image: green)
        engine.appendVideoImageAtEnd(RecordingImageFrame(image: black, presentationTime: CMTime(value: 306, timescale: 30)))
        let finishing = Task { await finish(engine) }
        for _ in 0..<50 {
            if probe.snapshot().attempts > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await engine.cancel()
        let result = await finishing.value
        guard result == nil, probe.snapshot().attempts > 0, probe.snapshot().failures == 0,
              !FileManager.default.fileExists(atPath: url.path) else {
            throw SelfTestError.failure("Cancellation must interrupt the final-frame wait without a successful clip or spurious writer error")
        }
    }

    nonisolated private static func missingFinalFrameFailsWithoutFallback(green: CGImage) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("final-missing-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = FinalFrameProbe(readyOnAttempt: nil)
        let engine = try RecordingEngine(url: url, width: 64, height: 48, systemAudio: false, microphone: false,
            permitsFallback: true, onFailure: { probe.record($0) })
        try await seedGreenVideo(engine, image: green)
        engine.appendVideoImageAtEnd(nil)
        guard await finish(engine) == nil, probe.snapshot().failures == 1,
              !FileManager.default.fileExists(atPath: url.path) else {
            throw SelfTestError.failure("A missing required final image must not export old imagery or a fallback movie")
        }
    }

    nonisolated private static func average(_ image: CGImage) throws -> [Double] {
        var pixels = [UInt8](repeating: 0, count: 64 * 48 * 4)
        try pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: 64, height: 48, bitsPerComponent: 8,
                                          bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SelfTestError.failure("MP4 decode context failed") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        return (0..<3).map { channel in stride(from: channel, to: pixels.count, by: 4).reduce(0.0) { $0 + Double(pixels[$1]) } / (64 * 48) }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw SelfTestError.failure("Recording integration: \(message)") }
    }
}

private final class FinalFrameProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let readyOnAttempt: Int?
    private var attempts = 0
    private var failures = 0
    private var timedOut = false
    init(readyOnAttempt: Int?) { self.readyOnAttempt = readyOnAttempt }
    func isReady() -> Bool {
        lock.lock(); defer { lock.unlock() }
        attempts += 1
        return readyOnAttempt.map { attempts >= $0 } ?? false
    }
    func record(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        failures += 1
        if let error = error as? RecordingEngine.FinalFrameError, case .readinessTimedOut = error { timedOut = true }
    }
    func snapshot() -> (attempts: Int, failures: Int, timedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (attempts, failures, timedOut)
    }
}

private final class WriterOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Void, Error>?
    func store(_ result: Result<Void, Error>) { lock.lock(); defer { lock.unlock() }; value = result }
    func result() -> Result<Void, Error> {
        lock.lock(); defer { lock.unlock() }
        return value ?? .failure(SelfTestError.failure("Writer did not publish a result"))
    }
}
