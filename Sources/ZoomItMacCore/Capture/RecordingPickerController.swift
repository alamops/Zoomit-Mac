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
        configuration.excludedWindowIDs = NSApp.windows.map { $0.windowNumber }
        configuration.allowsChangingSelectedContent = false
        previousConfiguration = picker.defaultConfiguration
        previouslyActive = picker.isActive
        picker.add(self)
        observing = true
        picker.defaultConfiguration = configuration
        picker.isActive = true
        picker.present(using: scope == .window ? .window : .application)
    }

    func bind(stream: SCStream) {
        boundStream = stream
        picker.setConfiguration(configuration, for: stream)
        // Default configuration only applies to unbound selection. Restore it
        // immediately after binding, retaining this stream's scoped settings.
        if let previousConfiguration { picker.defaultConfiguration = previousConfiguration }
        previousConfiguration = nil
    }

    func finish() {
        guard observing else { return }
        observing = false
        completion = nil
        picker.remove(self)
        if let boundStream { picker.setConfiguration(nil, for: boundStream) }
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
            let expected: SCShareableContentStyle = self.scope == .window ? .window : .application
            guard box.filter.style == expected else { self.resolve(.failure(PickerError.unexpectedSelection)); return }
            if #available(macOS 15.2, *) {
                let valid = self.scope == .window ? box.filter.includedWindows.count == 1
                    : box.filter.includedApplications.count == 1 && box.filter.includedDisplays.count == 1
                guard valid else { self.resolve(.failure(PickerError.unexpectedSelection)); return }
            }
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
