import Recognition

public enum SessionPhase: String, Sendable, Equatable, Codable {
    /// Nothing playing.
    case idle
    /// Something that might be music; the side detector is confirming.
    case listening
    /// A side is playing but we don't know the track yet.
    case recognizing
    /// A track is playing (`track` is nil if it couldn't be identified).
    case playing
    case betweenTracks
    /// The side finished; waiting for the flip.
    case sideEnded
}

public struct SessionConfig: Sendable, Equatable {
    /// A matching window gives up after this long.
    public var matchWindow = 15.0
    /// Re-match this often while a track plays (drift correction, catch segues).
    public var rematchInterval = 25.0
    /// Retry quickly while still trying to identify a track…
    public var retryInterval = 2.0
    /// …and give up (call it unknown) after this long without a match.
    public var unknownAfter = 45.0
    /// Then retry occasionally in case it was a rough intro.
    public var unknownRetryInterval = 30.0
    /// Re-match this soon after the clock says the track should have ended.
    public var endOfTrackGrace = 3.0

    public init() {}
}

public enum SessionInput: Sendable {
    case tick(time: Double, detector: SidePhase)
    case side(SideEvent)
    case match(TrackMatch, at: Double)
    /// Metadata arrived with the track's length.
    case trackDuration(identity: String, seconds: Double)
}

public enum SessionEffect: Sendable, Equatable {
    case startRecognition
    case stopRecognition
    /// The playing track changed (nil = unidentified).
    case trackChanged(TrackMatch?)
}

/// The brain: turns side events, recognitions and the passage of (audio) time into a
/// session phase, the current track and its clock, and requests to open/close matching
/// windows. A pure reducer — no clocks, threads, or I/O — so it's fully unit-testable.
public struct SessionMachine: Sendable {
    public var config: SessionConfig
    public private(set) var phase: SessionPhase = .idle
    public private(set) var track: TrackMatch?
    public private(set) var clock: PlaybackClock?
    public private(set) var sideStart: Double?
    /// True once we've given up identifying the current track.
    public private(set) var unidentified = false
    public private(set) var isRecognizing = false
    public private(set) var matchCount = 0

    private var windowOpenedAt: Double?
    private var nextMatchAt: Double?
    /// When the current search for a track began (side start, or the end of a gap).
    public private(set) var searchingSince: Double?
    private var trackDuration: Double?

    public init(config: SessionConfig = SessionConfig()) {
        self.config = config
    }

    public mutating func handle(_ input: SessionInput) -> [SessionEffect] {
        var effects: [SessionEffect] = []
        switch input {
        case .tick(let t, let detector):
            tick(t, detector, &effects)
        case .side(let event):
            side(event, &effects)
        case .match(let match, let t):
            matched(match, at: t, &effects)
        case .trackDuration(let identity, let seconds):
            guard identity == track?.identity else { break }
            trackDuration = seconds
            scheduleEndOfTrackCheck()
        }
        return effects
    }

    // MARK: - Inputs

    private mutating func tick(_ t: Double, _ detector: SidePhase, _ effects: inout [SessionEffect]) {
        switch phase {
        case .idle, .listening, .sideEnded:
            if case .arming = detector {
                phase = .listening
            } else if phase == .listening {
                phase = .idle
            }
            return
        case .betweenTracks:
            return
        case .recognizing, .playing:
            break
        }

        if isRecognizing, let opened = windowOpenedAt, t - opened >= config.matchWindow {
            closeWindow(&effects)
            windowMissed(at: t, &effects)
        }
        if !isRecognizing, let next = nextMatchAt, t >= next {
            openWindow(at: t, &effects)
        }
    }

    private mutating func side(_ event: SideEvent, _ effects: inout [SessionEffect]) {
        switch event {
        case .sideStarted(let t):
            sideStart = t
            phase = .recognizing
            setTrack(nil, notify: false, &effects)
            unidentified = false
            searchingSince = t
            openWindow(at: t, &effects)

        case .gapStarted:
            guard phase == .playing || phase == .recognizing else { return }
            phase = .betweenTracks
            nextMatchAt = nil
            closeWindow(&effects)

        case .trackGap(_, let end, _):
            // Music is back: almost certainly a new track.
            guard phase == .betweenTracks else { return }
            phase = .recognizing
            setTrack(nil, notify: true, &effects)
            unidentified = false
            searchingSince = end
            openWindow(at: end, &effects)

        case .sideEnded:
            phase = .sideEnded
            sideStart = nil
            nextMatchAt = nil
            searchingSince = nil
            closeWindow(&effects)
            setTrack(nil, notify: true, &effects)
            unidentified = false
        }
    }

    private mutating func matched(_ match: TrackMatch, at t: Double, _ effects: inout [SessionEffect]) {
        // Late results after the side ended (or during a gap) are stale.
        guard phase == .recognizing || phase == .playing else { return }
        closeWindow(&effects)
        matchCount += 1
        if match.isSameTrack(as: track), clock != nil {
            clock?.add(time: t, position: match.position, frequencySkew: match.frequencySkew)
            track = match
        } else {
            setTrack(match, notify: true, &effects)
            clock = PlaybackClock(time: t, position: match.position, frequencySkew: match.frequencySkew)
        }
        phase = .playing
        unidentified = false
        searchingSince = nil
        nextMatchAt = t + config.rematchInterval
        scheduleEndOfTrackCheck()
    }

    // MARK: - Helpers

    private mutating func windowMissed(at t: Double, _ effects: inout [SessionEffect]) {
        if track != nil {
            // Known track, re-match missed: keep the clock, try again later.
            nextMatchAt = t + config.rematchInterval
            return
        }
        let since = searchingSince ?? t
        if !unidentified, t - since >= config.unknownAfter {
            unidentified = true
            phase = .playing
            effects.append(.trackChanged(nil))
        }
        nextMatchAt = t + (unidentified ? config.unknownRetryInterval : config.retryInterval)
    }

    private mutating func scheduleEndOfTrackCheck() {
        guard let clock, let trackDuration, let next = nextMatchAt else { return }
        let endsAt = clock.trackStartTime + trackDuration / clock.rate
        nextMatchAt = min(next, endsAt + config.endOfTrackGrace)
    }

    private mutating func setTrack(_ match: TrackMatch?, notify: Bool, _ effects: inout [SessionEffect]) {
        let changed = track?.identity != match?.identity
        track = match
        if match == nil { clock = nil }
        trackDuration = nil
        if notify, changed { effects.append(.trackChanged(match)) }
    }

    private mutating func openWindow(at t: Double, _ effects: inout [SessionEffect]) {
        windowOpenedAt = t
        nextMatchAt = nil
        isRecognizing = true
        effects.append(.startRecognition)
    }

    private mutating func closeWindow(_ effects: inout [SessionEffect]) {
        guard isRecognizing else { return }
        isRecognizing = false
        windowOpenedAt = nil
        effects.append(.stopRecognition)
    }
}
