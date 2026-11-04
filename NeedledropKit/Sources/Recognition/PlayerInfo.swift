import Foundation

/// What a music app on this Mac says it's playing, from its system-wide "player info"
/// notification. Apple Music and Spotify both send one on every play, pause and track change.
public struct PlayerTrack: Sendable, Equatable {
    public enum Source: String, Sendable {
        case appleMusic = "Apple Music"
        case spotify = "Spotify"
    }

    public var source: Source
    public var title: String
    public var artist: String
    public var album: String?
    /// Seconds, if the app says.
    public var duration: Double?
    /// Seconds into the track when the notification was sent, if the app says (Spotify does).
    public var position: Double?
    public var playing: Bool

    public var identity: String { "\(artist.lowercased())|\(title.lowercased())" }

    public static let appleMusicNotification = Notification.Name("com.apple.Music.playerInfo")
    public static let spotifyNotification = Notification.Name("com.spotify.client.PlaybackStateChanged")

    /// Reads a notification's userInfo. Nil if it isn't a playing/paused track with a title
    /// and artist (e.g. a stop, or a radio station with no metadata).
    public init?(source: Source, userInfo: [AnyHashable: Any]) {
        func string(_ key: String) -> String? {
            (userInfo[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }
        func number(_ key: String) -> Double? {
            (userInfo[key] as? NSNumber)?.doubleValue ?? (userInfo[key] as? Double)
        }
        guard let title = string("Name"), let artist = string("Artist") else { return nil }
        let state = string("Player State") ?? ""
        guard state == "Playing" || state == "Paused" else { return nil }
        self.source = source
        self.title = title
        self.artist = artist
        album = string("Album")
        switch source {
        case .appleMusic:
            duration = number("Total Time").map { $0 / 1000 }       // milliseconds
            position = nil
        case .spotify:
            duration = number("Duration").map { $0 / 1000 }         // milliseconds
            position = number("Playback Position")                  // seconds
        }
        playing = state == "Playing"
    }
}
