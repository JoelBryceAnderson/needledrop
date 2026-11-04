import AudioCapture
import Foundation
import Observation
import Pipeline
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
    private(set) var pipeline: ListeningPipeline
    private(set) var devices: [AudioInputDevice] = []
    private(set) var log: [LogEntry] = []
    private(set) var microphoneDenied = false
    let presentation = PresentationController()

    private var eventTask: Task<Void, Never>?

    init() {
        let settings = AppSettings.load()
        self.settings = settings
        pipeline = ListeningPipeline(config: settings.detector)
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
        pipeline.stop()

        let source: any AudioSource
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
            source = FileReplaySource(url: URL(fileURLWithPath: path), loop: true)
        }

        let pipeline = ListeningPipeline(config: settings.detector)
        self.pipeline = pipeline
        eventTask = Task { [weak self] in
            for await event in pipeline.events {
                self?.handle(event)
            }
        }
        do {
            try pipeline.start(source: source)
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

    private func handle(_ event: PipelineEvent) {
        switch event {
        case .source(.running(let format, let name)): append("● \(name) — \(format)")
        case .source(.waitingForDevice(let what)): append("Waiting for \(what)")
        case .source(.failed(let message)): append("✖ \(message)")
        case .source(.finished): append("Replay finished")
        case .side(let side): append(Self.describe(side))
        }
    }

    private func append(_ text: String) {
        log.append(LogEntry(text: text))
        if log.count > 100 { log.removeFirst(log.count - 100) }
    }

    static func describe(_ event: SideEvent) -> String {
        switch event {
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
