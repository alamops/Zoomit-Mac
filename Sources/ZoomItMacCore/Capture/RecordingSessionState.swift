import CoreMedia

enum RecordingSourceAvailability: Equatable, Sendable {
    case available, unavailable, ended
}

/// A reducer owned by the recording actor. Generation-tagged callbacks cannot
/// mutate a later session; invalid transitions are rejected without side effects.
struct RecordingSessionState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle, selecting, starting, recording, stopping, editing, saving
    }
    private(set) var phase: Phase = .idle
    private(set) var generation: UInt64 = 0
    private(set) var scope: RecordingScope?
    private(set) var availability: RecordingSourceAvailability = .unavailable

    var isRecording: Bool { phase == .recording }
    var canStart: Bool { phase == .idle }
    var canStop: Bool { phase == .recording }

    @discardableResult
    mutating func begin(scope: RecordingScope) -> UInt64? {
        guard canStart else { return nil }
        generation &+= 1
        self.scope = scope
        availability = .unavailable
        phase = scope.isIsolated ? .selecting : .starting
        return generation
    }

    @discardableResult
    mutating func transition(to next: Phase, generation candidate: UInt64) -> Bool {
        guard candidate == generation else { return false }
        let allowed: Bool
        switch (phase, next) {
        case (.selecting, .starting), (.selecting, .idle),
             (.starting, .recording), (.starting, .idle),
             (.recording, .stopping), (.stopping, .editing), (.stopping, .idle),
             (.editing, .saving), (.editing, .idle), (.saving, .editing), (.saving, .idle):
            allowed = true
        default: allowed = false
        }
        guard allowed else { return false }
        phase = next
        if next == .idle {
            scope = nil
            availability = .unavailable
        }
        return true
    }

    @discardableResult
    mutating func setAvailability(_ value: RecordingSourceAvailability, generation candidate: UInt64) -> Bool {
        guard candidate == generation, phase == .recording,
              availability != .ended || value == .ended else { return false }
        availability = value
        return true
    }
}

/// Frame status policy, independent of native capture frameworks. Idle means
/// unchanged authorized content, never absence. Ended is terminal for a session.
struct RecordingSourcePolicy: Equatable, Sendable {
    enum Update: Sendable { case complete, idle, blank, suspended, stopped }
    private(set) var availability: RecordingSourceAvailability = .unavailable
    private(set) var contentRevision: UInt64 = 0

    mutating func consume(_ update: Update) {
        guard availability != .ended else { return }
        switch update {
        case .complete:
            availability = .available
            contentRevision &+= 1
        case .idle: break
        case .blank, .suspended: availability = .unavailable
        case .stopped: availability = .ended
        }
    }
}

/// Scheduled video frames use the same monotonic host clock as capture/audio.
/// Regressing or repeated timestamps advance by one cadence tick. This helper
/// must have one owner; it contains no timers and can be tested deterministically.
struct RecordingTimeline: Sendable {
    let frameDuration: CMTime
    private(set) var lastPresentationTime: CMTime?

    init(framesPerSecond: Int32 = 30) {
        frameDuration = CMTime(value: 1, timescale: max(1, framesPerSecond))
    }

    mutating func nextPresentationTime(hostTime: CMTime) -> CMTime {
        let proposed = hostTime.isNumeric ? hostTime : (lastPresentationTime.map { CMTimeAdd($0, frameDuration) } ?? .zero)
        let next: CMTime
        if let last = lastPresentationTime, CMTimeCompare(proposed, last) <= 0 {
            next = CMTimeAdd(last, frameDuration)
        } else { next = proposed }
        lastPresentationTime = next
        return next
    }
}
