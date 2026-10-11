import AppKit
import CoreMedia

/// Images are immutable CGImage values backed by owned snapshot storage; the
/// producer must not mutate a data provider after publication. Annotation arrays
/// contain only copied value types. No mutable AppKit views cross queue boundaries.
struct RecordingSourceFrame: @unchecked Sendable {
    let image: CGImage?
    let presentationTime: CMTime
    let availability: RecordingSourceAvailability
    let generation: UInt64

    init(image: CGImage?, presentationTime: CMTime, availability: RecordingSourceAvailability, generation: UInt64) {
        self.image = image
        self.presentationTime = presentationTime
        self.availability = availability
        self.generation = generation
    }
}

struct RecordingCaretSnapshot: @unchecked Sendable {
    let origin: CGPoint
    let height: CGFloat
    let color: AnnotationColor
}

struct RecordingCursorSnapshot: @unchecked Sendable {
    let point: CGPoint
    let rootWidth: CGFloat
    let color: AnnotationColor
}

enum RecordingSketchPad: Sendable { case white, black }

/// `viewport` and annotations use the stable top-left logical canvas. Frozen
/// imagery is normalized by `normalizedSourceImage` before it is published.
struct RecordingOverlaySnapshot: @unchecked Sendable {
    let generation: UInt64
    let viewport: CGRect
    let frozenImage: CGImage?
    let annotations: [Annotation]
    let inProgress: Annotation?
    let caret: RecordingCaretSnapshot?
    let cursor: RecordingCursorSnapshot?
    let sketchPad: RecordingSketchPad?

    init(generation: UInt64, viewport: CGRect, frozenImage: CGImage? = nil,
         annotations: [Annotation] = [], inProgress: Annotation? = nil,
         caret: RecordingCaretSnapshot? = nil, cursor: RecordingCursorSnapshot? = nil,
         sketchPad: RecordingSketchPad? = nil) {
        self.generation = generation
        self.viewport = viewport
        self.frozenImage = frozenImage
        self.annotations = annotations
        self.inProgress = inProgress
        self.caret = caret
        self.cursor = cursor
        self.sketchPad = sketchPad
    }
}

struct RecordingWebcamSnapshot: @unchecked Sendable {
    let image: CGImage
    /// Top-left normalized output coordinates, independent of source viewport.
    let normalizedRect: CGRect
    /// Radius measured in fixed logical canvas points.
    let cornerRadius: CGFloat
}

enum RecordingFrameRenderer {
    /// Aspect-fit the latest isolated source into a fixed canvas before viewport
    /// transformations. UI static snapshots and video use the same normalization.
    static func normalizedSourceImage(source: RecordingSourceFrame?, geometry: RecordingCanvasGeometry,
                                      generation: UInt64) -> CGImage? {
        guard let context = makeContext(geometry: geometry) else { return nil }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(geometry.logicalBounds)
        if let source, source.generation == generation, source.availability == .available, let image = source.image {
            let fit = RecordingCanvasGeometry.aspectFitRect(for: CGSize(width: image.width, height: image.height), in: geometry.logicalBounds)
            ZoomCanvasRenderer.drawImage(image, in: fit, context: context)
        }
        return context.makeImage()
    }

    static func render(source: RecordingSourceFrame?, overlay: RecordingOverlaySnapshot?,
                       geometry: RecordingCanvasGeometry, webcam: RecordingWebcamSnapshot? = nil,
                       generation: UInt64) -> CGImage? {
        guard let context = makeContext(geometry: geometry) else { return nil }
        let available = source?.generation == generation && source?.availability == .available && source?.image != nil
        let validOverlay = available && overlay?.generation == generation ? overlay : nil
        let image = validOverlay?.frozenImage ?? normalizedSourceImage(source: source, geometry: geometry, generation: generation)
        ZoomCanvasRenderer.draw(image: image, logicalBounds: geometry.logicalBounds,
                                destinationBounds: geometry.logicalBounds, overlay: validOverlay, in: context)
        if let webcam {
            let rect = CGRect(x: webcam.normalizedRect.minX * geometry.logicalSize.width,
                              y: webcam.normalizedRect.minY * geometry.logicalSize.height,
                              width: webcam.normalizedRect.width * geometry.logicalSize.width,
                              height: webcam.normalizedRect.height * geometry.logicalSize.height)
            if rect.width > 0, rect.height > 0, rect.minX.isFinite, rect.minY.isFinite,
               rect.width.isFinite, rect.height.isFinite {
                context.saveGState()
                context.addPath(CGPath(roundedRect: rect, cornerWidth: max(0, webcam.cornerRadius),
                                       cornerHeight: max(0, webcam.cornerRadius), transform: nil))
                context.clip()
                let scale = max(rect.width / CGFloat(webcam.image.width), rect.height / CGFloat(webcam.image.height))
                let fill = CGRect(x: rect.midX - CGFloat(webcam.image.width) * scale / 2,
                                  y: rect.midY - CGFloat(webcam.image.height) * scale / 2,
                                  width: CGFloat(webcam.image.width) * scale,
                                  height: CGFloat(webcam.image.height) * scale)
                ZoomCanvasRenderer.drawImage(webcam.image, in: fill, context: context)
                context.restoreGState()
            }
        }
        return context.makeImage()
    }

    private static func makeContext(geometry: RecordingCanvasGeometry) -> CGContext? {
        guard let context = CGContext(data: nil, width: geometry.outputWidth, height: geometry.outputHeight,
                                      bitsPerComponent: 8, bytesPerRow: geometry.outputWidth * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(geometry.outputHeight))
        context.scaleBy(x: CGFloat(geometry.outputWidth) / geometry.logicalSize.width,
                        y: -CGFloat(geometry.outputHeight) / geometry.logicalSize.height)
        return context
    }
}
