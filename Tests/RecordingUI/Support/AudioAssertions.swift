import AVFoundation
import XCTest

enum RecordedAudioAssertions {
    static func requireSelectedAppTones(in url: URL, test: XCTestCase) throws {
        let asset = AVURLAsset(url: url)
        let tracks = asset.tracks(withMediaType: .audio)
        guard tracks.count == 1, let track = tracks.first else {
            throw HarnessError("Expected exactly one selected-app audio track with microphone disabled, got \(tracks.count)")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw HarnessError("Cannot decode selected-app audio") }
        reader.add(output)
        guard reader.startReading() else { throw HarnessError("Audio decoder failed to start") }
        var mono: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw HarnessError("Decoded audio has no PCM block") }
            let length = CMBlockBufferGetDataLength(block)
            var data = [UInt8](repeating: 0, count: length)
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == noErr else { throw HarnessError("Cannot read PCM bytes, status \(status)") }
            data.withUnsafeBytes { bytes in
                for offset in stride(from: 0, to: length - 7, by: 8) {
                    let left = bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)
                    let right = bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
                    mono.append(Double(left + right) / 2)
                }
            }
        }
        guard reader.status == .completed, mono.count > 24_000 else { throw HarnessError("Expected at least half a second of decoded selected-app tones; samples=\(mono.count), error=\(String(describing: reader.error))") }
        let frequencies = [440.0, 660.0, 880.0]
        let amplitudes = frequencies.map { frequency in amplitude(samples: mono, frequency: frequency) }
        let report = XCTAttachment(string: "Decoded audio \(mono.count) samples @48000Hz; tone amplitude 440=\(amplitudes[0]), 660=\(amplitudes[1]), forbidden880=\(amplitudes[2])")
        report.name = url.deletingPathExtension().lastPathComponent + "-audio-spectrum"; report.lifetime = .keepAlways; test.add(report)
        guard amplitudes[0] > 0.025, amplitudes[1] > 0.015 else { throw HarnessError("Selected app's 440/660-Hz tones are absent: \(amplitudes)") }
        guard amplitudes[2] < max(0.003, min(amplitudes[0], amplitudes[1]) * 0.1) else {
            throw HarnessError("Forbidden app B's 880-Hz tone leaked into selected-app audio: \(amplitudes)")
        }
    }
    private static func amplitude(samples: [Double], frequency: Double) -> Double {
        let length = 8192
        var maximum = 0.0
        // A Hann window separates nearby components and codec padding. Compare
        // maximum energy per tone so a phase change cannot hide forbidden audio.
        for start in stride(from: 0, through: samples.count - length, by: length) {
            var real = 0.0, imaginary = 0.0
            for index in 0..<length {
                let weight = 0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(length - 1))
                let phase = 2 * .pi * frequency * Double(index) / 48_000
                real += samples[start + index] * weight * cos(phase)
                imaginary += samples[start + index] * weight * sin(phase)
            }
            maximum = max(maximum, 4 * hypot(real, imaginary) / Double(length))
        }
        return maximum
    }
    static func requireNoAudio(in url: URL) throws {
        guard AVURLAsset(url: url).tracks(withMediaType: .audio).isEmpty else { throw HarnessError("Audio-disabled recording exported an audio track") }
    }
}
