import AppKit
import ScreenCaptureKit
import CoreImage
import CoreMedia
import ApplicationServices

@main
struct PickerProbeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = PickerProbeDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Uses the actual picker-authorized filter without substituting a shareable-content filter.
/// The journal is evidence of native behavior, not a recording implementation or a mock.
final class PickerProbeDelegate: NSObject, NSApplicationDelegate, SCContentSharingPickerObserver, SCStreamDelegate {
    private let picker = SCContentSharingPicker.shared
    private var stream: SCStream?
    private let sink = ProbeOutput()
    private let backgroundColor = CGColor(gray: 0, alpha: 1)
    private var window: NSWindow!
    private let status = NSTextField(labelWithString: "idle")
    private let permission = NSTextField(labelWithString: "")
    private var requested = "window"
    private var generation = 0
    private var selected = false
    private var phase = "initial"
    private var events: [[String: Any]] = []
    private var frames: [[String: Any]] = []
    private var metadata: [String: Any] = [:]
    private var latestImage: CGImage?
    private var frameCount = 0
    private var audioCount = 0
    private var outputDirectory: URL {
        let path = ProcessInfo.processInfo.environment["ZOOMIT_UI_ARTIFACTS"]
            ?? NSTemporaryDirectory().appending("ZoomItPickerProbe")
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let item = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit Picker Probe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu; menu.addItem(item); NSApplication.shared.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 30, y: 600, width: 410, height: 340),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Recording Picker Probe"
        window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        status.setAccessibilityIdentifier("probe.status")
        permission.stringValue = CGPreflightScreenCaptureAccess() ? "screen-grant-present" : "picker-only-authorization"
        permission.setAccessibilityIdentifier("probe.permission")
        stack.addArrangedSubview(status); stack.addArrangedSubview(permission)
        let actions: [(String, String, Selector)] = [
            ("Select Window", "probe.window", #selector(selectWindow)),
            ("Select Application", "probe.application", #selector(selectApplication)),
            ("Stop Probe", "probe.stop", #selector(stop)),
            ("Snapshot", "probe.snapshot", #selector(snapshot)),
            ("Mark Idle Phase", "probe.phase.idle", #selector(markIdle)),
            ("Mark Hidden Phase", "probe.phase.hidden", #selector(markHidden)),
            ("Mark Restored Phase", "probe.phase.restored", #selector(markRestored)),
            ("Mark Closed Phase", "probe.phase.closed", #selector(markClosed))
        ]
        for (title, identifier, selector) in actions {
            let button = NSButton(title: title, target: self, action: selector)
            button.setAccessibilityIdentifier(identifier); stack.addArrangedSubview(button)
        }
        window.contentView = stack
        picker.add(self)
        sink.deliver = { [weak self] result in
            DispatchQueue.main.async { self?.consume(result) }
        }
        record("launch", details: ["screenPermission": CGPreflightScreenCaptureAccess(),
                                    "accessibilityPermission": AXIsProcessTrusted(),
                                    "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                    "displayCount": NSScreen.screens.count])
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func selectWindow() { select("window") }
    @objc private func selectApplication() { select("application") }
    private func select(_ mode: String) {
        guard stream == nil, status.stringValue != "selecting" else { return }
        generation += 1; requested = mode; selected = false
        phase = "initial"; frames.removeAll(); frameCount = 0; audioCount = 0; latestImage = nil
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = mode == "window" ? .singleWindow : .singleApplication
        configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier!]
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.isActive = true
        setStatus("selecting")
        record("selectionRequested", details: ["mode": mode, "generation": generation])
        picker.present(using: mode == "window" ? .window : .application)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, stream == nil, !self.selected else { return }
            self.record("cancelled"); self.setStatus("cancelled"); picker.isActive = false
        }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, stream == nil, self.stream == nil, !self.selected else { return }
            self.selected = true
            self.metadata = ["mode": self.requested, "style": filter.style.rawValue,
                             "contentX": filter.contentRect.minX, "contentY": filter.contentRect.minY,
                             "contentWidth": filter.contentRect.width, "contentHeight": filter.contentRect.height,
                             "scale": filter.pointPixelScale]
            if #available(macOS 15.2, *) {
                self.metadata["displays"] = filter.includedDisplays.map { $0.displayID }
                self.metadata["applications"] = filter.includedApplications.map { $0.bundleIdentifier }
                self.metadata["windows"] = filter.includedWindows.map { $0.windowID }
            } else {
                self.metadata["identityMetadata"] = "opaque-before-macOS-15.2; pixel and movement checks required"
            }
            self.record("authorizedFilter", details: self.metadata)
            let configuration = SCStreamConfiguration()
            // Small bounded probe frames keep repeated journal samples inexpensive.
            let ratio = max(0.01, filter.contentRect.height / max(1, filter.contentRect.width))
            configuration.width = 640
            configuration.height = max(2, Int(640 * ratio) / 2 * 2)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.backgroundColor = self.backgroundColor
            let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
            do {
                try capture.addStreamOutput(self.sink, type: .screen, sampleHandlerQueue: self.sink.queue)
                try capture.addStreamOutput(self.sink, type: .audio, sampleHandlerQueue: self.sink.queue)
            } catch { self.fail(error); return }
            self.stream = capture
            self.setStatus("starting")
            let currentGeneration = self.generation
            capture.startCapture { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, currentGeneration == self.generation else { return }
                    if let error { self.fail(error) } else { self.setStatus("capturing"); self.record("started") }
                }
            }
        }
    }
    func contentSharingPickerStartDidFailWithError(_ error: Error) { DispatchQueue.main.async { self.fail(error) } }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.record("terminalError", details: ["message": String(describing: error)])
            self.setStatus("source-stopped")
        }
    }
    private func consume(_ sample: ProbeSample) {
        guard stream === sample.source else { return }
        if sample.audio { audioCount += 1; return }
        frameCount += 1
        let detail: [String: Any] = ["status": sample.status, "phase": phase,
                                     "time": ProcessInfo.processInfo.systemUptime,
                                     "markers": sample.markers]
        if let image = sample.image { latestImage = image }
        frames.append(detail)
        if frames.count > 1_200 { frames.removeFirst(frames.count - 1_200) }
        writeJournal()
    }
    @objc private func stop() {
        generation += 1
        let capture = stream; stream = nil
        capture?.stopCapture { _ in }
        picker.isActive = false
        record("manualStop"); setStatus("stopped")
    }
    @objc private func snapshot() {
        guard let latestImage else { record("snapshotUnavailable"); return }
        let image = NSBitmapImageRep(cgImage: latestImage)
        do {
            try image.representation(using: .png, properties: [:])?.write(to: outputDirectory.appendingPathComponent("probe-latest.png"))
            record("snapshot")
        } catch { fail(error) }
    }
    @objc private func markIdle() { phase = "idle"; record("phase") }
    @objc private func markHidden() { phase = "hidden"; record("phase") }
    @objc private func markRestored() { phase = "restored"; record("phase") }
    @objc private func markClosed() { phase = "closed"; record("phase") }
    private func setStatus(_ value: String) { status.stringValue = value; writeJournal() }
    private func fail(_ error: Error) { record("error", details: ["message": String(describing: error)]); setStatus("error") }
    private func record(_ name: String, details: [String: Any] = [:]) {
        events.append(["event": name, "phase": phase, "time": ProcessInfo.processInfo.systemUptime, "details": details])
        writeJournal()
    }
    private func writeJournal() {
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["status": status.stringValue, "filter": metadata,
                "events": events, "frames": frames, "frameCount": frameCount, "audioCount": audioCount], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: outputDirectory.appendingPathComponent("probe-evidence.json"), options: .atomic)
        } catch {
            status.stringValue = "error: journal \(error.localizedDescription)"
            NSLog("Picker probe evidence error: %@", error.localizedDescription)
        }
    }
    func applicationWillTerminate(_ notification: Notification) { stop(); picker.remove(self) }
}

private struct ProbeSample {
    let source: SCStream
    var status: Int = -1
    var markers: [String: Double] = [:]
    var image: CGImage?
    var audio = false
}
private final class ProbeOutput: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "com.sysinternals.zoomitmac.pickerprobe.samples")
    var deliver: ((ProbeSample) -> Void)?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var lastSampleTime = 0.0
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { deliver?(ProbeSample(source: stream, audio: true)); return }
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int else { return }
        var sample = ProbeSample(source: stream, status: rawStatus)
        let now = ProcessInfo.processInfo.systemUptime
        if rawStatus == SCFrameStatus.complete.rawValue {
            guard now - lastSampleTime >= 0.1 else { return }
            lastSampleTime = now
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let image = CIImage(cvPixelBuffer: pixelBuffer)
                sample.image = context.createCGImage(image, from: image.extent)
                let scaled = image.transformed(by: CGAffineTransform(scaleX: 128 / image.extent.width, y: 128 / image.extent.height))
                var pixels = [UInt8](repeating: 0, count: 128 * 128 * 4)
                context.render(scaled, toBitmap: &pixels, rowBytes: 128 * 4, bounds: CGRect(x: 0, y: 0, width: 128, height: 128),
                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                var counts = ["primary": 0, "second": 0, "dialog": 0, "forbidden": 0, "black": 0]
                for offset in stride(from: 0, to: pixels.count, by: 4) {
                    let r = pixels[offset], g = pixels[offset + 1], b = pixels[offset + 2]
                    if r < 80 && g > 150 && b < 100 { counts["primary", default: 0] += 1 }
                    if r < 80 && g > 150 && b > 150 { counts["second", default: 0] += 1 }
                    if r > 170 && g > 90 && g < 180 && b < 80 { counts["dialog", default: 0] += 1 }
                    if r > 150 && g < 100 && b > 150 { counts["forbidden", default: 0] += 1 }
                    if r < 25 && g < 25 && b < 25 { counts["black", default: 0] += 1 }
                }
                sample.markers = counts.mapValues { Double($0) / (128 * 128) }
            }
        }
        deliver?(sample)
    }
}
