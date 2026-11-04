import AudioCapture
import SessionState
import SwiftUI
import UniformTypeIdentifiers
import Visuals

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            inputSection
            detectionSection
            displaySection
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.launchesAtLogin = $0 }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 640)
        .onAppear { model.refreshDevices() }
    }

    // MARK: - Input

    private var inputOptions: [(InputSelection, String)] {
        var options: [(InputSelection, String)] = [(.systemDefault, "System default input")]
        options += model.devices.map { (.device(uid: $0.uid, name: $0.name), $0.name) }
        if case .device(let uid, let name) = model.settings.input, !model.devices.contains(where: { $0.uid == uid }) {
            options.append((model.settings.input, "\(name) (disconnected)"))
        }
        if case .replay(let path) = model.settings.input {
            options.append((model.settings.input, "Replay: \(URL(fileURLWithPath: path).lastPathComponent)"))
        }
        return options
    }

    private var selectedDevice: AudioInputDevice? {
        guard case .device(let uid, _) = model.settings.input else { return nil }
        return model.devices.first { $0.uid == uid }
    }

    private var inputSection: some View {
        Section("Input") {
            Picker("Source", selection: Binding(
                get: { model.settings.input },
                set: { selection in Task { await model.selectInput(selection) } }
            )) {
                ForEach(inputOptions, id: \.0) { option, label in
                    Text(label).tag(option)
                }
            }
            if let device = selectedDevice, device.availableSampleRates.count > 1 {
                Picker("Sample rate", selection: Binding(
                    get: { device.nominalSampleRate },
                    set: { rate in Task { await model.setSampleRate(rate) } }
                )) {
                    ForEach(device.availableSampleRates, id: \.self) { rate in
                        Text("\(rate / 1000, specifier: "%g") kHz").tag(rate)
                    }
                }
            }
            HStack {
                Button("Replay a Recording…", action: chooseReplayFile)
                Spacer()
                Button("Refresh Devices") { model.refreshDevices() }
            }
            if model.microphoneDenied {
                Text("Microphone access is off. Enable Needledrop in System Settings › Privacy & Security › Microphone.")
                    .foregroundStyle(.red)
            }
            TimelineView(.animation) { _ in
                let snapshot = model.pipeline.snapshot()
                VStack(alignment: .leading, spacing: 6) {
                    LevelMeter(snapshot: snapshot, u: 9)
                        .frame(height: 34)
                    LevelHistory(snapshot: snapshot, u: 6)
                        .frame(height: 90)
                    Text(String(format: "Music band %.1f dB  ·  flatness %.2f", snapshot.gatedLevelDB, snapshot.gatedFlatness))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black))
            }
        }
    }

    private func chooseReplayFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a recording to replay as if it were the turntable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.selectInput(.replay(path: url.path)) }
    }

    // MARK: - Detection

    private func detector<Value>(_ keyPath: WritableKeyPath<SideDetectorConfig, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings.detector[keyPath: keyPath] },
            set: { value in
                var config = model.settings.detector
                config[keyPath: keyPath] = value
                model.updateDetector(config)
            }
        )
    }

    private var detectionSection: some View {
        Section {
            SliderRow(title: "Start threshold", value: detector(\.startThresholdDB), range: -70...(-10), format: "%.0f dB", color: .green)
            SliderRow(title: "Stop threshold", value: detector(\.stopThresholdDB), range: -80...(-20), format: "%.0f dB", color: .orange)
            SliderRow(title: "Needle-lift floor", value: detector(\.needleLiftFloorDB), range: -100...(-40), format: "%.0f dB", color: .red)
            SliderRow(title: "Max music flatness", value: detector(\.maxMusicFlatness), range: 0.05...0.8, format: "%.2f")
            SliderRow(title: "Start after", value: detector(\.startHold), range: 0.2...5, format: "%.1f s")
            SliderRow(title: "Track gap at least", value: detector(\.gapMinimum), range: 0.3...4, format: "%.1f s")
            SliderRow(title: "Side ends after", value: detector(\.sideEndSilence), range: 3...30, format: "%.0f s")
            SliderRow(title: "Needle lift confirm", value: detector(\.needleLiftConfirm), range: 0.5...10, format: "%.1f s")
            Button("Reset to Defaults") { model.updateDetector(SideDetectorConfig()) }
        } header: {
            Text("Side Detection")
        } footer: {
            Text("Levels are the 100 Hz–5 kHz band, median-filtered over \(model.settings.detector.smoothingWindow, specifier: "%.1f") s. Set the start line above lead-in groove noise and the stop line just above the quiet between tracks.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        Section("Visuals") {
            Picker("Display", selection: Binding(
                get: {
                    PresentationController.screen(displayID: model.settings.displayID, displayName: model.settings.displayName).displayID ?? 0
                },
                set: { id in
                    if let screen = NSScreen.screens.first(where: { $0.displayID == id }) { model.selectDisplay(screen) }
                }
            )) {
                ForEach(NSScreen.screens, id: \.displayID) { screen in
                    Text("\(screen.localizedName) — \(Int(screen.frame.width))×\(Int(screen.frame.height))")
                        .tag(screen.displayID ?? 0)
                }
            }
            Toggle("Full screen", isOn: Binding(
                get: { model.settings.fullScreen },
                set: { _ in model.toggleFullScreen() }
            ))
            Picker("Mode", selection: $model.settings.visualMode) {
                Text("Auto (living cover)").tag(VisualMode.auto)
                Text("Palette bleed only").tag(VisualMode.paletteBleed)
            }
            Toggle("Now-playing caption", isOn: $model.settings.showNowPlaying)
            Toggle("Debug overlay", isOn: $model.settings.showDebugOverlay)
        }
    }
}

private struct SliderRow<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    let title: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    let format: String
    var color: Color?

    var body: some View {
        HStack {
            if let color {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(title)
            Slider(value: $value, in: range)
            Text(String(format: format, Double(value)))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
    }
}
