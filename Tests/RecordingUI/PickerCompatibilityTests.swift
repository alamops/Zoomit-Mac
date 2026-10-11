import AppKit
import ScreenCaptureKit
import XCTest

final class PickerCompatibilityTests: XCTestCase {
    private var environment: RecordingTestEnvironment!
    private var probe: XCUIApplication!
    private var a: XCUIApplication!
    private var b: XCUIApplication!
    private var driver: NativePickerDriver!
    override func setUpWithError() throws {
        continueAfterFailure = false
        environment = try RecordingTestEnvironment()
        a = try environment.fixtureA(); b = try environment.fixtureB(); probe = try environment.probe()
        environment.launch(b); environment.launch(a); environment.launch(probe)
        driver = NativePickerDriver(test: self)
        XCTAssertTrue(probe.buttons["probe.window"].waitForExistence(timeout: 10))
    }
    override func tearDownWithError() throws {
        environment?.attachEvidence(to: self, name: name)
        driver?.attachDiagnostics("compatibility-final")
        for app in [probe, a, b].compactMap({ $0 }) where app.state != .notRunning { app.terminate() }
    }
    private func start(_ scope: NativePickerDriver.Scope) throws {
        if environment.pickerOnlyAuthorization {
            let permission = probe.staticTexts["probe.permission"]
            XCTAssertEqual(permission.value as? String ?? permission.label, "picker-only-authorization",
                           "--picker-only requires an independently configured login with no blanket grant for the dedicated probe; never reset TCC automatically.")
        }
        a.activate()
        try RecordingTestEnvironment.click(scope == .window ? "probe.window" : "probe.application", in: probe)
        try driver.select(scope: scope, targetApp: a, windowTitle: "Fixture A Primary")
        try RecordingTestEnvironment.wait(timeout: 15, description: "authorized native stream startup; inspect probe-evidence.json for permission failure") {
            (try? self.environment.evidence()["status"] as? String) == "capturing"
        }
        try waitForMarker("primary", above: scope == .window ? 0.2 : 0.005)
        let filter = try XCTUnwrap(environment.evidence()["filter"] as? [String: Any])
        XCTAssertEqual(filter["style"] as? Int, scope == .window ? SCShareableContentStyle.window.rawValue : SCShareableContentStyle.application.rawValue)
        if #available(macOS 15.2, *) {
            if scope == .application {
                XCTAssertEqual(filter["applications"] as? [String], [RecordingTestEnvironment.fixtureABundleID])
                XCTAssertEqual((filter["displays"] as? [Int])?.count, 1)
            } else {
                XCTAssertEqual((filter["windows"] as? [Int])?.count, 1)
            }
        }
    }
    private func frameSamples() throws -> [[String: Any]] { try environment.evidence()["frames"] as? [[String: Any]] ?? [] }
    private func waitForMarker(_ marker: String, above threshold: Double, phase: String? = nil) throws {
        try RecordingTestEnvironment.wait(timeout: 12, description: "isolated \(marker) marker in native stream, phase \(phase ?? "any")") {
            guard let frames = try? self.frameSamples() else { return false }
            return frames.contains {
                (phase == nil || $0["phase"] as? String == phase) && (($0["markers"] as? [String: Double])?[marker] ?? 0) > threshold
            }
        }
    }
    private func assertNoForbiddenFrames() throws {
        let frames = try frameSamples()
        XCTAssertFalse(frames.isEmpty)
        for frame in frames { XCTAssertLessThan((frame["markers"] as? [String: Double])?["forbidden"] ?? 0, 0.002, "Foreign app B leaked into authorized source: \(frame)") }
    }
    func testRealPickerCancellationAndRetry() throws {
        try RecordingTestEnvironment.click("probe.window", in: probe)
        driver.cancel(from: probe)
        try RecordingTestEnvironment.wait(description: "native picker cancellation") {
            (try? self.environment.evidence()["status"] as? String) == "cancelled"
        }
        let cancelled = try environment.evidence()
        XCTAssertEqual(cancelled["frameCount"] as? Int, 0)
        XCTAssertFalse((cancelled["events"] as? [[String: Any]] ?? []).contains { $0["event"] as? String == "started" })
        try start(.window)
        try assertNoForbiddenFrames()
    }
    func testWindowIsolationIdleHiddenRestoreAndCloseStatuses() throws {
        try start(.window)
        try RecordingTestEnvironment.click("probe.phase.idle", in: probe)
        // Request a snapshot only; do not animate the target. Native idle delivery is measured.
        try RecordingTestEnvironment.click("probe.snapshot", in: probe)
        let observation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ((try? self.frameSamples()) ?? []).contains { $0["phase"] as? String == "idle" }
        }, object: nil)
        _ = XCTWaiter.wait(for: [observation], timeout: 4)
        // Some OS builds send no callback for static content. Preserve that absence as evidence.
        let idleFrames = try frameSamples().filter { $0["phase"] as? String == "idle" }
        let idleEvidence = XCTAttachment(string: "Native static-target callbacks: \(idleFrames). No callback is an idle observation, never evidence of target loss.")
        idleEvidence.name = "idle-observation"; idleEvidence.lifetime = .keepAlways; add(idleEvidence)
        for frame in try frameSamples() {
            XCTAssertLessThan((frame["markers"] as? [String: Double])?["second"] ?? 0, 0.002)
        }
        try RecordingTestEnvironment.click("probe.phase.hidden", in: probe)
        try RecordingTestEnvironment.click("fixture.minimize", in: a)
        try requireLossSignal(phase: "hidden")
        try RecordingTestEnvironment.click("probe.phase.restored", in: probe)
        try RecordingTestEnvironment.click("fixture.restore", in: a)
        try waitForMarker("primary", above: 0.2, phase: "restored")
        try RecordingTestEnvironment.click("probe.phase.closed", in: probe)
        try RecordingTestEnvironment.click("fixture.closePrimary", in: a)
        try requireLossSignal(phase: "closed")
        try assertNoForbiddenFrames()
    }
    func testApplicationIncludesNewWindowsAndDialogButExcludesOtherApp() throws {
        try start(.application)
        try waitForMarker("second", above: 0.005)
        try RecordingTestEnvironment.click("fixture.closeSecond", in: a)
        try RecordingTestEnvironment.click("fixture.openSecond", in: a)
        try RecordingTestEnvironment.click("fixture.openDialog", in: a)
        try waitForMarker("dialog", above: 0.003)
        try RecordingTestEnvironment.click("fixture.overlap", in: b)
        try RecordingTestEnvironment.click("fixture.animation", in: a)
        try waitForMarker("primary", above: 0.005)
        try assertNoForbiddenFrames()
        try RecordingTestEnvironment.click("probe.phase.hidden", in: probe)
        try RecordingTestEnvironment.click("fixture.hide", in: a)
        try requireLossSignal(phase: "hidden")
        try RecordingTestEnvironment.click("probe.phase.restored", in: probe)
        a.activate()
        try waitForMarker("primary", above: 0.005, phase: "restored")
        try RecordingTestEnvironment.click("probe.phase.closed", in: probe)
        a.terminate()
        try requireLossSignal(phase: "closed")
    }
    private func requireLossSignal(phase: String) throws {
        try RecordingTestEnvironment.wait(timeout: 12, description: "native target-loss signal for \(phase); lack of a signal is a compatibility gate, not permission to reuse stale imagery") {
            let frames = (try? self.frameSamples()) ?? []
            if frames.contains(where: {
                guard $0["phase"] as? String == phase else { return false }
                let status = $0["status"] as? Int ?? -1
                return [SCFrameStatus.blank.rawValue, SCFrameStatus.suspended.rawValue, SCFrameStatus.stopped.rawValue].contains(status)
                    || (($0["markers"] as? [String: Double])?["black"] ?? 0) > 0.98
            }) { return true }
            let events = (try? self.environment.evidence()["events"] as? [[String: Any]]) ?? []
            return events.contains { $0["phase"] as? String == phase && $0["event"] as? String == "terminalError" }
        }
    }
    private func requireTwoDisplays() throws {
        guard NSScreen.screens.count >= 2 else {
            let message = "PENDING ENVIRONMENT: two-display native filter binding requires a real or supported virtual second display. This required check has not passed."
            let attachment = XCTAttachment(string: message); attachment.lifetime = .keepAlways; add(attachment)
            throw HarnessError(message)
        }
    }
    func testApplicationFilterRemainsBoundToOneDisplay() throws {
        try requireTwoDisplays()
        try start(.application)
        try waitForMarker("second", above: 0.005)
        try RecordingTestEnvironment.click("probe.phase.idle", in: probe)
        try RecordingTestEnvironment.click("fixture.secondNextDisplay", in: a)
        try RecordingTestEnvironment.click("fixture.animation", in: a)
        try RecordingTestEnvironment.wait(timeout: 12, description: "app's second-display window excluded on macOS 14 and newer") {
            let frames = ((try? self.frameSamples()) ?? []).filter { $0["phase"] as? String == "idle" && $0["status"] as? Int == SCFrameStatus.complete.rawValue }
            guard let last = frames.last, let markers = last["markers"] as? [String: Double] else { return false }
            return (markers["primary"] ?? 0) > 0.005 && (markers["second"] ?? 0) < 0.002
        }
        try assertNoForbiddenFrames()
    }
    func testWindowFilterFollowsTargetToAnotherDisplay() throws {
        try requireTwoDisplays()
        try start(.window)
        let original = a.windows["Fixture A Primary"].frame.origin
        try RecordingTestEnvironment.click("fixture.nextDisplay", in: a)
        try RecordingTestEnvironment.wait(description: "fixture moved across displays") { self.a.windows["Fixture A Primary"].frame.origin != original }
        try RecordingTestEnvironment.click("probe.phase.idle", in: probe)
        try RecordingTestEnvironment.click("fixture.animation", in: a)
        try waitForMarker("primary", above: 0.2, phase: "idle")
        try assertNoForbiddenFrames()
    }
}
