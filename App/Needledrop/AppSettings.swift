import Archive
import Foundation
import SessionState
import Visuals

enum InputSelection: Codable, Hashable {
    case systemDefault
    case device(uid: String, name: String)
    case replay(path: String)
}

/// Everything persisted between launches, as one JSON blob in UserDefaults.
/// Missing or unreadable fields fall back to their defaults individually.
struct AppSettings: Codable, Equatable {
    var input: InputSelection = .systemDefault
    var detector = SideDetectorConfig()
    var displayID: UInt32?
    var displayName: String?
    var fullScreen = true
    var background: BackgroundStyle = .paper
    var showCover = true
    var showNowPlaying = true
    var showDebugOverlay = false
    var showLyrics = true
    /// Seconds the room hears the record after the Mac does (AirPlay to HomePods ≈ 2 s).
    /// Visuals and lyrics are delayed by this much.
    var outputLatency = 0.0
    var archive = ArchiveSettings()

    private static let key = "settings.v1"

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        input = (try? c.decodeIfPresent(InputSelection.self, forKey: .input)) ?? d.input
        detector = try c.decodeIfPresent(SideDetectorConfig.self, forKey: .detector) ?? d.detector
        displayID = try c.decodeIfPresent(UInt32.self, forKey: .displayID)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        fullScreen = try c.decodeIfPresent(Bool.self, forKey: .fullScreen) ?? d.fullScreen
        background = (try? c.decodeIfPresent(BackgroundStyle.self, forKey: .background)) ?? d.background
        showCover = try c.decodeIfPresent(Bool.self, forKey: .showCover) ?? d.showCover
        showNowPlaying = try c.decodeIfPresent(Bool.self, forKey: .showNowPlaying) ?? d.showNowPlaying
        showDebugOverlay = try c.decodeIfPresent(Bool.self, forKey: .showDebugOverlay) ?? d.showDebugOverlay
        showLyrics = try c.decodeIfPresent(Bool.self, forKey: .showLyrics) ?? d.showLyrics
        outputLatency = try c.decodeIfPresent(Double.self, forKey: .outputLatency) ?? d.outputLatency
        archive = (try? c.decodeIfPresent(ArchiveSettings.self, forKey: .archive)) ?? d.archive
    }

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
