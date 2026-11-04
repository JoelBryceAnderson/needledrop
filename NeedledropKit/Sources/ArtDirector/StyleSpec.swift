import Foundation
import Visuals

/// The art direction Claude returns for an album (strict JSON, schema below).
public struct StyleSpec: Codable, Sendable, Equatable {
    public struct ModeWeights: Codable, Sendable, Equatable {
        public var livingCover: Double
        public var paletteBleed: Double
        public var dissolve: Double
        public var virtualRecord: Double
        public var googie: Double

        enum CodingKeys: String, CodingKey {
            case livingCover = "living_cover", paletteBleed = "palette_bleed", dissolve
            case virtualRecord = "virtual_record", googie
        }
    }

    public struct Folds: Codable, Sendable, Equatable {
        public var angleDegrees: Double
        public var count: Int

        enum CodingKeys: String, CodingKey { case angleDegrees = "angle_degrees", count }
    }

    public struct Motion: Codable, Sendable, Equatable {
        public var speed: Double
        public var bassResponse: Double
        public var beatResponse: Double
        public var turbulence: Double

        enum CodingKeys: String, CodingKey {
            case speed, bassResponse = "bass_response", beatResponse = "beat_response", turbulence
        }
    }

    public struct Typography: Codable, Sendable, Equatable {
        public var font: String
        public var weight: String
        public var letterCase: String
        public var animation: String

        enum CodingKeys: String, CodingKey { case font, weight, letterCase = "case", animation }
    }

    public struct Shader: Codable, Sendable, Equatable {
        /// Body of `customScene`; empty unless `background` is "custom".
        public var mslBody: String

        enum CodingKeys: String, CodingKey { case mslBody = "msl_body" }
    }

    public var mood: String
    public var palette: [String]
    public var background: String
    public var modeWeights: ModeWeights
    public var folds: Folds
    public var motion: Motion
    public var typography: Typography
    public var shader: Shader

    enum CodingKeys: String, CodingKey {
        case mood, palette, background, modeWeights = "mode_weights", folds, motion, typography, shader
    }

    // MARK: - Validation

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case palette(String)
        case value(String)

        public var description: String {
            switch self {
            case .palette(let m), .value(let m): m
            }
        }
    }

    /// Checks what the JSON schema can't express (hex colours, enums, ranges).
    public func validate() -> [Problem] {
        var problems: [Problem] = []
        if palette.count < 3 || palette.count > 8 { problems.append(.palette("palette needs 3–8 colours, got \(palette.count)")) }
        for hex in palette where Self.rgb(hex) == nil { problems.append(.palette("“\(hex)” isn't a #RRGGBB colour")) }
        if LookStyle.Background(rawValue: background) == nil || background == "smoke" {
            problems.append(.value("background must be paper, googie or custom"))
        }
        if LookStyle.Font(rawValue: typography.font) == nil { problems.append(.value("unknown font “\(typography.font)”")) }
        if LookStyle.Weight(rawValue: typography.weight) == nil { problems.append(.value("unknown weight “\(typography.weight)”")) }
        if LookStyle.LetterCase(rawValue: typography.letterCase) == nil { problems.append(.value("unknown case “\(typography.letterCase)”")) }
        if LookStyle.Animation(rawValue: typography.animation) == nil { problems.append(.value("unknown animation “\(typography.animation)”")) }
        if background == "custom", shader.mslBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append(.value("background is custom but shader.msl_body is empty"))
        }
        return problems
    }

    /// What the renderer uses. `shaderValid`: the custom body passed the sandbox.
    public func lookStyle(shaderValid: Bool) -> LookStyle {
        var s = LookStyle()
        s.background = LookStyle.Background(rawValue: background) ?? .paper
        // The cover takes the strongest of the three cover modes.
        let covers: [(LookStyle.CoverMode, Double)] = [
            (.living, modeWeights.livingCover), (.dissolve, modeWeights.dissolve), (.record, modeWeights.virtualRecord),
        ]
        s.coverMode = covers.max { $0.1 < $1.1 }?.0 ?? .living
        if s.background == .custom, !shaderValid { s.background = .paper }
        s.customShaderBody = s.background == .custom ? shader.mslBody : nil
        s.foldAngle = folds.angleDegrees
        s.foldCount = folds.count
        s.speed = motion.speed
        s.bassResponse = motion.bassResponse
        s.beatResponse = motion.beatResponse
        s.turbulence = motion.turbulence
        s.font = LookStyle.Font(rawValue: typography.font) ?? .serif
        s.weight = LookStyle.Weight(rawValue: typography.weight) ?? .bold
        s.letterCase = LookStyle.LetterCase(rawValue: typography.letterCase) ?? .asIs
        s.animation = LookStyle.Animation(rawValue: typography.animation) ?? .ink
        return s.clamped()
    }

    public var paletteColors: Palette? {
        let colors = palette.compactMap(Self.rgb)
        return colors.count >= 3 ? Palette(colors: colors) : nil
    }

    static func rgb(_ hex: String) -> RGB? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let value = UInt32(h, radix: 16) else { return nil }
        return RGB(hex: value)
    }

    // MARK: - JSON schema (structured outputs)

    /// The schema sent as `output_config.format`. Ranges and hex formats aren't expressible
    /// there, so they're stated in the prompt and checked by `validate()`.
    static var schema: [String: Any] {
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "additionalProperties": false, "required": Array(properties.keys).sorted(), "properties": properties]
        }
        let number: [String: Any] = ["type": "number"]
        func choice(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
        return object([
            "mood": ["type": "string"],
            "palette": ["type": "array", "items": ["type": "string"]],
            "background": choice(["paper", "googie", "custom"]),
            "mode_weights": object([
                "living_cover": number, "palette_bleed": number, "dissolve": number,
                "virtual_record": number, "googie": number,
            ]),
            "folds": object(["angle_degrees": number, "count": ["type": "integer"]]),
            "motion": object(["speed": number, "bass_response": number, "beat_response": number, "turbulence": number]),
            "typography": object([
                "font": choice(LookStyle.Font.allCases.map(\.rawValue)),
                "weight": choice(LookStyle.Weight.allCases.map(\.rawValue)),
                "case": choice(LookStyle.LetterCase.allCases.map(\.rawValue)),
                "animation": choice(LookStyle.Animation.allCases.map(\.rawValue)),
            ]),
            "shader": object(["msl_body": ["type": "string"]]),
        ])
    }
}
