import Foundation
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
            .init(start: $0.start, end: $0.end,
                  track: TrackMatch(title: $0.title, artist: $0.artist, appleMusicID: $0.appleMusicID),
                  offset: $0.offset ?? 0, rate: $0.rate ?? 1)
        }, latency: latency)
    }
}
