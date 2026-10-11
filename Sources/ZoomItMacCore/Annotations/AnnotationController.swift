import AppKit

@MainActor
final class AnnotationController {
    var currentTool: AnnotationTool = .pen
    var currentStyle: AnnotationStyle = .default

    // Typing mode state, mirroring ZoomIt's font scaling and justification.
    static let defaultFontSize: CGFloat = 20
    var typingFontSize: CGFloat = AnnotationController.defaultFontSize
    var typingRightAligned: Bool = false
    /// PostScript/font family name used for typing mode. Empty means the
    /// system font, matching the default appearance.
    var typingFontName: String = ""

    private var annotations: [Annotation] = []
    private var inProgress: Annotation?
    private var textAnnotationIndex: Int?
    private var insertionPoint: CGPoint = CGPoint(x: 120, y: 120)

    var annotationSnapshot: [Annotation] {
        annotations
    }

    var inProgressSnapshot: Annotation? {
        inProgress
    }

    /// Builds the typing-mode font for the given name and size, falling back to
    /// the semibold system font when no custom font is configured or available.
    static func typingFont(named name: String, size: CGFloat) -> NSFont {
        AnnotationRenderer.typingFont(named: name, size: size)
    }

    func reset() {
        annotations.removeAll()
        inProgress = nil
        textAnnotationIndex = nil
        insertionPoint = CGPoint(x: 120, y: 120)
        currentTool = .pen
        currentStyle = .default
        typingFontSize = AnnotationController.defaultFontSize
        typingRightAligned = false
    }

    func setInsertionPoint(_ point: CGPoint) {
        insertionPoint = point
        textAnnotationIndex = nil
    }

    /// Starts a fresh typing session, matching ZoomIt's behaviour when entering
    /// type mode (T enters left-justified, Shift+T right-justified).
    func beginTypingSession(rightAligned: Bool) {
        typingRightAligned = rightAligned
        textAnnotationIndex = nil
    }

    func increaseFontSize() {
        setTypingFontSize(typingFontSize * 1.1)
    }

    func decreaseFontSize() {
        setTypingFontSize(typingFontSize / 1.1)
    }

    private func setTypingFontSize(_ size: CGFloat) {
        typingFontSize = min(max(size, 10), 600)
        // Live-resize the text currently being typed, like ZoomIt.
        if let textAnnotationIndex, annotations.indices.contains(textAnnotationIndex),
           annotations[textAnnotationIndex].tool == .text {
            annotations[textAnnotationIndex].fontSize = typingFontSize
        }
    }

    /// Whether the typing caret is locked in place. ZoomIt lets the caret
    /// follow the mouse until the first character is typed, then locks it.
    var isTypingLocked: Bool {
        if let textAnnotationIndex, annotations.indices.contains(textAnnotationIndex),
           annotations[textAnnotationIndex].tool == .text {
            return true
        }
        return false
    }

    /// Returns the caret origin (top) and height in content space for the text
    /// currently being typed, or the insertion point when no text exists yet.
    func typingCaret() -> (origin: CGPoint, height: CGFloat)? {
        let activeAnnotation: Annotation?
        if let textAnnotationIndex, annotations.indices.contains(textAnnotationIndex),
           annotations[textAnnotationIndex].tool == .text {
            activeAnnotation = annotations[textAnnotationIndex]
        } else {
            activeAnnotation = nil
        }

        let fontSize = activeAnnotation?.fontSize ?? typingFontSize
        let fontName = activeAnnotation?.fontName ?? typingFontName
        let font = Self.typingFont(named: fontName, size: fontSize)
        let lineHeight = font.ascender - font.descender + font.leading

        guard let annotation = activeAnnotation, let point = annotation.points.first else {
            return (insertionPoint, lineHeight)
        }

        let lines = annotation.text.components(separatedBy: "\n")
        let lastLine = lines.last ?? ""
        let lastWidth = NSString(string: lastLine).size(withAttributes: [.font: font]).width
        let y = point.y + CGFloat(lines.count - 1) * lineHeight
        // Right-justified text grows to the left, so the caret stays at the
        // insertion point's x; left-justified text trails the last line.
        let x = annotation.rightAligned ? point.x : point.x + lastWidth
        return (CGPoint(x: x, y: y), lineHeight)
    }

    func begin(at point: CGPoint) {
        inProgress = Annotation(tool: currentTool, points: [point], style: currentStyle)
    }

    func begin(at point: CGPoint, tool: AnnotationTool) {
        inProgress = Annotation(tool: tool, points: [point], style: currentStyle)
    }

    func update(at point: CGPoint) {
        guard let tool = inProgress?.tool else { return }

        if tool == .pen || tool == .highlighter {
            inProgress?.points.append(point)
        } else if inProgress?.points.count == 1 {
            inProgress?.points.append(point)
        } else {
            inProgress?.points[1] = point
        }
    }

    func end(at point: CGPoint) {
        update(at: point)
        guard let annotation = inProgress else { return }
        annotations.append(annotation)
        inProgress = nil
    }

    func undo() {
        _ = annotations.popLast()
        textAnnotationIndex = nil
    }

    func clear() {
        annotations.removeAll()
        inProgress = nil
        textAnnotationIndex = nil
    }

    func insertText(_ text: String) {
        if let textAnnotationIndex, annotations.indices.contains(textAnnotationIndex), annotations[textAnnotationIndex].tool == .text {
            annotations[textAnnotationIndex].text.append(contentsOf: text)
            return
        }

        let annotation = Annotation(tool: .text, points: [insertionPoint], style: currentStyle, text: text, fontSize: typingFontSize, fontName: typingFontName, rightAligned: typingRightAligned)
        annotations.append(annotation)
        textAnnotationIndex = annotations.indices.last
    }

    func deleteBackward() {
        guard let textAnnotationIndex, annotations.indices.contains(textAnnotationIndex), annotations[textAnnotationIndex].tool == .text else {
            undo()
            return
        }

        if annotations[textAnnotationIndex].text.isEmpty {
            annotations.remove(at: textAnnotationIndex)
            self.textAnnotationIndex = nil
        } else {
            annotations[textAnnotationIndex].text.removeLast()
        }
    }

    func render(in context: CGContext, bounds: CGRect) {
        AnnotationRenderer.render(annotations: annotations, inProgress: inProgress, in: context, bounds: bounds)
    }
}
