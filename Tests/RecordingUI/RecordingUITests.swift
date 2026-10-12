import AppKit
import XCTest

/// All recordings are made through the shipped UI and Apple's actual picker.
/// Missing capture/automation permission or display prerequisites fail with
/// artifacts; these tests never replace OS authorization with a constructed filter.
final class RecordingUITests: XCTestCase {
    private var environment: RecordingTestEnvironment!
    private var recorder: XCUIApplication!
    private var a: XCUIApplication!
    private var b: XCUIApplication!
    private var picker: NativePickerDriver!
    private var startedAt = Date()

    override func setUpWithError() throws {
        continueAfterFailure = false
        environment = try RecordingTestEnvironment()
        recorder = environment.recorder(); a = try environment.fixtureA(); b = try environment.fixtureB()
        environment.launch(b); environment.launch(a); environment.launch(recorder)
        picker = NativePickerDriver(test: self); picker.include(recorder)
        try RecordingTestEnvironment.configureRecorder(recorder)
        try ready()
    }
    override func tearDownWithError() throws {
        picker?.attachDiagnostics("\(name)-final")
        if let recorder {
            let tree = XCTAttachment(string: recorder.debugDescription)
            tree.name = "recorder-final-tree"; tree.lifetime = .keepAlways; add(tree)
        }
        for app in [recorder, a, b].compactMap({ $0 }) where app.state != .notRunning { app.terminate() }
    }
    private func ready() throws { try state(containing: "Ready to record") }
    private func state(containing text: String, timeout: TimeInterval = 15) throws {
        try RecordingTestEnvironment.wait(timeout: timeout, description: "recorder status containing \(text); allow Screen Recording and Accessibility for dedicated test bundle if authorization failed") {
            RecordingTestEnvironment.status(in: self.recorder).contains(text)
        }
    }
    private func start(_ scope: NativePickerDriver.Scope, shortcut: Bool = false) throws {
        a.activate()
        if shortcut {
            let flags: XCUIElement.KeyModifierFlags = scope == .window ? [.control, .option] : [.control, .option, .shift]
            a.typeKey("5", modifierFlags: flags)
        } else {
            try RecordingTestEnvironment.menuAction(scope == .window ? "recording.recordWindow" : "recording.recordApplication", in: recorder)
        }
        try state(containing: "Choose a recording target")
        try picker.select(scope: scope, targetApp: a, windowTitle: "Fixture A Primary") {
            let status = RecordingTestEnvironment.status(in: self.recorder)
            return status.contains("Starting recording") || status.contains(scope == .window ? "Recording Window" : "Recording Application")
        }
        try state(containing: scope == .window ? "Recording Window" : "Recording Application")
        startedAt = Date()
        try hold(0.8)
        XCTAssertFalse(RecordingTestEnvironment.status(in: recorder).contains("unavailable"), "New visible authorized target must deliver source frames")
    }
    private func hold(_ seconds: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(seconds)
        try RecordingTestEnvironment.wait(timeout: seconds + 3, description: "capture interval \(seconds)s") { Date() >= deadline }
    }
    private var elapsed: Double { Date().timeIntervalSince(startedAt) }
    private func fixture(_ identifier: String, app: XCUIApplication? = nil) throws {
        try RecordingTestEnvironment.click(identifier, in: app ?? a)
    }
    private func stop(flags: XCUIElement.KeyModifierFlags? = nil) throws {
        if let flags {
            let keyboardApp = a.state == .notRunning ? recorder! : a!
            keyboardApp.typeKey("5", modifierFlags: flags)
        }
        else { try RecordingTestEnvironment.menuAction("recording.stop", in: recorder) }
        let editor = recorder.windows["recording.editor"]
        guard editor.waitForExistence(timeout: 25) else { throw HarnessError("Manual stop failed to open recording editor exactly once. \(recorder.debugDescription)") }
        XCTAssertEqual(recorder.windows.matching(identifier: "recording.editor").count, 1)
        try state(containing: "Editing recording")
    }
    private func cancelEditor() throws {
        try RecordingTestEnvironment.click("recording.editor.cancel", in: recorder)
        try ready()
        XCTAssertFalse(recorder.windows["recording.editor"].exists)
    }
    private func save(_ label: String, trim: Bool = false) throws -> RecordedVideo {
        let editor = recorder.windows["recording.editor"]
        if trim {
            let timeline = RecordingTestEnvironment.element("recording.editor.timeline", in: recorder)
            guard timeline.waitForExistence(timeout: 5) else { throw HarnessError("Accessible real editor trim timeline missing") }
            let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 14, dy: 0))
            let destination = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            start.press(forDuration: 0.2, thenDragTo: destination)
            guard let value = timeline.value as? String, !value.hasPrefix("Trim start 0.0,") else {
                throw HarnessError("Real trim grip drag did not change selection: \(String(describing: timeline.value))")
            }
        }
        try RecordingTestEnvironment.click("recording.editor.save", in: recorder)
        let panel = recorder.dialogs.firstMatch
        guard panel.waitForExistence(timeout: 30), panel.buttons["Save"].exists else {
            throw HarnessError("Recording editor export did not open the native Save panel. \(recorder.debugDescription)")
        }
        recorder.activate()
        let url = environment.artifacts.appendingPathComponent("\(label)-\(UUID().uuidString).mp4")
        // Navigate the actual NSSavePanel. This grants the sandbox its normal
        // user-selected destination authorization, with no preference bypass.
        recorder.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = recorder.dialogs.textFields["PathTextField"]
        guard pathField.waitForExistence(timeout: 5) else { throw HarnessError("Native Go to Folder path entry missing") }
        pathField.typeKey("a", modifierFlags: [.command])
        pathField.typeText(environment.artifacts.path)
        guard pathField.value as? String == environment.artifacts.path else {
            throw HarnessError("Native path entry did not accept the requested directory. Actual: \(String(describing: pathField.value)); expected: \(environment.artifacts.path)")
        }
        pathField.typeKey(.return, modifierFlags: [])
        try RecordingTestEnvironment.wait(description: "Go to Folder accepts the export directory") { !pathField.exists }
        let nameField = recorder.dialogs.textFields.matching(NSPredicate(format: "identifier == %@ OR label == %@", "saveAsNameTextField", "Save As:")).firstMatch
        let fallback = recorder.dialogs.textFields.firstMatch
        let entry = nameField.exists ? nameField : fallback
        guard entry.waitForExistence(timeout: 5) else { throw HarnessError("Native save filename field missing") }
        entry.click()
        entry.typeKey("a", modifierFlags: [.command])
        entry.typeText(url.lastPathComponent)
        let saveButton = recorder.dialogs.buttons["Save"].firstMatch
        guard saveButton.isEnabled else { throw HarnessError("Native save destination is not writable: \(environment.artifacts.path)") }
        saveButton.click()
        try ready()
        XCTAssertFalse(editor.exists)
        guard FileManager.default.fileExists(atPath: url.path) else { throw HarnessError("Native Save did not create the requested artifact: \(url.path)") }
        let movie = try RecordedVideo(url: url); movie.attach(to: self)
        return movie
    }

    func testPickerCancelDuplicateRequestRetryAndEditorCancel() throws {
        try RecordingTestEnvironment.menuAction("recording.recordWindow", in: recorder)
        try state(containing: "Choose a recording target")
        a.typeKey("5", modifierFlags: [.control, .option, .shift])
        try state(containing: "Choose a recording target")
        picker.cancel(from: recorder)
        try ready()
        XCTAssertFalse(recorder.windows["recording.editor"].exists, "Cancelled selection must never launch an editor")
        try start(.window, shortcut: true)
        try stop(flags: [.control])
        try cancelEditor()
        try start(.application, shortcut: true)
        try stop()
        let movie = try save("cancel-retry-application")
        try movie.requireMarker("primary", above: 0.005)
        try movie.exclude(["forbidden"])
    }

    func testWindowIsolationResizeMoveAndAspectPaddingInExport() throws {
        try start(.window)
        try fixture("fixture.overlap", app: b)
        try fixture("fixture.openDialog")
        try hold(1)
        try fixture("fixture.resize")
        try fixture("fixture.move")
        let resized = elapsed
        try hold(2)
        try stop()
        let movie = try save("window-isolation-resize")
        try movie.requireMarker("primary", above: 0.25)
        try movie.exclude(["second", "dialog", "forbidden"])
        try movie.requireBlackPadding(in: max(0, resized - 0.3)...movie.duration)
        XCTAssertGreaterThan(movie.duration, 2)
        XCTAssertEqual(Int(movie.size.width) % 2, 0); XCTAssertEqual(Int(movie.size.height) % 2, 0)
    }

    func testApplicationNewWindowsDialogsAndForeignOverlapInExport() throws {
        try start(.application)
        try hold(1)
        try fixture("fixture.closeSecond")
        try fixture("fixture.openSecond")
        try fixture("fixture.openDialog")
        try fixture("fixture.overlap", app: b)
        try fixture("fixture.animation")
        try hold(2)
        try stop()
        let movie = try save("application-new-windows-dialog")
        try movie.requireMarker("primary", above: 0.005)
        try movie.requireMarker("second", above: 0.005)
        try movie.requireMarker("dialog", above: 0.003)
        try movie.exclude(["forbidden"])
    }

    func testApplicationWindowClicksChangeRecordedStackingOrder() throws {
        try start(.application)
        try fixture("fixture.overlapOwnWindows")
        try hold(1.5)
        func focus(_ title: String, x: CGFloat) throws {
            a.windows[title].coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.6)).click()
            try RecordingTestEnvironment.wait(description: "clicked app window becomes main: \(title)") {
                RecordingTestEnvironment.element("fixture.focusedWindow", in: self.a).value as? String == "Focused: \(title)"
            }
            try hold(2)
        }
        try focus("Fixture A Primary", x: 0.1)
        try focus("Fixture A Second", x: 0.9)
        try focus("Fixture A Primary", x: 0.1)
        try stop()
        let movie = try save("app-window-order")
        // Equal-size overlapping windows expose the front window's color over
        // the shared area. Read their stable ordering directly from the MP4,
        // independent of the native picker's variable pre-recording latency.
        var runs: [(String, Int)] = []
        for frame in movie.frames {
            let difference = frame.fractions["primary", default: 0] - frame.fractions["second", default: 0]
            guard abs(difference) > 0.005 else { continue }
            let front = difference > 0 ? "primary" : "second"
            if runs.last?.0 == front { runs[runs.count - 1].1 += 1 }
            else { runs.append((front, 1)) }
        }
        let stable = runs.filter { $0.1 >= 3 }.map { $0.0 }
        let expected = ["second", "primary", "second", "primary"]
        var matched = 0
        for front in stable where matched < expected.count {
            if front == expected[matched] { matched += 1 }
        }
        XCTAssertEqual(matched, expected.count,
                       "Saved video must follow each clicked app window. Observed: \(stable). \(movie.summary)")
        try movie.exclude(["forbidden"])
    }

    func testWindowMinimizeRestoreCloseReopenAndContinuousBlackTail() throws {
        try start(.window)
        try fixture("fixture.minimize")
        try state(containing: "target unavailable")
        let hidden = elapsed
        try hold(1.5)
        try fixture("fixture.restore")
        try hold(1.5)
        XCTAssertFalse(RecordingTestEnvironment.status(in: recorder).contains("unavailable"))
        let restored = elapsed
        try fixture("fixture.closePrimary")
        try state(containing: "target unavailable")
        try fixture("fixture.openPrimary")
        try hold(2.5)
        try state(containing: "target unavailable")
        XCTAssertFalse(recorder.windows["recording.editor"].exists, "Target close cannot finalize the user's clip")
        try stop(flags: [.control, .option])
        let movie = try save("window-closed-black-tail")
        try movie.requireMarker("black", above: 0.98, in: max(0, hidden - 0.3)...restored)
        try movie.requireMarker("primary", above: 0.25, in: max(0, restored - 1.0)...restored + 0.5)
        try movie.requireBlankTail(atLeast: 1.5)
        try movie.exclude(["second", "forbidden"])
    }

    func testApplicationHideRestoreQuitRelaunchDoesNotRetarget() throws {
        try start(.application)
        try fixture("fixture.hide")
        try state(containing: "target unavailable")
        try hold(1.5)
        a.activate()
        try hold(1.5)
        XCTAssertFalse(RecordingTestEnvironment.status(in: recorder).contains("unavailable"))
        a.terminate()
        try state(containing: "target unavailable")
        environment.launch(a)
        try hold(2.5)
        try state(containing: "target unavailable")
        try stop()
        let movie = try save("application-quit-black-tail")
        try movie.requireMarker("primary", above: 0.005)
        try movie.requireBlankTail(atLeast: 1.5)
        try movie.exclude(["forbidden"])
    }

    func testEveryRecordingShortcutManuallyStopsAndAllowsRepeat() throws {
        for flags: XCUIElement.KeyModifierFlags in [[.control], [.control, .shift], [.control, .option], [.control, .option, .shift]] {
            try start(.window)
            try hold(0.5)
            try stop(flags: flags)
            try cancelEditor()
        }
        try start(.application)
        try stop()
        try cancelEditor()
    }

    func testSystemPickerFromRecordingShortcutsAndCancelEditor() throws {
        // Start both modes through their global shortcuts, then exercise the
        // explicit Stop menu action. Stop shortcuts have their own test above.
        for scope: NativePickerDriver.Scope in [.window, .application] {
            try start(scope, shortcut: true)
            try stop()
            try cancelEditor()
        }
    }

    func testSelectedAppAudioRejectsOtherApplicationTonesForBothScopes() throws {
        try RecordingTestEnvironment.configureRecorder(recorder, systemAudio: true)
        try fixture("fixture.tone")
        try fixture("fixture.tone", app: b)
        XCTAssertFalse(a.alerts.firstMatch.exists); XCTAssertFalse(b.alerts.firstMatch.exists)
        for scope: NativePickerDriver.Scope in [.window, .application] {
            try start(scope)
            try hold(3)
            try stop()
            let movie = try save(scope == .window ? "window-app-audio" : "application-audio")
            try RecordedAudioAssertions.requireSelectedAppTones(in: movie.url, test: self)
            try movie.exclude(["forbidden"])
        }
    }

    private func overlay(_ key: String) throws -> XCUIElement {
        a.typeKey(key, modifierFlags: [.control])
        let canvas = RecordingTestEnvironment.element("recording.isolatedCanvas", in: recorder)
        guard canvas.waitForExistence(timeout: 8) else { throw HarnessError("Isolated \(key) overlay did not open: \(recorder.debugDescription)") }
        try hold(0.8)
        return canvas
    }
    private func stroke(_ canvas: XCUIElement, from: CGVector, to: CGVector) {
        canvas.coordinate(withNormalizedOffset: from).press(forDuration: 0.2,
            thenDragTo: canvas.coordinate(withNormalizedOffset: to))
    }
    func testIsolatedStaticLiveDrawingTypingHighlightsUndoEraseAndFrozenLoss() throws {
        try start(.window)
        try fixture("fixture.animation")
        let staticCanvas = try overlay("1")
        // Static zoom's first click arms drawing without changing its zoom.
        // All coordinates are inside the fitted isolated content.
        staticCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        recorder.typeKey("r", modifierFlags: [])
        stroke(staticCanvas, from: CGVector(dx: 0.3, dy: 0.45), to: CGVector(dx: 0.7, dy: 0.45))
        try hold(0.8)
        recorder.typeKey("y", modifierFlags: [.shift])
        stroke(staticCanvas, from: CGVector(dx: 0.3, dy: 0.55), to: CGVector(dx: 0.7, dy: 0.55))
        try hold(0.8)
        recorder.typeKey("z", modifierFlags: [.command])
        try hold(0.5)
        recorder.typeKey("e", modifierFlags: [])
        try hold(0.5)
        recorder.typeKey("w", modifierFlags: [])
        staticCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).hover()
        recorder.typeKey("t", modifierFlags: [])
        recorder.typeText("ISOLATED TEXT")
        let textStart = elapsed
        try hold(1)
        let textEnd = elapsed
        recorder.typeKey(.escape, modifierFlags: [])
        recorder.typeKey(.escape, modifierFlags: [])
        try RecordingTestEnvironment.wait(description: "static overlay Escape leaves recording active") {
            !RecordingTestEnvironment.element("recording.isolatedCanvas", in: self.recorder).exists
        }
        try state(containing: "Recording Window")
        let liveCanvas = try overlay("4")
        recorder.typeKey("2", modifierFlags: [.control])
        recorder.typeKey("r", modifierFlags: [])
        stroke(liveCanvas, from: CGVector(dx: 0.4, dy: 0.5), to: CGVector(dx: 0.6, dy: 0.5))
        try hold(1)
        // Stop-time finalization must dismiss presentation and preserve isolated
        // content, not capture the full-screen interactive host window.
        try stop(flags: [.control, .shift])
        let movie = try save("isolated-overlays-static-live")
        try movie.requireMarker("red", above: 0.0005)
        try movie.requireMarker("highlight", above: 0.0005)
        let baselineWhite = movie.frames.prefix(3).map { $0.fractions["white", default: 0] }.max() ?? 0
        let typedFrames = movie.frames.filter { (max(0, textStart - 0.4)...textEnd + 0.4).contains($0.time) }
        XCTAssertGreaterThan(typedFrames.map { $0.fractions["white", default: 0] }.max() ?? 0, baselineWhite + 0.0005,
                             "Typing must add visible white glyph pixels above the captured target/title baseline")
        try movie.requireMarker("primary", above: 0.25)
        try movie.exclude(["forbidden", "second", "dialog"])

        try start(.window)
        _ = try overlay("2")
        recorder.typeKey("r", modifierFlags: [])
        let canvas = RecordingTestEnvironment.element("recording.isolatedCanvas", in: recorder)
        stroke(canvas, from: CGVector(dx: 0.3, dy: 0.5), to: CGVector(dx: 0.7, dy: 0.5))
        try hold(1)
        // Terminate the actual fixture while its isolated presentation is
        // still frozen. XCTest's public process lifecycle closes the selected
        // window without clicking through the interactive host overlay.
        a.terminate()
        try state(containing: "target unavailable")
        try hold(2)
        try stop(flags: [.control])
        let absent = try save("isolated-frozen-loss")
        try absent.requireBlankTail(atLeast: 1.5)
        try absent.exclude(["forbidden", "second"])
    }

    func testExistingScreenOverlayIsResetBeforeIsolatedSelection() throws {
        a.activate()
        a.typeKey("2", modifierFlags: [.control])
        try hold(1)
        recorder.typeKey("r", modifierFlags: [])
        let screenOverlay = recorder.windows.firstMatch
        guard screenOverlay.waitForExistence(timeout: 5) else { throw HarnessError("Existing screen drawing overlay did not appear") }
        screenOverlay.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.45)).press(forDuration: 0.2,
            thenDragTo: screenOverlay.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45)))
        // Use the derived shortcut while the old screen overlay is active.
        recorder.typeKey("5", modifierFlags: [.control, .option])
        try state(containing: "Choose a recording target")
        try picker.select(scope: .window, targetApp: a, windowTitle: "Fixture A Primary") {
            let status = RecordingTestEnvironment.status(in: self.recorder)
            return status.contains("Starting recording") || status.contains("Recording Window")
        }
        try state(containing: "Recording Window")
        try hold(2)
        try stop()
        let movie = try save("existing-screen-overlay-reset")
        try movie.requireMarker("primary", above: 0.25)
        try movie.exclude(["forbidden", "second", "dialog"])
        try movie.exclude(["red"], tolerance: 0.0001)
    }

    func testEditorMuteAccessibilityTracksAction() throws {
        try start(.window)
        try stop()
        let mute = recorder.buttons["recording.editor.mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 5))
        XCTAssertEqual(mute.label, "Mute recording preview")
        mute.click()
        XCTAssertEqual(mute.label, "Unmute recording preview")
        mute.click()
        XCTAssertEqual(mute.label, "Mute recording preview")
        try cancelEditor()
    }

    func testEditorTrimExportTransportAndSavePanelCancelRecovery() throws {
        try start(.window)
        try hold(3)
        try stop()
        let timeline = RecordingTestEnvironment.element("recording.editor.timeline", in: recorder)
        guard timeline.waitForExistence(timeout: 5), let value = timeline.value as? String,
              let token = value.components(separatedBy: ", duration ").last?.split(separator: " ").first,
              let untrimmedDuration = Double(token), untrimmedDuration.isFinite, untrimmedDuration > 0 else {
            throw HarnessError("Editor did not expose its actual source duration: \(String(describing: timeline.value))")
        }
        for button in ["recording.editor.skipEnd", "recording.editor.stepBack", "recording.editor.skipStart", "recording.editor.play", "recording.editor.play", "recording.editor.mute"] {
            try RecordingTestEnvironment.click(button, in: recorder)
        }
        let movie = try save("trimmed-window", trim: true)
        XCTAssertLessThan(movie.duration, untrimmedDuration, "Trimmed export must be shorter than full source clip")
        try movie.requireMarker("primary", above: 0.25)
        try movie.exclude(["forbidden", "second"])
        try start(.window)
        try stop()
        try RecordingTestEnvironment.click("recording.editor.save", in: recorder)
        let cancel = recorder.dialogs.buttons["Cancel"].firstMatch
        guard cancel.waitForExistence(timeout: 30) else { throw HarnessError("Native save-panel cancel unavailable") }
        cancel.click()
        try ready()
        try start(.window)
        try stop()
        try cancelEditor()
    }

    func testSystemSharingWithdrawalKeepsBlackRecordingUntilManualStop() throws {
        try start(.window)
        try picker.withdrawSharing()
        try state(containing: "target unavailable")
        try hold(2.5)
        XCTAssertFalse(recorder.windows["recording.editor"].exists)
        try stop()
        let movie = try save("system-withdrawal-black-tail")
        try movie.requireBlankTail(atLeast: 1.5)
        try movie.exclude(["forbidden", "second"])
    }

    private func requireTwoDisplays() throws {
        guard NSScreen.screens.count >= 2 else { throw HarnessError("Required two-display recording acceptance cannot run: attach a real or supported virtual second display. This environment gate is a failure, not a passed/omitted test.") }
    }
    func testWindowFollowsSecondDisplayWithFixedVideoSize() throws {
        try requireTwoDisplays()
        try start(.window)
        try fixture("fixture.nextDisplay")
        try fixture("fixture.animation")
        let moved = elapsed
        try hold(2)
        try stop()
        let movie = try save("window-two-displays")
        try movie.requireMarker("primary", above: 0.25, in: max(0, moved - 0.3)...movie.duration)
        try movie.exclude(["forbidden", "second"])
    }
    func testApplicationSecondDisplayWindowIsExcluded() throws {
        try requireTwoDisplays()
        try start(.application)
        try hold(1)
        try fixture("fixture.secondNextDisplay")
        try fixture("fixture.animation")
        let moved = elapsed
        try hold(2)
        try stop()
        let movie = try save("application-one-display")
        try movie.requireMarker("second", above: 0.005, in: 0...max(0, moved))
        let afterMove = movie.frames.filter { $0.time > moved + 0.5 }
        XCTAssertGreaterThan(afterMove.count, 3)
        for frame in afterMove { XCTAssertLessThan(frame.fractions["second", default: 0], 0.002) }
        try movie.requireMarker("primary", above: 0.005, in: moved...movie.duration)
        try movie.exclude(["forbidden"])
    }

    func testScreenAndRegionRecordingRegression() throws {
        for region in [false, true] {
            a.activate()
            try RecordingTestEnvironment.menuAction(region ? "recording.recordRegion" : "recording.recordScreen", in: recorder)
            if region {
                let target = a.windows["Fixture A Primary"]
                target.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).press(forDuration: 0.2,
                    thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8)))
            }
            try state(containing: region ? "Recording Region" : "Recording Screen")
            try hold(1.5)
            try stop()
            let movie = try save(region ? "legacy-region" : "legacy-screen")
            try movie.requireMarker("primary", above: region ? 0.2 : 0.005)
            try RecordedAudioAssertions.requireNoAudio(in: movie.url)
        }
    }
}
