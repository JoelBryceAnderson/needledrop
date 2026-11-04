import Foundation
import SignalAnalysis
import Visuals

/// What one light (or every channel of an area) should show right now.
public struct LightState: Sendable, Equatable {
    /// Hue and saturation (sRGB, brightest channel at 1 unless it's black).
    public var color: RGB
    /// 0…1 of the light's full output.
    public var brightness: Double

    public init(color: RGB, brightness: Double) {
        self.color = color
        self.brightness = brightness
    }

    public static let off = LightState(color: RGB(0, 0, 0), brightness: 0)
}

public struct LightShowConfig: Sendable, Equatable {
    /// The user's brightness, 0…1: what the light shows at rest, before pulses.
    public var brightness: Double
    /// How strong beat pulses are, 0…1 (scaled by `motion`).
    public var pulse: Double
    /// The Motion setting: 0 (still, no pulses), 0.5 (gentle), 1 (directed).
    public var motion: Double
    /// False for outputs too slow to pulse (groups over REST): colour only.
    public var pulses: Bool
    /// Seconds to fade from one album's colours to the next.
    public var crossfade: Double

    public init(brightness: Double = 0.7, pulse: Double = 0.5, motion: Double = 1, pulses: Bool = true, crossfade: Double = 3) {
        self.brightness = brightness
        self.pulse = pulse
        self.motion = motion
        self.pulses = pulses
        self.crossfade = crossfade
    }

    /// Pulse depth after the Motion setting.
    var pulseAmount: Double { pulses ? max(0, min(1, pulse)) * max(0, min(1, motion)) : 0 }
}

public struct LightShowInput: Sendable {
    public var palette: Palette
    public var features: AudioFeatures
    public var beatAge: Double?
    /// Music is playing (not idle, not between sides).
    public var active: Bool

    public init(palette: Palette, features: AudioFeatures = AudioFeatures(), beatAge: Double? = nil, active: Bool = false) {
        self.palette = palette
        self.features = features
        self.beatAge = beatAge
        self.active = active
    }
}

/// Turns the album's colours and the music into a light state, frame by frame:
/// the sheet colour (the paper the visuals fold), drifting toward the accent when the
/// music lifts, crossfading between albums, with gentle brightness pulses on the beat.
/// Deterministic for a given sequence of inputs and times.
public struct LightShow: Sendable {
    /// Colours as the shader sees them: dark → light, sheet then accent.
    public static func sheetAndAccent(_ palette: Palette) -> (sheet: RGB, accent: RGB) {
        let sorted = palette.colors.sorted { $0.luminance < $1.luminance }
        return (sorted[min(3, sorted.count - 1)], sorted[min(4, sorted.count - 1)])
    }

    private var fromColors: (sheet: RGB, accent: RGB)?
    private var toColors: (sheet: RGB, accent: RGB)?
    private var fadeStart = 0.0
    private var lastTime: Double?
    private var envelope = PulseEnvelope()
    private var lift = LiftTracker()
    private var accentMix = 0.0
    private var output: Double?

    public init() {}

    public mutating func update(_ input: LightShowInput, config: LightShowConfig, now: Double) -> LightState {
        let dt = lastTime.map { max(0, min(0.5, now - $0)) } ?? 0
        lastTime = now

        // Album colours, crossfaded.
        let target = Self.sheetAndAccent(input.palette)
        if toColors == nil {
            toColors = target
            fromColors = target
            fadeStart = now - config.crossfade
        } else if let to = toColors, to.sheet != target.sheet || to.accent != target.accent {
            fromColors = colors(at: now, crossfade: config.crossfade)
            toColors = target
            fadeStart = now
        }
        let shown = colors(at: now, crossfade: config.crossfade)

        // Sections: the accent comes up when the music lifts (a chorus, a drop).
        let lifted = input.active ? lift.update(level: Double(input.features.musicBandRMS), dt: dt) : lift.relax(dt: dt)
        let amount = input.active ? config.pulseAmount : 0
        let pulse = envelope.update(now: now, beatAge: input.active ? input.beatAge : nil,
                                    strength: Self.strength(input.features))
        let accentTarget = min(0.7, 0.55 * lifted + 0.2 * amount * pulse)
        accentMix += (accentTarget - accentMix) * Self.approach(dt: dt, tau: 0.4)

        let color = Self.normalized(HueColor.mix(shown.sheet, shown.accent, accentMix))
        let value = HueColor.value(HueColor.mix(shown.sheet, shown.accent, accentMix))
        // Dark albums sit dimmer than bright ones, but never so dim the colour is lost.
        var base = max(0, min(1, config.brightness)) * (0.45 + 0.55 * value)
        if !input.active { base *= 0.6 }
        // Pulses rise to the base brightness from a slightly dimmed rest.
        let depth = PulseEnvelope.maxDepth * amount
        let target2 = base * (1 - depth + depth * pulse)
        // A slew limit as a last guard against anything flash-like (setting jumps, toggles).
        let slewed: Double
        if let previous = output, dt > 0 {
            let step = Self.maxSlew * dt
            slewed = max(previous - step, min(previous + step, target2))
        } else {
            slewed = target2
        }
        output = slewed
        return LightState(color: color, brightness: slewed)
    }

    /// Brightness change per second the show never exceeds (fraction of full output).
    static let maxSlew = 6.0

    private func colors(at now: Double, crossfade: Double) -> (sheet: RGB, accent: RGB) {
        guard let from = fromColors, let to = toColors else { return (RGB(0, 0, 0), RGB(0, 0, 0)) }
        let t = crossfade > 0 ? max(0, min(1, (now - fadeStart) / crossfade)) : 1
        let s = t * t * (3 - 2 * t)
        return (HueColor.mix(from.sheet, to.sheet, s), HueColor.mix(from.accent, to.accent, s))
    }

    /// Louder passages pulse harder: the music band from −50 dB (0.3) to −15 dB (1).
    static func strength(_ features: AudioFeatures) -> Double {
        let db = Double(features.musicBandDB)
        guard db.isFinite else { return 0.3 }
        return max(0.3, min(1, 0.3 + 0.7 * (db + 50) / 35))
    }

    /// Scales a colour so its brightest channel is 1: the light's brightness carries the rest.
    static func normalized(_ c: RGB) -> RGB {
        let m = max(c.r, c.g, c.b)
        guard m > 1e-4 else { return RGB(1, 1, 1) }
        return RGB(c.r / m, c.g / m, c.b / m)
    }

    static func approach(dt: Double, tau: Double) -> Double {
        dt <= 0 ? 0 : 1 - exp(-dt / tau)
    }
}

/// A soft swell after each beat: a short eased rise, then an exponential fall.
/// Never more than one pulse every `minInterval` (fast tempos pulse every other beat),
/// and never deeper than `maxDepth` of the light's brightness, so it can't strobe.
public struct PulseEnvelope: Sendable {
    public static let attack = 0.07
    public static let decay = 0.30
    /// At most 2.5 pulses a second.
    public static let minInterval = 0.4
    public static let maxDepth = 0.35

    private var lastBeat: Double?
    private var pulseStart: Double?
    private var pulseStrength = 0.0

    public init() {}

    /// The pulse now, 0…1. `beatAge` is seconds since the last tracked beat (nil without one).
    public mutating func update(now: Double, beatAge: Double?, strength: Double) -> Double {
        if let beatAge, beatAge >= 0, beatAge < 0.25 {
            let beat = now - beatAge
            if lastBeat.map({ abs(beat - $0) > 0.05 }) ?? true {
                lastBeat = beat
                if pulseStart.map({ beat - $0 >= Self.minInterval }) ?? true {
                    pulseStart = beat
                    pulseStrength = max(0, min(1, strength))
                }
            }
        }
        guard let start = pulseStart else { return 0 }
        return pulseStrength * Self.shape(now - start)
    }

    /// The envelope `t` seconds after a beat.
    public static func shape(_ t: Double) -> Double {
        guard t >= 0 else { return 0 }
        if t < attack {
            let u = t / attack
            return u * u * (3 - 2 * u)
        }
        return exp(-(t - attack) / decay)
    }
}

/// Spots the music lifting (a chorus, a drop): a short-term level well above the
/// longer-term one. Returns 0…1, smoothed so it comes and goes over a second or two.
struct LiftTracker: Sendable {
    private var fast = 0.0
    private var slow = 0.0
    private var value = 0.0
    private var primed = false

    mutating func update(level: Double, dt: Double) -> Double {
        let level = max(0, level)
        if !primed {
            fast = level
            slow = level
            primed = true
        }
        fast += (level - fast) * LightShow.approach(dt: dt, tau: 1.5)
        slow += (level - slow) * LightShow.approach(dt: dt, tau: 12)
        let ratio = slow > 1e-5 ? fast / slow : 1
        let target = max(0, min(1, (ratio - 1.15) / 0.35))
        value += (target - value) * LightShow.approach(dt: dt, tau: 1.5)
        return value
    }

    mutating func relax(dt: Double) -> Double {
        value += (0 - value) * LightShow.approach(dt: dt, tau: 1.5)
        return value
    }
}

/// A token bucket: `rate` sends a second, at most `burst` at once.
public struct RateLimiter: Sendable {
    public let rate: Double
    public let burst: Double
    private var tokens: Double
    private var last: Double?

    public init(rate: Double, burst: Double = 1) {
        self.rate = rate
        self.burst = max(1, burst)
        tokens = max(1, burst)
    }

    /// True (and spends a token) if a send is allowed at `now`.
    public mutating func tryAcquire(now: Double) -> Bool {
        if let last { tokens = min(burst, tokens + max(0, now - last) * rate) }
        last = now
        guard tokens >= 1 - 1e-9 else { return false }  // float drift would otherwise skip a frame
        tokens -= 1
        return true
    }
}
