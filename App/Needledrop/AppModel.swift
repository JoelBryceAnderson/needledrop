import AppKit
import Archive
import ArtDirector
import AudioCapture
import Foundation
import Lyrics
import Metadata
import Observation
import Pipeline
import Recognition
import ReplayHarness
import ServiceManagement
import SessionState
import SwiftUI
import Visuals

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

@MainActor
@Observable
final class AppModel {
    var settings: AppSettings {
        didSet {
            settings.save()
            applyVisualSettings()
            if settings.archive != oldValue.archive {
                let archive = settings.archive
                Task { await engine.updateArchiveSettings(archive) }
            }
        }
    }
    /// Nil only if Metal is unavailable; the stage then stays black.
    let renderer: VisualsRenderer?
    private(set) var engine: Engine
    var pipeline: ListeningPipeline { engine.pipeline }
    /// Current track's metadata and artwork, for the now-playing panel.
    private(set) var metadata: TrackMetadata?
    private(set) var artwork: NSImage?
    private var artworkData: Data?
    /// What the art director last did, for Settings.
    private(set) var artDirectionStatus = "No album yet"
    private(set) var currentAlbumKey: String?
    private var tracksHeard: [String: [String]] = [:]
    /// Sides this sitting (A, B, …); resets after a long break.
    private var sideIndex = -1
    private var lastSideEnded: Date?
    /// When the turntable went quiet (for the library wall).
    private(set) var idleSince: Date?
    private let playerWatcher = PlayerWatcher()
    private let setup = SetupPresenter()
    // Recovery.
    private var stall = StallDetector()
    private var watchdog: Timer?
    private var wakeObserver: NSObjectProtocol?
    /// Keeps the display (the TV) awake while music plays.
    private var displayAwake: NSObjectProtocol?
    /// A track a music app announced, waiting for Needledrop to hear it start.
    private var pendingPlayerTrack: (track: PlayerTrack, position: Double?, received: Date)?
    private var applyingPlayerTrack = false
    private let styleStore = StyleStore(directory: MetadataResolver.defaultCacheDirectory.appendingPathComponent("styles"))
    private(set) var devices: [AudioInputDevice] = []
    private(set) var log: [LogEntry] = []
    private(set) var microphoneDenied = false
    let presentation = PresentationController()

    private var eventTask: Task<Void, Never>?
    private let metadataResolver = MetadataResolver(cacheDirectory: MetadataResolver.defaultCacheDirectory)
    private let lyricsProvider = LyricsProvider(cacheDirectory: MetadataResolver.defaultCacheDirectory)
    /// Plays, albums and archived recordings. Nil if the database can't be opened.
    let library: Library? = try? Library(path: Library.defaultPath)

    init() {
        let settings = AppSettings.load()
        self.settings = settings
        engine = Engine(detector: settings.detector, recognizer: ShazamRecognizer(), metadata: nil)
        do {
            renderer = try VisualsRenderer()
        } catch {
            renderer = nil
            log.append(LogEntry(text: "Visuals unavailable: \(error)"))
        }
        applyVisualSettings()
        renderer?.inputProvider = { [weak self] in self?.visualInput() ?? VisualInput() }
        playerWatcher.onTrack = { [weak self] track, position in self?.playerAnnounced(track, position: position) }
    }

    /// Everything is read `outputLatency` behind the newest audio, so picture and words
    /// line up with what the room hears rather than what the Mac hears.
    private func visualInput() -> VisualInput {
        let (features, beatAge, onsetAge) = pipeline.features(delayedBy: settings.outputLatency)
        let session = engine.session()
        var input = VisualInput(features: features, beatAge: beatAge,
                                active: session.phase != .idle && session.phase != .sideEnded)
        input.onsetAge = onsetAge
        input.sideEnded = session.phase == .sideEnded
        if let start = session.sideStart {
            input.sideProgress = min(1, max(0, (features.time - start) / Self.typicalSideLength))
        }
        input.rpm = rpm
        if session.phase == .sideEnded, sideIndex >= 0 {
            // The intermission card, printed like the caption.
            let side = Self.sideLetter(sideIndex), next = Self.sideLetter(sideIndex + 1)
            input.caption = CaptionFrame(id: "intermission-\(side)", title: "Side \(side) complete",
                                         subtitle: "Flip for side \(next)")
        } else if settings.showNowPlaying, let info = metadata {
            input.caption = CaptionFrame(id: "\(info.artist)|\(info.title)", title: info.title,
                                         subtitle: [info.artist, info.album].compactMap { $0 }.joined(separator: "  ·  "))
        }
        if settings.showLyrics, let lyrics = session.lyrics, lyrics.isSynced, !lyrics.instrumental,
           let clock = session.clock, session.identifiedByHand || clock.confidence(at: features.time) > 0.15 {
            input.lyricsAvailable = true
            let position = clock.position(at: features.time)
            if let cue = lyrics.cue(at: position) {
                var frame = LyricFrame(id: cue.index, text: cue.text, next: cue.next)
                if typewriter {
                    // Words in time with the singing, snapped onto the beat grid where it's close.
                    var beats: [Double] = []
                    if let bpm = features.tempo, let beatAge {
                        let beat = clock.position(at: features.time - beatAge)
                        let period = 60 / bpm * clock.rate
                        let k0 = ((cue.start - beat) / period).rounded(.down)
                        beats = (0..<64).map { beat + (k0 + Double($0)) * period }.filter { $0 <= cue.end }
                    }
                    let starts = WordTiming.starts(for: cue.text, from: cue.start, to: cue.end, beats: beats)
                    frame.revealedWords = WordTiming.revealed(at: position, starts: starts)
                }
                input.lyric = frame
            }
        }
        return input
    }

    func launch() async {
        // A crash or power cut mid-side leaves a raw recording behind: keep it.
        for file in Archiver.recoverOrphans(root: settings.archive.root) {
            append("Recovered an interrupted side recording: Sides/\(file.lastPathComponent)")
        }
        startRecoveryWatch()
        refreshDevices()
        await restartInput()
        if settings.followMusicApps { playerWatcher.checkNow() }
        // First run with a live input: walk through levels and latency.
        if !settings.setupCompleted, settings.input == .systemDefault || { if case .device = settings.input { true } else { false } }() {
            showSetup()
        }
        presentVisuals()
        presentation.onDisplaysChanged = { [weak self] in self?.presentVisuals() }
        presentation.onToggleFullScreen = { [weak self] in self?.toggleFullScreen() }
    }

    // MARK: - Input

    func refreshDevices() {
        devices = AudioDeviceCatalog.inputDevices()
    }

    func selectInput(_ input: InputSelection) async {
        guard input != settings.input else { return }
        settings.input = input
        await restartInput()
    }

    func restartInput() async {
        eventTask?.cancel()
        await engine.stop()
        metadata = nil
        artwork = nil

        let source: any AudioSource
        var recognizer: any TrackRecognizer = ShazamRecognizer()
        var catalog: (any TrackCatalog)?
        switch settings.input {
        case .systemDefault, .device:
            microphoneDenied = !(await MicrophoneAccess.request())
            if microphoneDenied { append("Microphone access denied — enable Needledrop in System Settings › Privacy & Security › Microphone") }
            if case .device(let uid, _) = settings.input {
                source = LiveInputSource(deviceUID: uid)
            } else {
                source = LiveInputSource(deviceUID: nil)
            }
        case .systemAudio:
            source = SystemAudioSource()
            append("Listening to this Mac's audio (not archived)")
        case .replay(let path):
            let url = URL(fileURLWithPath: path)
            source = FileReplaySource(url: url, loop: true, audible: settings.replayAudible)
            do {
                if let script = try ReplayScript.load(for: url) {
                    recognizer = script.recognizer()
                    catalog = script.catalog(directory: url.deletingLastPathComponent())
                    append("Using \(ReplayScript.sidecarURL(for: url).lastPathComponent) instead of Shazam")
                } else if let script = await ReplayScript.fromTags(of: url), let track = script.tracks.first {
                    // A song file you own: its tags say what it is; everything else (cover,
                    // metadata, lyrics, art direction) is looked up as for a real record.
                    recognizer = script.recognizer()
                    append("Replaying \(track.artist) — \(track.title) (from the file's tags)")
                }
            } catch {
                append("Ignoring unreadable track sidecar: \(error.localizedDescription)")
            }
        }

        let engine = Engine(detector: settings.detector, recognizer: recognizer, metadata: metadataResolver,
                            lyrics: lyricsProvider,
                            // The archive is for records you own: streamed audio isn't recorded.
                            archiver: settings.input == .systemAudio ? nil : Archiver(settings: settings.archive, library: library),
                            catalog: catalog)
        self.engine = engine
        eventTask = Task { [weak self] in
            for await event in engine.events {
                self?.handle(event)
            }
        }
        do {
            try await engine.start(source: source)
        } catch {
            append("Couldn't start \(source.displayName): \(error.localizedDescription)")
        }
    }

    func setSampleRate(_ rate: Double) async {
        guard case .device(let uid, _) = settings.input else { return }
        do {
            try AudioDeviceCatalog.setNominalSampleRate(rate, deviceUID: uid)
            refreshDevices()
        } catch {
            append("Couldn't set sample rate: \(error)")
        }
        // The engine sees a configuration change and rebuilds itself at the new rate.
    }

    func updateDetector(_ config: SideDetectorConfig) {
        settings.detector = config
        pipeline.updateConfig(config)
    }

    // MARK: - Visuals

    func presentVisuals() {
        presentation.present(
            StageView(model: self),
            displayID: settings.displayID,
            displayName: settings.displayName,
            fullScreen: settings.fullScreen
        )
    }

    func toggleFullScreen() {
        settings.fullScreen.toggle()
        presentVisuals()
    }

    func selectDisplay(_ screen: NSScreen) {
        settings.displayID = screen.displayID
        settings.displayName = screen.localizedName
        presentVisuals()
    }

    // MARK: - Launch at login

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                append("Launch at login: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Events

    private func handle(_ event: EngineEvent) {
        switch event {
        case .pipeline(.source(.running(let format, let name))): append("● \(name) — \(format)")
        case .pipeline(.source(.waitingForDevice(let what))): append("Waiting for \(what)")
        case .pipeline(.source(.failed(let message))): append("✖ \(message)")
        case .pipeline(.source(.finished)): append("Replay finished")
        case .pipeline(.side(let side)):
            if let text = Self.describe(side) { append(text) }
            switch side {
            case .sideStarted:
                // Music just started: if a player app is the source, ask it what's on.
                if settings.followMusicApps { playerWatcher.checkNow() }
                // A new sitting after a long break starts again at side A.
                if let ended = lastSideEnded, Date().timeIntervalSince(ended) < 15 * 60 { sideIndex += 1 } else { sideIndex = 0 }
            case .sideEnded:
                lastSideEnded = Date()
            default:
                break
            }
        case .pipeline(.tick):
            if pendingPlayerTrack != nil { Task { await applyPlayerTrack() } }
            let phase = engine.session().phase
            if phase == .idle || phase == .sideEnded {
                if idleSince == nil { idleSince = Date() }
            } else if idleSince != nil {
                idleSince = nil
            }
            keepDisplayAwake(phase != .idle && phase != .sideEnded)
        case .pipeline(.recognition): break
        case .trackChanged(let track):
            metadata = nil
            artwork = nil
            if let track {
                append("♫ \(track.artist) — \(track.title)")
            } else if engine.session().unidentified {
                append("Couldn't identify this record")
                renderer?.show(.neutral)
            }
            // Between tracks the current look stays up; the next album crossfades in.
        case .metadata(let info, let data):
            metadata = info
            artwork = data.flatMap(NSImage.init(data:))
            artworkData = data
            updateLook(for: info)
        case .lyrics(let lyrics):
            if let lyrics, lyrics.instrumental {
                append("Instrumental — no lyrics")
            } else if let lyrics, lyrics.isSynced {
                append("Lyrics: \(lyrics.lines.filter { !$0.text.isEmpty }.count) synced lines")
            } else {
                append(lyrics?.plain == nil ? "No lyrics found" : "Only unsynced lyrics found")
            }
        case .archived(let report):
            let kept = report.tracks.filter { $0.path != nil }.count
            let replacedNote = kept < report.tracks.count ? ", \(report.tracks.count - kept) already had better copies" : ""
            append("Archived \(kept) track\(kept == 1 ? "" : "s")\(replacedNote)")
            if let error = report.error { append("✖ Archive: \(error)") }
        case .recognitionError(let message):
            append("✖ \(message)")
        }
    }

    private static func albumKey(_ info: TrackMetadata) -> String {
        info.collectionID ?? "\(info.artist)|\(info.album ?? info.title)"
    }

    /// A new album gets its extracted-palette look at once, then (if the art director is
    /// on) crossfades to Claude's direction — one request per album, cached after that.
    /// For the tonearm: a typical LP side.
    static let typicalSideLength = 22.0 * 60

    static func sideLetter(_ index: Int) -> String {
        String(UnicodeScalar(UInt8(65 + index % 26)))
    }

    private var typewriter: Bool {
        switch settings.lyricAnimation {
        case .auto: renderer?.currentStyle.animation == .typewriter
        case .ink: false
        case .typewriter: true
        }
    }

    /// 45 for singles and EPs (four tracks or fewer, or named so), else 33⅓.
    private var rpm: Double {
        switch settings.rpm {
        case .rpm33: return 100.0 / 3
        case .rpm45: return 45
        case .auto:
            let album = metadata?.album ?? ""
            let short = (metadata?.trackCount ?? 99) <= 4 || album.hasSuffix("- Single") || album.hasSuffix("- EP")
            return short ? 45 : 100.0 / 3
        }
    }

    private func updateLook(for info: TrackMetadata, reroll: Bool = false) {
        let key = Self.albumKey(info)
        tracksHeard[key, default: []].append(info.title)
        guard let renderer, let image = artwork?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        guard reroll || currentAlbumKey != key || renderer.currentLookID == nil else { return }
        currentAlbumKey = key
        Task { [weak self] in
            guard let self else { return }
            let pinned = await self.styleStore.isPinned(key)
            if self.currentAlbumKey == key { self.pinnedCache = pinned }
        }
        let theme = settings.theme
        let brief = AlbumBrief(artist: info.albumArtist ?? info.artist, album: info.album ?? info.title, year: info.year,
                               genre: info.genre, tracks: tracksHeard[key] ?? [], artwork: artworkData)
        Task { [weak self] in
            var look = await AlbumLook.make(id: key, artwork: image)
            if theme == .googie { look.style = .googie }
            guard let self, self.currentAlbumKey == key else { return }
            if !reroll { self.renderer?.show(look) }
            guard let director = self.makeArtDirector() else { return }
            var detailed = brief
            detailed.extractedPalette = look.palette.colors.map(Self.hex)
            self.artDirectionStatus = "Asking Claude about “\(brief.album)”…"
            do {
                let direction = try await director.direction(for: detailed, key: key, theme: Self.directorTheme(theme), reroll: reroll)
                guard self.currentAlbumKey == key else { return }
                look.style = direction.style
                if let palette = direction.palette { look.palette = palette }
                look.id = "\(key)#\(direction.spec.mood)"
                self.renderer?.show(look)
                self.artDirectionStatus = "“\(direction.spec.mood)”" + (direction.shaderFellBack ? " (custom shader failed checks; using paper)" : "")
                self.append("Art direction: \(direction.spec.mood)")
            } catch {
                self.artDirectionStatus = "\(error)"
                self.append("Art director: \(error)")
            }
        }
    }

    private func makeArtDirector() -> ArtDirector? {
        guard settings.artDirector.enabled, let key = APIKeyStore.load() else { return nil }
        return ArtDirector(client: ClaudeClient(apiKey: key, model: settings.artDirector.model), store: styleStore)
    }

    private static func directorTheme(_ theme: AppTheme) -> Theme {
        switch theme {
        case .auto, .smoke: .auto
        case .paper: .paper
        case .googie: .googie
        }
    }

    private static func hex(_ c: RGB) -> String {
        String(format: "#%02X%02X%02X", Int(c.r * 255), Int(c.g * 255), Int(c.b * 255))
    }

    // MARK: - Following Apple Music / Spotify

    private func playerAnnounced(_ track: PlayerTrack, position: Double?) {
        guard settings.followMusicApps, track.playing else { return }  // pauses: the side detector hears them
        pendingPlayerTrack = (track, position, Date())
        Task { await applyPlayerTrack() }
    }

    /// Hands the announced track to the session once there's music to attach it to (a side
    /// needs ~1.5 s of sound to start). Retried on each tick for up to 30 s.
    private func applyPlayerTrack() async {
        // Ticks retry this; only one attempt at a time.
        guard let pending = pendingPlayerTrack, !applyingPlayerTrack else { return }
        applyingPlayerTrack = true
        defer { applyingPlayerTrack = false }
        let elapsed = Date().timeIntervalSince(pending.received)
        guard elapsed < 30 else {
            pendingPlayerTrack = nil
            return
        }
        // Without a reported position, assume it started when the app announced it.
        let position = (pending.position ?? 0) + elapsed
        if await engine.identify(title: pending.track.title, artist: pending.track.artist, position: position) {
            pendingPlayerTrack = nil
            append("♫ from \(pending.track.source.rawValue): \(pending.track.artist) — \(pending.track.title)")
        }
    }

    /// Names what's playing. Returns a problem to show, or nil on success.
    func identify(artist: String, title: String, at text: String) async -> String? {
        var position: Double?
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let parts = trimmed.split(separator: ":").map { Double($0) }
            guard !parts.contains(nil), (1...3).contains(parts.count) else { return "Couldn't read “\(trimmed)” — use 1:23 or 83" }
            position = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        }
        let ok = await engine.identify(title: title.trimmingCharacters(in: .whitespaces),
                                       artist: artist.trimmingCharacters(in: .whitespaces), position: position)
        return ok ? nil : "Start the music first — Needledrop hasn't heard anything playing yet."
    }

    /// A fresh direction for the album playing (unless its look is pinned).
    func rerollAlbumLook() {
        guard let info = metadata else { return }
        updateLook(for: info, reroll: true)
    }

    var currentLookPinned: Bool {
        get { pinnedCache }
        set {
            pinnedCache = newValue
            guard let key = currentAlbumKey else { return }
            Task { await styleStore.setPinned(newValue, for: key) }
        }
    }
    private var pinnedCache = false

    var hasAPIKey: Bool { APIKeyStore.load() != nil }

    func saveAPIKey(_ key: String) {
        APIKeyStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
        append(key.isEmpty ? "API key removed" : "API key saved to the keychain")
    }

    private func applyVisualSettings() {
        renderer?.themeOverride = switch settings.theme {
        case .auto: nil
        case .paper: .paper
        case .smoke: .smoke
        case .googie: .googie
        }
        renderer?.showCover = settings.showCover
        renderer?.renderResolution = settings.renderResolution
        renderer?.coverModeOverride = switch settings.cover {
        case .auto: nil
        case .living: .living
        case .dissolve: .dissolve
        case .record: .record
        }
    }

    // MARK: - Recovery

    private func startRecoveryWatch() {
        // No audio arriving while the source says it's running: restart it.
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForStall() }
        }
        // Audio engines often don't survive sleep.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.append("Mac woke up: restarting input")
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    await self.restartInput()
                }
            }
        }
    }

    private func checkForStall() {
        let snapshot = pipeline.snapshot()
        var running = false
        if case .running = snapshot.sourceStatus { running = true }
        if stall.update(now: ProcessInfo.processInfo.systemUptime, audioTime: snapshot.features.time, running: running) {
            append("No audio arriving from \(snapshot.sourceName ?? "the input"): restarting it")
            Task { await restartInput() }
        }
    }

    private func keepDisplayAwake(_ awake: Bool) {
        if awake, displayAwake == nil {
            displayAwake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                                 reason: "Showing visuals for the music playing")
        } else if !awake, let activity = displayAwake {
            ProcessInfo.processInfo.endActivity(activity)
            displayAwake = nil
        }
    }

    func showSetup() {
        setup.show(model: self)
    }

    func toggleDebugOverlay() {
        settings.showDebugOverlay.toggle()
    }

    func toggleLyrics() {
        settings.showLyrics.toggle()
    }

    func toggleCover() {
        settings.showCover.toggle()
    }

    private func append(_ text: String) {
        // Recognition errors repeat every matching window; one line is enough.
        guard log.last?.text != text else { return }
        log.append(LogEntry(text: text))
        if log.count > 100 { log.removeFirst(log.count - 100) }
    }

    static func describe(_ event: SideEvent) -> String? {
        switch event {
        case .gapStarted:
            nil
        case .sideStarted:
            "Side started"
        case .trackGap(let start, let end, _):
            "Track gap \(String(format: "%.1f", end - start)) s"
        case .sideEnded(let start, let end, let reason):
            "Side ended (\(reason == .runout ? "run-out" : "needle lift")) after \(formatDuration(end - start))"
        }
    }
}

func formatDuration(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return String(format: "%d:%02d", s / 60, s % 60)
}
