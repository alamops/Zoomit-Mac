import AppKit
import Carbon.HIToolbox

@MainActor
enum RecordingHotkeySelfTests {
    static func run() throws {
        // Every customized Option/Shift base must yield four distinct bindings.
        let shift = NSEvent.ModifierFlags.shift.rawValue
        let option = NSEvent.ModifierFlags.option.rawValue
        for base in [NSEvent.ModifierFlags.control.rawValue,
                     NSEvent.ModifierFlags.command.rawValue] {
            for toggles in [UInt(0), shift, option, shift | option] {
                var settings = AppSettings.defaults
                settings.recordHotKeyModifiers = base | toggles
                settings.recordHotKeyCode = 23
                let recording = HotkeyBindings.all(settings: settings).filter { $0.group == .record }
                try require(recording.count == 4, "all four recording scopes registered")
                let expected: [UInt32: UInt] = [8: base | toggles, 9: (base | toggles) ^ shift,
                                              19: (base | toggles) ^ option, 20: (base | toggles) ^ shift ^ option]
                for binding in recording {
                    try require(binding.keyCode == 23 && binding.modifiers == expected[binding.id], "customized base must use XOR for \(binding.actionName)")
                }
                try require(Set(recording.map(\.modifiers)).count == 4, "modified base retains distinct scopes")
            }
        }
        let defaults = HotkeyBindings.registrationPlan(settings: .defaults)
        try require(defaults.bindings.filter { $0.group == .record }.count == 4 && defaults.issues.isEmpty,
                    "defaults register all recording shortcuts without displacing existing features")
        // Test both Settings edit directions against each effective variant.
        for id: UInt32 in [8, 9, 19, 20] {
            var settings = AppSettings.defaults
            let target = HotkeyBindings.all(settings: settings).first { $0.id == id }!
            settings.drawHotKeyCode = target.keyCode
            settings.drawHotKeyModifiers = target.modifiers
            let fromRecord = HotkeyBindings.conflict(settings: settings, editedGroup: .record)
            let fromDraw = HotkeyBindings.conflict(settings: settings, editedGroup: .draw)
            try require(fromRecord?.0.id == id && fromRecord?.1.group == .draw,
                        "record edit must detect \(target.actionName) collision")
            try require(fromDraw?.0.group == .draw && fromDraw?.1.id == id,
                        "other feature edit must detect \(target.actionName) collision")
            let plan = HotkeyBindings.registrationPlan(settings: settings)
            try require(plan.bindings.contains { $0.group == .draw }, "upgraded settings preserve existing Draw action")
            try require(!plan.bindings.contains { $0.id == id }, "colliding recorder variant cannot claim registration")
            try require(plan.issues.contains { $0.contains(target.actionName) && $0.contains("Draw") }, "collision must explain exact unavailable action")
            try require(HotkeyBindings.conflict(settings: settings, editedGroup: .breakTimer) == nil,
                        "unrelated historic collision must remain repairable")
        }
        var navigationCollision = AppSettings.defaults
        navigationCollision.recordHotKeyCode = 126
        navigationCollision.recordHotKeyModifiers = option
        try require(HotkeyBindings.conflict(settings: navigationCollision, editedGroup: .record)?.1.group == .navigation,
                    "validation includes live-navigation shortcuts")
        try navigationPrecedence()
        var siblingCollision = AppSettings.defaults
        siblingCollision.snipHotKeyCode = siblingCollision.recordHotKeyCode
        siblingCollision.snipHotKeyModifiers = siblingCollision.recordHotKeyModifiers ^ option ^ shift
        try require(HotkeyBindings.conflict(settings: siblingCollision, editedGroup: .snip) != nil,
                    "derived save-snip collision must be checked")
        let values = HotkeyBindings.all(settings: .defaults, includeNavigation: true)
        try require(Set(values.map(\.id)).count == values.count, "dispatch identifiers are unique")
        #if ZOOMIT_APP_STORE
        try require(!values.contains { $0.group == .demoType }, "App Store bindings exclude DemoType")
        #else
        var enabledDemo = AppSettings.defaults
        enabledDemo.demoTypeHotKeyCode = 49
        try require(HotkeyBindings.all(settings: enabledDemo).filter { $0.group == .demoType }.count == 2,
                    "standard distribution retains DemoType modifier variant")
        #endif
    }

    private static func navigationPrecedence() throws {
        let shift = NSEvent.ModifierFlags.shift.rawValue
        let option = NSEvent.ModifierFlags.option.rawValue
        for (keyCode, navigationName) in [(Int(kVK_UpArrow), "Live Zoom In"),
                                           (Int(kVK_DownArrow), "Live Zoom Out")] {
            for base in [UInt(0), shift] {
                var settings = AppSettings.defaults
                settings.recordHotKeyCode = keyCode
                settings.recordHotKeyModifiers = base
                let blockedID: UInt32 = base == 0 ? 19 : 20
                let allowedID: UInt32 = base == 0 ? 20 : 19
                let blockedName = base == 0 ? "Record Window" : "Record Application"
                let plan = HotkeyBindings.registrationPlan(settings: settings)
                try require(!plan.bindings.contains { $0.id == blockedID },
                            "new \(blockedName) variant must reserve \(navigationName)")
                try require([UInt32(8), 9, allowedID].allSatisfy { id in plan.bindings.contains { $0.id == id } },
                            "reserving navigation must preserve the other recording variants")
                try require(plan.issues.count == 1 && plan.issues[0].contains(blockedName) && plan.issues[0].contains(navigationName),
                            "registration must explain which new variant conflicts with live navigation")
                try require(!plan.bindings.contains { $0.group == .navigation },
                            "reserved navigation must remain conditional on Live Zoom")
                let conflict = HotkeyBindings.conflict(settings: settings, editedGroup: .record)
                try require(conflict?.0.id == blockedID && conflict?.1.actionName == navigationName,
                            "Settings and startup must agree on navigation precedence")
            }
            // Existing saved shortcuts keep their historical behavior; only
            // the new window/application variants acquire this reservation.
            for base in [option, option | shift] {
                var settings = AppSettings.defaults
                settings.recordHotKeyCode = keyCode
                settings.recordHotKeyModifiers = base
                let plan = HotkeyBindings.registrationPlan(settings: settings)
                try require(plan.bindings.filter { $0.group == .record }.count == 4 && plan.issues.isEmpty,
                            "historical screen/region navigation collisions must remain unchanged")
            }
            var settings = AppSettings.defaults
            settings.drawHotKeyCode = keyCode
            settings.drawHotKeyModifiers = option
            let plan = HotkeyBindings.registrationPlan(settings: settings)
            try require(plan.bindings.contains { $0.group == .draw } && plan.issues.isEmpty,
                        "historical non-recording navigation collisions must remain unchanged")
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SelfTestError.failure("Recording hotkeys: \(message)") }
    }
}
