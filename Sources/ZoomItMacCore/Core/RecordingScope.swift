/// Capture intent; isolated scopes can never use display pixels as fallback.
enum RecordingScope: String, CaseIterable, Equatable, Sendable {
    case screen, region, window, application

    var isIsolated: Bool { self == .window || self == .application }

    var displayName: String {
        switch self {
        case .screen: "Screen"
        case .region: "Region"
        case .window: "Window"
        case .application: "Application"
        }
    }
}
