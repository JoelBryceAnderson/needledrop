import Foundation

/// An identified track as the session saw it during a side.
public struct TrackObservation: Sendable, Equatable {
    public var identity: String
    /// Audio time at which the track's position was 0 (from the playback clock).
    public var clockStart: Double
    /// Seconds, if metadata knew.
    public var duration: Double?
    /// Audio times it was first and last the current track.
    public var firstSeen: Double
    public var lastSeen: Double

    public init(identity: String, clockStart: Double, duration: Double?, firstSeen: Double, lastSeen: Double) {
        self.identity = identity
        self.clockStart = clockStart
        self.duration = duration
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    var expectedEnd: Double? { duration.map { clockStart + $0 } }
}

public struct TrackSegment: Sendable, Equatable {
    /// Audio times.
    public var start: Double
    public var end: Double
    /// Index into the observations, or nil for an unidentified track.
    public var observation: Int?
    /// The boundary was placed by estimate, not at a gap or clear dip.
    public var uncertainStart = false
    public var uncertainEnd = false

    public init(start: Double, end: Double, observation: Int? = nil, uncertainStart: Bool = false, uncertainEnd: Bool = false) {
        self.start = start
        self.end = end
        self.observation = observation
        self.uncertainStart = uncertainStart
        self.uncertainEnd = uncertainEnd
    }

    public var duration: Double { end - start }
    public var uncertain: Bool { uncertainStart || uncertainEnd }
}

/// Decides where tracks begin and end within a recorded side.
///
/// 1. Cut at every detected gap (midpoint of the silence).
/// 2. Give each identified track the segment it was playing in. A segment with no track
///    whose neighbour's track should still be playing (by its known length) was a quiet
///    passage, not a gap: merge it back.
/// 3. A segment holding two tracks is a segue: split near the later track's clock start,
///    snapped to the quietest point within a few seconds. No clear dip → uncertain.
public enum TrackSplitter {
    public struct Input: Sendable {
        public var sideStart: Double
        public var sideEnd: Double
        public var recordingStart: Double
        public var recordingEnd: Double
        public var gaps: [ClosedRange<Double>]
        public var observations: [TrackObservation]
        /// dBFS per `envelopeInterval` from `recordingStart`.
        public var envelope: [Float]
        public var envelopeInterval: Double

        public init(sideStart: Double, sideEnd: Double, recordingStart: Double, recordingEnd: Double,
                    gaps: [ClosedRange<Double>], observations: [TrackObservation],
                    envelope: [Float], envelopeInterval: Double = 0.1) {
            self.sideStart = sideStart
            self.sideEnd = sideEnd
            self.recordingStart = recordingStart
            self.recordingEnd = recordingEnd
            self.gaps = gaps
            self.observations = observations
            self.envelope = envelope
            self.envelopeInterval = envelopeInterval
        }
    }

    public static let leadIn = 0.5
    public static let tail = 1.5
    /// How far from the clock's estimate a segue boundary may snap.
    public static let snapWindow = 4.0
    /// A dip must be this far below the window's median to count.
    public static let dipDepth: Float = 6
    /// A gap is a quiet passage if the previous track should run this far past it.
    public static let overrunTolerance = 5.0

    public static func split(_ input: Input) -> [TrackSegment] {
        let start = max(input.recordingStart, input.sideStart - leadIn)
        let end = min(input.recordingEnd, input.sideEnd + tail)
        guard end > start else { return [] }

        // 1. Gap cuts.
        let cuts = input.gaps
            .filter { $0.lowerBound > input.sideStart && $0.upperBound < input.sideEnd }
            .map { ($0.lowerBound + $0.upperBound) / 2 }
            .sorted()
        var segments = zip([start] + cuts, cuts + [end]).map { TrackSegment(start: $0, end: $1) }

        // 2. Which segment was each track playing in?
        func segmentIndex(_ t: Double) -> Int {
            segments.lastIndex { $0.start <= t } ?? 0
        }
        var members = Array(repeating: [Int](), count: segments.count)
        for (i, o) in input.observations.enumerated() {
            members[segmentIndex((o.firstSeen + o.lastSeen) / 2)].append(i)
        }

        // Merge empty segments into a neighbour whose track overruns into them.
        var k = 0
        while k < segments.count {
            if members[k].isEmpty {
                if k > 0, let last = members[k - 1].last,
                   let expected = input.observations[last].expectedEnd,
                   expected > segments[k].start + overrunTolerance {
                    segments[k - 1].end = segments[k].end
                    segments.remove(at: k)
                    members.remove(at: k)
                    continue
                }
                if k + 1 < segments.count, let first = members[k + 1].first,
                   input.observations[first].clockStart < segments[k + 1].start - overrunTolerance {
                    segments[k + 1].start = segments[k].start
                    segments.remove(at: k)
                    members.remove(at: k)
                    continue
                }
            }
            k += 1
        }

        // 3. Split segues.
        var result: [TrackSegment] = []
        for (segment, indices) in zip(segments, members) {
            let ordered = indices.sorted { input.observations[$0].clockStart < input.observations[$1].clockStart }
            guard ordered.count > 1 else {
                var s = segment
                s.observation = ordered.first
                result.append(s)
                continue
            }
            var pieceStart = segment.start
            var uncertainStart = false
            for (n, index) in ordered.enumerated() {
                var pieceEnd = segment.end
                var uncertainEnd = false
                if n + 1 < ordered.count {
                    let guess = min(max(input.observations[ordered[n + 1]].clockStart, pieceStart + 1), segment.end - 1)
                    let (boundary, clear) = snap(guess, in: input)
                    pieceEnd = boundary
                    uncertainEnd = !clear
                }
                result.append(TrackSegment(start: pieceStart, end: pieceEnd, observation: index,
                                           uncertainStart: uncertainStart, uncertainEnd: uncertainEnd))
                pieceStart = pieceEnd
                uncertainStart = uncertainEnd
            }
        }
        return result
    }

    /// The quietest point within `snapWindow` of `guess`, and whether it's a real dip.
    static func snap(_ guess: Double, in input: Input) -> (Double, Bool) {
        let interval = input.envelopeInterval
        let first = max(0, Int(((guess - snapWindow) - input.recordingStart) / interval))
        let last = min(input.envelope.count - 1, Int(((guess + snapWindow) - input.recordingStart) / interval))
        guard last - first >= 4 else { return (guess, false) }
        // Smooth over ~0.5 s so a single quiet block between two hits doesn't win.
        let radius = max(1, Int(0.25 / interval))
        var smoothed: [(time: Double, db: Float)] = []
        for i in first...last {
            let lo = max(0, i - radius), hi = min(input.envelope.count - 1, i + radius)
            let mean = input.envelope[lo...hi].reduce(0, +) / Float(hi - lo + 1)
            smoothed.append((input.recordingStart + (Double(i) + 0.5) * interval, mean))
        }
        let quietest = smoothed.min { $0.db < $1.db }!
        let median = smoothed.map(\.db).sorted()[smoothed.count / 2]
        let clear = median - quietest.db >= dipDepth
        return clear ? (quietest.time, true) : (guess, false)
    }
}
