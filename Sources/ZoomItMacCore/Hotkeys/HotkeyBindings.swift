import AppKit
import Carbon.HIToolbox

struct HotkeyBinding: Equatable, Sendable {
    enum Group: String, Sendable { case zoom, draw, live, snip, snipOcr, record, demoType, panorama, breakTimer, demoMirror, navigation }
    let id: UInt32
    let group: Group
    let actionName: String
    let keyCode: Int
    let modifiers: UInt
    let isNewRecordingVariant: Bool

    func conflicts(with other: HotkeyBinding) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

/// One binding map drives both registration and Settings validation, including
/// every derived shortcut. Shift/Option toggle relative to the stored base.
enum HotkeyBindings {
    static func all(settings: AppSettings, includeNavigation: Bool = false) -> [HotkeyBinding] {
        let mask = NSEvent.ModifierFlags([.command, .control, .option, .shift]).rawValue
        let shift = NSEvent.ModifierFlags.shift.rawValue
        let option = NSEvent.ModifierFlags.option.rawValue
        func binding(_ id: UInt32, _ group: HotkeyBinding.Group, _ name: String, _ code: Int, _ mods: UInt, _ toggle: UInt = 0, new: Bool = false) -> HotkeyBinding {
            HotkeyBinding(id: id, group: group, actionName: name, keyCode: code,
                          modifiers: (mods ^ toggle) & mask, isNewRecordingVariant: new)
        }
        // Existing registration order is retained, and new variants follow every
        // existing action so an upgraded preference never displaces one.
        var values = [
            binding(1, .zoom, "Static Zoom", settings.hotKeyCode, settings.hotKeyModifiers),
            binding(2, .draw, "Draw", settings.drawHotKeyCode, settings.drawHotKeyModifiers),
            binding(3, .live, "Live Zoom", settings.liveHotKeyCode, settings.liveHotKeyModifiers),
            binding(6, .snip, "Copy Region", settings.snipHotKeyCode, settings.snipHotKeyModifiers),
            binding(7, .snip, "Save Region", settings.snipHotKeyCode, settings.snipHotKeyModifiers, shift)
        ]
        if settings.snipOcrHotKeyCode != 0 {
            values.append(binding(13, .snipOcr, "Recognize Text", settings.snipOcrHotKeyCode, settings.snipOcrHotKeyModifiers))
        }
        values += [
            binding(8, .record, "Record Screen", settings.recordHotKeyCode, settings.recordHotKeyModifiers),
            binding(9, .record, "Record Region", settings.recordHotKeyCode, settings.recordHotKeyModifiers, shift)
        ]
        #if !ZOOMIT_APP_STORE
        if settings.demoTypeHotKeyCode != 0 {
            values += [binding(14, .demoType, "DemoType", settings.demoTypeHotKeyCode, settings.demoTypeHotKeyModifiers),
                       binding(15, .demoType, "Reset DemoType", settings.demoTypeHotKeyCode, settings.demoTypeHotKeyModifiers, shift)]
        }
        #endif
        values += [
            binding(10, .panorama, "Copy Panorama", settings.panoramaHotKeyCode, settings.panoramaHotKeyModifiers),
            binding(11, .panorama, "Save Panorama", settings.panoramaHotKeyCode, settings.panoramaHotKeyModifiers, shift),
            binding(12, .breakTimer, "Break Timer", settings.breakHotKeyCode, settings.breakHotKeyModifiers),
            binding(16, .demoMirror, "Mirror Screen", settings.demoMirrorHotKeyCode, settings.demoMirrorHotKeyModifiers),
            binding(17, .demoMirror, "Mirror Region", settings.demoMirrorHotKeyCode, settings.demoMirrorHotKeyModifiers, shift),
            binding(18, .demoMirror, "Mirror Window", settings.demoMirrorHotKeyCode, settings.demoMirrorHotKeyModifiers, option),
            binding(19, .record, "Record Window", settings.recordHotKeyCode, settings.recordHotKeyModifiers, option, new: true),
            binding(20, .record, "Record Application", settings.recordHotKeyCode, settings.recordHotKeyModifiers, shift ^ option, new: true)
        ]
        if includeNavigation {
            values += [binding(4, .navigation, "Live Zoom In", Int(kVK_UpArrow), option),
                       binding(5, .navigation, "Live Zoom Out", Int(kVK_DownArrow), option)]
        }
        return values
    }

    /// Only conflicts involving the edited group block a change. Unrelated
    /// pre-existing collisions remain repairable without resetting preferences.
    static func conflict(settings: AppSettings, editedGroup: HotkeyBinding.Group) -> (HotkeyBinding, HotkeyBinding)? {
        let bindings = all(settings: settings, includeNavigation: true)
        for candidate in bindings where candidate.group == editedGroup {
            if let other = bindings.first(where: { $0.id != candidate.id && $0.conflicts(with: candidate) }) {
                return (candidate, other)
            }
        }
        return nil
    }

    static func registrationPlan(settings: AppSettings) -> (bindings: [HotkeyBinding], issues: [String]) {
        var accepted: [HotkeyBinding] = []
        var issues: [String] = []
        for candidate in all(settings: settings) {
            if let previous = accepted.first(where: { $0.conflicts(with: candidate) }) {
                issues.append("\(candidate.actionName) is unavailable because its shortcut is assigned to \(previous.actionName). Change either shortcut in Settings; the menu action remains available.")
            } else { accepted.append(candidate) }
        }
        return (accepted, issues)
    }
}

@MainActor
enum HotkeyRegistrationDiagnostics {
    static var issues: [String] = []
}
