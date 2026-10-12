import AppKit
import ScreenCaptureKit
import CoreMedia

@MainActor
enum RecordingSelfTests {
    static func run() throws {
        try geometryAndMapping()
        try lifecycleAndGeneration()
        try transitionCommandIsolation()
        try pickerWindowIDValidation()
        try pickerSelectionValidation()
        try sourcePolicyAndTimeline()
        try renderingIsolationAndOrientation()
        try annotationEquivalenceAndHighlights()
        try webcamPlacementAndAspect()
    }

    private static func pickerWindowIDValidation() throws {
        let invalid = [Int.min, -1, 0, Int(UInt32.max) + 1, Int.max]
        try expect(RecordingPickerController.validExcludedWindowIDs(invalid).isEmpty,
                   "closed/unrealized/out-of-range windows must not be sent to the system picker")
        try expect(RecordingPickerController.validExcludedWindowIDs([-1, 17, 0, 42, Int.max]) == [17, 42],
                   "valid own-window exclusions remain intact alongside closed windows")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 32, height: 32),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        try expect(window.windowNumber == -1 && RecordingPickerController.validExcludedWindowIDs([window.windowNumber]).isEmpty,
                   "real unrealized AppKit windows reproduce the invalid window-ID case")
    }

    private static func transitionCommandIsolation() throws {
        var activations: [AppCommand] = [.activateStaticZoom, .activateLiveZoom, .activateDrawWithoutZoom,
            .snipRegion(save: false), .snipOcr, .startPanorama(save: true), .zoomIn, .zoomOutOrExit,
            .toggleBreakTimer, .toggleDemoMirror(scope: .screen), .toggleDemoMirror(scope: .region),
            .toggleDemoMirror(scope: .window)]
        #if !ZOOMIT_APP_STORE
        activations += [.startDemoType, .resetDemoType]
        #endif
        for phase: RecordingSessionState.Phase in [.selecting, .starting, .stopping, .editing, .saving] {
            for command in activations {
                try expect(!ModeCoordinator.allowsCommand(command, during: phase),
                           "\(command) must not interfere with recording phase \(phase)")
            }
            for command: AppCommand in [.stopRecording, .toggleRecording(scope: .application), .exit] {
                try expect(ModeCoordinator.allowsCommand(command, during: phase),
                           "stop/cancellation handling must remain reachable during \(phase)")
            }
        }
        for phase: RecordingSessionState.Phase in [.idle, .recording] {
            for command in activations {
                try expect(ModeCoordinator.allowsCommand(command, during: phase),
                           "normal feature commands must remain available during \(phase)")
            }
        }
    }

    private static func pickerSelectionValidation() throws {
        try expect(RecordingPickerController.validSelection(scope: .application, style: .display,
                   windowCount: 0, applicationCount: 1, displayCount: 1),
                   "native application selection is a display-style filter restricted to one app")
        for counts in [(0, 1), (2, 1), (1, 0), (1, 2)] {
            try expect(!RecordingPickerController.validSelection(scope: .application, style: .display,
                       applicationCount: counts.0, displayCount: counts.1),
                       "application mode rejects unrestricted, multi-app and multi-display filters")
        }
        try expect(!RecordingPickerController.validSelection(scope: .window, style: .display,
                   windowCount: 1, applicationCount: 1, displayCount: 1),
                   "window mode cannot accept a display/application selection")
        try expect(!RecordingPickerController.validSelection(scope: .application, style: .window,
                   windowCount: 1, applicationCount: 1, displayCount: 1),
                   "application mode cannot accept a single-window selection")
        try expect(RecordingPickerController.validSelection(scope: .window, style: .window, windowCount: 1)
                   && !RecordingPickerController.validSelection(scope: .window, style: .window, windowCount: 2),
                   "window mode requires exactly one target")
        try expect(RecordingPickerController.validSelection(scope: .application, style: .display)
                   && RecordingPickerController.validSelection(scope: .window, style: .window),
                   "opaque older-OS filters remain usable under the pinned native picker mode")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw SelfTestError.failure("Recording: \(message)") }
    }

    private static func geometryAndMapping() throws {
        let geometry = try RecordingCanvasGeometry(logicalSize: CGSize(width: 101, height: 51), pixelScale: 1,
                                                   hostDisplayFrame: CGRect(x: -800, y: 200, width: 800, height: 800))
        try expect(geometry.outputWidth == 102 && geometry.outputHeight == 52, "encoder canvas must round up to positive even dimensions")
        try expect(RecordingCanvasGeometry.aspectFitRect(for: CGSize(width: 100, height: 50), in: CGRect(x: 10, y: 20, width: 200, height: 200)) == CGRect(x: 10, y: 70, width: 200, height: 100), "aspect fitting must center padding")
        let content = CGPoint(x: 40, y: 25)
        let view = geometry.viewPoint(forContentPoint: content, viewBounds: geometry.presentationBounds)
        let mapped = geometry.contentPoint(forViewPoint: view, viewBounds: geometry.presentationBounds)
        try expect(mapped.map { hypot($0.x - content.x, $0.y - content.y) < 0.0001 } == true, "content/view inverse mapping")
        let global = geometry.globalPoint(forViewPoint: view)
        try expect(hypot(geometry.viewPoint(forGlobalPoint: global).x - view.x, geometry.viewPoint(forGlobalPoint: global).y - view.y) < 0.0001, "negative-monitor global/view inverse mapping")
        try expect(geometry.contentPoint(forGlobalPoint: global).map { hypot($0.x - content.x, $0.y - content.y) < 0.0001 } == true, "global content round trip")
        try expect(geometry.contentPoint(forViewPoint: .zero, viewBounds: geometry.presentationBounds) == nil, "padding must reject pointer input")
        let viewport = CGRect(x: 10, y: 10, width: 50, height: 25)
        let zoomed = geometry.viewPoint(forContentPoint: content, viewBounds: geometry.presentationBounds, viewport: viewport)
        try expect(geometry.contentPoint(forViewPoint: zoomed, viewBounds: geometry.presentationBounds, viewport: viewport).map { hypot($0.x - content.x, $0.y - content.y) < 0.0001 } == true, "zoomed pointer mapping")
        for (size, scale) in [(CGSize.zero, CGFloat(1)), (CGSize(width: -1, height: 1), 1),
                               (CGSize(width: 1, height: 1), 0), (CGSize(width: 1, height: 1), .nan),
                               (CGSize(width: 20_000, height: 1), 1)] {
            do {
                _ = try RecordingCanvasGeometry(logicalSize: size, pixelScale: scale, hostDisplayFrame: geometry.hostDisplayFrame)
                throw SelfTestError.failure("Recording: invalid geometry was accepted")
            } catch is RecordingCanvasGeometry.ValidationError { }
        }
    }

    private static func lifecycleAndGeneration() throws {
        var state = RecordingSessionState()
        guard let first = state.begin(scope: .window) else { throw SelfTestError.failure("Recording: session did not start") }
        try expect(state.phase == .selecting && !state.canStart && !state.canStop, "isolated session must select before recording")
        try expect(state.begin(scope: .application) == nil, "duplicate start must be rejected")
        try expect(!state.transition(to: .recording, generation: first), "selection must not bypass startup")
        try expect(state.transition(to: .starting, generation: first), "picker accepted")
        try expect(state.transition(to: .recording, generation: first), "writer startup accepted")
        try expect(state.setAvailability(.available, generation: first), "valid source callback")
        try expect(state.setAvailability(.ended, generation: first), "closed source is terminal")
        try expect(!state.setAvailability(.available, generation: first) && state.isRecording, "terminal source cannot retarget or stop recording")
        try expect(state.transition(to: .stopping, generation: first), "explicit stop")
        try expect(!state.transition(to: .stopping, generation: first), "duplicate stop must be rejected")
        try expect(state.transition(to: .editing, generation: first), "open editor once")
        try expect(state.transition(to: .saving, generation: first), "save begins")
        try expect(state.transition(to: .editing, generation: first), "failed or canceled save returns to editor")
        try expect(state.transition(to: .idle, generation: first), "editor cancellation finishes")
        guard let second = state.begin(scope: .application) else { throw SelfTestError.failure("Recording: second session did not start") }
        try expect(second != first, "session generations must differ")
        try expect(!state.transition(to: .idle, generation: first), "stale picker cancellation rejected")
        try expect(state.transition(to: .idle, generation: second), "current picker cancellation returns idle")
        guard let third = state.begin(scope: .screen) else { throw SelfTestError.failure("Recording: screen session did not start") }
        try expect(state.phase == .starting, "legacy screen has no picker")
        try expect(state.transition(to: .idle, generation: third), "startup failure restores idle")
    }

    private static func sourcePolicyAndTimeline() throws {
        var policy = RecordingSourcePolicy()
        policy.consume(.complete)
        let revision = policy.contentRevision
        policy.consume(.idle)
        try expect(policy.availability == .available && policy.contentRevision == revision, "idle retains unchanged authorized content")
        policy.consume(.suspended)
        try expect(policy.availability == .unavailable, "hidden source blanks")
        policy.consume(.complete)
        try expect(policy.availability == .available, "same-stream source can resume")
        policy.consume(.blank)
        try expect(policy.availability == .unavailable, "blank clears retained content")
        policy.consume(.stopped)
        policy.consume(.complete)
        try expect(policy.availability == .ended, "terminal source cannot resume")
        var timeline = RecordingTimeline()
        let first = timeline.nextPresentationTime(hostTime: CMTime(value: 10, timescale: 1))
        let repeated = timeline.nextPresentationTime(hostTime: first)
        let regressed = timeline.nextPresentationTime(hostTime: .zero)
        let invalid = timeline.nextPresentationTime(hostTime: .invalid)
        let future = timeline.nextPresentationTime(hostTime: CMTime(value: 12, timescale: 1))
        try expect(CMTimeCompare(first, repeated) < 0 && CMTimeCompare(repeated, regressed) < 0 && CMTimeCompare(regressed, invalid) < 0 && CMTimeCompare(invalid, future) < 0, "timeline must always advance including repeated/missing source callbacks")
    }

    private static func renderingIsolationAndOrientation() throws {
        let geometry = try canvas(64, 64)
        let image = try pixelImage(width: 64, height: 32) { _, y in y < 16 ? (255, 0, 0) : (0, 0, 255) }
        let source = RecordingSourceFrame(image: image, presentationTime: .zero, availability: .available, generation: 1)
        guard let normalized = RecordingFrameRenderer.normalizedSourceImage(source: source, geometry: geometry, generation: 1) else { throw SelfTestError.failure("Recording: normalization failed") }
        try expect(try rgb(normalized, x: 32, y: 2) == [0, 0, 0], "source aspect fitting must pad black")
        try expect(try rgb(normalized, x: 32, y: 20) == [255, 0, 0], "source top must stay at top")
        try expect(try rgb(normalized, x: 32, y: 44) == [0, 0, 255], "source bottom must stay at bottom")
        let red = Annotation(tool: .rectangle, points: [.zero, CGPoint(x: 64, y: 64)], style: AnnotationStyle(color: .red, rootWidth: 20, alpha: 1))
        let frozen = try pixelImage(width: 64, height: 64) { _, _ in (0, 255, 0) }
        let overlay = RecordingOverlaySnapshot(generation: 1, viewport: geometry.logicalBounds, frozenImage: frozen, annotations: [red], sketchPad: .white)
        let absent = RecordingSourceFrame(image: image, presentationTime: .zero, availability: .unavailable, generation: 1)
        guard let blank = RecordingFrameRenderer.render(source: absent, overlay: overlay, geometry: geometry, generation: 1),
              let stale = RecordingFrameRenderer.render(source: source, overlay: overlay, geometry: geometry, generation: 2) else { throw SelfTestError.failure("Recording: blank renderer failed") }
        try expect(try rgb(blank, x: 1, y: 32) == [0, 0, 0] && rgb(blank, x: 32, y: 32) == [0, 0, 0], "absence must override frozen image, annotations, sketch pad")
        try expect(try rgb(stale, x: 32, y: 32) == [0, 0, 0], "old generation images cannot leak into next session")
        let staticOverlay = RecordingOverlaySnapshot(generation: 1, viewport: geometry.logicalBounds, frozenImage: frozen)
        guard let staticImage = RecordingFrameRenderer.render(source: source, overlay: staticOverlay, geometry: geometry, generation: 1),
              let liveImage = RecordingFrameRenderer.render(source: source, overlay: nil, geometry: geometry, generation: 1) else { throw SelfTestError.failure("Recording: static/live rendering failed") }
        try expect(try rgb(staticImage, x: 32, y: 20) == [0, 255, 0], "static uses frozen isolated canvas")
        try expect(try rgb(liveImage, x: 32, y: 20) == [255, 0, 0], "live uses latest isolated canvas")
    }

    private static func annotationEquivalenceAndHighlights() throws {
        let controller = AnnotationController()
        controller.currentTool = .highlighter
        controller.currentStyle = AnnotationStyle(color: .yellow, rootWidth: 12, alpha: 0.5)
        controller.begin(at: CGPoint(x: 10, y: 30))
        controller.end(at: CGPoint(x: 54, y: 30))
        controller.currentTool = .pen
        controller.currentStyle = AnnotationStyle(color: .red, rootWidth: 3, alpha: 1)
        controller.begin(at: CGPoint(x: 10, y: 40))
        controller.update(at: CGPoint(x: 54, y: 40))
        controller.setInsertionPoint(CGPoint(x: 4, y: 4))
        controller.typingFontSize = 12
        controller.insertText("Text")
        let original = try annotationImage { context in controller.render(in: context, bounds: CGRect(x: 0, y: 0, width: 64, height: 64)) }
        let shared = try annotationImage { context in
            AnnotationRenderer.render(annotations: controller.annotationSnapshot, inProgress: controller.inProgressSnapshot,
                                      in: context, bounds: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        try expect((original.dataProvider?.data as Data?) == (shared.dataProvider?.data as Data?), "controller and snapshot renderer must match text, highlights and in-progress pen")
        let highlight = controller.annotationSnapshot[0]
        let once = try annotationImage { context in AnnotationRenderer.render(annotations: [highlight], in: context, bounds: CGRect(x: 0, y: 0, width: 64, height: 64)) }
        let twice = try annotationImage { context in AnnotationRenderer.render(annotations: [highlight, highlight], in: context, bounds: CGRect(x: 0, y: 0, width: 64, height: 64)) }
        try expect(try rgb(once, x: 32, y: 30) == rgb(twice, x: 32, y: 30), "overlapping highlights must not accumulate opacity")
    }

    private static func webcamPlacementAndAspect() throws {
        let geometry = try canvas(64, 64)
        // Wide image with red/blue edge bands; aspect-fill into a square removes
        // the bands. Stretching would leave them visible at the square edges.
        let camera = try pixelImage(width: 64, height: 16) { x, _ in
            x < 16 ? (255, 0, 0) : (x >= 48 ? (0, 0, 255) : (0, 255, 0))
        }
        let webcam = RecordingWebcamSnapshot(image: camera, normalizedRect: CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25), cornerRadius: 0)
        let unavailable = RecordingSourceFrame(image: nil, presentationTime: .zero, availability: .unavailable, generation: 1)
        guard let image = RecordingFrameRenderer.render(source: unavailable, overlay: nil, geometry: geometry, webcam: webcam, generation: 1) else { throw SelfTestError.failure("Recording: camera renderer failed") }
        try expect(try rgb(image, x: 33, y: 40) == [0, 255, 0] && rgb(image, x: 46, y: 40) == [0, 255, 0], "camera aspect-fill must preserve shape without stretching")
        try expect(try rgb(image, x: 10, y: 10) == [0, 0, 0], "camera is bounded on absent target")
        let source = RecordingSourceFrame(image: try pixelImage(width: 64, height: 64) { _, _ in (0, 0, 255) }, presentationTime: .zero, availability: .available, generation: 1)
        let zoom = RecordingOverlaySnapshot(generation: 1, viewport: CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let zoomed = RecordingFrameRenderer.render(source: source, overlay: zoom, geometry: geometry, webcam: webcam, generation: 1) else { throw SelfTestError.failure("Recording: zoom camera renderer failed") }
        try expect(try rgb(zoomed, x: 40, y: 40) == rgb(image, x: 40, y: 40), "camera must retain fixed position and size after source zoom")
    }

    static func canvas(_ width: CGFloat, _ height: CGFloat) throws -> RecordingCanvasGeometry {
        try RecordingCanvasGeometry(logicalSize: CGSize(width: width, height: height), pixelScale: 1,
                                    hostDisplayFrame: CGRect(x: 0, y: 0, width: width, height: height))
    }

    static func pixelImage(width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        var bytes = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let c = color(x, y)
                bytes.append(contentsOf: [c.0, c.1, c.2, 255])
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw SelfTestError.failure("Recording: fixture image creation failed") }
        return image
    }

    private static func annotationImage(draw: (CGContext) -> Void) throws -> CGImage {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SelfTestError.failure("Recording: fixture context creation failed") }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.translateBy(x: 0, y: 64)
        context.scaleBy(x: 1, y: -1)
        draw(context)
        guard let image = context.makeImage() else { throw SelfTestError.failure("Recording: fixture context image failed") }
        return image
    }

    static func rgb(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { throw SelfTestError.failure("Recording: image has no pixel storage") }
        let offset = y * image.bytesPerRow + x * 4
        return [bytes[offset], bytes[offset + 1], bytes[offset + 2]]
    }
}
