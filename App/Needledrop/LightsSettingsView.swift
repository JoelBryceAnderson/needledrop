import Lights
import SwiftUI

/// Settings › Lights: find and pair a Hue Bridge, pick a light or entertainment area,
/// and set how bright and how much it pulses.
struct LightsSection: View {
    @Bindable var model: AppModel
    @State private var selectedBridge: HueBridge?
    @State private var manualHost = ""
    @State private var message: String?

    private var lights: LightsController { model.lights }

    var body: some View {
        bridgeSection
        if lights.paired {
            followSection
        }
    }

    private var bridgeSection: some View {
        Section {
            if let bridge = model.settings.lights.bridge, lights.paired {
                LabeledContent("Bridge", value: bridge.host)
                Button("Forget This Bridge", role: .destructive) { lights.forget() }
            } else {
                Picker("Bridge", selection: $selectedBridge) {
                    Text(lights.bridges.isEmpty ? "None found yet" : "Choose…").tag(HueBridge?.none)
                    ForEach(lights.bridges) { bridge in
                        Text("\(bridge.host)  (\(bridge.id.suffix(6).uppercased()))").tag(HueBridge?.some(bridge))
                    }
                }
                HStack {
                    Button(lights.discovering ? "Searching…" : "Search for Bridges") {
                        Task {
                            await lights.discover()
                            if selectedBridge == nil { selectedBridge = lights.bridges.first }
                        }
                    }
                    .disabled(lights.discovering)
                    Spacer()
                    TextField("or address", text: $manualHost)
                        .frame(width: 140)
                        .onSubmit { addManual() }
                    Button("Add") { addManual() }
                        .disabled(manualHost.isEmpty)
                }
                Button(lights.pairing ? "Press the link button on the bridge…" : "Pair") {
                    guard let bridge = selectedBridge else { return }
                    message = nil
                    Task { message = await lights.pair(with: bridge) }
                }
                .disabled(selectedBridge == nil || lights.pairing)
            }
            if let message {
                Text(message).foregroundStyle(.red)
            }
        } header: {
            Text("Philips Hue")
        } footer: {
            Text("Pairing: choose your bridge, click Pair, then press the round button on top of the bridge within 30 seconds. The key is kept in your keychain.")
        }
    }

    private var followSection: some View {
        Section {
            Toggle("Lights follow the music", isOn: $model.settings.lights.enabled)
            Picker("Light", selection: $model.settings.lights.target) {
                Text("Choose…").tag(LightTarget?.none)
                let areas = lights.resources.filter { if case .entertainment = $0.target { true } else { false } }
                let groups = lights.resources.filter { if case .group = $0.target { true } else { false } }
                let singles = lights.resources.filter { if case .light = $0.target { true } else { false } }
                if !areas.isEmpty {
                    Section("Entertainment areas (pulse on the beat)") {
                        ForEach(areas) { Text($0.target.name).tag(LightTarget?.some($0.target)) }
                    }
                }
                if !singles.isEmpty {
                    Section("Lights") {
                        ForEach(singles) { Text($0.target.name).tag(LightTarget?.some($0.target)) }
                    }
                }
                if !groups.isEmpty {
                    Section("Rooms and zones (colour only)") {
                        ForEach(groups) { Text($0.target.name).tag(LightTarget?.some($0.target)) }
                    }
                }
                if let target = model.settings.lights.target, !lights.resources.contains(where: { $0.target == target }) {
                    Text(target.name).tag(LightTarget?.some(target))
                }
            }
            HStack {
                Text("Brightness")
                Slider(value: $model.settings.lights.brightness, in: 0.05...1)
                Text("\(Int(model.settings.lights.brightness * 100)) %").monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            HStack {
                Text("Beat pulse")
                Slider(value: $model.settings.lights.pulse, in: 0...1)
                Text("\(Int(model.settings.lights.pulse * 100)) %").monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            Button(lights.loadingResources ? "Loading…" : "Refresh Lights") { Task { await lights.loadResources() } }
                .disabled(lights.loadingResources)
            Text(lights.status).foregroundStyle(.secondary)
        } footer: {
            Text("The lights take the paper colour of the album on screen, warm toward its accent when the music lifts, and fade between albums. An entertainment area (set one up in the Hue app) pulses gently on the beat; single lights pulse more slowly and rooms only change colour. Motion › Still turns pulses off. Lights follow the output latency, like the visuals.")
        }
    }

    private func addManual() {
        Task {
            message = await lights.addBridge(host: manualHost)
            if message == nil {
                selectedBridge = lights.bridges.first
                manualHost = ""
            }
        }
    }
}
