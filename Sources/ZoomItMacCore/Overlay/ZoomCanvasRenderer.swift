import AppKit

/// Common canvas renderer for an interactive flipped view and exported frames.
/// The caller supplies a top-left CGContext; this API never captures a screen.
enum ZoomCanvasRenderer {
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    static func draw(image: CGImage?, logicalBounds: CGRect, destinationBounds: CGRect,
                     overlay: RecordingOverlaySnapshot?, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: destinationBounds)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(destinationBounds)
        let destination = RecordingCanvasGeometry.aspectFitRect(for: logicalBounds.size, in: destinationBounds)
        context.clip(to: destination)
        let proposedViewport = overlay?.viewport ?? logicalBounds
        // Clip a malformed/external viewport; never sample unrelated content or
        // manufacture a zero-size transform. Geometry is stable across resizes.
        let clippedViewport = proposedViewport.intersection(logicalBounds)
        let source = clippedViewport.isNull || clippedViewport.isEmpty ? logicalBounds : clippedViewport
        let transform = RecordingCanvasGeometry.transform(from: source, to: destination)
        context.saveGState()
        context.concatenate(transform)
        context.clip(to: source)
        if let sketch = overlay?.sketchPad {
            context.setFillColor((sketch == .white ? NSColor.white : NSColor.black).cgColor)
            context.fill(logicalBounds)
        } else if let image {
            drawImage(image, in: logicalBounds, context: context)
        }
        if let overlay {
            context.saveGState()
            if let footprint = overlay.activeContentRect { context.clip(to: footprint.intersection(logicalBounds)) }
            AnnotationRenderer.render(annotations: overlay.annotations, inProgress: overlay.inProgress,
                                      in: context, bounds: logicalBounds)
            if let caret = overlay.caret {
                context.setStrokeColor(caret.color.nsColor.cgColor)
                context.setLineWidth(max(1, caret.height * 0.06))
                context.setLineCap(.butt)
                context.move(to: caret.origin)
                context.addLine(to: CGPoint(x: caret.origin.x, y: caret.origin.y + caret.height))
                context.strokePath()
            }
            context.restoreGState()
        }
        context.restoreGState()
        if let cursor = overlay?.cursor, source.contains(cursor.point),
           overlay?.activeContentRect?.contains(cursor.point) != false {
            let center = cursor.point.applying(transform)
            let radius = max(4, cursor.rootWidth * transform.a / 2)
            context.setFillColor(cursor.color.nsColor.cgColor)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                          width: radius * 2, height: radius * 2))
        }
    }
}
