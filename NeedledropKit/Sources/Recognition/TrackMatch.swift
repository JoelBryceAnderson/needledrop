import Foundation

/// One recognition result: what's playing and where in it we are.
public struct TrackMatch: Sendable, Equatable, Codable {
    public var title: String
    public var artist: String
    public var appleMusicID: String?
    public var isrc: String?
    public var shazamID: String?
    public var artworkURL: URL?
    /// Track position (seconds) at the audio time the match was reported.
    public var position: Double
    /// Shazam's frequency skew: how far the record's pitch is from the reference.
    /// ≈ playback speed − 1 (positive = running fast).
    public var frequencySkew: Double

    public init(
        title: String, artist: String, appleMusicID: String? = nil, isrc: String? = nil,
        shazamID: String? = nil, artworkURL: URL? = nil, position: Double = 0, frequencySkew: Double = 0
    ) {
        self.title = title
        self.artist = artist
        self.appleMusicID = appleMusicID
        self.isrc = isrc
        self.shazamID = shazamID
        self.artworkURL = artworkURL
        self.position = position
        self.frequencySkew = frequencySkew
    }

    /// Stable key for "is this the same song", independent of position.
    public var identity: String {
        if let isrc { return "isrc:\(isrc)" }
        if let appleMusicID { return "am:\(appleMusicID)" }
        if let shazamID { return "shazam:\(shazamID)" }
        return "text:\(artist.lowercased())|\(title.lowercased())"
    }

    public func isSameTrack(as other: TrackMatch?) -> Bool {
        other.map { $0.identity == identity } ?? false
    }
}

public enum RecognitionEvent: Sendable, Equatable {
    /// `at` is the audio time of the latest audio fed when the match arrived.
    case match(TrackMatch, at: Double)
    case error(String)
}
