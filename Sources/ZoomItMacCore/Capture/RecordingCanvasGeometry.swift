import CoreGraphics

struct RecordingCanvasGeometry: Equatable, Sendable {
    enum ValidationError: Error { case invalidSize, invalidScale, invalidHostFrame }

    let logicalSize: CGSize
    let pixelScale: CGFloat
    let outputWidth: Int
    let outputHeight: Int
    /// AppKit global coordinates (bottom-left origin); logical/view coordinates
    /// are top-left. Presentation is aspect fitted to this host display.
    let hostDisplayFrame: CGRect

    init(logicalSize: CGSize, pixelScale: CGFloat, hostDisplayFrame: CGRect) throws {
        guard Self.isValid(logicalSize), logicalSize.width * pixelScale <= 16_384,
              logicalSize.height * pixelScale <= 16_384 else { throw ValidationError.invalidSize }
        guard pixelScale.isFinite, pixelScale > 0 else { throw ValidationError.invalidScale }
        guard Self.isValid(hostDisplayFrame.size), hostDisplayFrame.origin.x.isFinite,
              hostDisplayFrame.origin.y.isFinite else { throw ValidationError.invalidHostFrame }
        self.logicalSize = logicalSize
        self.pixelScale = pixelScale
        self.hostDisplayFrame = hostDisplayFrame
        outputWidth = max(2, Int(ceil(logicalSize.width * pixelScale / 2)) * 2)
        outputHeight = max(2, Int(ceil(logicalSize.height * pixelScale / 2)) * 2)
    }

    var logicalBounds: CGRect { CGRect(origin: .zero, size: logicalSize) }
    var outputBounds: CGRect { CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight) }
    var presentationBounds: CGRect { CGRect(origin: .zero, size: hostDisplayFrame.size) }
    var presentationContentRect: CGRect { Self.aspectFitRect(for: logicalSize, in: presentationBounds) }

    static func aspectFitRect(for sourceSize: CGSize, in bounds: CGRect) -> CGRect {
        guard isValid(sourceSize), isValid(bounds.size) else { return .zero }
        let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func transform(from source: CGRect, to destination: CGRect) -> CGAffineTransform {
        guard isValid(source.size), isValid(destination.size) else { return .identity }
        let sx = destination.width / source.width
        let sy = destination.height / source.height
        return CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                                 tx: destination.minX - source.minX * sx,
                                 ty: destination.minY - source.minY * sy)
    }

    /// Current target footprint in the stable canvas (after a resize). Hosts
    /// can use it to reject drawing on target padding while retaining stable
    /// annotation coordinates.
    func sourceContentRect(forImageSize size: CGSize) -> CGRect {
        Self.aspectFitRect(for: size, in: logicalBounds)
    }

    func contentToViewTransform(viewBounds: CGRect, viewport: CGRect? = nil) -> CGAffineTransform {
        Self.transform(from: viewport ?? logicalBounds,
                       to: Self.aspectFitRect(for: logicalSize, in: viewBounds))
    }

    func contentPoint(forViewPoint point: CGPoint, viewBounds: CGRect, viewport: CGRect? = nil, activeContentRect: CGRect? = nil) -> CGPoint? {
        let rect = Self.aspectFitRect(for: logicalSize, in: viewBounds)
        guard rect.contains(point) else { return nil }
        let mapped = point.applying(contentToViewTransform(viewBounds: viewBounds, viewport: viewport).inverted())
        return logicalBounds.contains(mapped) && (activeContentRect?.contains(mapped) ?? true) ? mapped : nil
    }

    func viewPoint(forContentPoint point: CGPoint, viewBounds: CGRect, viewport: CGRect? = nil) -> CGPoint {
        point.applying(contentToViewTransform(viewBounds: viewBounds, viewport: viewport))
    }

    func viewPoint(forGlobalPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - hostDisplayFrame.minX, y: hostDisplayFrame.maxY - point.y)
    }

    func globalPoint(forViewPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + hostDisplayFrame.minX, y: hostDisplayFrame.maxY - point.y)
    }

    func contentPoint(forGlobalPoint point: CGPoint, viewport: CGRect? = nil) -> CGPoint? {
        contentPoint(forViewPoint: viewPoint(forGlobalPoint: point), viewBounds: presentationBounds, viewport: viewport)
    }

    /// Converts a bottom-left global webcam frame to top-left normalized video
    /// coordinates. Output composition applies this after source zoom.
    func normalizedOutputRect(forGlobalRect rect: CGRect) -> CGRect {
        let fit = presentationContentRect
        return CGRect(x: (rect.minX - hostDisplayFrame.minX - fit.minX) / fit.width,
                      y: (hostDisplayFrame.maxY - rect.maxY - fit.minY) / fit.height,
                      width: rect.width / fit.width, height: rect.height / fit.height)
    }

    private static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
