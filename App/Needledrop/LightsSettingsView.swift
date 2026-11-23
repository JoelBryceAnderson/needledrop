import Lights
import SwiftUI

/// Settings › Lights: Philips Hue (find and pair a bridge, pick a light or entertainment
/// area) or Apple Home (pick a colour light or room), and how bright and how much it pulses.
struct LightsSection: View {
    @Bindable var model: AppModel
    @State private var selectedBridge: HueBridge?
    @State private var manualHost = ""
    @State private var message: String?

    private var lights: LightsController { model.lights }

    var body: some View {
        Section {
            Picker("Lights", selection: $model.settings.lights.provider) {
                ForEach(LightsProvider.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        switch model.settings.lights.provider {
        case .hue:
            bridgeSection
            if lights.paired {
                followSection
            }
        case .homeKit:
            homeSection
        }
    }

    private var homeSection: some View {
        Section {
            Toggle("Lights follow the music", isOn: $model.settings.lights.enabled)
                .disabled(lights.homeAuthorization != .authorized)
            Picker("Light", selection: $model.settings.lights.homeTarget) {
                Text(lights.homeLights.isEmpty ? "None found" : "Choose…").tag(HomeTarget?.none)
                if !lights.homeRooms.isEmpty {
                    Section("Rooms (every colour light in it)") {
                        ForEach(lights.homeRooms) { room in
                            let target = HomeTarget.room(id: room.id, name: room.name)
                            Text(Self.label(room.name, count: room.lights.count)).tag(HomeTarget?.some(target))
                        }
                    }
                }
                if !lights.homeLights.isEmpty {
                    Section("Lights") {
                        ForEach(lights.homeLights) { light in
                            let target = HomeTarget.light(id: light.id, name: light.name)
                            Text(light.room.map { "\(light.name) (\($0))" } ?? light.name).tag(HomeTarget?.some(target))
                        }
                    }
                }
                if let target = model.settings.lights.homeTarget, !isListed(target) {
                    Text(target.name).tag(HomeTarget?.some(target))
                }
            }
            HStack {
                Text("Brightness")
                Slider(value: $model.settings.lights.brightness, in: 0.05...1)
                Text("\(Int(model.settings.lights.brightness * 100)) %").monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            Button("Refresh Lights") { lights.refreshHome() }
            Text(lights.status).foregroundStyle(.secondary)
        } header: {
            Text("Apple Home")
        } footer: {
            Text("Any colour light in the Home app works, however it connects. The lights take the paper colour of the album on screen, warm toward its accent when the music lifts, and fade between albums. HomeKit is too slow for beat pulses, so they change colour about twice a second. A small helper, Needledrop Home, talks to HomeKit and asks for access to your Home data once.")
        }
    }

    private func isListed(_ target: HomeTarget) -> Bool {
        switch target {
        case .light(let id, _): lights.homeLights.contains { $0.id == id }
        case .room(let id, _): lights.homeRooms.contains { $0.id == id }
        }
    }

    private static func label(_ name: String, count: Int) -> String {
        "\(name) (\(count) light\(count == 1 ? "" : "s"))"
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
            Text("Pairing: choose your bridge, click Pair, then press the round button on top of the bridge within 30 seconds. The key is kept privately on this Mac.")
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
