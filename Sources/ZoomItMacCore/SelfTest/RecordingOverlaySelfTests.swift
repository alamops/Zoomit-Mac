import AppKit
@preconcurrency import ScreenCaptureKit

@MainActor
enum RecordingOverlaySelfTests {
    static func run() throws {
        try nativeFootprintAndClipping()
        let geometry = try RecordingCanvasGeometry(logicalSize: CGSize(width: 64, height: 32), pixelScale: 2,
                                                   hostDisplayFrame: CGRect(x: -1000, y: 200, width: 600, height: 600))
        let green = try RecordingSelfTests.pixelImage(width: 128, height: 64) { _, _ in (0, 255, 0) }
        let blue = try RecordingSelfTests.pixelImage(width: 128, height: 64) { _, _ in (0, 0, 255) }
        let black = try RecordingSelfTests.pixelImage(width: 128, height: 64) { _, _ in (0, 0, 0) }
        let frame = CapturedFrame(image: green, display: DisplayDescriptor(id: 1, frame: geometry.hostDisplayFrame, scaleFactor: 2),
                                  pixelSize: CGSize(width: 128, height: 64), timestamp: Date(timeIntervalSince1970: 0))
        let viewport = ZoomViewportController()
        viewport.configure(for: frame, initialZoom: 2, contentGeometry: geometry)
        let source = viewport.sourceRect(for: geometry.presentationBounds, cursorLocation: nil)
        try require(source.size == CGSize(width: 32, height: 16), "viewport uses logical target size rather than monitor dimensions")
        let point = CGPoint(x: source.midX, y: source.midY)
        let transform = viewport.contentToDestinationTransform(source: source, destinationBounds: geometry.presentationBounds)
        let viewPoint = point.applying(transform)
        let roundTrip = viewport.contentPoint(for: viewPoint, destinationBounds: geometry.presentationBounds, cursorLocation: nil)
        try require(hypot(roundTrip.x - point.x, roundTrip.y - point.y) < 0.0001, "real viewport inverse preserves target-relative input")
        for corner in [CGPoint(x: -1000, y: 800), CGPoint(x: -400, y: 200)] {
            let pan = viewport.sourceRect(for: geometry.presentationBounds, cursorLocation: corner)
            try require(geometry.logicalBounds.contains(pan), "negative-origin display panning cannot leave target")
        }
        viewport.setZoomFactor(1)
        let annotations = AnnotationController()
        let preferences = UserDefaults(suiteName: "RecordingOverlaySelfTests.\(UUID().uuidString)")!
        let canvas = ZoomCanvasView(frame: geometry.presentationBounds, capturedFrame: frame,
                                    viewportController: viewport, annotationController: annotations, smoothImage: false,
                                    contentGeometry: geometry, generation: 42, activeContentRect: geometry.logicalBounds,
                                    userSelectedResourceAccess: UserDefaultsUserSelectedResourceAccess(defaults: preferences), commandSink: { _ in })
        defer { canvas.prepareForClose() }
        let first = try snapshot(canvas)
        try require(first.activeContentRect == geometry.logicalBounds, "canvas exports its actual target footprint")
        try require(first.frozenImage === green, "static overlay freezes only authorized source")
        canvas.updateIsolatedSource(image: blue, activeContentRect: geometry.logicalBounds, available: true, generation: 42)
        try require(try snapshot(canvas).frozenImage === green, "static zoom retains frozen source while native frames change")
        canvas.interactionMode = .liveZoom
        canvas.updateIsolatedSource(image: blue, activeContentRect: geometry.logicalBounds, available: true, generation: 42)
        try require(try snapshot(canvas).frozenImage == nil, "live zoom uses source slot instead of a frozen image")
        canvas.interactionMode = .staticZoom
        try require(try snapshot(canvas).frozenImage === blue, "return from live freezes the current isolated frame")
        annotations.currentTool = .highlighter
        annotations.begin(at: CGPoint(x: 5, y: 8))
        annotations.update(at: CGPoint(x: 45, y: 8))
        try require(try snapshot(canvas).inProgress != nil, "real canvas exports in-progress drawing")
        annotations.end(at: CGPoint(x: 50, y: 8))
        annotations.setInsertionPoint(CGPoint(x: 10, y: 20))
        annotations.insertText("isolated")
        try require(try snapshot(canvas).annotations.count == 2, "snapshot includes text and highlights")
        annotations.undo()
        try require(try snapshot(canvas).annotations.count == 1, "undo updates recording snapshot")
        annotations.clear()
        try require(try snapshot(canvas).annotations.isEmpty, "erase removes exported annotations")
        annotations.begin(at: CGPoint(x: 5, y: 8))
        annotations.end(at: CGPoint(x: 50, y: 8))
        canvas.updateIsolatedSource(image: green, activeContentRect: geometry.logicalBounds, available: false, generation: 41)
        try require(canvas.recordingOverlaySnapshot() != nil && annotations.annotationSnapshot.count == 1,
                    "stale source loss cannot clear current canvas")
        canvas.updateIsolatedSource(image: black, activeContentRect: nil, available: false, generation: 42)
        try require(canvas.recordingOverlaySnapshot() == nil && annotations.annotationSnapshot.isEmpty && annotations.inProgressSnapshot == nil,
                    "current source loss clears frozen/annotation state and suppresses recording overlay")
        canvas.updateIsolatedSource(image: green, activeContentRect: geometry.logicalBounds, available: true, generation: 42)
        try require(try snapshot(canvas).frozenImage === green && snapshot(canvas).annotations.isEmpty,
                    "restored static overlay freezes new image without resurrecting annotations")
        // The ordinary display path stays independent from isolated updates.
        let ordinaryViewport = ZoomViewportController()
        ordinaryViewport.configure(for: frame, initialZoom: 2)
        let ordinary = ZoomCanvasView(frame: geometry.presentationBounds, capturedFrame: frame,
                                     viewportController: ordinaryViewport, annotationController: AnnotationController(), smoothImage: false,
                                     userSelectedResourceAccess: UserDefaultsUserSelectedResourceAccess(defaults: preferences), commandSink: { _ in })
        defer { ordinary.prepareForClose() }
        ordinary.updateIsolatedSource(image: black, activeContentRect: nil, available: false, generation: 0)
        try require(ordinary.isolatedCanvasGeneration == nil && ordinary.recordingOverlaySnapshot() == nil,
                    "legacy screen overlay never exports an isolated snapshot")
        let legacy = ordinaryViewport.sourceRect(for: geometry.presentationBounds, cursorLocation: nil)
        try require(legacy.size == CGSize(width: 300, height: 300), "ordinary zoom retains display geometry")
    }

    private static func nativeFootprintAndClipping() throws {
        let geometry = try RecordingCanvasGeometry(logicalSize: CGSize(width: 64, height: 64), pixelScale: 2,
                                                   hostDisplayFrame: CGRect(x: 0, y: 0, width: 128, height: 128))
        let metadata: [SCStreamFrameInfo: Any] = [
            .contentRect: CGRect(x: 16, y: 0, width: 32, height: 64).dictionaryRepresentation,
            .contentScale: CGFloat(0.5), .scaleFactor: CGFloat(4)
        ]
        let pixels = RecordingSourceSession.pixelContentRect(attachments: metadata, pixelSize: CGSize(width: 128, height: 128))
        try require(pixels == CGRect(x: 32, y: 0, width: 64, height: 128), "native scale metadata maps content into buffer pixels")
        let black = try RecordingSelfTests.pixelImage(width: 128, height: 128) { _, _ in (0, 0, 0) }
        let slot = RecordingSourceSession(generation: 1, audioSink: { _ in })
        slot.consume(.complete, image: black, contentRect: pixels)
        let frame = slot.snapshot().frame
        try require(frame.contentRect == pixels, "source publication preserves changing content footprint")
        guard let footprint = RecordingFrameRenderer.logicalContentRect(source: frame, geometry: geometry, generation: 1) else {
            throw SelfTestError.failure("Native target footprint was not mapped")
        }
        try require(footprint == CGRect(x: 16, y: 0, width: 32, height: 64), "fixed-size surface does not imply full target coverage")
        try require(geometry.contentPoint(forViewPoint: CGPoint(x: 8, y: 64), viewBounds: geometry.presentationBounds,
                                          activeContentRect: footprint) == nil, "inner native letterbox padding rejects drawing input")
        let stroke = Annotation(tool: .line, points: [CGPoint(x: 0, y: 32), CGPoint(x: 64, y: 32)],
                                style: AnnotationStyle(color: .red, rootWidth: 8, alpha: 1))
        let overlay = RecordingOverlaySnapshot(generation: 1, viewport: geometry.logicalBounds, annotations: [stroke],
            caret: RecordingCaretSnapshot(origin: CGPoint(x: 4, y: 18), height: 6, color: .red),
            cursor: RecordingCursorSnapshot(point: CGPoint(x: 4, y: 32), rootWidth: 8, color: .red), activeContentRect: footprint)
        guard let rendered = RecordingFrameRenderer.render(source: frame, overlay: overlay, geometry: geometry, generation: 1) else {
            throw SelfTestError.failure("Footprint renderer failed")
        }
        try require(try RecordingSelfTests.rgb(rendered, x: 8, y: 64) == [0, 0, 0], "annotation and cursor cannot paint target padding")
        try require(try RecordingSelfTests.rgb(rendered, x: 8, y: 40) == [0, 0, 0], "typing caret cannot paint target padding")
        let center = try RecordingSelfTests.rgb(rendered, x: 64, y: 64)
        try require(center[0] > 150 && center[1] < 150, "annotations still paint actual target content")
        slot.setTargetVisible(false)
        try require(slot.snapshot().frame.contentRect == nil, "source loss clears both pixels and their footprint")
        let empty: [SCStreamFrameInfo: Any] = [.contentRect: CGRect.zero.dictionaryRepresentation]
        try require(RecordingSourceSession.pixelContentRect(attachments: empty, pixelSize: CGSize(width: 128, height: 128)) == nil,
                    "empty native content cannot keep a frozen target alive")
        try require(RecordingFrameRenderer.logicalContentRect(source: frame, geometry: geometry, generation: 2) == nil,
                    "old-session footprint cannot affect a new target")
    }

    private static func snapshot(_ canvas: ZoomCanvasView) throws -> RecordingOverlaySnapshot {
        guard let snapshot = canvas.recordingOverlaySnapshot() else { throw SelfTestError.failure("Recording overlay snapshot missing") }
        return snapshot
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw SelfTestError.failure("Recording overlay: \(message)") }
    }
}
