import CryptoKit
import Foundation
import Recognition

public struct TrackMetadata: Sendable, Equatable, Codable {
    public var title: String
    public var artist: String
    public var album: String?
    public var albumArtist: String?
    public var trackNumber: Int?
    public var trackCount: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?
    /// Seconds.
    public var duration: Double?
    public var appleMusicID: String?
    /// iTunes collection (album) ID: the key for per-album caches (art direction, library).
    public var collectionID: String?
    public var artworkURL: URL?

    public init(title: String, artist: String) {
        self.title = title
        self.artist = artist
    }

    /// Best effort from the match alone, when lookup fails or is offline.
    public init(match: TrackMatch) {
        self.init(title: match.title, artist: match.artist)
        appleMusicID = match.appleMusicID
        artworkURL = match.artworkURL
    }
}

public protocol HTTPClient: Sendable {
    /// GET `url`; throws `HTTPError.status` for non-2xx responses.
    func get(_ url: URL, headers: [String: String]) async throws -> Data
}

public enum HTTPError: Error, Equatable {
    case status(Int)
}

extension URLSession: HTTPClient {
    public func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError.status(http.statusCode)
        }
        return data
    }
}

/// Identifies the app to free APIs that ask clients to (LRCLIB, iTunes).
public let needledropUserAgent = "Needledrop/0.4 (macOS turntable visualizer)"
let userAgentHeader = ["User-Agent": needledropUserAgent]

/// Resolves album/track info and artwork. Lookups go to the iTunes API (no auth) — by
/// Apple Music ID when Shazam gave one, else a search on artist + title. Everything is
/// cached on disk, so a record you play often never touches the network again.
public actor MetadataResolver {
    private let http: any HTTPClient
    private let cacheDirectory: URL
    private var memory: [String: TrackMetadata] = [:]

    public init(cacheDirectory: URL, http: any HTTPClient = URLSession.shared) {
        self.http = http
        self.cacheDirectory = cacheDirectory
        try? FileManager.default.createDirectory(at: cacheDirectory.appendingPathComponent("metadata"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheDirectory.appendingPathComponent("artwork"), withIntermediateDirectories: true)
    }

    public static var defaultCacheDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Needledrop/Cache", isDirectory: true)
    }

    /// Never throws: falls back to what the match itself carries.
    public func resolve(_ match: TrackMatch) async -> TrackMetadata {
        // v2: earlier versions could match a same-titled song by another artist; ignore them.
        let key = "v4|" + match.identity + "|" + (match.albumHint.map(Self.normalize) ?? "")
        if let cached = memory[key] ?? readCache(key) {
            memory[key] = cached
            return cached
        }
        var result: TrackMetadata?
        if let id = match.appleMusicID {
            result = try? await lookup(id: id)
        }
        if result == nil {
            result = try? await search(artist: match.artist, title: match.title, album: match.albumHint,
                                       duration: match.durationHint)
        }
        guard var resolved = result else { return TrackMetadata(match: match) }
        if resolved.artworkURL == nil { resolved.artworkURL = match.artworkURL }
        memory[key] = resolved
        writeCache(resolved, key)
        return resolved
    }

    /// Artwork bytes, cached per album (or per URL when there's no album ID). iTunes
    /// artwork comes at 3000 px (falling back to 1200 px if that size isn't served).
    public func artwork(for metadata: TrackMetadata) async -> Data? {
        guard let url = metadata.artworkURL else { return nil }
        let file = cacheDirectory.appendingPathComponent("artwork/3000-\(Self.hash(metadata.collectionID ?? url.absoluteString)).img")
        if let data = try? Data(contentsOf: file) { return data }
        for candidate in Self.artworkCandidates(url) {
            if let data = try? await http.get(candidate, headers: userAgentHeader), !data.isEmpty {
                try? data.write(to: file, options: .atomic)
                return data
            }
        }
        return nil
    }

    /// Largest first. Older cached metadata may still name the 1200 px rendition.
    static func artworkCandidates(_ url: URL) -> [URL] {
        let s = url.absoluteString
        guard s.contains("1200x1200bb") || s.contains("100x100bb") else { return [url] }
        let large = s.replacingOccurrences(of: "1200x1200bb", with: "3000x3000bb").replacingOccurrences(of: "100x100bb", with: "3000x3000bb")
        let medium = large.replacingOccurrences(of: "3000x3000bb", with: "1200x1200bb")
        return [large, medium].compactMap(URL.init(string:))
    }

    // MARK: - iTunes API

    private func lookup(id: String) async throws -> TrackMetadata? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [.init(name: "id", value: id), .init(name: "entity", value: "song")]
        let response = try JSONDecoder().decode(ITunesResponse.self, from: try await http.get(components.url!, headers: userAgentHeader))
        return response.results.first { $0.kind == "song" }.map(Self.metadata)
    }

    /// The track after `track` on its album (by disc and track number), for getting ready
    /// before it plays. Nil without an album ID, at the end of the album, or offline.
    public func nextTrack(after track: TrackMetadata) async -> TrackMetadata? {
        guard let album = track.collectionID, let number = track.trackNumber else { return nil }
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [.init(name: "id", value: album), .init(name: "entity", value: "song")]
        guard let url = components.url, let data = try? await http.get(url, headers: userAgentHeader),
              let response = try? JSONDecoder().decode(ITunesResponse.self, from: data) else { return nil }
        let disc = track.discNumber ?? 1
        let songs = response.results.filter { $0.kind == "song" }.map(Self.metadata)
            .sorted { (($0.discNumber ?? 1), ($0.trackNumber ?? 0)) < (($1.discNumber ?? 1), ($1.trackNumber ?? 0)) }
        return songs.first { ($0.discNumber ?? 1, $0.trackNumber ?? 0) > (disc, number) }
    }

    /// The catalogue's version of a song: the title and artist must match. Then the version
    /// played wins over others of the same name (an instrumental, a remix, a live take), the
    /// album the player named wins, and so does a matching length. If no result is on the
    /// named album, search again by album.
    private func search(artist: String, title: String, album: String? = nil, duration: Double? = nil) async throws -> TrackMetadata? {
        var songs = try await songs(term: "\(artist) \(title)")
        if let album, !songs.contains(where: { Self.normalize($0.collectionName ?? "") == Self.normalize(album) }) {
            songs += (try? await self.songs(term: "\(Self.cleanAlbum(album)) \(title)")) ?? []
        }
        let best = songs.compactMap { song -> (Int, ITunesResult)? in
            Self.score(song, artist: artist, title: title, album: album, duration: duration).map { ($0, song) }
        }.max { l, r in
            l.0 != r.0 ? l.0 < r.0 : (l.1.releaseDate ?? "") > (r.1.releaseDate ?? "")
        }
        // Only another version of the song (an instrumental, a remix)? With the album named,
        // its cover is what matters: find the album itself, even if this track isn't listed.
        let otherVersion = best.map { Self.isOtherVersion($0.1.trackName ?? "", of: title) } ?? true
        if otherVersion, let album, let found = try? await self.album(named: album, by: artist) {
            var m = Self.metadata(found)
            m.title = title
            m.artist = artist
            m.duration = duration
            m.trackNumber = nil
            m.appleMusicID = nil
            return m
        }
        guard let best else { return nil }
        var m = Self.metadata(best.1)
        if otherVersion {
            // Another version of the song: keep its album's cover only if it's the album named
            // (an instrumental on the same record has the same cover), and the title played.
            if let album, Self.normalize(m.album ?? "") != Self.normalize(album) { return nil }
            m.title = title
            m.artist = artist
            m.appleMusicID = nil
            if let album { m.album = Self.cleanAlbum(album) }
        }
        return m
    }

    /// An album by name and artist, for its cover when the track itself can't be found.
    private func album(named name: String, by artist: String) async throws -> ITunesResult? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: "\(artist) \(Self.cleanAlbum(name))"),
            .init(name: "entity", value: "album"),
            .init(name: "limit", value: "10"),
        ]
        let response = try JSONDecoder().decode(ITunesResponse.self, from: try await http.get(components.url!, headers: userAgentHeader))
        let want = Self.normalize(name)
        return response.results.filter { r in
            Self.artistMatch(artist, r.artistName ?? "") > 0 && {
                // The same album (edition notes in brackets aside), not another one that starts the same.
                Self.normalize(r.collectionName ?? "") == want
            }()
        }.min { Self.isOtherVersion($0.collectionName ?? "", of: name) == false && Self.isOtherVersion($1.collectionName ?? "", of: name) }
    }

    /// Does `found` name a version (instrumental, remix, live…) that `wanted` doesn't?
    static func isOtherVersion(_ found: String, of wanted: String) -> Bool {
        func says(_ text: String, _ word: String) -> Bool {
            text.lowercased().range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil
        }
        return versionWords.contains { says(found, $0) && !says(wanted, $0) }
    }

    private func songs(term: String) async throws -> [ITunesResult] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: term),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "15"),
        ]
        let response = try JSONDecoder().decode(ITunesResponse.self, from: try await http.get(components.url!, headers: userAgentHeader))
        return response.results.filter { $0.kind == "song" }
    }

    /// Words that mark a different version of a song.
    static let versionWords = ["instrumental", "karaoke", "acapella", "a cappella", "remix", "live", "version",
                               "versión", "demo", "acoustic", "edit", "mix", "rework", "cover"]

    /// How well a catalogue song matches what's playing; nil if it's not the same song.
    static func score(_ song: ITunesResult, artist: String, title: String, album: String?, duration: Double?) -> Int? {
        let wantTitle = normalize(title), found = song.trackName ?? ""
        let t = normalize(found)
        guard !t.isEmpty, !wantTitle.isEmpty else { return nil }
        var score = t == wantTitle ? 4 : (t.hasPrefix(wantTitle) || wantTitle.hasPrefix(t) ? 2 : 0)
        guard score > 0 else { return nil }
        // The credit (or the album's credit) must be the same artist(s).
        let artistScore = max(artistMatch(artist, song.artistName ?? ""), artistMatch(artist, song.collectionArtistName ?? ""))
        guard artistScore > 0 else { return nil }
        score += artistScore
        // Exactly the title played, brackets and all.
        // (A remaster, mono or stereo mix, or deluxe reissue is the same recording: ignore those notes.)
        func plain(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US")).lowercased()
                .replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(remaster|mono|stereo|deluxe|anniversary|expanded)[^\)\]]*[\)\]]"#,
                                      with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+-\s+.*(remaster|mono|stereo).*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        if plain(found) == plain(title) { score += 3 }
        // A version word the player didn't say: another take on the song.
        let wanted = plain(title), have = plain(found)
        if isOtherVersion(have, of: wanted) { score -= 6 }
        if let album {
            let a = normalize(song.collectionName ?? ""), b = normalize(album)
            if !a.isEmpty, a == b { score += 5 } else if !a.isEmpty, !b.isEmpty, a.contains(b) || b.contains(a) { score += 3 }
        }
        if let duration, let ms = song.trackTimeMillis, abs(Double(ms) / 1000 - duration) < 3 { score += 2 }
        if song.collectionArtistName == nil || song.collectionArtistName == song.artistName { score += 1 }
        return score
    }

    private static func metadata(_ r: ITunesResult) -> TrackMetadata {
        var m = TrackMetadata(title: r.trackName ?? "", artist: r.artistName ?? "")
        m.album = r.collectionName.map(cleanAlbum)
        m.albumArtist = r.collectionArtistName ?? r.artistName
        m.trackNumber = r.trackNumber
        m.trackCount = r.trackCount
        m.discNumber = r.discNumber
        m.year = r.releaseDate.flatMap { Int($0.prefix(4)) }
        m.genre = r.primaryGenreName
        m.duration = r.trackTimeMillis.map { Double($0) / 1000 }
        m.appleMusicID = r.trackId.map(String.init)
        m.collectionID = r.collectionId.map(String.init)
        m.artworkURL = r.artworkUrl100.flatMap(highResolutionArtwork)
        return m
    }

    static func highResolutionArtwork(_ url: String) -> URL? {
        URL(string: url.replacingOccurrences(of: "100x100bb", with: "3000x3000bb"))
    }

    /// "Rumours (Remastered)" → "Rumours"; we want the record's name, not the reissue's.
    static func cleanAlbum(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(remaster|deluxe|edition|expanded|anniversary)[^\)\]]*[\)\]]"#,
                                  with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// Lowercased, bracketed asides ("(Remastered)") and punctuation dropped, "&" read as
    /// "and", and a leading "The" ignored ("The Beatles" = "Beatles").
    /// Lowercased, accents and stylised letters folded ("JAŸ-Z" → "jay z", "Beyoncé" →
    /// "beyonce"), bracketed parts dropped, "&" as "and", punctuation as spaces.
    static func normalize(_ s: String) -> String {
        var n = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
            .lowercased()
            .replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if n.hasPrefix("the ") { n.removeFirst(4) }
        return n
    }

    // MARK: - Disk cache

    private func readCache(_ key: String) -> TrackMetadata? {
        let file = cacheDirectory.appendingPathComponent("metadata/\(Self.hash(key)).json")
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(TrackMetadata.self, from: $0) }
    }

    private func writeCache(_ metadata: TrackMetadata, _ key: String) {
        let file = cacheDirectory.appendingPathComponent("metadata/\(Self.hash(key)).json")
        try? JSONEncoder().encode(metadata).write(to: file, options: .atomic)
    }

    /// The names in a credit ("JAY-Z & Kanye West", "Kanye West, JAY-Z feat. Frank Ocean").
    static func artistNames(_ credit: String) -> Set<String> {
        let folded = credit.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US")).lowercased()
        let parts = folded.replacingOccurrences(of: #"\s+(feat\.?|ft\.?|featuring|with|x|and|vs\.?)\s+|\s*[&,/+]\s*"#,
                                                with: "|", options: .regularExpression)
            .split(separator: "|")
        return Set(parts.map { normalize(String($0)) }.filter { !$0.isEmpty })
    }

    /// 3: the same credit; 2: the same artists in another order or form; 1: they share an
    /// artist; 0: different artists.
    public static func artistMatch(_ wanted: String, _ found: String) -> Int {
        let a = normalize(wanted), b = normalize(found)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 3 }
        let x = artistNames(wanted), y = artistNames(found)
        if !x.isEmpty, x == y { return 2 }
        if !x.isDisjoint(with: y) || a.contains(b) || b.contains(a) { return 1 }
        return 0
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

struct ITunesResponse: Decodable {
    var results: [ITunesResult]
}

struct ITunesResult: Decodable {
    var kind: String?
    var trackId: Int?
    var collectionId: Int?
    var trackName: String?
    var artistName: String?
    var collectionName: String?
    var collectionArtistName: String?
    var artworkUrl100: String?
    var releaseDate: String?
    var trackCount: Int?
    var trackNumber: Int?
    var discNumber: Int?
    var trackTimeMillis: Int?
    var primaryGenreName: String?
}
