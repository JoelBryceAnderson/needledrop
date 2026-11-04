import AppKit
import AudioCapture
import Foundation
import Metadata
import Observation
import Pipeline
import Recognition
import ReplayHarness
import ServiceManagement
import SessionState
import SwiftUI

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

@MainActor
@Observable
final class AppModel {
    var settings: AppSettings {
        didSet { settings.save() }
    }
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

    init() {
        let settings = AppSettings.load()
        self.settings = settings
        engine = Engine(detector: settings.detector, recognizer: ShazamRecognizer(), metadata: nil)
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

        let engine = Engine(detector: settings.detector, recognizer: recognizer, metadata: metadataResolver)
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
            DebugOverlayView(model: self),
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
            if let track {
                append("♫ \(track.artist) — \(track.title)")
            } else if engine.session().unidentified {
                append("Couldn't identify this record")
            }
        case .metadata(let info, let data):
            metadata = info
            artwork = data.flatMap(NSImage.init(data:))
        case .recognitionError(let message):
            append("✖ \(message)")
        }
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
