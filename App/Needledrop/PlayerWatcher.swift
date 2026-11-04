import AppKit
import Recognition

/// Follows Apple Music and Spotify on this Mac: they announce every play, pause and track
/// change system-wide, so Needledrop knows exactly what's playing without listening for it.
@MainActor
final class PlayerWatcher {
    /// The track, and its position (seconds) as of now if known.
    var onTrack: ((PlayerTrack, Double?) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = DistributedNotificationCenter.default()
        for (name, source) in [(PlayerTrack.appleMusicNotification, PlayerTrack.Source.appleMusic),
                               (PlayerTrack.spotifyNotification, .spotify)] {
            // Lives as long as the app, so the observers are never removed.
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let track = PlayerTrack(source: source, userInfo: note.userInfo ?? [:]) else { return }
                MainActor.assumeIsolated { self?.handle(track) }
            })
        }
    }

    private func handle(_ track: PlayerTrack) {
        let source = track.source
        var position = track.position
        // Music doesn't include the position; ask it (it's running — it just told us so).
        if source == .appleMusic, track.playing { position = Self.musicPosition() }
        onTrack?(track, position)
    }

    /// Asks Music and Spotify directly (they only announce *changes*, so a song already
    /// playing when Needledrop starts would otherwise go unnoticed). Only apps that are
    /// running are asked — never launched. Reports through `onTrack`.
    func checkNow() {
        let players: [(String, PlayerTrack.Source, String)] = [
            ("com.apple.Music", .appleMusic, "Music"),
            ("com.spotify.client", .spotify, "Spotify"),
        ]
        for (bundle, source, name) in players where !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
            // Music gives duration in seconds; Spotify in milliseconds.
            let duration = source == .spotify ? "(duration of t) / 1000" : "duration of t"
            let script = """
                tell application "\(name)"
                    if player state is playing then
                        set t to current track
                        return {name of t, artist of t, album of t, \(duration), player position}
                    end if
                end tell
                """
            var error: NSDictionary?
            guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error), error == nil,
                  result.numberOfItems == 5,
                  let title = result.atIndex(1)?.stringValue, let artist = result.atIndex(2)?.stringValue,
                  !title.isEmpty, !artist.isEmpty else { continue }
            var info: [AnyHashable: Any] = ["Name": title, "Artist": artist, "Player State": "Playing"]
            info["Album"] = result.atIndex(3)?.stringValue
            guard let track = PlayerTrack(source: source, userInfo: info) else { continue }
            var reported = track
            reported.duration = result.atIndex(4)?.doubleValue
            onTrack?(reported, result.atIndex(5)?.doubleValue)
            return
        }
    }

    /// Needs the one-time "Needledrop wants to control Music" permission; nil without it.
    private static func musicPosition() -> Double? {
        // Never launch Music just to ask.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else { return nil }
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application \"Music\" to return player position")
        guard let result = script?.executeAndReturnError(&error), error == nil else { return nil }
        let value = result.doubleValue
        return value.isFinite && value >= 0 ? value : nil
    }
}
