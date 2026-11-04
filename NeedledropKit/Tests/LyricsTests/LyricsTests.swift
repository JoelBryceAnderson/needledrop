import Foundation
import Lyrics
import Metadata
import Synchronization
import Testing

@Suite struct LRCParserTests {
    @Test func parsesTimestampsInEveryPrecision() {
        let lines = LRCParser.parse("""
            [00:12.34]Now here you go again
            [00:17.5]You say you want your freedom
            [01:02]Well who am I to keep you down
            [01:05.120]It's only right
            """)
        #expect(lines.map(\.time) == [12.34, 17.5, 62, 65.12])
        #expect(lines[0].text == "Now here you go again")
    }

    @Test func expandsMultipleStampsAndSorts() {
        let lines = LRCParser.parse("""
            [00:30.00][01:30.00]Thunder only happens when it's raining
            [00:10.00]Verse
            """)
        #expect(lines.map(\.time) == [10, 30, 90])
        #expect(lines[2].text == "Thunder only happens when it's raining")
    }

    @Test func ignoresTagsAndAppliesOffset() {
        let lines = LRCParser.parse("""
            [ar:Fleetwood Mac]
            [ti:Dreams]
            [length: 04:17]
            [offset:+500]
            [00:10.00]Line
            """)
        #expect(lines == [LyricLine(time: 9.5, text: "Line")])
    }

    @Test func keepsInstrumentalBreaksAndStripsWordStamps() {
        let lines = LRCParser.parse("[00:01.00]<00:01.00>Players <00:01.50>only <00:02.00>love\r\n[00:05.00]\r\nnot a lyric line")
        #expect(lines == [LyricLine(time: 1, text: "Players only love"), LyricLine(time: 5, text: "")])
    }

    @Test func rejectsGarbageStamps() {
        #expect(LRCParser.parse("[ab:cd]x\n[00:75.00]y\n[-1:00.00]z").isEmpty)
    }
}

@Suite struct LyricCueTests {
    private let lyrics = Lyrics(lines: [
        LyricLine(time: 10, text: "one"),
        LyricLine(time: 14, text: "two"),
        LyricLine(time: 18, text: ""),
        LyricLine(time: 40, text: "three"),
    ])

    @Test func findsTheLineSounding() {
        #expect(lyrics.cue(at: 5) == nil)
        let cue = lyrics.cue(at: 12)
        #expect(cue?.text == "one" && cue?.start == 10 && cue?.end == 14 && cue?.next == "two")
        #expect(lyrics.cue(at: 14)?.text == "two")
        #expect(lyrics.cue(at: 14)?.next == "three")  // skips the break
    }

    @Test func breaksAndLongGapsShowNothing() {
        #expect(lyrics.cue(at: 20) == nil)
        let late = Lyrics(lines: [LyricLine(time: 0, text: "hold"), LyricLine(time: 30, text: "next")])
        #expect(late.cue(at: 7.9)?.text == "hold")
        #expect(late.cue(at: 8.1) == nil)
        #expect(lyrics.cue(at: 47.9)?.text == "three" && lyrics.cue(at: 48.1) == nil)
    }
}

/// Canned responses by URL substring; unmatched URLs 404.
private final class FakeHTTP: HTTPClient {
    let routes: [(String, String)]
    let log = Mutex<[(URL, [String: String])]>([])
    let offline: Bool

    init(_ routes: [(String, String)], offline: Bool = false) {
        self.routes = routes
        self.offline = offline
    }

    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        log.withLock { $0.append((url, headers)) }
        if offline { throw URLError(.notConnectedToInternet) }
        guard let route = routes.first(where: { url.absoluteString.contains($0.0) }) else { throw HTTPError.status(404) }
        return Data(route.1.utf8)
    }

    var urls: [String] { log.withLock { $0.map(\.0.absoluteString) } }
}

@Suite struct LyricsProviderTests {
    private func dreams() -> TrackMetadata {
        var t = TrackMetadata(title: "Dreams", artist: "Fleetwood Mac")
        t.album = "Rumours"
        t.duration = 257.8
        return t
    }

    private func dir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("needledrop-lyrics-\(UUID())") }

    @Test func exactGetWithAllFieldsAndUserAgent() async throws {
        let http = FakeHTTP([("/get?", #"{"trackName":"Dreams","duration":258,"instrumental":false,"plainLyrics":"Now here","syncedLyrics":"[00:12.00]Now here you go again"}"#)])
        let lyrics = try #require(await LyricsProvider(cacheDirectory: dir(), http: http).lyrics(for: dreams()))
        #expect(lyrics.lines == [LyricLine(time: 12, text: "Now here you go again")])
        let url = try #require(http.urls.first)
        #expect(url.contains("artist_name=Fleetwood%20Mac") && url.contains("album_name=Rumours") && url.contains("duration=258"))
        #expect(http.log.withLock { $0[0].1["User-Agent"]?.hasPrefix("Needledrop/") } == true)
    }

    @Test func anExactMatchWithoutTimingKeepsLooking() async throws {
        // LRCLIB's exact record for N95 has plain lyrics only; other uploads have them synced.
        let http = FakeHTTP([
            ("/get?", #"{"trackName":"Dreams","duration":258,"instrumental":false,"plainLyrics":"Now here you go"}"#),
            ("/search?", #"[{"trackName":"Dreams","artistName":"Fleetwood Mac","duration":258,"syncedLyrics":"[00:12.00]Now here you go again"}]"#),
        ])
        let lyrics = try #require(await LyricsProvider(cacheDirectory: dir(), http: http).lyrics(for: dreams()))
        #expect(lyrics.isSynced)
        // Nothing synced anywhere: the plain text is still better than nothing.
        let plainOnly = FakeHTTP([("/get?", #"{"trackName":"Dreams","duration":258,"plainLyrics":"Now here you go"}"#),
                                  ("/search?", "[]")])
        let fallback = try #require(await LyricsProvider(cacheDirectory: dir(), http: plainOnly).lyrics(for: dreams()))
        #expect(!fallback.isSynced && fallback.plain == "Now here you go")
    }

    @Test func searchFallbackPrefersSyncedAndClosestDuration() async throws {
        let http = FakeHTTP([("/search?", #"""
            [{"trackName":"Dreams","duration":300,"syncedLyrics":"[00:01.00]live version"},
             {"trackName":"Dreams","duration":257,"plainLyrics":"plain only"},
             {"trackName":"Dreams","duration":259,"syncedLyrics":"[00:01.00]album version"}]
            """#)])
        let lyrics = try #require(await LyricsProvider(cacheDirectory: dir(), http: http).lyrics(for: dreams()))
        #expect(lyrics.lines.first?.text == "album version")
        #expect(http.urls.count == 2)
    }

    @Test func instrumentalsAreMarked() async throws {
        let http = FakeHTTP([("/get?", #"{"trackName":"Interlude","instrumental":true}"#)])
        let lyrics = try #require(await LyricsProvider(cacheDirectory: dir(), http: http).lyrics(for: dreams()))
        #expect(lyrics.instrumental && !lyrics.isSynced)
    }

    @Test func cachesHitsAndMisses() async {
        let directory = dir()
        let hit = FakeHTTP([("/get?", #"{"syncedLyrics":"[00:01.00]x"}"#)])
        _ = await LyricsProvider(cacheDirectory: directory, http: hit).lyrics(for: dreams())
        _ = await LyricsProvider(cacheDirectory: directory, http: hit).lyrics(for: dreams())
        #expect(hit.urls.count == 1)

        var other = dreams()
        other.title = "Unreleased"
        let miss = FakeHTTP([("/search?", "[]")])
        #expect(await LyricsProvider(cacheDirectory: directory, http: miss).lyrics(for: other) == nil)
        #expect(await LyricsProvider(cacheDirectory: directory, http: miss).lyrics(for: other) == nil)
        #expect(miss.urls.count == 2)  // get + search once; second time from the negative cache
    }

    @Test func offlineIsNotCached() async {
        let directory = dir()
        let offline = FakeHTTP([], offline: true)
        #expect(await LyricsProvider(cacheDirectory: directory, http: offline).lyrics(for: dreams()) == nil)
        let online = FakeHTTP([("/get?", #"{"syncedLyrics":"[00:01.00]x"}"#)])
        #expect(await LyricsProvider(cacheDirectory: directory, http: online).lyrics(for: dreams()) != nil)
    }
}
