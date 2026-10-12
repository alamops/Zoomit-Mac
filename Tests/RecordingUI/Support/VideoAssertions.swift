import AppKit
import AVFoundation
import XCTest

/// Decodes the saved MP4, rather than inspecting the host desktop or preview.
struct RecordedVideo {
    struct Frame {
        let time: Double
        let width: Int
        let height: Int
        let fractions: [String: Double]
    }
    let url: URL
    let duration: Double
    let size: CGSize
    let frames: [Frame]

    init(url: URL) throws {
        self.url = url
        let asset = AVURLAsset(url: url)
        duration = asset.duration.seconds
        guard duration.isFinite, duration > 0,
              let track = asset.tracks(withMediaType: .video).first else { throw HarnessError("Exported MP4 has no finite video: \(url.path)") }
        size = track.naturalSize
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw HarnessError("Cannot decode MP4 video") }
        reader.add(output)
        guard reader.startReading() else { throw HarnessError("Video reader startup failed: \(String(describing: reader.error))") }
        var decoded: [Frame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = sample.imageBuffer else { throw HarnessError("Decoded video sample has no image") }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            guard width == Int(size.width), height == Int(size.height) else { throw HarnessError("MP4 frame changed canvas from \(size) to \(width)x\(height)") }
            // Privacy and lifecycle assertions must see every frame, including brief
            // leaks between otherwise clean samples. Only diagnostics are sampled.
            let frame = Frame(time: time, width: width, height: height, fractions: try Self.measure(buffer))
            decoded.append(frame)
        }
        guard reader.status == .completed, !decoded.isEmpty else {
            throw HarnessError("MP4 decoding incomplete: status \(reader.status.rawValue), error \(String(describing: reader.error))")
        }
        frames = decoded
    }

    private static func measure(_ buffer: CVPixelBuffer) throws -> [String: Double] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let storage = CVPixelBufferGetBaseAddress(buffer) else { throw HarnessError("Decoded pixel storage unavailable") }
        let pixels = storage.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var counts: [String: Int] = [:]
        var total = 0
        let stridePixels = max(1, min(width, height) / 160)
        for y in stride(from: 0, to: height, by: stridePixels) {
            for x in stride(from: 0, to: width, by: stridePixels) {
                let offset = y * rowBytes + x * 4
                let b = Int(pixels[offset]), g = Int(pixels[offset + 1]), r = Int(pixels[offset + 2])
                total += 1
                if r < 70 && g > 150 && b < 110 { counts["primary", default: 0] += 1 }
                if r < 80 && g > 150 && b > 150 { counts["second", default: 0] += 1 }
                if r > 180 && (90...190).contains(g) && b < 80 { counts["dialog", default: 0] += 1 }
                if r > 150 && g < 100 && b > 150 { counts["forbidden", default: 0] += 1 }
                if r < 18 && g < 18 && b < 18 { counts["black", default: 0] += 1 }
                if r > 175 && g < 110 && b < 110 { counts["red", default: 0] += 1 }
                if r > 170 && g > 140 && b < 120 { counts["yellow", default: 0] += 1 }
                if (70...170).contains(r) && g > 140 && b < 120 { counts["highlight", default: 0] += 1 }
                if r > 225 && g > 225 && b > 225 { counts["white", default: 0] += 1 }
            }
        }
        return ["primary", "second", "dialog", "forbidden", "black", "red", "yellow", "highlight", "white"].reduce(into: [:]) {
            $0[$1] = Double(counts[$1, default: 0]) / Double(total)
        }
    }

    func requireMarker(_ marker: String, above minimum: Double, in interval: ClosedRange<Double>? = nil) throws {
        guard frames.contains(where: { (interval?.contains($0.time) ?? true) && $0.fractions[marker, default: 0] > minimum }) else {
            throw HarnessError("Export lacks \(marker) > \(minimum), interval \(String(describing: interval)). \(summary)")
        }
    }
    func exclude(_ markers: [String], tolerance: Double = 0.002) throws {
        for frame in frames {
            for marker in markers where frame.fractions[marker, default: 0] > tolerance {
                throw HarnessError("Export leaked \(marker) at \(frame.time)s: \(frame.fractions). \(url.path)")
            }
        }
    }
    func requireBlankTail(atLeast seconds: Double) throws {
        let tail = frames.filter { $0.time >= duration - seconds }
        guard tail.count >= 3,
              tail.last!.time - tail.first!.time >= seconds - 0.25,
              tail.allSatisfy({ $0.fractions["black", default: 0] > 0.98 }) else {
            throw HarnessError("Blank target did not continue on advancing video timeline for \(seconds)s. \(summary)")
        }
    }
    func requireBlackPadding(in interval: ClosedRange<Double>) throws {
        guard frames.contains(where: { interval.contains($0.time) && $0.fractions["black", default: 0] > 0.15 && $0.fractions["primary", default: 0] > 0.25 }) else {
            throw HarnessError("Resized source was not aspect-fitted with visible black padding. \(summary)")
        }
    }
    var summary: String {
        // Keep attachments readable without weakening the all-frame checks above.
        let limit = 24
        let indices = frames.count <= limit ? Array(frames.indices) : (0..<limit).map {
            $0 * (frames.count - 1) / (limit - 1)
        }
        let samples = indices.map { ["time": frames[$0].time, "markers": frames[$0].fractions] as [String: Any] }
        return "\(Int(size.width))x\(Int(size.height)), duration=\(duration), decodedFrames=\(frames.count), diagnosticSamples=\(samples)"
    }
    func attach(to test: XCTestCase) {
        let report = XCTAttachment(string: summary)
        report.name = url.deletingPathExtension().lastPathComponent + "-decoded-video"; report.lifetime = .keepAlways; test.add(report)
        let movie = XCTAttachment(contentsOfFile: url)
        movie.name = url.lastPathComponent; movie.lifetime = .keepAlways; test.add(movie)
    }
}
