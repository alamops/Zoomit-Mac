import XCTest

final class HarnessSmokeTests: XCTestCase {
    private var launched: [XCUIApplication] = []
    override func tearDownWithError() throws {
        for app in launched.reversed() where app.state != .notRunning { app.terminate() }
        launched.removeAll()
    }
    func testPreflight() throws {
        continueAfterFailure = false
        let environment = try RecordingTestEnvironment()
        let probe = try environment.probe()
        environment.launch(probe); launched.append(probe)
        XCTAssertTrue(probe.buttons["probe.window"].waitForExistence(timeout: 10),
                      "Allow Xcode's runner to control applications; use an unlocked logged-in desktop.")
        XCTAssertTrue(probe.staticTexts["probe.permission"].exists)
        let recorder = environment.recorder()
        environment.launch(recorder); launched.append(recorder)
        XCTAssertNotEqual(recorder.state, .notRunning, "The dedicated recorder must launch successfully.")
        let permission = probe.staticTexts["probe.permission"]
        let attachment = XCTAttachment(string: "distribution=\(environment.distribution)\nurl=\(environment.recorderURL.path)\npermission=\(permission.value ?? permission.label)")
        attachment.name = "preflight"; attachment.lifetime = .keepAlways; add(attachment)
        environment.attachEvidence(to: self, name: "preflight")
    }
    func testFixtureControlsAndDistinctIdentities() throws {
        continueAfterFailure = false
        let environment = try RecordingTestEnvironment()
        let a = try environment.fixtureA(), b = try environment.fixtureB()
        environment.launch(a); launched.append(a)
        environment.launch(b); launched.append(b)
        XCTAssertTrue(a.windows["Fixture A Primary"].waitForExistence(timeout: 8))
        XCTAssertTrue(b.windows["Fixture B Primary"].waitForExistence(timeout: 8))
        XCTAssertTrue(a.windows["Fixture A Second"].exists)
        try RecordingTestEnvironment.click("fixture.openDialog", in: a)
        XCTAssertTrue(a.windows["Fixture A Dialog"].waitForExistence(timeout: 5))
        let original = a.windows["Fixture A Primary"].frame
        try RecordingTestEnvironment.click("fixture.resize", in: a)
        try RecordingTestEnvironment.wait(description: "fixture resize") { a.windows["Fixture A Primary"].frame.size != original.size }
        try RecordingTestEnvironment.click("fixture.closePrimary", in: a)
        try RecordingTestEnvironment.wait(description: "fixture primary closed") { !a.windows["Fixture A Primary"].exists }
        try RecordingTestEnvironment.click("fixture.openPrimary", in: a)
        XCTAssertTrue(a.windows["Fixture A Primary"].waitForExistence(timeout: 5))
        try RecordingTestEnvironment.click("fixture.minimize", in: a)
        try RecordingTestEnvironment.click("fixture.restore", in: a)
        try RecordingTestEnvironment.click("fixture.tone", in: a)
        try RecordingTestEnvironment.click("fixture.tone", in: b)
        XCTAssertFalse(a.alerts.firstMatch.exists, "Fixture A's deterministic 440/660-Hz playback must initialize.")
        XCTAssertFalse(b.alerts.firstMatch.exists, "Fixture B's forbidden 880-Hz playback must initialize.")
        try RecordingTestEnvironment.click("fixture.tone", in: a)
        try RecordingTestEnvironment.click("fixture.tone", in: b)
    }
}
