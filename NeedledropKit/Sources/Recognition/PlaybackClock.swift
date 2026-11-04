import Foundation

/// Where we are in the current track, between recognitions.
///
/// Each match gives an anchor (audio time → track position). Between anchors the clock
/// runs at the estimated playback rate. That's 1 + frequency skew until anchors span
/// long enough to fit a slope, which then absorbs speed error and wow. Small corrections
/// are slewed in over `slewDuration` so lyrics never jump; big ones (the needle was moved)
/// snap immediately.
public struct PlaybackClock: Sendable, Equatable {
    public struct Anchor: Sendable, Equatable {
        public var time: Double
        public var position: Double
    }

    public var slewDuration = 2.0
    public var jumpThreshold = 3.0
    /// Anchors must span this long before the fitted slope is trusted over the skew.
    public var minimumFitSpan = 40.0

    public private(set) var anchors: [Anchor]
    public private(set) var rate: Double
    public private(set) var lastError: Double = 0

    private var skewRate: Double
    private var base: Anchor
    private var slew: (start: Double, error: Double)?

    public init(time: Double, position: Double, frequencySkew: Double = 0) {
        let anchor = Anchor(time: time, position: position)
        anchors = [anchor]
        skewRate = Self.rate(fromSkew: frequencySkew)
        rate = skewRate
        base = anchor
    }

    /// Track position at audio time `t`.
    public func position(at t: Double) -> Double {
        var p = base.position + (t - base.time) * rate
        if let slew {
            let remaining = max(0, 1 - (t - slew.start) / slewDuration)
            p -= slew.error * remaining
        }
        return p
    }

    /// Audio time at which the track started (position 0).
    public var trackStartTime: Double { base.time - base.position / rate }

    /// Adds a recognition anchor. Returns the error against the prediction (seconds).
    @discardableResult
    public mutating func add(time: Double, position: Double, frequencySkew: Double = 0) -> Double {
        let error = position - self.position(at: time)
        lastError = error
        let anchor = Anchor(time: time, position: position)
        skewRate = Self.rate(fromSkew: frequencySkew)
        if abs(error) > jumpThreshold {
            anchors = [anchor]
            rate = skewRate
            slew = nil
        } else {
            anchors.append(anchor)
            if anchors.count > 8 { anchors.removeFirst() }
            rate = fittedRate() ?? skewRate
            slew = (time, error)
        }
        base = anchor
        return error
    }

    /// 0…1: how much to trust `position(at:)` now. Drops with staleness and big corrections.
    public func confidence(at t: Double) -> Double {
        let base = anchors.count >= 2 ? 0.9 : 0.6
        let age = max(0, t - (anchors.last?.time ?? t))
        return base * exp(-abs(lastError) / 2) * exp(-age / 180)
    }

    private func fittedRate() -> Double? {
        guard let first = anchors.first, let last = anchors.last, last.time - first.time >= minimumFitSpan else { return nil }
        let n = Double(anchors.count)
        let meanT = anchors.reduce(0) { $0 + $1.time } / n
        let meanP = anchors.reduce(0) { $0 + $1.position } / n
        var covariance = 0.0, variance = 0.0
        for a in anchors {
            covariance += (a.time - meanT) * (a.position - meanP)
            variance += (a.time - meanT) * (a.time - meanT)
        }
        guard variance > 0 else { return nil }
        return min(1.06, max(0.94, covariance / variance))
    }

    private static func rate(fromSkew skew: Double) -> Double {
        1 + min(0.03, max(-0.03, skew))
    }

    public static func == (a: PlaybackClock, b: PlaybackClock) -> Bool {
        a.anchors == b.anchors && a.rate == b.rate && a.base == b.base && a.lastError == b.lastError
    }
}
