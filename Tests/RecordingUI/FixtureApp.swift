import AppKit
import AVFoundation

/// Stable colors, window titles and identifiers are the interface of this fixture.
/// A and B are separate processes/bundle identifiers, never child windows of the probe.
@main
struct FixtureMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = FixtureDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

final class FixtureDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let isB = Bundle.main.bundleIdentifier?.hasSuffix("fixtureb") == true
    private var primary: NSWindow?
    private var second: NSWindow?
    private var dialog: NSWindow?
    private var controls: NSWindow!
    private let focusedWindow = NSTextField(labelWithString: "Focused: none")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var tonePlaying = false
    private var resizeLarge = false
    private var animate = false
    private var animationTimer: Timer?
    private var tick = 0
    private var name: String { isB ? "B" : "A" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Every marker is an independent capture target, regardless of the
        // login's preference for opening document windows in tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
        let appMenu = NSMenu()
        let root = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit Fixture \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = menu
        appMenu.addItem(root)
        NSApplication.shared.mainMenu = appMenu
        controls = NSWindow(contentRect: NSRect(x: 40, y: 60, width: 330, height: 600),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        controls.tabbingMode = .disallowed
        controls.title = "Fixture \(name) Controls"
        controls.setAccessibilityIdentifier("fixture.controls")
        controls.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        focusedWindow.setAccessibilityIdentifier("fixture.focusedWindow")
        stack.addArrangedSubview(focusedWindow)
        let items: [(String, String, Selector)] = [
            ("Open Primary", "fixture.openPrimary", #selector(openPrimary)),
            ("Open Second", "fixture.openSecond", #selector(openSecond)),
            ("Open Dialog", "fixture.openDialog", #selector(openDialog)),
            ("Close Primary", "fixture.closePrimary", #selector(closePrimary)),
            ("Close Second", "fixture.closeSecond", #selector(closeSecond)),
            ("Close Dialog", "fixture.closeDialog", #selector(closeDialog)),
            ("Minimize Primary", "fixture.minimize", #selector(minimize)),
            ("Restore Primary", "fixture.restore", #selector(restore)),
            ("Hide App", "fixture.hide", #selector(hideApp)),
            ("Resize Primary", "fixture.resize", #selector(resize)),
            ("Move Primary", "fixture.move", #selector(move)),
            ("Primary to Next Display", "fixture.nextDisplay", #selector(nextDisplay)),
            ("Second to Next Display", "fixture.secondNextDisplay", #selector(secondNextDisplay)),
            ("Overlap Forbidden Window", "fixture.overlap", #selector(overlap)),
            ("Overlap App Windows", "fixture.overlapOwnWindows", #selector(overlapOwnWindows)),
            ("Toggle Animation", "fixture.animation", #selector(toggleAnimation)),
            ("Toggle Tone", "fixture.tone", #selector(toggleTone)),
            ("Quit Fixture", "fixture.quit", #selector(quit))
        ]
        for (title, identifier, action) in items {
            let button = NSButton(title: title, target: self, action: action)
            button.setAccessibilityIdentifier(identifier)
            stack.addArrangedSubview(button)
        }
        controls.contentView = stack
        openPrimary()
        if !isB { openSecond() }
        controls.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func makeWindow(_ role: String, frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.tabbingMode = .disallowed
        window.title = "Fixture \(name) \(role)"
        window.setAccessibilityIdentifier("fixture.\(role.lowercased())")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = MarkerView(role: isB ? "forbidden" : role.lowercased())
        window.orderFront(nil)
        return window
    }
    @objc private func openPrimary() {
        if let primary, primary.isVisible { primary.orderFront(nil); return }
        primary = makeWindow("Primary", frame: NSRect(x: 430, y: 220, width: 500, height: 340))
    }
    @objc private func openSecond() {
        if let second, second.isVisible { second.orderFront(nil); return }
        second = makeWindow("Second", frame: NSRect(x: 960, y: 260, width: 300, height: 240))
    }
    @objc private func openDialog() {
        if let dialog, dialog.isVisible { dialog.orderFront(nil); return }
        dialog = makeWindow("Dialog", frame: NSRect(x: 700, y: 100, width: 250, height: 160))
        if let primary, let dialog { primary.addChildWindow(dialog, ordered: .above) }
    }
    @objc private func closePrimary() { primary?.close(); primary = nil }
    @objc private func closeSecond() { second?.close(); second = nil }
    @objc private func closeDialog() { dialog?.close(); dialog = nil }
    @objc private func minimize() { primary?.miniaturize(nil) }
    @objc private func restore() { primary?.deminiaturize(nil); primary?.orderFront(nil) }
    @objc private func hideApp() { NSApplication.shared.hide(nil) }
    @objc private func resize() {
        guard let primary else { return }
        resizeLarge.toggle()
        primary.setContentSize(resizeLarge ? NSSize(width: 720, height: 240) : NSSize(width: 500, height: 340))
    }
    @objc private func move() {
        guard let primary else { return }
        primary.setFrameOrigin(NSPoint(x: primary.frame.minX > 500 ? 430 : 530, y: 220))
    }
    private func moveToNextDisplay(_ window: NSWindow?) {
        guard let window, NSScreen.screens.count > 1 else { return }
        let index = NSScreen.screens.firstIndex(where: { $0 === window.screen }) ?? 0
        let next = NSScreen.screens[(index + 1) % NSScreen.screens.count]
        window.setFrameOrigin(NSPoint(x: next.visibleFrame.minX + 60, y: next.visibleFrame.minY + 80))
    }
    @objc private func nextDisplay() { moveToNextDisplay(primary) }
    @objc private func secondNextDisplay() { moveToNextDisplay(second) }
    @objc private func overlap() {
        guard let primary else { return }
        primary.setFrameOrigin(NSPoint(x: 470, y: 250))
        primary.orderFrontRegardless()
    }
    @objc private func overlapOwnWindows() {
        guard let primary, let second else { return }
        primary.setFrameOrigin(NSPoint(x: 430, y: 220))
        second.setFrame(NSRect(x: 560, y: 270, width: primary.frame.width, height: primary.frame.height), display: true)
        second.makeKeyAndOrderFront(nil)
    }
    func windowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        focusedWindow.stringValue = "Focused: \(window.title)"
    }
    @objc private func toggleAnimation() {
        animate.toggle()
        animationTimer?.invalidate()
        animationTimer = nil
        guard animate else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick += 1
            for window in [self.primary, self.second, self.dialog] {
                guard let view = window?.contentView as? MarkerView else { continue }
                view.tick = self.tick
                view.needsDisplay = true
            }
        }
    }
    @objc private func toggleTone() {
        if tonePlaying { player.stop(); engine.stop(); tonePlaying = false; return }
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            if !engine.attachedNodes.contains(player) {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
            }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            buffer.frameLength = buffer.frameCapacity
            // Integer frequencies make the one-second looping buffer phase continuous.
            for frame in 0..<Int(buffer.frameLength) {
                let t = Double(frame) / 48_000
                let sample = isB ? 0.18 * sin(2 * .pi * 880 * t)
                    : 0.12 * sin(2 * .pi * 440 * t) + 0.08 * sin(2 * .pi * 660 * t)
                for channel in 0..<2 { buffer.floatChannelData![channel][frame] = Float(sample) }
            }
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            tonePlaying = true
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Fixture tone failed"
            alert.runModal()
        }
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { animationTimer?.invalidate(); engine.stop() }
}

final class MarkerView: NSView {
    let role: String
    var tick = 0
    init(role: String) { self.role = role; super.init(frame: .zero); setAccessibilityIdentifier("fixture.marker.\(role)") }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor
        switch role {
        case "primary": color = NSColor(srgbRed: 0.05, green: 0.85, blue: 0.1, alpha: 1)
        case "second": color = NSColor(srgbRed: 0.05, green: 0.85, blue: 0.85, alpha: 1)
        case "dialog": color = NSColor(srgbRed: 0.95, green: 0.55, blue: 0.05, alpha: 1)
        default: color = NSColor(srgbRed: 0.9, green: 0.05, blue: 0.9, alpha: 1)
        }
        color.setFill()
        bounds.fill()
        // Dark, narrow stripes prove geometry without obscuring the color marker.
        NSColor.black.setFill()
        for x in stride(from: 0, through: Int(bounds.width), by: 64) {
            NSRect(x: x + tick % 12, y: 0, width: 3, height: Int(bounds.height)).fill()
        }
        let label = role == "forbidden" ? "FORBIDDEN APP B" : "TARGET A \(role.uppercased())"
        (label as NSString).draw(at: NSPoint(x: 20, y: 35), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.black
        ])
    }
}
