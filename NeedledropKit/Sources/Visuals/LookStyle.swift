import Foundation

/// How one album is rendered: the art direction, whether it came from Claude or a built-in
/// theme. Everything is optional-with-defaults so a partial direction still works.
public struct LookStyle: Sendable, Equatable, Codable {
    public enum Background: String, Sendable, Codable, CaseIterable {
        /// A sheet folded along a few creases.
        case paper
        /// The original palette-bleed flow.
        case smoke
        /// Mid-century atomic-age: starbursts, boomerangs, kidney shapes.
        case googie
        /// A Claude-written fragment shader (see `customShaderBody`).
        case custom
    }

    public enum Font: String, Sendable, Codable, CaseIterable {
        case serif, sans, rounded, mono, condensed
        /// Retro-futurist geometric sans for Googie.
        case geometric
    }

    public enum Weight: String, Sendable, Codable, CaseIterable {
        case regular, bold, heavy
    }

    public enum LetterCase: String, Sendable, Codable, CaseIterable {
        case asIs = "as_is", upper, lower, title
    }

    public enum Animation: String, Sendable, Codable, CaseIterable {
        /// Ink soaks in, line by line.
        case ink
        /// Words print one at a time, in time with the singing.
        case typewriter
    }

    public enum CoverMode: String, Sendable, Codable, CaseIterable {
        /// The artwork with its subject lifted off the background.
        case living
        /// The artwork in paper shards that fly out on transients.
        case dissolve
        /// A record spinning, the artwork as its label.
        case record
    }

    public var background: Background = .paper
    public var coverMode: CoverMode = .living
    /// Overrides for the fold composition (degrees from horizontal; 2…4 creases).
    public var foldAngle: Double?
    public var foldCount: Int?
    /// 1 = default. Speed of everything; how much bass and beats push the scene; how much
    /// the folds wander.
    public var speed = 1.0
    public var bassResponse = 1.0
    public var beatResponse = 1.0
    public var turbulence = 0.5
    public var font: Font = .serif
    public var weight: Weight = .bold
    public var letterCase: LetterCase = .asIs
    public var animation: Animation = .ink
    /// Body of `customScene(...)` for `.custom` — already validated.
    public var customShaderBody: String?

    public init() {}

    /// The built-in Googie translation of any album.
    public static var googie: LookStyle {
        var s = LookStyle()
        s.background = .googie
        s.font = .geometric
        s.weight = .heavy
        s.letterCase = .upper
        s.speed = 1.1
        return s
    }

    /// Clamps numbers into ranges the renderer handles well.
    public func clamped() -> LookStyle {
        var s = self
        s.speed = min(2, max(0.25, speed))
        s.bassResponse = min(2, max(0, bassResponse))
        s.beatResponse = min(2, max(0, beatResponse))
        s.turbulence = min(1, max(0, turbulence))
        s.foldAngle = foldAngle.map { min(45, max(-45, $0)) }
        s.foldCount = foldCount.map { min(4, max(2, $0)) }
        if background == .custom, customShaderBody == nil { s.background = .paper }
        return s
    }

    public func apply(case text: String) -> String {
        switch letterCase {
        case .asIs: text
        case .upper: text.uppercased()
        case .lower: text.lowercased()
        case .title: text.capitalized
        }
    }
}
