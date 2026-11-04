import Foundation
import Lyrics
import Metadata
import Pipeline
import Recognition

/// What's on a recording, as a `<file>.tracks.json` sidecar. With one present, replay uses
/// `ScriptedRecognizer` instead of Shazam, so recognition, the clock and metadata can be
/// exercised offline, unsigned, or with audio Shazam can't match (like synthetic sides).
public struct ReplayScript: Codable, Sendable {
    public struct Track: Codable, Sendable {
        public var start: Double
        public var end: Double
        public var title: String
        public var artist: String
        public var appleMusicID: String?
        /// Track position at `start` (default 0).
        public var offset: Double?
        /// Playback speed (default 1).
        public var rate: Double?
        /// Optional local metadata, so a replay needs no online lookups. Paths are
        /// relative to the sidecar.
        public var album: String?
        public var year: Int?
        public var trackNumber: Int?
        public var duration: Double?
        public var artwork: String?
        public var lyrics: String?

        public init(start: Double, end: Double, title: String, artist: String,
                    appleMusicID: String? = nil, offset: Double? = nil, rate: Double? = nil) {
            self.start = start
            self.end = end
            self.title = title
            self.artist = artist
            self.appleMusicID = appleMusicID
            self.offset = offset
            self.rate = rate
        }

        var match: TrackMatch { TrackMatch(title: title, artist: artist, appleMusicID: appleMusicID) }
    }

    public var tracks: [Track]

    public init(tracks: [Track]) {
        self.tracks = tracks
    }

    public static func sidecarURL(for audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("tracks.json")
    }

    /// The sidecar for `audio`, if there is one.
    public static func load(for audio: URL) throws -> ReplayScript? {
        let url = sidecarURL(for: audio)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ReplayScript.self, from: Data(contentsOf: url))
    }

    public func write(for audio: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.sidecarURL(for: audio), options: .atomic)
    }

    public func recognizer(latency: Double = 5) -> ScriptedRecognizer {
        ScriptedRecognizer(segments: tracks.map {
            .init(start: $0.start, end: $0.end, track: $0.match, offset: $0.offset ?? 0, rate: $0.rate ?? 1)
        }, latency: latency)
    }

    /// Local metadata, artwork and lyrics for tracks that specify an album, if any do.
    /// `directory` is where the sidecar lives (relative paths resolve against it).
    public func catalog(directory: URL) -> (any TrackCatalog)? {
        var entries: [String: CatalogEntry] = [:]
        for t in tracks where t.album != nil {
            var m = TrackMetadata(title: t.title, artist: t.artist)
            m.album = t.album
            m.albumArtist = t.artist
            m.year = t.year
            m.trackNumber = t.trackNumber
            m.trackCount = tracks.count
            m.duration = t.duration
            m.collectionID = "local:\(t.artist)|\(t.album ?? "")"
            let artwork = t.artwork.flatMap { try? Data(contentsOf: directory.appendingPathComponent($0)) }
            let lyrics = t.lyrics
                .flatMap { try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }
                .map { Lyrics(lines: LRCParser.parse($0)) }
            entries[t.match.identity] = CatalogEntry(metadata: m, artwork: artwork, lyrics: lyrics)
        }
        return entries.isEmpty ? nil : ScriptCatalog(entries: entries)
    }
}

private struct ScriptCatalog: TrackCatalog {
    let entries: [String: CatalogEntry]

    func entry(for match: TrackMatch) -> CatalogEntry? { entries[match.identity] }
}
