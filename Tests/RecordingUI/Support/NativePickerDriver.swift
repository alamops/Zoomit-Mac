import XCTest

/// Drives Apple's UI with public XCTest queries and pointer events. A missing accessibility
/// surface fails with process trees/screenshots; it never creates a filter on the test's behalf.
final class NativePickerDriver {
    enum Scope { case window, application }
    private let test: XCTestCase
    private let systemApps = [
        XCUIApplication(bundleIdentifier: "com.apple.controlcenter"),
        XCUIApplication(bundleIdentifier: "com.apple.screencaptureui"),
        XCUIApplication(bundleIdentifier: "com.apple.WindowManager"),
        XCUIApplication(bundleIdentifier: "com.apple.systemuiserver")
    ]
    private var requestingApps: [XCUIApplication] = []
    init(test: XCTestCase) { self.test = test }
    func include(_ app: XCUIApplication) { requestingApps.append(app) }

    func select(scope: Scope, targetApp: XCUIApplication, windowTitle: String,
                applicationName: String = "Recording Fixture A") throws {
        include(targetApp)
        let target = targetApp.windows[windowTitle]
        guard target.waitForExistence(timeout: 8) else { throw HarnessError("Missing fixture target \(windowTitle)") }
        let modeLabels = scope == .window ? ["Window", "Windows"] : ["Application", "Applications", "App"]
        clickSystemElement(labels: modeLabels, types: [.radioButton, .button, .popUpButton])
        // Some OS revisions show a chooser; others use a pointer highlight on the actual window.
        let targetLabels = scope == .window ? [windowTitle] : [applicationName, windowTitle]
        let choseFromList = clickSystemElement(labels: targetLabels, types: [.button, .cell, .tableRow, .menuItem])
        if !choseFromList { target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover() }
        let confirmation = scope == .window
            ? ["Share This Window", "Share Window", "Share", "Start Sharing"]
            : ["Share This Application", "Share This App", "Share Application", "Share", "Start Sharing"]
        do {
            try RecordingTestEnvironment.wait(timeout: 8, description: "native picker's \(confirmation.joined(separator: "/")) button") {
                self.findSystemElement(labels: confirmation, types: [.button]) != nil
            }
            guard let button = findSystemElement(labels: confirmation, types: [.button]) else { throw HarnessError("Native picker confirmation vanished") }
            button.click()
        } catch {
            attachDiagnostics("picker-selection-failed")
            throw HarnessError("The real system picker could not be driven on this OS. Use an English test login and allow UI automation, then inspect the retained picker trees and screenshot. \(error)")
        }
    }
    func cancel(from requestingApp: XCUIApplication) {
        include(requestingApp)
        if !clickSystemElement(labels: ["Cancel", "Stop Selecting", "Close"], types: [.button]) {
            requestingApp.typeKey(.escape, modifierFlags: [])
        }
    }
    func withdrawSharing() throws {
        let candidates = ["Screen Sharing", "Screen Recording", "Sharing", "Recording"]
        _ = clickSystemElement(labels: candidates, types: [.menuBarItem, .button, .statusItem], systemOnly: true)
        do {
            try RecordingTestEnvironment.wait(timeout: 8, description: "system Stop Sharing control") {
                self.findSystemElement(labels: ["Stop Sharing", "Stop Recording", "Stop"], types: [.button, .menuItem], systemOnly: true) != nil
            }
            guard clickSystemElement(labels: ["Stop Sharing", "Stop Recording", "Stop"], types: [.button, .menuItem], systemOnly: true) else {
                throw HarnessError("OS withdrawal control disappeared")
            }
        } catch {
            attachDiagnostics("system-withdrawal-failed")
            throw HarnessError("Cannot withdraw source sharing through Apple's UI on this OS: \(error)")
        }
    }
    @discardableResult private func clickSystemElement(labels: [String], types: [XCUIElement.ElementType], systemOnly: Bool = false) -> Bool {
        guard let element = findSystemElement(labels: labels, types: types, systemOnly: systemOnly) else { return false }
        element.click(); return true
    }
    private func findSystemElement(labels: [String], types: [XCUIElement.ElementType], systemOnly: Bool = false) -> XCUIElement? {
        let applications = systemOnly ? systemApps : systemApps + requestingApps
        for app in applications where app.state != .notRunning {
            for type in types {
                let descendants = app.descendants(matching: type)
                for label in labels {
                    let element = descendants.matching(NSPredicate(format: "label == %@ OR title == %@ OR identifier == %@", label, label, label)).firstMatch
                    if element.exists && element.isEnabled { return element }
                }
            }
        }
        return nil
    }
    func attachDiagnostics(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "\(name)-desktop"; screenshot.lifetime = .keepAlways; test.add(screenshot)
        for app in systemApps + requestingApps where app.state != .notRunning {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "\(name)-\(app.label)-tree"; tree.lifetime = .keepAlways; test.add(tree)
        }
    }
}
