import Foundation
import HomeKit
import HomeLink
import Network
import UIKit

// NeedledropHome: a windowless Mac Catalyst app inside Needledrop.app that holds the HomeKit
// permission (HMHomeManager isn't available to native Mac apps). Needledrop launches it with
// the path of a Unix socket; it connects, sends Needledrop the colour lights in Apple Home,
// and writes the colours it's sent. When Needledrop goes away, so does it.

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private var link: HelperLink?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: HomeLink.socketArgument), index + 1 < arguments.count else {
            // Opened by hand: there's nothing to do without Needledrop.
            exit(0)
        }
        link = HelperLink(socketPath: arguments[index + 1])
        return true
    }
}

/// UIKit insists on a scene. It gets no window, so nothing appears.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
}

@MainActor
final class HelperLink: NSObject, HMHomeManagerDelegate {
    private let connection: NWConnection
    private let manager = HMHomeManager()
    private var framer = LineFramer()
    private var ready = false
    /// Colour lightbulb services by id, rebuilt with each catalog.
    private var services: [String: HMService] = [:]
    /// What each light was last set to, so unchanged characteristics aren't rewritten.
    private var written: [String: HomeColor] = [:]
    private var writing = false
    private var pending: (lights: [String], color: HomeColor)?
    private var lastProblem: (message: String, at: Date)?

    init(socketPath: String) {
        connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        super.init()
        manager.delegate = self
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.connectionChanged(state) }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated {
                if self?.ready != true { exit(0) }
            }
        }
    }

    // MARK: - The link

    private func connectionChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            ready = true
            send(.hello(version: HomeLink.version))
            sendCatalog()
            receive()
        case .failed, .cancelled, .waiting:
            // Needledrop quit (or its socket is gone): nothing left to do.
            exit(0)
        default:
            break
        }
    }

    private func send(_ event: HomeEvent) {
        guard let data = try? HomeLink.encode(event) else { return }
        connection.send(content: data, completion: .idempotent)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data {
                    for line in self.framer.append(data) {
                        if let request = try? HomeLink.decode(HomeRequest.self, from: line) { self.handle(request) }
                    }
                }
                if complete || error != nil { exit(0) }
                self.receive()
            }
        }
    }

    private func handle(_ request: HomeRequest) {
        switch request {
        case .list:
            sendCatalog()
        case .set(let lights, let color):
            if writing {
                pending = (lights, color)
            } else {
                write(lights: lights, color: color)
            }
        }
    }

    // MARK: - HomeKit

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        MainActor.assumeIsolated { sendCatalog() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        MainActor.assumeIsolated { sendCatalog() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
        MainActor.assumeIsolated { sendCatalog() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) {
        MainActor.assumeIsolated { sendCatalog() }
    }

    private var authorization: HomeAuthorization {
        let status = manager.authorizationStatus
        if !status.contains(.determined) { return .notDetermined }
        if status.contains(.authorized) { return .authorized }
        if status.contains(.restricted) { return .restricted }
        return .denied
    }

    private func sendCatalog() {
        guard ready else { return }
        var lights: [HomeLight] = []
        var rooms: [String: HomeRoom] = [:]
        var found: [String: HMService] = [:]
        for home in manager.homes {
            for accessory in home.accessories {
                for service in accessory.services where Self.isColourLight(service) {
                    let id = service.uniqueIdentifier.uuidString
                    found[id] = service
                    let name = service.name.isEmpty ? accessory.name : service.name
                    lights.append(HomeLight(id: id, name: name, room: accessory.room?.name, home: home.name))
                    if let room = accessory.room {
                        let roomID = room.uniqueIdentifier.uuidString
                        rooms[roomID, default: HomeRoom(id: roomID, name: room.name, home: home.name, lights: [])].lights.append(id)
                    }
                }
            }
        }
        services = found
        written = written.filter { found[$0.key] != nil }
        send(.catalog(authorization: authorization,
                      lights: lights.sorted { ($0.home, $0.room ?? "", $0.name) < ($1.home, $1.room ?? "", $1.name) },
                      rooms: rooms.values.sorted { ($0.home, $0.name) < ($1.home, $1.name) }))
    }

    private static func isColourLight(_ service: HMService) -> Bool {
        guard service.serviceType == HMServiceTypeLightbulb else { return false }
        let types = Set(service.characteristics.map(\.characteristicType))
        return types.contains(HMCharacteristicTypeHue) && types.contains(HMCharacteristicTypeSaturation)
    }

    /// Writes only what changed for each light; all lights at once. A command that arrives
    /// meanwhile waits (only the newest), so a slow or unreachable light never queues up.
    private func write(lights: [String], color: HomeColor) {
        var writes: [(String, HMCharacteristic, Any)] = []
        for id in lights {
            guard let service = services[id] else { continue }
            let before = written[id]
            func characteristic(_ type: String) -> HMCharacteristic? {
                service.characteristics.first { $0.characteristicType == type }
            }
            if before?.on != color.on, let power = characteristic(HMCharacteristicTypePowerState) {
                writes.append((id, power, color.on))
            }
            if color.on {
                if before?.brightness != color.brightness || before?.on != true,
                   let brightness = characteristic(HMCharacteristicTypeBrightness) {
                    writes.append((id, brightness, color.brightness))
                }
                if before.map({ abs($0.hue - color.hue) >= 0.5 }) ?? true, let hue = characteristic(HMCharacteristicTypeHue) {
                    writes.append((id, hue, Float(color.hue)))
                }
                if before.map({ abs($0.saturation - color.saturation) >= 0.5 }) ?? true,
                   let saturation = characteristic(HMCharacteristicTypeSaturation) {
                    writes.append((id, saturation, Float(color.saturation)))
                }
            }
            written[id] = color
        }
        guard !writes.isEmpty else { return }
        writing = true
        let countdown = Countdown(writes.count)
        for (id, characteristic, value) in writes {
            characteristic.writeValue(value) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.written[id] = nil  // resend everything next time
                        self.problem("Couldn't set “\(self.services[id]?.name ?? "a light")”: \(error.localizedDescription)")
                    }
                    if countdown.tick() { self.finished() }
                }
            }
        }
    }

    private func finished() {
        writing = false
        if let next = pending {
            pending = nil
            write(lights: next.lights, color: next.color)
        }
    }

    /// The same problem at most every 30 s.
    private func problem(_ message: String) {
        if let last = lastProblem, last.message == message, Date().timeIntervalSince(last.at) < 30 { return }
        lastProblem = (message, Date())
        send(.problem(message))
    }
}

/// Counts writes down to the last one.
@MainActor
private final class Countdown {
    private var remaining: Int
    init(_ count: Int) { remaining = count }
    /// True on the last.
    func tick() -> Bool {
        remaining -= 1
        return remaining == 0
    }
}
