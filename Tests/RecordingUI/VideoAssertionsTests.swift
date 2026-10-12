import AVFoundation
import XCTest

/// Exercises export assertions without launching the recorder or Apple's picker.
final class VideoAssertionsTests: XCTestCase {
    func testSingleFramePrivacyLeakBetweenFormerSamplesIsDetected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let leakedURL = directory.appendingPathComponent("single-frame-leak.mp4")
        try await writeMovie(to: leakedURL, forbiddenFrame: 1)
        let leaked = try RecordedVideo(url: leakedURL)
        XCTAssertEqual(leaked.frames.count, 30, "Every encoded frame must participate in privacy and lifecycle checks.")
        let forbidden = try XCTUnwrap(leaked.frames.first { $0.fractions["forbidden", default: 0] > 0.9 })
        XCTAssertEqual(forbidden.time, 1.0 / 30.0, accuracy: 0.001)
        XCTAssertThrowsError(try leaked.exclude(["forbidden"])) { error in
            XCTAssertTrue(String(describing: error).contains("Export leaked forbidden"))
        }

        let cleanURL = directory.appendingPathComponent("clean.mp4")
        try await writeMovie(to: cleanURL, forbiddenFrame: nil)
        let clean = try RecordedVideo(url: cleanURL)
        XCTAssertEqual(clean.frames.count, 30)
        XCTAssertNoThrow(try clean.exclude(["forbidden"]))
        XCTAssertNoThrow(try clean.requireBlankTail(atLeast: 0.5))
    }

    func testBlankTailRejectsOneNonblankFrameBetweenFormerSamples() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        // Frame 19 (0.633s) was skipped by the old 0.15-second sampling loop,
        // and is outside its final-0.2-second exception.
        try await writeMovie(to: url, forbiddenFrame: 19)
        let video = try RecordedVideo(url: url)
        XCTAssertThrowsError(try video.requireBlankTail(atLeast: 0.5))
    }

    private func writeMovie(to url: URL, forbiddenFrame: Int?) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64
        ])
        guard writer.canAdd(input) else { throw HarnessError("Test writer cannot add its video input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? HarnessError("Test writer failed to start") }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<30 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else {
                    throw writer.error ?? HarnessError("Test writer stalled")
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var optionalBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &optionalBuffer)
            guard status == kCVReturnSuccess, let buffer = optionalBuffer else { throw HarnessError("Test pixel allocation failed") }
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw HarnessError("Test pixel storage unavailable") }
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<64 {
                for x in 0..<64 {
                    let offset = y * rowBytes + x * 4
                    pixels[offset] = index == forbiddenFrame ? 255 : 0
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = index == forbiddenFrame ? 255 : 0
                    pixels[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                throw writer.error ?? HarnessError("Test frame append failed")
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 30, timescale: 30))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? HarnessError("Test movie did not finalize") }
    }
}
