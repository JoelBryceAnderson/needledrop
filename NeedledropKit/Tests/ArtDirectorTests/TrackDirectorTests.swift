import Foundation
import Synchronization
import Testing
import Visuals
@testable import ArtDirector

/// Replies from a queue and records every request.
private final class Transport: HTTPTransport {
    let replies: Mutex<[(Int, Data)]>
    let requests = Mutex<[URLRequest]>([])

    init(_ replies: [[String: Any]]) {
        self.replies = Mutex(replies.map { reply in
            let text = String(decoding: try! JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
            let body: [String: Any] = ["model": "claude-sonnet-5-5", "stop_reason": "end_turn",
                                       "content": [["type": "text", "text": text]]]
            return (200, try! JSONSerialization.data(withJSONObject: body))
        })
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.withLock { $0.append(request) }
        let (status, body) = replies.withLock { $0.removeFirst() }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    var bodies: [[String: Any]] {
        requests.withLock { $0.compactMap { ($0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] } }
    }
}

/// An original song: verse, chorus (repeated), verse, chorus, with a long gap before each chorus.
let songTimeline: LyricTimeline = {
    let words = [
        (0, 10.0, "we drove out past the edge of town"), (1, 14.0, "the radio was all we had"),
        (2, 18.0, "and every light was going down"),
        (3, 26.0, "so let it play"), (4, 30.0, "the needle finds the groove again"),
        (5, 34.0, "so let it play"),
        (6, 44.0, "a paper sun above the road"), (7, 48.0, "we folded up the map we had"),
        (8, 58.0, "so let it play"), (9, 62.0, "the needle finds the groove again"),
        (10, 66.0, "so let it play"),
    ]
    return LyricTimeline(lines: words.map { LyricTimeline.Line(index: $0.0, start: $0.1, shownUntil: $0.1 + 2.6, heldUntil: $0.1 + 4, text: $0.2) },
                         duration: 80)
}()

private func scoreJSON(keyframeBefore: Int = 3, transition: String = "refold", bigLine: Int = 3,
                       bigText: String = "so let it play") -> [String: Any] {
    [
        "sections": [
            ["start_line": 0, "label": "verse", "energy": "still"],
            ["start_line": 3, "label": "chorus", "energy": "directed"],
        ],
        "keyframes": [[
            "before_line": keyframeBefore, "before_line_text": "so let it", "framing": "lean_back", "intensity": 0.8,
            "creases": 2, "angle_degrees": -20, "accent_strip": NSNull(), "transition": transition, "palette": "swap",
        ]],
        "lines": [["line": bigLine, "text": bigText, "emphasis": "big", "placement": "upper", "animation": "default", "hold": false]],
        "notes": "Hold still through the verses so the chorus can lean back.",
    ]
}

@Suite struct LyricStructureTests {
    @Test func findsSectionsAtGapsAndTheChorusByRepeats() {
        let structure = songTimeline.structure()
        #expect(structure.sections.map(\.firstLine) == [0, 3, 6, 8])
        #expect(structure.sections.map(\.kind) == [.verse, .chorus, .verse, .chorus])
        #expect(structure.repeats[3] == structure.repeats[5])
        #expect(structure.repeats[3] == structure.repeats[8])
        #expect(structure.repeats[0] == nil)
    }

    @Test func gapsRunFromWhenTheLastLineCameDown() {
        #expect(songTimeline.gap(before: 3) == 26 - 20.6)
        #expect(songTimeline.gap(before: 0) == 10)
    }
}

@Suite struct TrackScoreTests {
    @Test func sanitizingRealignsShiftedLinesAndClampsValues() {
        var score = TrackScore(keyframes: [
            // Off by one (a lyric version with an extra line): found by its words.
            .init(beforeLine: 4, beforeLineText: "so let it", framing: .pushIn, intensity: 4, creases: 9, angleDegrees: 80),
            // No such words anywhere near: dropped.
            .init(beforeLine: 6, beforeLineText: "nothing like this", framing: .roll),
        ])
        score.lines = [.init(line: 99, text: "so let it play", emphasis: .big)]
        let clean = score.sanitized(for: songTimeline)
        #expect(clean.keyframes.count == 1)
        #expect(clean.keyframes[0].beforeLine == 3)
        #expect(clean.keyframes[0].intensity == 1)
        #expect(clean.keyframes[0].creases == 4)
        #expect(clean.keyframes[0].angleDegrees == 45)
        #expect(clean.lines.isEmpty)
    }

    @Test func framingsAreNamedCameras() {
        #expect(TrackScore.Framing.flat.camera(intensity: 1) == .identity)
        #expect(TrackScore.Framing.leanBack.camera(intensity: 1).pitch > 0.4)
        #expect(TrackScore.Framing.turnLeft.camera(intensity: 1).yaw < 0)
        #expect(TrackScore.Framing.pushIn.camera(intensity: 0.5).zoom > 1.1)
    }
}

@Suite struct ScoreCheckerTests {
    @Test func aMoveNeedsAGapLongEnoughForItsTransition() {
        // Line 4 follows line 3 with 1.4 s of quiet: too short for a refold, fine for a snap.
        let tight = TrackScore(keyframes: [.init(beforeLine: 4, framing: .roll, transition: .refold)])
        let issues = ScoreChecker.check(tight, timeline: songTimeline)
        #expect(issues.count == 1)
        #expect(issues[0].message.contains("3 (5.4 s)"))
        let quick = TrackScore(keyframes: [.init(beforeLine: 4, framing: .roll, transition: .snap)])
        #expect(ScoreChecker.check(quick, timeline: songTimeline).isEmpty)
    }

    @Test func holdingTheLineBeforeClosesTheGap() {
        var score = TrackScore(keyframes: [.init(beforeLine: 4, framing: .roll, transition: .snap)])
        score.lines = [.init(line: 3, text: "so let it play", hold: true)]
        #expect(ScoreChecker.check(score, timeline: songTimeline).count == 1)
    }

    @Test func bigIsForShortLines() {
        let score = TrackScore(lines: [.init(line: 4, text: "the needle finds", emphasis: .big),
                                       .init(line: 3, text: "so let it play", emphasis: .big)])
        let long = LyricTimeline(lines: songTimeline.lines.map { line in
            var l = line
            if l.index == 4 { l.text = "the needle finds the groove again and again tonight" }
            return l
        })
        let issues = ScoreChecker.check(score, timeline: long)
        #expect(issues.map(\.kind) == [.line(4)])
    }
}

@Suite struct TrackDirectorTests {
    private func director(_ transport: Transport) -> TrackDirector {
        let store = ScoreStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("needledrop-scores-\(UUID())"))
        return TrackDirector(client: ClaudeClient(apiKey: "test-key", model: TrackDirector.defaultModel, transport: transport),
                             store: store)
    }

    private let brief = TrackBrief(artist: "The Creases", title: "Let It Play", album: "Paper Weather", tempo: 112,
                                   timeline: songTimeline)

    @Test func sendsTheWholeLyricWithTimingAndStructure() async throws {
        let transport = Transport([scoreJSON()])
        let result = try await director(transport).score(for: brief)
        #expect(result.score.keyframes.count == 1)
        #expect(result.score.sections.map(\.energy) == [.still, .directed])
        let body = try #require(transport.bodies.first)
        #expect(body["model"] as? String == "claude-sonnet-5-5")
        let config = try #require(body["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "medium")
        let content = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        #expect(text.contains("3 | 26.0 | 28.6 | 5.4 | R0 | so let it play"))
        #expect(text.contains("lines 3–5, chorus"))
    }

    @Test func aScoreThatDoesntFitGetsOneCorrectionThenLosesWhatStillFails() async throws {
        // First reply: a refold in a 1.4 s gap. The correction keeps it there: it's dropped.
        let bad = scoreJSON(keyframeBefore: 4, transition: "refold")
        var badKeyframe = bad
        badKeyframe["keyframes"] = [[
            "before_line": 4, "before_line_text": "the needle finds", "framing": "roll", "intensity": 0.5,
            "creases": NSNull(), "angle_degrees": NSNull(), "accent_strip": NSNull(), "transition": "refold", "palette": "none",
        ]]
        let transport = Transport([badKeyframe, badKeyframe])
        let result = try await director(transport).score(for: brief)
        #expect(transport.requests.withLock { $0.count } == 2)
        let followUp = try #require((transport.bodies.last?["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
        #expect((followUp.first?["text"] as? String)?.contains("needs a 1.8 s gap") == true)
        #expect(result.score.keyframes.isEmpty)
        #expect(result.dropped.count == 1)
    }

    @Test func scoresAreCachedPerTrackAndLyricVersion() async throws {
        let transport = Transport([scoreJSON(), scoreJSON()])
        let d = director(transport)
        _ = try await d.score(for: brief)
        let again = try await d.score(for: brief)
        #expect(again.fromCache)
        var other = brief
        other.timeline.lines[0].text = "we drove out past the edge of the city"
        let fresh = try await d.score(for: other)
        #expect(!fresh.fromCache)
        #expect(transport.requests.withLock { $0.count } == 2)
    }
}
