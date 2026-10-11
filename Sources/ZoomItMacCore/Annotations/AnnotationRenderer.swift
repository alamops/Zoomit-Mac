import AppKit

/// Shared, stateless drawing for immutable annotation snapshots.
enum AnnotationRenderer {
    static func typingFont(named name: String, size: CGFloat) -> NSFont {
        if !name.isEmpty, let font = NSFont(name: name, size: size) { return font }
        return NSFont.systemFont(ofSize: size, weight: .regular)
    }

    /// A highlight is the translucent highlighter tool or any shape drawn with
    /// the translucent Shift+color style. Text is never treated as a highlight.
    private static func isHighlight(_ annotation: Annotation) -> Bool {
        guard annotation.tool != .text else { return false }
        return annotation.tool == .highlighter || annotation.style.alpha < 1
    }

    static func render(annotations: [Annotation], inProgress: Annotation? = nil, in context: CGContext, bounds: CGRect) {
        let all = annotations + (inProgress.map { [$0] } ?? [])
        let highlights = all.filter(isHighlight)
        let solids = all.filter { !isHighlight($0) }

        // Composite every highlight into a single transparency layer drawn at
        // full opacity, then blend the whole layer once at the highlight alpha.
        // This way overlapping highlight strokes (within or across annotations)
        // paint the same opaque pixels and never accumulate, so going over a
        // highlight again doesn't darken it. Highlights sit beneath solid ink.
        if !highlights.isEmpty {
            context.saveGState()
            context.setAlpha(AnnotationStyle.highlightAlpha)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            for annotation in highlights {
                render(annotation, in: context, forceOpaque: true)
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }

        for annotation in solids {
            render(annotation, in: context)
        }
    }

    private static func render(_ annotation: Annotation, in context: CGContext, forceOpaque: Bool = false) {
        guard let first = annotation.points.first else { return }

        let highlight = isHighlight(annotation)
        // Inside the highlight transparency layer everything is drawn opaque so
        // overlaps don't accumulate; the layer applies the highlight alpha once.
        let drawAlpha: CGFloat = forceOpaque ? 1 : (highlight ? AnnotationStyle.highlightAlpha : annotation.style.alpha)
        let color = annotation.style.color.nsColor.withAlphaComponent(drawAlpha)
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(annotation.style.rootWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.tool {
        case .pen, .highlighter:
            let path = CGMutablePath()
            path.move(to: first)
            for point in annotation.points.dropFirst() {
                path.addLine(to: point)
            }
            context.addPath(path)
            context.strokePath()
        case .line, .arrow:
            guard let last = annotation.points.last else { return }
            // Only draw the arrowhead once the shaft is long enough to make the
            // direction unambiguous; until then show a plain line without a tip.
            let shaftLength = hypot(last.x - first.x, last.y - first.y)
            let headLength = annotation.style.rootWidth * 3.5
            if annotation.tool == .arrow && annotation.points.count >= 2 && shaftLength >= headLength {
                // ZoomIt anchors the arrowhead at the start point (where the
                // drag began) and trails the shaft out to the current cursor.
                drawArrow(tail: last, tip: first, width: annotation.style.rootWidth, color: color, in: context)
            } else {
                context.move(to: first)
                context.addLine(to: last)
                context.strokePath()
            }
        case .rectangle:
            guard let last = annotation.points.last else { return }
            let rect = CGRect(origin: first, size: CGSize(width: last.x - first.x, height: last.y - first.y)).standardized
            // In highlight mode shapes are filled so they read as a highlight
            // swatch; otherwise they're outlined.
            if highlight {
                context.fill(rect)
            } else {
                context.stroke(rect)
            }
        case .ellipse:
            guard let last = annotation.points.last else { return }
            let rect = CGRect(origin: first, size: CGSize(width: last.x - first.x, height: last.y - first.y)).standardized
            if highlight {
                context.fillEllipse(in: rect)
            } else {
                context.strokeEllipse(in: rect)
            }
        case .text:
            drawText(annotation, in: context)
        }
    }

    private static func drawText(_ annotation: Annotation, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let point = annotation.points.first else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = annotation.rightAligned ? .right : .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.typingFont(named: annotation.fontName, size: annotation.fontSize),
            .foregroundColor: annotation.style.color.nsColor.withAlphaComponent(annotation.style.alpha),
            .paragraphStyle: paragraph
        ]
        let string = NSString(string: annotation.text)
        if annotation.rightAligned {
            // Anchor the right edge of the text at the insertion point so the
            // text grows to the left as ZoomIt's right-justified mode does.
            let size = string.size(withAttributes: attributes)
            let rect = CGRect(x: point.x - size.width, y: point.y, width: size.width, height: size.height)
            string.draw(in: rect, withAttributes: attributes)
        } else {
            string.draw(at: point, withAttributes: attributes)
        }
    }

    private static func drawArrow(tail: CGPoint, tip: CGPoint, width: CGFloat, color: NSColor, in context: CGContext) {
        let dx = tip.x - tail.x
        let dy = tip.y - tail.y
        let length = hypot(dx, dy)
        let ux: CGFloat = length > 0 ? dx / length : 1
        let uy: CGFloat = length > 0 ? dy / length : 0

        // Slightly larger than ZoomIt's head (penWidth * 2.5 / 1.5) for a more
        // visible arrowhead.
        let headLength = width * 3.5
        let headHalfWidth = width * 2.0

        // Base midpoint, backed off from the tip along the shaft.
        let baseX = tip.x - ux * headLength
        let baseY = tip.y - uy * headLength
        // Wings perpendicular to the shaft.
        let left = CGPoint(x: baseX - uy * headHalfWidth, y: baseY + ux * headHalfWidth)
        let right = CGPoint(x: baseX + uy * headHalfWidth, y: baseY - ux * headHalfWidth)
        // Indented base center for a concave (nicer) arrowhead.
        let mid = CGPoint(x: tip.x - ux * headLength / 2, y: tip.y - uy * headLength / 2)

        // Shaft runs from the tail to the indented base of the head.
        context.move(to: tail)
        context.addLine(to: mid)
        context.strokePath()

        // Filled arrowhead: tip -> left wing -> indented mid -> right wing.
        context.setFillColor(color.cgColor)
        context.beginPath()
        context.move(to: tip)
        context.addLine(to: left)
        context.addLine(to: mid)
        context.addLine(to: right)
        context.closePath()
        context.fillPath()
    }
}
