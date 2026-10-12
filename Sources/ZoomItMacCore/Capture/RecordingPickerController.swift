import AppKit
@preconcurrency import ScreenCaptureKit

/// Keeps the OS-issued authorization/filter alive for exactly one recording.
/// A picked filter is never rebuilt from a window title, rectangle, or bundle ID.
@MainActor
final class RecordingPickerController: NSObject, SCContentSharingPickerObserver {
    enum PickerError: LocalizedError {
        case unexpectedSelection
        var errorDescription: String? { "The sharing picker returned content outside the requested recording scope. Please choose the target again." }
    }
    private struct FilterBox: @unchecked Sendable { let filter: SCContentFilter }
    private let picker = SCContentSharingPicker.shared
    private let scope: RecordingScope
    private var completion: ((Result<SCContentFilter?, Error>) -> Void)?
    private var configuration = SCContentSharingPickerConfiguration()
    private var previousConfiguration: SCContentSharingPickerConfiguration?
    private var previouslyActive = false
    private var observing = false
    private var boundStream: SCStream?

    init(scope: RecordingScope) {
        self.scope = scope
        super.init()
    }

    func present(completion: @escaping (Result<SCContentFilter?, Error>) -> Void) {
        guard !observing, scope.isIsolated else { return }
        self.completion = completion
        configuration.allowedPickerModes = scope == .window ? .singleWindow : .singleApplication
        configuration.excludedBundleIDs = Bundle.main.bundleIdentifier.map { [$0] } ?? []
        configuration.excludedWindowIDs = Self.validExcludedWindowIDs(NSApp.windows.map { $0.windowNumber })
        configuration.allowsChangingSelectedContent = false
        previousConfiguration = picker.defaultConfiguration
        previouslyActive = picker.isActive
        picker.add(self)
        observing = true
        picker.defaultConfiguration = configuration
        // Status-menu actions run before menu tracking has unwound. Presenting
        // there can leave the system selection UI obscured or without focus.
        // Use the normal chooser entry point; allowedPickerModes pins the scope.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.observing, self.completion != nil else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.picker.isActive = true
            self.picker.present()
        }
    }

    /// Closed or not-yet-shown AppKit windows report -1. The system picker
    /// consumes these as unsigned CGWindowIDs; invalid values can crash its UI.
    static func validExcludedWindowIDs(_ windowNumbers: [Int]) -> [Int] {
        windowNumbers.filter { $0 > 0 && $0 <= Int(UInt32.max) }
    }

    static func validSelection(scope: RecordingScope, style: SCShareableContentStyle,
                               windowCount: Int? = nil, applicationCount: Int? = nil,
                               displayCount: Int? = nil) -> Bool {
        if scope == .window {
            return style == .window && (windowCount == nil || windowCount == 1)
        }
        // Application selection is a display stream restricted to one app, not
        // necessarily an application-style filter. Keep the native authorization.
        guard scope == .application, style == .application || style == .display else { return false }
        if applicationCount == nil && displayCount == nil { return true }
        return applicationCount == 1 && displayCount == 1
    }

    func bind(stream: SCStream) {
        boundStream = stream
        // The stable default configuration already pins this session's scope
        // and disallows repicking. A stream-specific override would mutate the
        // issued filter's metadata and invalidate picker-only authorization.
    }

    func finish() {
        guard observing else { return }
        observing = false
        completion = nil
        picker.remove(self)
        boundStream = nil
        if let previousConfiguration { picker.defaultConfiguration = previousConfiguration }
        previousConfiguration = nil
        if !previouslyActive { picker.isActive = false }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        guard stream == nil else { return }
        Task { @MainActor [weak self] in self?.resolve(.success(nil)) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        guard stream == nil else { return }
        let box = FilterBox(filter: filter)
        Task { @MainActor [weak self] in
            guard let self, self.observing, self.completion != nil else { return }
            let valid: Bool
            if #available(macOS 15.2, *) {
                valid = Self.validSelection(scope: self.scope, style: box.filter.style,
                    windowCount: box.filter.includedWindows.count,
                    applicationCount: box.filter.includedApplications.count,
                    displayCount: box.filter.includedDisplays.count)
            } else {
                // The native picker is restricted to exactly the requested mode;
                // older systems do not expose the filter's identity metadata.
                valid = Self.validSelection(scope: self.scope, style: box.filter.style)
            }
            guard valid else { self.resolve(.failure(PickerError.unexpectedSelection)); return }
            self.resolve(.success(box.filter))
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in self?.resolve(.failure(error)) }
    }

    private func resolve(_ result: Result<SCContentFilter?, Error>) {
        guard observing, let completion else { return }
        self.completion = nil
        completion(result)
    }
}
