import Foundation
import Synchronization
import Testing
import Visuals
@testable import ArtDirector

/// Replies from a queue and records every request.
private final class FakeTransport: HTTPTransport {
    let replies: Mutex<[(Int, Data)]>
    let requests = Mutex<[URLRequest]>([])

    init(_ replies: [(Int, [String: Any])]) {
        self.replies = Mutex(replies.map { ($0.0, try! JSONSerialization.data(withJSONObject: $0.1)) })
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.withLock { $0.append(request) }
        let (status, body) = replies.withLock { $0.removeFirst() }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }

    var bodies: [[String: Any]] {
        requests.withLock { $0.compactMap { ($0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] } }
    }
}

private func spec(background: String = "paper", shader: String = "", mood: String = "Sun-bleached and slow",
                  palette: [String] = ["#12343B", "#2D6A6F", "#C8553D", "#E8A33D", "#F2E8CF", "#0A1A1E"]) -> [String: Any] {
    [
        "mood": mood, "palette": palette, "background": background,
        "mode_weights": ["living_cover": 0.8, "palette_bleed": 0.2, "dissolve": 0.1, "virtual_record": 0.3, "googie": 0],
        "folds": ["angle_degrees": -22, "count": 3],
        "motion": ["speed": 0.7, "bass_response": 0.8, "beat_response": 0.5, "turbulence": 0.3],
        "typography": ["font": "serif", "weight": "bold", "case": "as_is", "animation": "typewriter"],
        "shader": ["msl_body": shader],
    ]
}

private func message(_ spec: [String: Any], stop: String = "end_turn") -> (Int, [String: Any]) {
    let text = String(decoding: try! JSONSerialization.data(withJSONObject: spec), as: UTF8.self)
    return (200, [
        "model": "claude-opus-5-5", "stop_reason": stop,
        "content": [["type": "thinking", "thinking": "", "signature": "sig"], ["type": "text", "text": text]],
    ])
}

private let brief = AlbumBrief(artist: "The Creases", album: "Paper Weather", year: 2026, tracks: ["Paper Weather"],
                               artwork: Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), extractedPalette: ["#15333B", "#E6A13D"])

private func director(_ transport: FakeTransport, valid: @escaping @Sendable (String) -> Bool = { _ in true }) -> (ArtDirector, StyleStore) {
    let store = StyleStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("needledrop-styles-\(UUID())"))
    let client = ClaudeClient(apiKey: "test-key", transport: transport)
    return (ArtDirector(client: client, store: store, validate: { valid($0) ? .valid : .invalid("NaN at time 7.3") }), store)
}

@Suite struct ArtDirectorTests {
    @Test func sendsAWellFormedRequest() async throws {
        let transport = FakeTransport([message(spec())])
        let (director, _) = director(transport)
        _ = try await director.direction(for: brief, key: "a", theme: .googie)

        let request = try #require(transport.requests.withLock { $0.first })
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let body = try #require(transport.bodies.first)
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["temperature"] == nil && body["thinking"] == nil)
        let config = try #require(body["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "high")
        #expect((config["format"] as? [String: Any])?["type"] as? String == "json_schema")
        let content = try #require(((body["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        let image = try #require(content.first { $0["type"] as? String == "image" })
        #expect((image["source"] as? [String: Any])?["media_type"] as? String == "image/png")
        let text = try #require(content.first { $0["type"] as? String == "text" }?["text"] as? String)
        #expect(text.contains("Paper Weather") && text.contains("Googie"))
    }

    @Test func turnsTheSpecIntoAStyleAndCachesIt() async throws {
        let transport = FakeTransport([message(spec())])
        let (director, _) = director(transport)
        let first = try await director.direction(for: brief, key: "a", theme: .auto)
        #expect(first.style.background == .paper)
        #expect(first.style.foldAngle == -22 && first.style.animation == .typewriter)
        #expect(first.palette?.colors.count == Palette.size)
        _ = try await director.direction(for: brief, key: "a", theme: .auto)
        let calls: Int = transport.requests.withLock { $0.count }
        #expect(calls == 1)  // one call per album
    }

    @Test func aFailingShaderGetsOneFixWithTheErrorAndTheReplyEchoed() async throws {
        let transport = FakeTransport([
            message(spec(background: "custom", shader: "return float3(sqrt(-1.0));")),
            message(spec(background: "custom", shader: "return pal[2].rgb * uv.x;")),
        ])
        let (director, _) = director(transport, valid: { !$0.contains("sqrt") })
        let result = try await director.direction(for: brief, key: "a", theme: .auto)
        #expect(result.style.background == .custom && !result.shaderFellBack)
        #expect(result.style.customShaderBody == "return pal[2].rgb * uv.x;")

        let second = try #require(transport.bodies.last?["messages"] as? [[String: Any]])
        #expect(second.count == 3)
        // The first reply is sent back exactly, thinking block included.
        let echoed = try #require(second[1]["content"] as? [[String: Any]])
        #expect(echoed.first?["type"] as? String == "thinking" && echoed.first?["signature"] as? String == "sig")
        #expect((second[2]["content"] as? String)?.contains("NaN at time 7.3") == true)
    }

    @Test func aShaderThatFailsTwiceFallsBackToPaper() async throws {
        let bad = message(spec(background: "custom", shader: "return float3(sqrt(-1.0));"))
        let (director, _) = director(FakeTransport([bad, bad]), valid: { _ in false })
        let result = try await director.direction(for: brief, key: "a", theme: .auto)
        #expect(result.style.background == .paper && result.shaderFellBack)
        #expect(result.style.foldAngle == -22)  // the rest of the direction still applies
    }

    @Test func refusalsAndErrorsSurface() async {
        let refusal: (Int, [String: Any]) = (200, ["stop_reason": "refusal", "stop_details": ["category": "cyber"], "content": []])
        let (a, _) = director(FakeTransport([refusal]))
        await #expect(throws: ClaudeError.refusal("cyber")) { try await a.direction(for: brief, key: "a", theme: .auto) }
        let (b, _) = director(FakeTransport([(401, ["error": ["message": "invalid x-api-key"]])]))
        await #expect(throws: ClaudeError.http(401, "invalid x-api-key")) { try await b.direction(for: brief, key: "a", theme: .auto) }
    }

    @Test func rerollAsksForSomethingNewUnlessPinned() async throws {
        let transport = FakeTransport([message(spec()), message(spec(mood: "Night swim"))])
        let (director, store) = director(transport)
        _ = try await director.direction(for: brief, key: "a", theme: .auto)
        let rerolled = try await director.direction(for: brief, key: "a", theme: .auto, reroll: true)
        #expect(rerolled.spec.mood == "Night swim")
        let prompt = try #require((((transport.bodies.last?["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])?.last?["text"] as? String)
        #expect(prompt.contains("Sun-bleached and slow"))

        await store.setPinned(true, for: "a")
        let pinned = try await director.direction(for: brief, key: "a", theme: .auto, reroll: true)
        #expect(pinned.spec.mood == "Night swim")
        let callsAfter: Int = transport.requests.withLock { $0.count }
        #expect(callsAfter == 2)
    }

    @Test func specValidationCatchesWhatTheSchemaCannot() throws {
        var bad = spec(palette: ["#12343B", "teal", "#C8553D"])
        bad["background"] = "smoke"
        let decoded = try JSONDecoder().decode(StyleSpec.self, from: JSONSerialization.data(withJSONObject: bad))
        let problems = decoded.validate().map(\.description)
        #expect(problems.contains { $0.contains("teal") })
        #expect(problems.contains { $0.contains("background") })
    }
}
