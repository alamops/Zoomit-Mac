import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var appController: AppController?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstance.claim() else {
            NSApplication.shared.terminate(nil)
            return
        }

        ZoomItAppIcon.apply()

        let settingsStore = UserDefaultsSettingsStore()
        let savedSettings = settingsStore.load()
        if settingsStore.hasLaunchAtLoginPreference {
            LaunchAtLogin.applySavedPreference(savedSettings.launchAtLogin)
        } else if LaunchAtLogin.isEnabledOrPending {
            var migratedSettings = savedSettings
            migratedSettings.launchAtLogin = true
            settingsStore.save(migratedSettings)
        }
        let permissionService = SystemPermissionService()
        let userSelectedResourceAccess = UserDefaultsUserSelectedResourceAccess()
        let displayManager = SystemDisplayManager()
        let captureService = ScreenCaptureKitCaptureService(displayManager: displayManager)
        let overlayController = OverlayWindowController(userSelectedResourceAccess: userSelectedResourceAccess)
        let annotationController = AnnotationController()
        let viewportController = ZoomViewportController()

        let modeCoordinator = ModeCoordinator(
            settingsStore: settingsStore,
            permissionService: permissionService,
            displayManager: displayManager,
            captureService: captureService,
            overlayController: overlayController,
            annotationController: annotationController,
            viewportController: viewportController,
            userSelectedResourceAccess: userSelectedResourceAccess
        )

        let hotkeyService = HotkeyService(settingsStore: settingsStore) { command in
            Task { @MainActor in
                modeCoordinator.handle(command)
            }
        }

        // Register Control+Up/Down zoom hotkeys only while live zoom is active.
        modeCoordinator.onBeginLiveZoomNavigation = { [weak hotkeyService] in
            hotkeyService?.beginLiveZoomNavigation()
        }
        modeCoordinator.onEndLiveZoomNavigation = { [weak hotkeyService] in
            hotkeyService?.endLiveZoomNavigation()
        }

        appController = AppController(
            settingsStore: settingsStore,
            permissionService: permissionService,
            hotkeyService: hotkeyService,
            modeCoordinator: modeCoordinator,
            userSelectedResourceAccess: userSelectedResourceAccess
        )

        installMainMenu(controller: appController!)
        statusItem = makeStatusItem(controller: appController!)
        modeCoordinator.onRecordingSessionStateChanged = { [weak self] state in
            self?.updateRecordingMenu(state)
        }
        updateRecordingMenu(modeCoordinator.recordingSessionState)
        hotkeyService.start()

        // On a fresh install, open Settings so the user has a clear entry point
        // instead of a silent menu-bar-only launch (issue #21). Upgrading users
        // are detected as returning by hasCompletedFirstLaunch, so they don't get
        // an unexpected pop-up. Persist the flag either way so later launches no
        // longer depend on the legacy migration sentinel.
        if !settingsStore.hasCompletedFirstLaunch {
            appController?.showSettings()
        }
        settingsStore.markFirstLaunchCompleted()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        SingleInstance.release()
    }

    /// AppKit routes Command-A/C/X/V through the main menu's responder-chain
    /// actions. A status menu alone leaves native text fields and save panels
    /// without those editing commands when our ordinary windows are active.
    private func installMainMenu(controller: AppController) {
        let main = NSMenu()
        let application = NSMenuItem()
        let applicationMenu = NSMenu(title: "ZoomIt")
        let settings = NSMenuItem(title: "Settings…", action: #selector(AppController.showSettings), keyEquivalent: ",")
        settings.target = controller
        applicationMenu.addItem(settings)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit ZoomIt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = applicationMenu
        main.addItem(application)

        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        main.addItem(edit)
        NSApp.mainMenu = main
    }

    /// Swaps the menu-bar icon for a red record indicator while recording.
    private func updateRecordingIndicator(_ recording: Bool) {
        guard let button = statusItem?.button else { return }
        if recording {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")?
                .withSymbolConfiguration(config)
            image?.size = NSSize(width: Self.menuBarIconGlyph, height: Self.menuBarIconGlyph)
            button.image = image
        } else {
            button.image = Self.menuBarIcon()
        }
    }

    private func updateRecordingMenu(_ state: RecordingSessionState) {
        updateRecordingIndicator(state.isRecording || state.phase == .stopping)
        let status: String
        switch state.phase {
        case .idle: status = "Ready to record"
        case .selecting: status = "Choose a recording target…"
        case .starting: status = "Starting recording…"
        case .recording:
            let name = state.scope?.displayName ?? "Screen"
            status = state.availability == .available ? "Recording \(name)" : "Recording \(name) — target unavailable; recording blank content"
        case .stopping: status = "Finishing recording…"
        case .editing: status = "Editing recording"
        case .saving: status = "Saving recording…"
        }
        statusItem?.button?.toolTip = status
        statusItem?.button?.setAccessibilityIdentifier("recording.statusIndicator")
        statusItem?.button?.setAccessibilityLabel("ZoomIt: \(status)")
        guard let menu = statusItem?.menu else { return }
        for item in menu.items {
            switch item.action {
            case #selector(AppController.toggleRecording), #selector(AppController.toggleRecordingRegion),
                 #selector(AppController.toggleRecordingWindow), #selector(AppController.toggleRecordingApplication):
                item.isEnabled = state.canStart
            case #selector(AppController.stopRecording): item.isEnabled = state.canStop
            default: break
            }
            if item.identifier?.rawValue == "recording.status" { item.title = status }
        }
    }

    private func makeStatusItem(controller: AppController) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Intentionally no autosaveName: persisting an absolute menu-bar slot makes
        // AppKit re-assert that position on every relaunch/relayout, which fights
        // menu-bar managers like Bartender and Ice (the icon snaps back out of their
        // "shown" section). Letting the system place the item keeps ZoomIt compatible
        // with those tools; users can still Command-drag it to reorder.
        // Use the Windows ZoomIt icon (document with a magnifying glass) rendered
        // as a black template image so it tints to match the menu bar, following
        // the macOS convention for menu-bar icons.
        if let button = item.button {
            if let image = Self.menuBarIcon() {
                button.image = image
            } else {
                button.title = "ZoomIt"
            }
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in Self.statusMenuEntries() {
            if entry.isSeparator {
                menu.addItem(.separator())
            } else {
                let menuItem = NSMenuItem(title: entry.title, action: entry.action, keyEquivalent: entry.keyEquivalent)
                let identifier: String?
                switch entry.action {
                case #selector(AppController.toggleRecording): identifier = "recording.recordScreen"
                case #selector(AppController.toggleRecordingRegion): identifier = "recording.recordRegion"
                case #selector(AppController.toggleRecordingWindow): identifier = "recording.recordWindow"
                case #selector(AppController.toggleRecordingApplication): identifier = "recording.recordApplication"
                case #selector(AppController.stopRecording): identifier = "recording.stop"
                default: identifier = nil
                }
                if let identifier {
                    menuItem.identifier = NSUserInterfaceItemIdentifier(identifier)
                    menuItem.setAccessibilityIdentifier(identifier)
                }
                menu.addItem(menuItem)
            }
        }

        for item in menu.items {
            item.target = controller
        }

        let recordingStatus = NSMenuItem(title: "Ready to record", action: nil, keyEquivalent: "")
        recordingStatus.identifier = NSUserInterfaceItemIdentifier("recording.status")
        recordingStatus.setAccessibilityIdentifier("recording.status")
        recordingStatus.isEnabled = false
        if let index = menu.items.firstIndex(where: { $0.action == #selector(AppController.toggleRecording) }) {
            menu.insertItem(recordingStatus, at: index)
        }
        item.menu = menu
        return item
    }

    /// A single status-bar menu entry (or a separator when `action` is nil).
    struct StatusMenuEntry {
        let title: String
        let action: Selector?
        let keyEquivalent: String

        var isSeparator: Bool { action == nil }

        static let separator = StatusMenuEntry(title: "", action: nil, keyEquivalent: "")

        init(title: String, action: Selector?, keyEquivalent: String) {
            self.title = title
            self.action = action
            self.keyEquivalent = keyEquivalent
        }
    }

    /// The status-bar menu. It broadly follows the Windows ZoomIt tray order
    /// (Options first, then the modes, then Check Permissions and Quit), with
    /// Panorama Capture as a macOS-only addition after Record and the Break
    /// Timer placed at the end of the mode group (below Panorama Capture).
    static func statusMenuEntries() -> [StatusMenuEntry] {
        [
            StatusMenuEntry(title: "Settings…", action: #selector(AppController.showSettings), keyEquivalent: ","),
            .separator,
            StatusMenuEntry(title: "Draw", action: #selector(AppController.activateDrawWithoutZoom), keyEquivalent: ""),
            StatusMenuEntry(title: "Static Zoom", action: #selector(AppController.activateStaticZoom), keyEquivalent: ""),
            StatusMenuEntry(title: "Live Zoom", action: #selector(AppController.activateLiveZoom), keyEquivalent: ""),
            StatusMenuEntry(title: "Record Screen", action: #selector(AppController.toggleRecording), keyEquivalent: ""),
            StatusMenuEntry(title: "Record Region…", action: #selector(AppController.toggleRecordingRegion), keyEquivalent: ""),
            StatusMenuEntry(title: "Record Window…", action: #selector(AppController.toggleRecordingWindow), keyEquivalent: ""),
            StatusMenuEntry(title: "Record Application…", action: #selector(AppController.toggleRecordingApplication), keyEquivalent: ""),
            StatusMenuEntry(title: "Stop Recording", action: #selector(AppController.stopRecording), keyEquivalent: ""),
            StatusMenuEntry(title: "Panorama Capture", action: #selector(AppController.startPanorama), keyEquivalent: ""),
            StatusMenuEntry(title: "DemoMirror", action: #selector(AppController.toggleDemoMirror), keyEquivalent: ""),
            StatusMenuEntry(title: "Break Timer", action: #selector(AppController.toggleBreakTimer), keyEquivalent: ""),
            .separator,
            StatusMenuEntry(title: "Check Permissions", action: #selector(AppController.checkPermissions), keyEquivalent: ""),
            StatusMenuEntry(title: "Quit", action: #selector(AppController.quit), keyEquivalent: "q")
        ]
    }

    /// Loads the bundled black template version of the Windows ZoomIt icon and
    /// sizes it for the menu bar. As a template image it is tinted by the system
    /// (black on a light menu bar, white on a dark one).
    private static func menuBarIcon() -> NSImage? {
        guard let source = loadZoomItIcon() else { return nil }
        return Self.menuBarImage(from: source)
    }

    /// The square point size of the menu-bar item's image slot.
    static let menuBarIconCanvas: CGFloat = 18
    /// The glyph is drawn smaller than the canvas so ZoomIt's icon carries the
    /// same interior padding as system menu-bar icons; a full-bleed image made
    /// it look oversized and misaligned next to them.
    static let menuBarIconGlyph: CGFloat = 15

    /// Renders `source` centered inside a padded, square template image so it
    /// matches the size and vertical alignment of other menu-bar icons.
    static func menuBarImage(from source: NSImage) -> NSImage {
        let canvas = NSSize(width: menuBarIconCanvas, height: menuBarIconCanvas)
        let image = NSImage(size: canvas)
        image.lockFocus()
        let rect = NSRect(
            x: (canvas.width - menuBarIconGlyph) / 2,
            y: (canvas.height - menuBarIconGlyph) / 2,
            width: menuBarIconGlyph,
            height: menuBarIconGlyph
        )
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func loadZoomItIcon() -> NSImage? {
        ZoomItAppIcon.loadTemplateIcon()
    }
}
