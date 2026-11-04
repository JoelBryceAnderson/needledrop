import AppKit
import AudioCapture
import Pipeline
import SessionState
import SignalAnalysis
import SwiftUI

/// First-run setup for a turntable: input, gain, the three levels side detection needs,
/// output latency, and launch at login. Also reachable from the menu bar later.
struct SetupAssistant: View {
    @Bindable var model: AppModel
    var close: () -> Void

    enum Step: Int, CaseIterable {
        case input, gain, groove, music, needleUp, thresholds, latency, finish
    }

    @State private var step: Step = .input
    @State private var measuring = false
    @State private var progress = 0.0
    @State private var gain: Calibration.GainAdvice?
    @State private var groove: Float?
    @State private var music: Float?
    @State private var needleUp: Float?
    @State private var startAtLogin = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up Your Turntable").font(.title2.bold())
            Text("Step \(step.rawValue + 1) of \(Step.allCases.count)").foregroundStyle(.secondary)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if [.gain, .groove, .music, .needleUp, .latency].contains(step) {
                meter
            }
            if measuring { ProgressView(value: progress) }
            HStack {
                if step != .input { Button("Back") { move(-1) }.disabled(measuring) }
                Spacer()
                Button("Skip Setup") { finish(apply: false) }.disabled(measuring)
                Button(step == .finish ? "Done" : "Next") { step == .finish ? finish(apply: true) : move(1) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(measuring)
            }
        }
        .padding(24)
        .frame(width: 560, height: 560)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .input:
            Text("Which input is the turntable connected to? Pick your USB audio interface.")
            Picker("Input", selection: Binding(
                get: { model.settings.input },
                set: { selection in Task { await model.selectInput(selection) } }
            )) {
                Text("System default input").tag(InputSelection.systemDefault)
                Text("This Mac's audio (no turntable yet)").tag(InputSelection.systemAudio)
                if case .replay(let path) = model.settings.input {
                    Text("Replay: \(URL(fileURLWithPath: path).lastPathComponent)").tag(model.settings.input)
                }
                ForEach(model.devices) { device in
                    Text("\(device.name) — \(device.inputChannelCount) ch").tag(InputSelection.device(uid: device.uid, name: device.name))
                }
            }
            Button("Refresh Devices") { model.refreshDevices() }
            Text("If macOS asks for microphone access, allow it: that's how Needledrop hears the interface.")
                .font(.caption).foregroundStyle(.secondary)

        case .gain:
            Text("Play the loudest part of a record, then measure for 10 seconds.")
            measureButton("Measure Level") {
                let samples = await sample(seconds: 10) { ($0.peakHoldDB, $0.lastClipTime) }
                let peak = samples.map(\.0).max() ?? -120
                let clipped = Set(samples.compactMap(\.1)).count > 0
                gain = Calibration.gainAdvice(peakDB: peak, clipped: clipped)
            }
            if let gain {
                Label(gain.message, systemImage: gain == .good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(gain == .good ? .green : .orange)
                if gain != .good { Text("Adjust the gain knob, then measure again.").foregroundStyle(.secondary) }
            }

        case .groove:
            Text("Lower the needle onto the lead-in groove at the very start of a side — before the music — and measure for 6 seconds.")
            measureButton("Measure Groove Noise") {
                groove = Calibration.level(await sample(seconds: 6) { $0.gatedLevelDB }, percentile: 0.5)
            }
            if let groove { Text(String(format: "Groove noise: %.0f dB", groove)) }

        case .music:
            Text("Now let it play into the music and measure for 10 seconds.")
            measureButton("Measure Music") {
                music = Calibration.level(await sample(seconds: 10) { $0.gatedLevelDB }, percentile: 0.6)
            }
            if let music { Text(String(format: "Music: %.0f dB", music)) }

        case .needleUp:
            Text("Lift the needle off the record and measure for 5 seconds. (Optional: lets Needledrop tell a lifted needle from the quiet between tracks.)")
            measureButton("Measure Needle Up") {
                needleUp = Calibration.level(await sample(seconds: 5) { $0.gatedLevelDB }, percentile: 0.5)
            }
            if let needleUp { Text(String(format: "Needle up: %.0f dB", needleUp)) }

        case .thresholds:
            if let groove, let music {
                let fit = Calibration.fit(.init(grooveNoiseDB: groove, musicDB: music, needleUpDB: needleUp), base: model.settings.detector)
                Text("Side detection will use:")
                Grid(alignment: .leading) {
                    GridRow { Text("Side starts above"); Text(String(format: "%.0f dB", fit.config.startThresholdDB)).monospacedDigit() }
                    GridRow { Text("Quiet below"); Text(String(format: "%.0f dB", fit.config.stopThresholdDB)).monospacedDigit() }
                    GridRow { Text("Needle up below"); Text(String(format: "%.0f dB", fit.config.needleLiftFloorDB)).monospacedDigit() }
                }
                ForEach(fit.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                Text("These are applied when you press Next. You can fine-tune them later in Settings › Listening.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Measure the groove noise and the music first (go Back), or press Next to keep the current settings.")
            }

        case .latency:
            Text("If you listen through AirPlay speakers (HomePods via Apple TV), they play a couple of seconds behind the turntable. Play a record with a clear beat and drag until the dot flashes with what you hear.")
            HStack(spacing: 16) {
                TimelineView(.animation) { _ in
                    let age = model.pipeline.features(delayedBy: model.settings.outputLatency).beatAge ?? 9
                    Circle()
                        .fill(Color.accentColor.opacity(0.15 + 0.85 * max(0, 1 - age / 0.15)))
                        .frame(width: 48, height: 48)
                }
                Slider(value: $model.settings.outputLatency, in: 0...4)
                Text(String(format: "%.2f s", model.settings.outputLatency)).monospacedDigit().frame(width: 60)
            }

        case .finish:
            Text("That's it. Drop the needle and the TV comes alive.")
            Toggle("Start Needledrop when this Mac starts", isOn: $startAtLogin)
            Text("You can run this again from the menu bar: Set Up Turntable…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var meter: some View {
        TimelineView(.animation) { _ in
            let snapshot = model.pipeline.snapshot()
            VStack(alignment: .leading, spacing: 6) {
                LevelMeter(snapshot: snapshot, u: 9).frame(height: 34)
                LevelHistory(snapshot: snapshot, u: 6).frame(height: 70)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black))
        }
    }

    private func measureButton(_ title: String, _ action: @escaping () async -> Void) -> some View {
        Button(title) {
            Task {
                measuring = true
                await action()
                measuring = false
            }
        }
        .disabled(measuring)
    }

    /// Reads the pipeline every 50 ms for `seconds`, updating the progress bar.
    private func sample<T>(seconds: Double, _ read: (PipelineSnapshot) -> T) async -> [T] {
        var values: [T] = []
        let count = Int(seconds * 20)
        for i in 0..<count {
            values.append(read(model.pipeline.snapshot()))
            progress = Double(i + 1) / Double(count)
            try? await Task.sleep(for: .milliseconds(50))
        }
        return values
    }

    private func move(_ delta: Int) {
        if step == .thresholds, delta > 0, let groove, let music {
            model.updateDetector(Calibration.fit(.init(grooveNoiseDB: groove, musicDB: music, needleUpDB: needleUp),
                                                 base: model.settings.detector).config)
        }
        step = Step(rawValue: step.rawValue + delta) ?? step
    }

    private func finish(apply: Bool) {
        if apply, startAtLogin { model.launchesAtLogin = true }
        model.settings.setupCompleted = true
        close()
    }
}

/// Shows the assistant in its own window.
@MainActor
final class SetupPresenter {
    private var window: NSWindow?

    func show(model: AppModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set Up Turntable"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SetupAssistant(model: model) { [weak self] in
            self?.window?.close()
            self?.window = nil
        })
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
