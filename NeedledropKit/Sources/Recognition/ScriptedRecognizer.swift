import Foundation

/// A recognizer that "knows" what's on a recording: for tests, and for replaying a file
/// whose tracks you already know without hitting Shazam. Matches arrive after `latency`
/// seconds of audio inside a scripted segment, like a real recognizer would.
public final class ScriptedRecognizer: TrackRecognizer, @unchecked Sendable {
    public struct Segment: Sendable {
        /// Audio-time span this track occupies on the recording.
        public var start: Double
        public var end: Double
        public var track: TrackMatch
        /// Track position at `start` (non-zero if the recording starts mid-song).
        public var offset: Double
        /// Playback speed relative to the reference (1.003 = running 0.3% fast).
        public var rate: Double

        public init(start: Double, end: Double, track: TrackMatch, offset: Double = 0, rate: Double = 1) {
            self.start = start
            self.end = end
            self.track = track
            self.offset = offset
            self.rate = rate
        }
    }

    public let segments: [Segment]
    public var latency: Double

    private var handler: (@Sendable (RecognizerResult) -> Void)?
    private var windowStart: Double?
    private var answered = false

    public init(segments: [Segment], latency: Double = 4) {
        self.segments = segments
        self.latency = latency
    }

    public func setHandler(_ handler: @escaping @Sendable (RecognizerResult) -> Void) {
        self.handler = handler
    }

    public func beginWindow(sampleRate: Double) {
        windowStart = nil
        answered = false
    }

    public func feed(_ mono: UnsafePointer<Float>, frameCount: Int, endTime: Double) {
        let start = windowStart ?? endTime
        windowStart = start
        guard !answered, endTime - start >= latency,
              let segment = segments.first(where: { $0.start <= start && endTime <= $0.end }) else { return }
        answered = true
        var match = segment.track
        match.position = segment.offset + (endTime - segment.start) * segment.rate
        match.frequencySkew = segment.rate - 1
        handler?(.match(match))
    }

    public func endWindow() {
        windowStart = nil
    }
}
