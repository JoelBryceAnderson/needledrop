import AppKit
import Foundation
import HomeLink
import Lights
import Observation
import QuartzCore
import SessionState
import Visuals

/// Which lights Needledrop drives.
enum LightsProvider: String, Codable, CaseIterable {
    case hue, homeKit

    var label: String {
        switch self {
        case .hue: "Philips Hue"
        case .homeKit: "Apple Home"
        }
    }
}

/// The Lights settings: Hue (which bridge, which light or area) or Apple Home (which light
/// or room), and how much it moves. Hue keys live in `HueKeyStore` (private files), not here.
struct LightsSettings: Codable, Equatable {
    var enabled = false
    var provider = LightsProvider.hue
    var bridge: HueBridge?
    var target: LightTarget?
    var homeTarget: HomeTarget?
    /// 0…1 of the lights' full output, at rest.
    var brightness = 0.7
    /// 0…1: how deep beat pulses go (the Motion setting scales it; Still turns them off).
    var pulse = 0.5

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LightsSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        provider = (try? c.decodeIfPresent(LightsProvider.self, forKey: .provider)) ?? d.provider
        homeTarget = try? c.decodeIfPresent(HomeTarget.self, forKey: .homeTarget)
        bridge = try? c.decodeIfPresent(HueBridge.self, forKey: .bridge)
        target = try? c.decodeIfPresent(LightTarget.self, forKey: .target)
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? d.brightness
        pulse = try c.decodeIfPresent(Double.self, forKey: .pulse) ?? d.pulse
    }
}

/// Drives the user's lights from what's on screen: the album look's colours and the
/// (latency-delayed) beat. Reads the model ~30 times a second; the output decides how
/// much of that it can send (Hue streaming at 50 Hz, Hue REST at the bridge's limits,
/// Apple Home through the NeedledropHome helper at 2 a second).
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
    /// Apple Home, as the helper last reported it (nil until it has).
    private(set) var homeAuthorization: HomeAuthorization?
    private(set) var homeLights: [HomeLight] = []
    private(set) var homeRooms: [HomeRoom] = []
    /// The helper's state in words, shown while nothing is following.
    private(set) var homeStatus = "Starting…"

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var show = LightShow()
    @ObservationIgnored private var output: (any LightOutput)?
    /// The settings `output` was built for; a change rebuilds it.
    @ObservationIgnored private var connectedFor: Connection?
    @ObservationIgnored private var connecting = false
    @ObservationIgnored private var client: HueClient?
    @ObservationIgnored private var home: HomeLinkServer?
    /// When the helper link may be tried again after it failed.
    @ObservationIgnored private var homeRetry = Date.distantPast

    private enum Connection: Equatable {
        case hue(bridge: HueBridge, target: LightTarget)
        /// With the lights it means now, so a room gaining a light reconnects.
        case home(target: HomeTarget, lights: [String])
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
        if settings.provider == .homeKit {
            if home == nil, Date() >= homeRetry { startHome() }
        } else if home != nil {
            stopHome()
        }
        let wanted: Connection? = switch settings.provider {
        case .hue:
            if settings.enabled, let bridge = settings.bridge, let target = settings.target {
                .hue(bridge: bridge, target: target)
            } else {
                nil
            }
        case .homeKit:
            if settings.enabled, let target = settings.homeTarget, homeAuthorization == .authorized, home != nil {
                .home(target: target, lights: target.lights(in: homeRooms))
            } else {
                nil
            }
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
        let onError: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor in self?.failed(error) }
        }
        switch connection {
        case nil:
            status = model?.settings.lights.provider == .homeKit ? homeStatus : "Off"
        case .hue(let bridge, let target):
            await connectHue(bridge: bridge, target: target, onError: onError)
        case .home(let target, let lights):
            guard let home else { return }
            if lights.isEmpty {
                status = "“\(target.name)” has no colour lights in Apple Home now."
            } else {
                output = HomeLightOutput(sink: home, lights: lights)
                let count = lights.count == 1 ? "" : " (\(lights.count) lights)"
                status = "Following the album on “\(target.name)”\(count). Apple Home lights change colour about twice a second, without pulses."
            }
        }
        show = LightShow()
    }

    private func connectHue(bridge: HueBridge, target: LightTarget, onError: @escaping @Sendable (Error) -> Void) async {
        let connection = (bridge: bridge, target: target)
        guard let credentials = HueKeyStore.load(bridgeID: connection.bridge.id) else {
            status = "Not paired with this bridge"
            return
        }
        let client = client(for: connection.bridge, credentials: credentials)
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

    // MARK: - Apple Home (through the NeedledropHome helper)

    private static var helperURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Library/Helpers/NeedledropHome.app")
    }

    /// Starts listening and launches the helper, which connects and sends the catalog.
    private func startHome() {
        let url = Self.helperURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            homeUnavailable("This build doesn't include the HomeKit helper. Build with make app-signed.", retry: false)
            return
        }
        guard Self.hasHomeKitEntitlement(url) else {
            homeUnavailable("Apple Home needs a build signed with your developer team: make run-signed.", retry: false)
            return
        }
        let server = HomeLinkServer(
            onEvent: { [weak self] event in Task { @MainActor in self?.received(event) } },
            onDisconnect: { [weak self] in Task { @MainActor in self?.homeDisconnected() } })
        do {
            try server.start()
        } catch {
            homeUnavailable("Couldn't open the link to the HomeKit helper: \(error)", retry: true)
            return
        }
        home = server
        homeStatus = "Starting the HomeKit helper…"
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [HomeLink.socketArgument, server.socketPath]
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.stopHome()
                self?.homeUnavailable("Couldn't start the HomeKit helper: \(error.localizedDescription)", retry: true)
            }
        }
        // It connects within a moment, or not at all.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.home === server, self.homeAuthorization == nil else { return }
            self.stopHome()
            self.homeUnavailable("The HomeKit helper didn't answer.", retry: true)
        }
    }

    private func stopHome() {
        home?.stop()  // the helper quits when its link closes
        home = nil
        homeAuthorization = nil
        if case .home = connectedFor {
            output = nil
            connectedFor = nil
        }
    }

    private func homeUnavailable(_ message: String, retry: Bool) {
        homeStatus = message
        // Without a retry, wait for a provider switch (or relaunch); otherwise try again soon.
        homeRetry = retry ? Date().addingTimeInterval(15) : .distantFuture
        if model?.settings.lights.provider == .homeKit { status = message }
    }

    private func homeDisconnected() {
        guard home != nil else { return }
        stopHome()
        homeUnavailable("The HomeKit helper stopped. Trying again…", retry: true)
    }

    private func received(_ event: HomeEvent) {
        switch event {
        case .hello(let version) where version != HomeLink.version:
            stopHome()
            homeUnavailable("The HomeKit helper is from a different build. Rebuild Needledrop.", retry: false)
        case .hello:
            break
        case .catalog(let authorization, let lights, let rooms):
            homeAuthorization = authorization
            homeLights = lights
            homeRooms = rooms
            homeStatus = switch authorization {
            case .authorized: lights.isEmpty ? "No colour lights in Apple Home." : "Off"
            case .notDetermined: "Allow Needledrop Home to use your Home data when macOS asks."
            case .denied: "Needledrop Home isn't allowed to use Home data. Turn it on in System Settings › Privacy & Security › Home."
            case .restricted: "Home data is restricted on this Mac."
            }
            if output == nil { status = homeStatus }
        case .problem(let message):
            status = message
        }
    }

    /// Asks the helper for the lights again (Home changes are also sent unasked).
    func refreshHome() {
        home?.send(.list)
        if home == nil { homeRetry = .distantPast }
    }

    /// Unsigned builds (make app) carry a helper without HomeKit, which can't work.
    private static func hasHomeKitEntitlement(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements["com.apple.developer.homekit"] as? Bool == true
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
