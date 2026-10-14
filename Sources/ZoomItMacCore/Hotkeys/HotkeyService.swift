import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyService {
    private let settingsStore: SettingsStore
    private let commandHandler: (AppCommand) -> Void
    private var registeredRefs: [UInt32: EventHotKeyRef] = [:]
    private(set) var registrationIssues: [String] = []
    private var zoomInNavRef: EventHotKeyRef?
    private var zoomOutNavRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init(settingsStore: SettingsStore, commandHandler: @escaping (AppCommand) -> Void) {
        self.settingsStore = settingsStore
        self.commandHandler = commandHandler
    }

    func start() {
        installEventHandlerIfNeeded()
        registerHotKey()
    }

    /// Re-registers the global hotkey from the latest saved settings. Call this
    /// after the user changes the shortcut in the settings dialog.
    func reloadHotkey() {
        registerHotKey()
    }

    func stop() {
        unregisterHotKey()
        endLiveZoomNavigation()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        eventHandlerRef = nil
    }

    /// Registers Option+Up / Option+Down as global hotkeys for the duration of
    /// live zoom so they zoom in and out. They are registered globally (rather
    /// than handled by the overlay) so they fire even though the overlay is the
    /// key window. Option+arrows is used instead of Control+arrows because macOS
    /// reserves Control+Up/Down for Mission Control / App Exposé and will not
    /// yield them to a registered hotkey.
    func beginLiveZoomNavigation() {
        installEventHandlerIfNeeded()
        let target = GetApplicationEventTarget()
        let signature = fourCharacterCode("ZITM")

        endLiveZoomNavigation()
        guard eventHandlerRef != nil else { return }
        registrationIssues.removeAll { $0.hasPrefix("Live Zoom In could not register") || $0.hasPrefix("Live Zoom Out could not register") }
        let upStatus = RegisterEventHotKey(UInt32(kVK_UpArrow), UInt32(optionKey),
                                           EventHotKeyID(signature: signature, id: 4), target, 0, &zoomInNavRef)
        let downStatus = RegisterEventHotKey(UInt32(kVK_DownArrow), UInt32(optionKey),
                                             EventHotKeyID(signature: signature, id: 5), target, 0, &zoomOutNavRef)
        if upStatus != noErr || zoomInNavRef == nil {
            registrationIssues.append("Live Zoom In could not register Option+Up (macOS error \(upStatus)). Check shortcut assignments in Settings.")
        }
        if downStatus != noErr || zoomOutNavRef == nil {
            registrationIssues.append("Live Zoom Out could not register Option+Down (macOS error \(downStatus)). Check shortcut assignments in Settings.")
        }
        HotkeyRegistrationDiagnostics.issues = registrationIssues
    }

    func endLiveZoomNavigation() {
        if let zoomInNavRef {
            UnregisterEventHotKey(zoomInNavRef)
        }
        zoomInNavRef = nil
        if let zoomOutNavRef {
            UnregisterEventHotKey(zoomOutNavRef)
        }
        zoomOutNavRef = nil
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }

                var hotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard parameterStatus == noErr else { return parameterStatus }

                let command: AppCommand
                switch hotKeyID.id {
                case 1: command = .activateStaticZoom
                case 2: command = .activateDrawWithoutZoom
                case 3: command = .activateLiveZoom
                case 4: command = .zoomIn
                case 5: command = .zoomOutOrExit
                case 6: command = .snipRegion(save: false)
                case 7: command = .snipRegion(save: true)
                case 8: command = .toggleRecording(scope: .screen)
                case 9: command = .toggleRecording(scope: .region)
                case 10: command = .startPanorama(save: false)
                case 11: command = .startPanorama(save: true)
                case 12: command = .toggleBreakTimer
                case 13: command = .snipOcr
                #if !ZOOMIT_APP_STORE
                case 14: command = .startDemoType
                case 15: command = .resetDemoType
                #endif
                case 16: command = .toggleDemoMirror(scope: .screen)
                case 17: command = .toggleDemoMirror(scope: .region)
                case 18: command = .toggleDemoMirror(scope: .window)
                case 19: command = .toggleRecording(scope: .window)
                case 20: command = .toggleRecording(scope: .application)
                default: return noErr
                }

                let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    service.commandHandler(command)
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )
        if status != noErr {
            registrationIssues = ["Global shortcuts are unavailable (macOS event handler error \(status)). Restart ZoomIt or use the menu actions."]
            HotkeyRegistrationDiagnostics.issues = registrationIssues
        }
    }

    private func registerHotKey() {
        unregisterHotKey()
        let plan = HotkeyBindings.registrationPlan(settings: settingsStore.load())
        registrationIssues = plan.issues
        if eventHandlerRef == nil {
            registrationIssues.append("Global shortcut handling is unavailable. Restart ZoomIt or use the menu actions.")
            HotkeyRegistrationDiagnostics.issues = registrationIssues
            return
        }
        let target = GetApplicationEventTarget()
        let signature = fourCharacterCode("ZITM")
        for binding in plan.bindings {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(clamping: binding.keyCode),
                                            carbonModifiers(from: NSEvent.ModifierFlags(rawValue: binding.modifiers)),
                                            EventHotKeyID(signature: signature, id: binding.id), target, 0, &reference)
            if status == noErr, let reference {
                registeredRefs[binding.id] = reference
            } else {
                registrationIssues.append("\(binding.actionName) could not register its global shortcut (macOS error \(status)). Choose another shortcut in Settings; its menu action remains available.")
            }
        }
        HotkeyRegistrationDiagnostics.issues = registrationIssues
    }

    private func unregisterHotKey() {
        for reference in registeredRefs.values { UnregisterEventHotKey(reference) }
        registeredRefs.removeAll()
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}

private func fourCharacterCode(_ string: String) -> OSType {
    string.utf8.reduce(0) { code, character in
        (code << 8) + OSType(character)
    }
}