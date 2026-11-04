import Foundation

/// Decides what's on screen and how bright, in wall-clock time: crossfades between looks
/// (one per album) and fades to black when nothing has been playing for a while.
/// Pure state — the renderer asks it each frame.
public struct SceneDirector: Sendable {
    public var crossfadeDuration = 3.0
    /// Keep the picture up this long after the music stops (needle lifts, flips)…
    public var idleDelay = 20.0
    /// …then fade out over this long.
    public var fadeOutDuration = 4.0
    public var fadeInDuration = 1.5

    public private(set) var currentID: String?
    public private(set) var previousID: String?

    private var transitionStart: Double?
    private var inactiveSince: Double?
    private var brightness = 0.0
    private var lastUpdate: Double?

    public init() {}

    public struct Frame: Sendable, Equatable {
        /// 0 = previous look only, 1 = current only.
        public var mix: Float
        public var brightness: Float
        /// Once a crossfade completes, the previous look can be released.
        public var previousReleased: Bool
    }

    /// Returns true if this starts a transition (a different look).
    @discardableResult
    public mutating func show(_ id: String, at t: Double) -> Bool {
        guard id != currentID else { return false }
        previousID = currentID
        currentID = id
        // Nothing on screen yet (or still black): cut, don't crossfade from nothing.
        transitionStart = previousID == nil || brightness < 0.01 ? nil : t
        if transitionStart == nil { previousID = nil }
        return true
    }

    /// `active`: music is playing or about to (anything but idle / side ended).
    public mutating func update(at t: Double, active: Bool) -> Frame {
        let dt = lastUpdate.map { max(0, t - $0) } ?? 0
        lastUpdate = t

        if active {
            inactiveSince = nil
        } else if inactiveSince == nil {
            inactiveSince = t
        }
        let lit = inactiveSince.map { t - $0 < idleDelay } ?? true
        if lit {
            brightness = min(1, brightness + dt / fadeInDuration)
        } else {
            brightness = max(0, brightness - dt / fadeOutDuration)
        }

        var mix: Float = 1
        if let start = transitionStart {
            let x = min(1, max(0, (t - start) / crossfadeDuration))
            mix = Float(x * x * (3 - 2 * x))
            if x >= 1 {
                transitionStart = nil
                previousID = nil
            }
        }
        // Smoothstep the fade too: linear brightness ramps look steppy on a TV.
        let b = brightness * brightness * (3 - 2 * brightness)
        return Frame(mix: mix, brightness: Float(b), previousReleased: previousID == nil)
    }
}
