import SessionState
import SignalAnalysis

/// Human-level summary of a replay: the sides found and the tracks within them,
/// with per-track tempo and level. Used by the CLI and integration tests.
public struct SideReport: Sendable {
    public struct Track: Sendable {
        public var start: Double
        public var end: Double
        /// Median tracked tempo over the track (nil if none locked).
        public var tempo: Double?
        public var peakDB: Float
        public var clippedSamples: Int
    }

    public struct Side: Sendable {
        public var start: Double
        public var end: Double?
        public var endReason: SideEndReason?
        public var tracks: [Track]
    }

    public var sides: [Side]

    /// `timeline` is optional; without it tracks carry no tempo/level.
    public init(events: [SideEvent], timeline: [AudioFeatures] = []) {
        var sides: [Side] = []
        var current: (start: Double, boundaries: [Double])?

        func closeSide(end: Double?, reason: SideEndReason?) {
            guard let side = current else { return }
            let points = [side.start] + side.boundaries + [end ?? timeline.last?.time ?? side.start]
            var tracks: [Track] = []
            var i = 0
            while i + 1 < points.count {
                tracks.append(Self.track(from: points[i], to: points[i + 1], timeline: timeline))
                i += 2
            }
            sides.append(Side(start: side.start, end: end, endReason: reason, tracks: tracks))
            current = nil
        }

        for event in events {
            switch event {
            case .sideStarted(let t):
                closeSide(end: nil, reason: nil)
                current = (t, [])
            case .gapStarted:
                break
            case .trackGap(let start, let end, _):
                current?.boundaries += [start, end]
            case .sideEnded(_, let end, let reason):
                closeSide(end: end, reason: reason)
            }
        }
        closeSide(end: nil, reason: nil)
        self.sides = sides
    }

    private static func track(from start: Double, to end: Double, timeline: [AudioFeatures]) -> Track {
        let slice = timeline.filter { $0.time >= start && $0.time <= end }
        // Ignore the first few seconds while the tempo tracker locks on.
        let tempos = slice.filter { $0.time >= start + 5 }.compactMap(\.tempo).sorted()
        return Track(
            start: start, end: end,
            tempo: tempos.isEmpty ? nil : tempos[tempos.count / 2],
            peakDB: decibels(slice.map(\.peak).max() ?? 0),
            clippedSamples: slice.reduce(0) { $0 + $1.clippedSamples }
        )
    }
}
