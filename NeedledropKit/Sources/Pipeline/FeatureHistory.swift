import SignalAnalysis

/// The last few seconds of per-hop features, so output can be delayed to line up with
/// what's heard. (In this setup the room hears the record through AirPlay, ~2 s after
/// the Mac does.)
public struct FeatureHistory: Sendable {
    public static let maximumDelay = 5.0

    private var entries: [AudioFeatures]
    private var next = 0
    private var count = 0

    public init(capacity: Int = 1024) {
        entries = Array(repeating: AudioFeatures(), count: capacity)
    }

    public mutating func append(_ features: AudioFeatures) {
        entries[next] = features
        next = (next + 1) % entries.count
        count = min(count + 1, entries.count)
    }

    /// Features as of `delay` seconds before the newest hop, plus seconds since the last
    /// beat at that point. Falls back to the oldest kept hop if history is shorter.
    public func features(delayedBy delay: Double) -> (features: AudioFeatures, beatAge: Double?) {
        guard count > 0 else { return (AudioFeatures(), nil) }
        let newest = entry(0)
        let target = newest.time - max(0, delay)
        var i = 0
        while i + 1 < count, entry(i).time > target { i += 1 }
        let found = entry(i)
        var beatAge: Double?
        var j = i
        while j < count, found.time - entry(j).time <= 2 {
            if entry(j).beat {
                beatAge = found.time - entry(j).time
                break
            }
            j += 1
        }
        return (found, beatAge)
    }

    /// `back` hops before the newest.
    private func entry(_ back: Int) -> AudioFeatures {
        entries[(next - 1 - back + entries.count * 2) % entries.count]
    }
}
