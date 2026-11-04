import CryptoKit
import Foundation
import Metadata

/// Time-synced lyrics from LRCLIB (free, no key), cached on disk. "No lyrics found" is
/// cached too, for a week, so an obscure record doesn't hit the API every play.
public actor LyricsProvider {
    private let http: any HTTPClient
    private let directory: URL
    private let base: URL
    private let negativeCacheLifetime: TimeInterval = 7 * 24 * 3600

    public init(cacheDirectory: URL, http: any HTTPClient = URLSession.shared,
                baseURL: URL = URL(string: "https://lrclib.net/api")!) {
        self.http = http
        directory = cacheDirectory.appendingPathComponent("lyrics", isDirectory: true)
        base = baseURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Nil when there are none (or LRCLIB is unreachable).
    public func lyrics(for track: TrackMetadata) async -> Lyrics? {
        let key = Self.key(track)
        switch readCache(key) {
        case .found(let lyrics): return lyrics
        case .none: return nil
        case .miss: break
        }

        do {
            let result = try await fetch(track)
            writeCache(key, result)
            return result
        } catch {
            return nil  // offline etc.: don't cache, try again next play
        }
    }

    // MARK: - LRCLIB

    private struct Record: Decodable {
        var trackName: String?
        var artistName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?

        var lyrics: Lyrics {
            Lyrics(lines: syncedLyrics.map(LRCParser.parse) ?? [], plain: plainLyrics, instrumental: instrumental ?? false)
        }
    }

    /// Exact `get` first (artist, title, album, duration); on 404, `search` and pick the
    /// synced result closest in duration.
    private func fetch(_ track: TrackMetadata) async throws -> Lyrics? {
        var get = URLComponents(url: base.appendingPathComponent("get"), resolvingAgainstBaseURL: false)!
        get.queryItems = [
            .init(name: "artist_name", value: track.artist),
            .init(name: "track_name", value: track.title),
        ]
        if let album = track.album { get.queryItems?.append(.init(name: "album_name", value: album)) }
        if let duration = track.duration { get.queryItems?.append(.init(name: "duration", value: String(Int(duration.rounded())))) }

        do {
            let data = try await http.get(get.url!, headers: userAgent)
            return try JSONDecoder().decode(Record.self, from: data).lyrics
        } catch HTTPError.status(404) {
            // Fall through to search.
        }

        var search = URLComponents(url: base.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        search.queryItems = [
            .init(name: "artist_name", value: track.artist),
            .init(name: "track_name", value: track.title),
        ]
        let records = try JSONDecoder().decode([Record].self, from: try await http.get(search.url!, headers: userAgent))
        let candidates = records.filter { record in
            guard let wanted = track.duration, let got = record.duration else { return true }
            return abs(wanted - got) <= 5
        }
        let best = candidates.min { a, b in
            let aSynced = a.syncedLyrics != nil, bSynced = b.syncedLyrics != nil
            if aSynced != bSynced { return aSynced }
            let wanted = track.duration ?? 0
            return abs((a.duration ?? 0) - wanted) < abs((b.duration ?? 0) - wanted)
        }
        return best?.lyrics
    }

    private var userAgent: [String: String] { ["User-Agent": needledropUserAgent] }

    // MARK: - Cache

    private enum Cached {
        case found(Lyrics)
        case none
        case miss
    }

    private struct Entry: Codable {
        var lyrics: Lyrics?
        var fetched: Date
    }

    private func readCache(_ key: String) -> Cached {
        guard let data = try? Data(contentsOf: file(key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return .miss }
        if let lyrics = entry.lyrics { return .found(lyrics) }
        return Date().timeIntervalSince(entry.fetched) < negativeCacheLifetime ? .none : .miss
    }

    private func writeCache(_ key: String, _ lyrics: Lyrics?) {
        let entry = Entry(lyrics: lyrics, fetched: Date())
        try? JSONEncoder().encode(entry).write(to: file(key), options: .atomic)
    }

    private func file(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash).json")
    }

    private static func key(_ t: TrackMetadata) -> String {
        "\(t.artist.lowercased())|\(t.title.lowercased())|\(t.album?.lowercased() ?? "")|\(Int(t.duration ?? 0))"
    }
}
