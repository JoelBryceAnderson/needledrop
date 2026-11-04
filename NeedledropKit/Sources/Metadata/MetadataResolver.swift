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
        let key = "v2|" + match.identity
        if let cached = memory[key] ?? readCache(key) {
            memory[key] = cached
            return cached
        }
        var result: TrackMetadata?
        if let id = match.appleMusicID {
            result = try? await lookup(id: id)
        }
        if result == nil {
            result = try? await search(artist: match.artist, title: match.title)
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

    private func search(artist: String, title: String) async throws -> TrackMetadata? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: "\(artist) \(title)"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "10"),
        ]
        let response = try JSONDecoder().decode(ITunesResponse.self, from: try await http.get(components.url!, headers: userAgentHeader))
        let wantTitle = Self.normalize(title), wantArtist = Self.normalize(artist)
        // Both the title and the artist must match (a same-named song by someone else is
        // the wrong record). Then prefer exact matches and the original album over
        // compilations, earliest release first.
        let songs = response.results.filter { $0.kind == "song" }
        let scored = songs.compactMap { song -> (Int, ITunesResult)? in
            let t = Self.normalize(song.trackName ?? "")
            let a = Self.normalize(song.artistName ?? "")
            guard !t.isEmpty, !a.isEmpty, !wantTitle.isEmpty, !wantArtist.isEmpty else { return nil }
            let titleScore = t == wantTitle ? 4 : (t.hasPrefix(wantTitle) || wantTitle.hasPrefix(t) ? 2 : 0)
            let artistScore = a == wantArtist ? 3 : (a.contains(wantArtist) || wantArtist.contains(a) ? 1 : 0)
            guard titleScore > 0, artistScore > 0 else { return nil }
            let original = song.collectionArtistName == nil || song.collectionArtistName == song.artistName ? 1 : 0
            return (titleScore + artistScore + original, song)
        }
        let best = scored.max { l, r in
            l.0 != r.0 ? l.0 < r.0 : (l.1.releaseDate ?? "") > (r.1.releaseDate ?? "")
        }
        return best.map { Self.metadata($0.1) }
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

    /// iTunes serves any size by rewriting the dimensions in the URL.
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
    static func normalize(_ s: String) -> String {
        var n = s.lowercased()
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

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ITunesResponse: Decodable {
    var results: [ITunesResult]
}

private struct ITunesResult: Decodable {
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
