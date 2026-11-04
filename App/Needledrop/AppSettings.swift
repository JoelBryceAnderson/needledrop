import Archive
import ArtDirector
import Foundation
import SessionState
import Visuals

/// The Theme setting: let the art director choose per album, or force one look.
enum AppTheme: String, Codable, CaseIterable {
    case auto, paper, smoke, googie, collage, risograph
}

/// Settings that force a choice the art director would otherwise make per album.
enum CoverChoice: String, Codable, CaseIterable { case auto, living, dissolve, record }
enum LyricAnimationChoice: String, Codable, CaseIterable { case auto, ink, typewriter }
enum RPMChoice: String, Codable, CaseIterable { case auto, rpm33, rpm45 }
enum IdleScreen: String, Codable, CaseIterable { case libraryWall, black }
/// How much the picture is directed over a song (shots, camera moves, the cover moving).
enum MotionChoice: String, Codable, CaseIterable {
    case still, gentle, directed

    var amount: Double {
        switch self {
        case .still: 0
        case .gentle: 0.5
        case .directed: 1
        }
    }
}

struct ArtDirectorSettings: Codable, Equatable {
    var enabled = true
    /// The album look (reads the cover, may write a shader).
    var model = ClaudeClient.defaultModel
    /// Score each track from its lyrics (keyframes, sections, line treatments).
    var scoreTracks = true
    var scoreModel = TrackDirector.defaultModel

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ArtDirectorSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        scoreTracks = try c.decodeIfPresent(Bool.self, forKey: .scoreTracks) ?? d.scoreTracks
        scoreModel = try c.decodeIfPresent(String.self, forKey: .scoreModel) ?? d.scoreModel
    }
}

enum InputSelection: Codable, Hashable {
    case systemDefault
    case device(uid: String, name: String)
    case replay(path: String)
    /// What this Mac is playing (YouTube, a music app…), via a Core Audio process tap.
    case systemAudio
}

/// Everything persisted between launches, as one JSON blob in UserDefaults.
/// Missing or unreadable fields fall back to their defaults individually.
struct AppSettings: Codable, Equatable {
    var input: InputSelection = .systemDefault
    var detector = SideDetectorConfig()
    var displayID: UInt32?
    var displayName: String?
    var fullScreen = true
    var theme: AppTheme = .auto
    var cover: CoverChoice = .auto
    var lyricAnimation: LyricAnimationChoice = .auto
    var rpm: RPMChoice = .auto
    var idleScreen: IdleScreen = .libraryWall
    var motion: MotionChoice = .directed
    /// Replays play through the Mac's speakers too (never the turntable path).
    var replayAudible = true
    /// Take what's playing from Apple Music / Spotify when they're the source.
    var followMusicApps = true
    var setupCompleted = false
    var renderResolution: VisualsRenderer.RenderResolution = .auto
    var artDirector = ArtDirectorSettings()
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
        theme = (try? c.decodeIfPresent(AppTheme.self, forKey: .theme)) ?? d.theme
        cover = (try? c.decodeIfPresent(CoverChoice.self, forKey: .cover)) ?? d.cover
        lyricAnimation = (try? c.decodeIfPresent(LyricAnimationChoice.self, forKey: .lyricAnimation)) ?? d.lyricAnimation
        rpm = (try? c.decodeIfPresent(RPMChoice.self, forKey: .rpm)) ?? d.rpm
        idleScreen = (try? c.decodeIfPresent(IdleScreen.self, forKey: .idleScreen)) ?? d.idleScreen
        motion = (try? c.decodeIfPresent(MotionChoice.self, forKey: .motion)) ?? d.motion
        replayAudible = try c.decodeIfPresent(Bool.self, forKey: .replayAudible) ?? d.replayAudible
        followMusicApps = try c.decodeIfPresent(Bool.self, forKey: .followMusicApps) ?? d.followMusicApps
        setupCompleted = try c.decodeIfPresent(Bool.self, forKey: .setupCompleted) ?? d.setupCompleted
        renderResolution = (try? c.decodeIfPresent(VisualsRenderer.RenderResolution.self, forKey: .renderResolution)) ?? d.renderResolution
        artDirector = (try? c.decodeIfPresent(ArtDirectorSettings.self, forKey: .artDirector)) ?? d.artDirector
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
