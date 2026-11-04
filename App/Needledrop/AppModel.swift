import AppKit
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
            renderer?.mode = settings.visualMode
        }
    }
    /// Nil only if Metal is unavailable; the stage then stays black.
    let renderer: VisualsRenderer?
    /// When the current track's caption should start showing.
    private(set) var nowPlayingSince: Date?
    private(set) var engine: Engine
    var pipeline: ListeningPipeline { engine.pipeline }
    /// Current track's metadata and artwork, for the now-playing panel.
    private(set) var metadata: TrackMetadata?
    private(set) var artwork: NSImage?
    private(set) var devices: [AudioInputDevice] = []
    private(set) var log: [LogEntry] = []
    private(set) var microphoneDenied = false
    let presentation = PresentationController()

    private var eventTask: Task<Void, Never>?
    private let metadataResolver = MetadataResolver(cacheDirectory: MetadataResolver.defaultCacheDirectory)
    private let lyricsProvider = LyricsProvider(cacheDirectory: MetadataResolver.defaultCacheDirectory)

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
        renderer?.mode = settings.visualMode
        renderer?.inputProvider = { [weak self] in self?.visualInput() ?? VisualInput() }
    }

    /// Everything is read `outputLatency` behind the newest audio, so picture and words
    /// line up with what the room hears rather than what the Mac hears.
    private func visualInput() -> VisualInput {
        let (features, beatAge) = pipeline.features(delayedBy: settings.outputLatency)
        let session = engine.session()
        var input = VisualInput(features: features, beatAge: beatAge,
                                active: session.phase != .idle && session.phase != .sideEnded)
        if settings.showLyrics, let lyrics = session.lyrics, lyrics.isSynced, !lyrics.instrumental,
           let clock = session.clock, clock.confidence(at: features.time) > 0.15 {
            input.lyricsAvailable = true
            if let cue = lyrics.cue(at: clock.position(at: features.time)) {
                input.lyric = LyricFrame(id: cue.index, text: cue.text, next: cue.next)
            }
        }
        return input
    }

    func launch() async {
        refreshDevices()
        await restartInput()
        presentVisuals()
        presentation.onDisplaysChanged = { [weak self] in self?.presentVisuals() }
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
        switch settings.input {
        case .systemDefault, .device:
            microphoneDenied = !(await MicrophoneAccess.request())
            if microphoneDenied { append("Microphone access denied — enable Needledrop in System Settings › Privacy & Security › Microphone") }
            if case .device(let uid, _) = settings.input {
                source = LiveInputSource(deviceUID: uid)
            } else {
                source = LiveInputSource(deviceUID: nil)
            }
        case .replay(let path):
            let url = URL(fileURLWithPath: path)
            source = FileReplaySource(url: url, loop: true)
            do {
                if let script = try ReplayScript.load(for: url) {
                    recognizer = script.recognizer()
                    append("Using \(ReplayScript.sidecarURL(for: url).lastPathComponent) instead of Shazam")
                }
            } catch {
                append("Ignoring unreadable track sidecar: \(error.localizedDescription)")
            }
        }

        let engine = Engine(detector: settings.detector, recognizer: recognizer, metadata: metadataResolver,
                            lyrics: lyricsProvider)
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
        case .pipeline(.side(let side)): if let text = Self.describe(side) { append(text) }
        case .pipeline(.tick), .pipeline(.recognition): break
        case .trackChanged(let track):
            metadata = nil
            artwork = nil
            nowPlayingSince = nil
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
            nowPlayingSince = Date()
            updateLook(for: info)
        case .lyrics(let lyrics):
            if let lyrics, lyrics.instrumental {
                append("Instrumental — no lyrics")
            } else if let lyrics, lyrics.isSynced {
                append("Lyrics: \(lyrics.lines.filter { !$0.text.isEmpty }.count) synced lines")
            } else {
                append(lyrics?.plain == nil ? "No lyrics found" : "Only unsynced lyrics found")
            }
        case .recognitionError(let message):
            append("✖ \(message)")
        }
    }

    private func updateLook(for info: TrackMetadata) {
        guard let renderer, let image = artwork?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let id = info.collectionID ?? "\(info.artist)|\(info.album ?? info.title)"
        guard renderer.currentLookID != id else { return }
        Task { [weak self] in
            let look = await AlbumLook.make(id: id, artwork: image)
            // Only if it's still the album playing.
            guard let self, let current = self.metadata,
                  (current.collectionID ?? "\(current.artist)|\(current.album ?? current.title)") == id else { return }
            self.renderer?.show(look)
        }
    }

    func toggleDebugOverlay() {
        settings.showDebugOverlay.toggle()
    }

    private func append(_ text: String) {
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
