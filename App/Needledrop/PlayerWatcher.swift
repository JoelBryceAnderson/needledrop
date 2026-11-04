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
