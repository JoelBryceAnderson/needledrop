import Foundation
import Lights
import Observation
import QuartzCore
import SessionState
import Visuals

/// The Lights settings: which bridge, which light or area, and how much it moves.
/// Keys live in `HueKeyStore` (private files), not here.
struct LightsSettings: Codable, Equatable {
    var enabled = false
    var bridge: HueBridge?
    var target: LightTarget?
    /// 0…1 of the lights' full output, at rest.
    var brightness = 0.7
    /// 0…1: how deep beat pulses go (the Motion setting scales it; Still turns them off).
    var pulse = 0.5

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LightsSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        bridge = try? c.decodeIfPresent(HueBridge.self, forKey: .bridge)
        target = try? c.decodeIfPresent(LightTarget.self, forKey: .target)
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? d.brightness
        pulse = try c.decodeIfPresent(Double.self, forKey: .pulse) ?? d.pulse
    }
}

/// Drives the user's Hue lights from what's on screen: the album look's colours and the
/// (latency-delayed) beat. Reads the model ~30 times a second; the output decides how
/// much of that it can send (streaming at 50 Hz, REST at the bridge's limits).
@MainActor
@Observable
final class LightsController {
    private(set) var bridges: [HueBridge] = []
    private(set) var discovering = false
    private(set) var pairing = false
    private(set) var resources: [HueResource] = []
    private(set) var loadingResources = false
    /// What the lights are doing, for Settings.
    private(set) var status = "Off"

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var show = LightShow()
    @ObservationIgnored private var output: (any LightOutput)?
    /// The settings `output` was built for; a change rebuilds it.
    @ObservationIgnored private var connectedFor: Connection?
    @ObservationIgnored private var connecting = false
    @ObservationIgnored private var client: HueClient?

    private struct Connection: Equatable {
        var bridge: HueBridge
        var target: LightTarget
    }

    func start(model: AppModel) {
        self.model = model
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.005
        if model.settings.lights.bridge != nil { Task { await loadResources() } }
    }

    var paired: Bool {
        guard let bridge = model?.settings.lights.bridge else { return false }
        return HueKeyStore.load(bridgeID: bridge.id) != nil
    }

    // MARK: - Frame loop

    private func tick() {
        guard let model else { return }
        let settings = model.settings.lights
        let wanted: Connection? = if settings.enabled, let bridge = settings.bridge, let target = settings.target {
            Connection(bridge: bridge, target: target)
        } else {
            nil
        }
        if wanted != connectedFor, !connecting {
            Task { await reconnect(to: wanted) }
            return
        }
        guard let output, !connecting else { return }

        let (features, beatAge, _) = model.pipeline.features(delayedBy: model.settings.outputLatency)
        let phase = model.engine.session().phase
        let input = LightShowInput(palette: model.renderer?.currentPalette ?? .neutral, features: features,
                                   beatAge: beatAge, active: phase != .idle && phase != .sideEnded)
        let config = LightShowConfig(brightness: settings.brightness, pulse: settings.pulse,
                                     motion: model.settings.motion.amount, pulses: output.pulses)
        let now = CACurrentMediaTime()
        output.send(show.update(input, config: config, now: now), now: now)
    }

    private func reconnect(to connection: Connection?) async {
        connecting = true
        defer { connecting = false }
        if let output { await output.close() }
        output = nil
        connectedFor = connection
        guard let connection else {
            status = "Off"
            return
        }
        guard let credentials = HueKeyStore.load(bridgeID: connection.bridge.id) else {
            status = "Not paired with this bridge"
            return
        }
        let client = client(for: connection.bridge, credentials: credentials)
        let onError: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor in self?.failed(error) }
        }
        switch connection.target {
        case .light(let id, let name):
            let gamut = resources.first { $0.target == connection.target }?.gamut ?? .c
            output = RESTLightOutput(sink: client, targets: [(.light(id: id, name: name), gamut)], onError: onError)
            status = "Following the album on “\(name)”"
        case .group(_, let name):
            output = RESTLightOutput(sink: client, targets: [(connection.target, .c)], onError: onError)
            status = "Following the album on “\(name)” (rooms update once a second: colour only, no pulses)"
        case .entertainment(let id, let name):
            if resources.isEmpty { await loadResources() }
            let area = resources.first { $0.target == connection.target }
            do {
                output = try await EntertainmentOutput.start(client: client, areaID: id, channels: area?.channels ?? [],
                                                             onError: onError)
                status = "Streaming to “\(name)”"
            } catch {
                // Another app may be streaming, or the pairing predates client keys: drive
                // the area's lights over REST instead (slower, so pulses only for one light).
                let lights = (area?.lights ?? []).map { id -> (target: LightTarget, gamut: Gamut) in
                    let light = resources.first { if case .light(id, _) = $0.target { true } else { false } }
                    return (.light(id: id, name: light?.target.name ?? id), light?.gamut ?? .c)
                }
                output = RESTLightOutput(sink: client, targets: lights, onError: onError)
                status = "Couldn't stream to “\(name)” (\(error)). Using slower updates instead."
            }
        }
        show = LightShow()
    }

    private func failed(_ error: Error) {
        if case HueError.unauthorized = error {
            status = HueError.unauthorized.description
        } else if !status.hasPrefix("Problem") {
            status = "Problem talking to the bridge: \(error)"
        }
    }

    private func client(for bridge: HueBridge, credentials: HueCredentials?) -> HueClient {
        if let client, client.bridge == bridge {
            var updated = client
            updated.credentials = credentials
            self.client = updated
            return updated
        }
        let made = HueClient(bridge: bridge, credentials: credentials)
        client = made
        return made
    }

    // MARK: - Setup

    func discover() async {
        discovering = true
        defer { discovering = false }
        bridges = await HueDiscovery.discover()
        if let saved = model?.settings.lights.bridge, !bridges.contains(where: { $0.id == saved.id }) {
            bridges.insert(saved, at: 0)
        }
    }

    /// A bridge typed in by address (when discovery finds nothing, e.g. across subnets).
    func addBridge(host: String) async -> String? {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        do {
            let id = try await HueClient.bridgeID(host: host)
            let bridge = HueBridge(id: id, host: host)
            bridges.removeAll { $0.id == id }
            bridges.insert(bridge, at: 0)
            return nil
        } catch {
            return "No Hue Bridge answered at \(host)."
        }
    }

    /// Waits up to 30 s for the link button, then saves the keys and lists the lights.
    func pair(with bridge: HueBridge) async -> String? {
        pairing = true
        defer { pairing = false }
        let client = HueClient(bridge: bridge)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            do {
                let credentials = try await client.pair()
                HueKeyStore.save(credentials, bridgeID: bridge.id)
                model?.settings.lights.bridge = bridge
                self.client = nil
                connectedFor = nil  // reconnect with the new keys
                await loadResources()
                return nil
            } catch HueError.linkButtonNotPressed {
                try? await Task.sleep(for: .seconds(2))
            } catch {
                return "\(error)"
            }
        }
        return HueError.linkButtonNotPressed.description
    }

    func forget() {
        guard let model, let bridge = model.settings.lights.bridge else { return }
        HueKeyStore.save(nil, bridgeID: bridge.id)
        model.settings.lights.bridge = nil
        model.settings.lights.target = nil
        model.settings.lights.enabled = false
        resources = []
        client = nil
    }

    func loadResources() async {
        guard let bridge = model?.settings.lights.bridge,
              let credentials = HueKeyStore.load(bridgeID: bridge.id) else { return }
        loadingResources = true
        defer { loadingResources = false }
        do {
            resources = try await client(for: bridge, credentials: credentials).resources()
        } catch {
            status = "Couldn't list the bridge's lights: \(error)"
        }
    }
}
