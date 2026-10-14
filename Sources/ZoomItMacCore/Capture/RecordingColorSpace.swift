import AVFoundation
import CoreGraphics
import CoreVideo
import ScreenCaptureKit

/// Generated recording frames have one explicit SDR color contract. Native
/// capture buffers retain their own tags; AVAssetWriter converts tagged inputs
/// to the isolated recording's Rec. 709 output.
enum RecordingColorSpace {
    enum ConfigurationError: LocalizedError {
        case windowIsolationUnavailable
        var errorDescription: String? {
            "Recording one window without its child dialogs requires macOS 14.2 or later."
        }
    }
    static let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func makeCaptureConfiguration(for scope: RecordingScope) throws -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        if #available(macOS 14.2, *) {
            // The native default also captures attached dialogs. Window mode
            // promises one window; application mode intentionally includes them.
            configuration.includeChildWindows = scope != .window
        } else if scope == .window {
            // Older systems cannot enforce the single-window privacy contract.
            throw ConfigurationError.windowIsolationUnavailable
        }
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // ScreenCaptureKit otherwise emits the display's color space. Request
        // the same SDR RGB contract used by our renderer and generated frames.
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }

    static var videoProperties: [String: String] {
        [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
         AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
         AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
    }

    static func tag(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, rgb, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
}
