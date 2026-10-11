import AppKit
import XCTest

struct RecordingTestEnvironment {
    static let fixtureABundleID = "com.sysinternals.zoomitmac.recordingtests.fixturea"
    static let fixtureBBundleID = "com.sysinternals.zoomitmac.recordingtests.fixtureb"
    static let probeBundleID = "com.sysinternals.zoomitmac.recordingtests.pickerprobe"
    let artifacts: URL
    let recorderURL: URL
    let distribution: String
    let products: URL
    var pickerOnlyAuthorization: Bool { ProcessInfo.processInfo.environment["ZOOMIT_PICKER_AUTHORIZATION"] == "picker-only" }

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let artifactPath = environment["ZOOMIT_UI_ARTIFACTS"],
              let recorderPath = environment["ZOOMIT_UI_APP_PATH"],
              let productPath = environment["ZOOMIT_UI_PRODUCTS"] else {
            throw HarnessError("Run Scripts/test-recording-ui.sh; ZOOMIT_UI_ARTIFACTS, ZOOMIT_UI_APP_PATH and ZOOMIT_UI_PRODUCTS are required.")
        }
        distribution = environment["ZOOMIT_UI_DISTRIBUTION"] ?? "homebrew"
        guard ["homebrew", "appstore"].contains(distribution) else { throw HarnessError("Unknown distribution \(distribution)") }
        artifacts = URL(fileURLWithPath: artifactPath, isDirectory: true)
        recorderURL = URL(fileURLWithPath: recorderPath, isDirectory: true)
        products = URL(fileURLWithPath: productPath, isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let infoURL = recorderURL.appendingPathComponent("Contents/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any]
        let expectedID = "com.sysinternals.zoomitmac.recordingtests.\(distribution)"
        guard info?["CFBundleIdentifier"] as? String == expectedID,
              info?["ZoomItDistribution"] as? String == distribution else {
            throw HarnessError("The supplied app must be the dedicated \(distribution) recording-test bundle (\(expectedID)). Refusing to launch an installed official app.")
        }
        if distribution == "appstore" { try verifySandbox() }
    }
    private func verifySandbox() throws {
        let command = Process(); let pipe = Pipe()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        command.arguments = ["-d", "--entitlements", ":-", recorderURL.path]
        command.standardOutput = pipe; command.standardError = FileHandle.nullDevice
        try command.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); command.waitUntilExit()
        guard command.terminationStatus == 0,
              let entitlements = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              entitlements["com.apple.security.app-sandbox"] as? Bool == true else {
            throw HarnessError("The App Store test bundle must have its real app-sandbox entitlement. Rebuild through Scripts/build-app.sh with ZOOMIT_DISTRIBUTION=appstore.")
        }
    }
    func app(named name: String) throws -> XCUIApplication {
        let url = products.appendingPathComponent(name + ".app")
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/MacOS").path) else {
            throw HarnessError("Missing fixture bundle at \(url.path); run the wrapper to build it.")
        }
        return XCUIApplication(url: url)
    }
    func recorder() -> XCUIApplication { XCUIApplication(url: recorderURL) }
    func launch(_ app: XCUIApplication, arguments: [String] = []) {
        app.launchEnvironment["ZOOMIT_UI_ARTIFACTS"] = artifacts.path
        app.launchArguments = arguments
        app.launch()
    }
    func probe() throws -> XCUIApplication { try app(named: "Recording Picker Probe") }
    func fixtureA() throws -> XCUIApplication { try app(named: "Recording Fixture A") }
    func fixtureB() throws -> XCUIApplication { try app(named: "Recording Fixture B") }
    func evidence() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: artifacts.appendingPathComponent("probe-evidence.json"))) as? [String: Any] ?? [:]
    }
    func attachEvidence(to test: XCTestCase, name: String) {
        for file in ["probe-evidence.json", "probe-latest.png"] {
            let url = artifacts.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let attachment = XCTAttachment(contentsOfFile: url)
            attachment.name = "\(name)-\(file)"; attachment.lifetime = .keepAlways; test.add(attachment)
        }
    }
    static func click(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 8) throws {
        let button = app.buttons[identifier]
        guard button.waitForExistence(timeout: timeout), button.isEnabled else {
            throw HarnessError("Cannot use \(identifier). Ensure the desktop is unlocked and allow Xcode's test runner in Privacy & Security > Accessibility and Automation. UI: \(app.debugDescription)")
        }
        button.click()
    }
    static func wait(timeout: TimeInterval = 10, description: String, condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else { throw HarnessError("Timed out: \(description)") }
    }
}
struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
