import Foundation
import Visuals

/// What Claude is told about an album.
public struct AlbumBrief: Sendable, Equatable {
    public var artist: String
    public var album: String
    public var year: Int?
    public var genre: String?
    public var tracks: [String]
    /// JPEG or PNG.
    public var artwork: Data?
    /// The palette extracted from the cover, as #RRGGBB.
    public var extractedPalette: [String]

    public init(artist: String, album: String, year: Int? = nil, genre: String? = nil, tracks: [String] = [],
                artwork: Data? = nil, extractedPalette: [String] = []) {
        self.artist = artist
        self.album = album
        self.year = year
        self.genre = genre
        self.tracks = tracks
        self.artwork = artwork
        self.extractedPalette = extractedPalette
    }
}

public enum Theme: String, Codable, Sendable, CaseIterable {
    /// Claude chooses.
    case auto
    case paper
    case googie
}

public struct Direction: Sendable, Equatable {
    public var spec: StyleSpec
    public var style: LookStyle
    public var palette: Palette?
    /// The custom shader failed validation twice; the look fell back to a built-in background.
    public var shaderFellBack: Bool
}

/// Claude as art director: one request per new album (cached), a strict-JSON style spec,
/// and a sandboxed custom shader that gets one chance to be fixed.
public actor ArtDirector {
    private let client: ClaudeClient
    private let store: StyleStore
    private let validate: @Sendable (String) async -> ShaderValidator.Outcome

    public init(client: ClaudeClient, store: StyleStore,
                validate: @escaping @Sendable (String) async -> ShaderValidator.Outcome = { await ShaderValidator.validate(body: $0) }) {
        self.client = client
        self.store = store
        self.validate = validate
    }

    /// The cached direction for `key`, or a new one from Claude. `reroll` asks for a fresh
    /// take unless the current one is pinned.
    public func direction(for brief: AlbumBrief, key: String, theme: Theme, reroll: Bool = false) async throws -> Direction {
        let pinned = await store.isPinned(key)
        if let cached = await store.current(for: key), !reroll || pinned {
            var shaderValid = true
            if cached.background == "custom" { shaderValid = await validate(cached.shader.mslBody) == .valid }
            return finish(cached, shaderValid: shaderValid)
        }
        let previous = await store.history(for: key).map(\.mood)

        var messages: [[String: Any]] = [["role": "user", "content": userContent(brief, theme: theme, previousMoods: previous)]]
        var reply = try await client.send(system: Self.system, messages: messages, schema: StyleSpec.schema)
        var spec = try decode(reply.text)

        // One correction turn if the spec or its shader doesn't pass.
        var problem = spec.validate().first.map(\.description)
        if problem == nil, spec.background == "custom", case .invalid(let reason) = await validate(spec.shader.mslBody) {
            problem = "The shader failed validation: \(reason)"
        }
        var shaderValid = spec.background != "custom"
        if let problem {
            messages.append(["role": "assistant", "content": reply.content])
            messages.append(["role": "user", "content": "\(problem)\n\nReturn the complete JSON again with that fixed; keep the rest unless it needs to change."])
            reply = try await client.send(system: Self.system, messages: messages, schema: StyleSpec.schema)
            spec = try decode(reply.text)
        }
        if spec.background == "custom" {
            shaderValid = await validate(spec.shader.mslBody) == .valid
        }
        await store.add(spec, for: key, model: reply.model)
        return finish(spec, shaderValid: shaderValid)
    }

    private func finish(_ spec: StyleSpec, shaderValid: Bool) -> Direction {
        Direction(spec: spec, style: spec.lookStyle(shaderValid: shaderValid), palette: spec.paletteColors,
                  shaderFellBack: spec.background == "custom" && !shaderValid)
    }

    private func decode(_ text: String) throws -> StyleSpec {
        do {
            return try JSONDecoder().decode(StyleSpec.self, from: Data(text.utf8))
        } catch {
            throw ClaudeError.malformed("\(error)")
        }
    }

    // MARK: - Prompt

    private func userContent(_ brief: AlbumBrief, theme: Theme, previousMoods: [String]) -> [[String: Any]] {
        var content: [[String: Any]] = []
        if let artwork = brief.artwork {
            let png = artwork.starts(with: [0x89, 0x50, 0x4E, 0x47])
            content.append(["type": "image", "source": [
                "type": "base64", "media_type": png ? "image/png" : "image/jpeg",
                "data": artwork.base64EncodedString(),
            ]])
        }
        var lines = ["Album: \(brief.album)", "Artist: \(brief.artist)"]
        if let year = brief.year { lines.append("Year: \(year)") }
        if let genre = brief.genre { lines.append("Genre: \(genre)") }
        if !brief.tracks.isEmpty { lines.append("Tracks heard so far: \(brief.tracks.joined(separator: "; "))") }
        if !brief.extractedPalette.isEmpty { lines.append("Palette extracted from the cover (most dominant first): \(brief.extractedPalette.joined(separator: " "))") }
        switch theme {
        case .auto: lines.append("Theme: your choice of background.")
        case .paper: lines.append("Theme: paper — set background to \"paper\".")
        case .googie: lines.append("Theme: Googie — set background to \"googie\" and translate this album into mid-century atomic-age design (typography included), using its own colours.")
        }
        if !previousMoods.isEmpty {
            lines.append("Earlier directions for this album (take it somewhere different this time): \(previousMoods.joined(separator: " | "))")
        }
        lines.append("The cover image above is the album artwork.")
        content.append(["type": "text", "text": lines.joined(separator: "\n")])
        return content
    }

    static let system = """
        You are the art director for Needledrop, which turns a living-room TV into a visual \
        world for whatever vinyl record is playing. For each album you set one look that lasts \
        the whole record. Return it as JSON matching the schema.

        The medium: the picture is rendered at 480 lines and reaches a 65" TV over composite \
        video. Big flat shapes, bold colour and slow, deliberate motion read beautifully; fine \
        detail, thin lines, small text and fast flicker turn to mush. Aim for something that \
        looks like a considered, pre-rendered music video for this record, not a screensaver.

        What you control:
        - palette: 6 colours as #RRGGBB, drawn from the cover but curated (they're shown dark \
        to light; the two lightest/middle ones become the main paper colours).
        - background: "paper" (one sheet folded along a few long straight creases, each strip \
        lit by its own angle), "googie" (mid-century atomic-age: starbursts, boomerangs, kidney \
        shapes in flat colour), or "custom" (your own animated fragment shader, below). Use \
        custom only when the album calls for something the built-ins can't do.
        - folds: angle_degrees (-45…45, the creases' lean) and count (2…4). Lyrics are set \
        along these creases, so they shape the whole composition, whatever the background.
        - motion: speed, bass_response, beat_response (0…2, 1 = default) and turbulence (0…1, \
        how much the folds wander). Calm records want low values.
        - typography for the lyrics and caption: font (serif, sans, rounded, mono, condensed, \
        geometric), weight, case, and animation ("ink": each line soaks into the paper; \
        "typewriter": words print one at a time with the singing).
        - mode_weights (0…1 each): how much the album leans on living_cover (the artwork with \
        its subject lifted off the background), palette_bleed, dissolve (the cover breaking \
        into pieces on transients), virtual_record (a spinning record) and googie.
        - mood: a few words naming the look.

        Custom shader contract (only when background is "custom"; otherwise msl_body is ""):
        write only the body of this Metal function; it must return a float3 colour in 0…1.
            float3 customScene(float2 uv, constant Uniforms &u, constant float4 *pal) {
                float2 resolution; float aspect; float time;  // already set; time is smooth, seconds-ish
                float bass, mids, highs, level, beat;         // 0…1, already smoothed
                { /* your body */ }
            }
        uv is 0…1 with y down. pal[0]…pal[5] are your palette, dark to light (use pal[i].rgb). \
        Helpers you can call: hash21(float2), vnoise(float2), fbm(float2) (4 octaves), \
        paletteAt(pal, float t), rot2(float2, float), smin(float, float, float), \
        sdStar(float2 p, float r, int n, float m). No #directives, textures, samplers, device \
        memory, while loops or goto; bounded for loops only. Keep it cheap (under 8 ms a frame \
        at 854×480 on an Apple-silicon Mac mini: a handful of fbm calls, loops of at most a few \
        dozen iterations). It's checked by compiling it and rendering test frames; if it fails \
        you'll get the error and one chance to fix it.
        """
}
