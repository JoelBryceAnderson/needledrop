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
    func data(from url: URL) async throws -> Data
}

extension URLSession: HTTPClient {
    public func data(from url: URL) async throws -> Data {
        let (data, response) = try await data(from: url, delegate: nil)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

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
        let key = match.identity
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

    /// Artwork bytes, cached per album (or per URL when there's no album ID).
    public func artwork(for metadata: TrackMetadata) async -> Data? {
        guard let url = metadata.artworkURL else { return nil }
        let file = cacheDirectory.appendingPathComponent("artwork/\(Self.hash(metadata.collectionID ?? url.absoluteString)).img")
        if let data = try? Data(contentsOf: file) { return data }
        guard let data = try? await http.data(from: url) else { return nil }
        try? data.write(to: file, options: .atomic)
        return data
    }

    // MARK: - iTunes API

    private func lookup(id: String) async throws -> TrackMetadata? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [.init(name: "id", value: id), .init(name: "entity", value: "song")]
        let response = try JSONDecoder().decode(ITunesResponse.self, from: try await http.data(from: components.url!))
        return response.results.first { $0.kind == "song" }.map(Self.metadata)
    }

    private func search(artist: String, title: String) async throws -> TrackMetadata? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: "\(artist) \(title)"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "10"),
        ]
        let response = try JSONDecoder().decode(ITunesResponse.self, from: try await http.data(from: components.url!))
        let wantTitle = Self.normalize(title), wantArtist = Self.normalize(artist)
        // Prefer an exact title + artist match, then anything whose title matches,
        // preferring albums over compilations (earliest release).
        let songs = response.results.filter { $0.kind == "song" }
        let scored = songs.map { song -> (Int, ITunesResult) in
            let t = Self.normalize(song.trackName ?? "")
            let a = Self.normalize(song.artistName ?? "")
            var score = 0
            if t == wantTitle { score += 4 } else if t.hasPrefix(wantTitle) || wantTitle.hasPrefix(t) { score += 2 }
            if a == wantArtist { score += 3 } else if a.contains(wantArtist) || wantArtist.contains(a) { score += 1 }
            if song.collectionArtistName == nil || song.collectionArtistName == song.artistName { score += 1 }
            return (score, song)
        }
        let best = scored.filter { $0.0 >= 5 }.max { l, r in
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
        URL(string: url.replacingOccurrences(of: "100x100bb", with: "1200x1200bb"))
    }

    /// "Rumours (Remastered)" → "Rumours"; we want the record's name, not the reissue's.
    static func cleanAlbum(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(remaster|deluxe|edition|expanded|anniversary)[^\)\]]*[\)\]]"#,
                                  with: "", options: [.regularExpression, .caseInsensitive])
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
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
