import Foundation
import HomeLink
import Network
import Synchronization
import Visuals

/// What the lights follow in Apple Home: one colour light, or every colour light in a room.
public enum HomeTarget: Sendable, Hashable, Codable {
    case light(id: String, name: String)
    case room(id: String, name: String)

    public var name: String {
        switch self {
        case .light(_, let name), .room(_, let name): name
        }
    }

    /// The light ids this target means in `catalog`'s rooms (a room's lights can change).
    public func lights(in rooms: [HomeRoom]) -> [String] {
        switch self {
        case .light(let id, _): [id]
        case .room(let id, _): rooms.first { $0.id == id }?.lights ?? []
        }
    }
}

extension HomeColor {
    /// HomeKit takes hue and saturation (HSV) and a separate brightness percentage.
    public init(_ state: LightState) {
        let r = Double(max(0, min(1, state.color.r)))
        let g = Double(max(0, min(1, state.color.g)))
        let b = Double(max(0, min(1, state.color.b)))
        let high = max(r, g, b), low = min(r, g, b), span = high - low
        var hue = 0.0
        if span > 1e-6 {
            if high == r {
                hue = 60 * ((g - b) / span).truncatingRemainder(dividingBy: 6)
            } else if high == g {
                hue = 60 * ((b - r) / span + 2)
            } else {
                hue = 60 * ((r - g) / span + 4)
            }
            if hue < 0 { hue += 360 }
        }
        let saturation = high > 1e-6 ? span / high * 100 : 0
        let percent = Int((max(0, min(1, state.brightness)) * 100).rounded())
        let on = state.brightness >= 0.005
        self.init(hue: hue, saturation: saturation, brightness: on ? max(1, percent) : 0, on: on)
    }

    /// Below what anyone would see from a HomeKit light (they take whole percents).
    func close(to other: HomeColor) -> Bool {
        guard on == other.on else { return false }
        guard on else { return true }
        let dh = abs(hue - other.hue), hueGap = min(dh, 360 - dh)
        // Hue barely matters when the colour is nearly white.
        let hueMatters = max(saturation, other.saturation) > 8
        return brightness == other.brightness && abs(saturation - other.saturation) < 1.5
            && (!hueMatters || hueGap < 1.5)
    }
}

/// Something that takes HomeKit colour commands (the helper link, or a fake).
public protocol HomeCommandSink: Sendable {
    func set(lights: [String], color: HomeColor)
}

/// HomeKit through the helper: colour only, a couple of updates a second. HomeKit has no
/// fade time, and each light needs a write per characteristic, so faster only queues up.
/// Unchanged states aren't resent.
public final class HomeLightOutput: LightOutput {
    public static let rate = 2.0
    public let pulses = false
    private let sink: any HomeCommandSink
    private let lights: [String]
    private let state: Mutex<State>

    private struct State {
        var limiter = RateLimiter(rate: HomeLightOutput.rate)
        var last: HomeColor?
        var closed = false
    }

    public init(sink: any HomeCommandSink, lights: [String]) {
        self.sink = sink
        self.lights = lights
        state = Mutex(State())
    }

    public func send(_ light: LightState, now: Double) {
        guard !lights.isEmpty else { return }
        let color = HomeColor(light)
        let go = state.withLock { s in
            guard !s.closed else { return false }
            if let last = s.last, last.close(to: color) { return false }
            guard s.limiter.tryAcquire(now: now) else { return false }
            s.last = color
            return true
        }
        if go { sink.set(lights: lights, color: color) }
    }

    public func close() async {
        state.withLock { $0.closed = true }
    }
}

// MARK: - The link to the helper

/// Needledrop's end of the link: listens on a Unix socket for the helper (one at a time;
/// a newer connection replaces the old) and passes its events on.
public final class HomeLinkServer: HomeCommandSink, @unchecked Sendable {  // listener and connection live on `queue`
    public let socketPath: String
    private let queue = DispatchQueue(label: "needledrop.homelink")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var framer = LineFramer()
    private let onEvent: @Sendable (HomeEvent) -> Void
    private let onDisconnect: @Sendable () -> Void

    public init(socketPath: String = HomeLinkServer.defaultSocketPath(),
                onEvent: @escaping @Sendable (HomeEvent) -> Void,
                onDisconnect: @escaping @Sendable () -> Void = {}) {
        self.socketPath = socketPath
        self.onEvent = onEvent
        self.onDisconnect = onDisconnect
    }

    /// Short enough for `sun_path` (104 bytes) and private to this user.
    public static func defaultSocketPath() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("needledrop-home-\(getpid()).sock")
    }

    public func start() throws {
        unlink(socketPath)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socketPath)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        queue.sync { self.listener = listener }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            connection?.cancel()
            connection = nil
        }
        unlink(socketPath)
    }

    public var connected: Bool { queue.sync { connection != nil } }

    public func send(_ request: HomeRequest) {
        guard let data = try? HomeLink.encode(request) else { return }
        queue.async { self.connection?.send(content: data, completion: .idempotent) }
    }

    public func set(lights: [String], color: HomeColor) {
        send(.set(lights: lights, color: color))
    }

    private func accept(_ new: NWConnection) {
        connection?.cancel()
        connection = new
        framer = LineFramer()
        new.stateUpdateHandler = { [weak self, weak new] state in
            guard let self, let new else { return }
            switch state {
            case .failed, .cancelled:
                if self.connection === new {
                    self.connection = nil
                    self.onDisconnect()
                }
            default:
                break
            }
        }
        new.start(queue: queue)
        receive(on: new)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, self.connection === connection else { return }
            if let data {
                for line in self.framer.append(data) {
                    if let event = try? HomeLink.decode(HomeEvent.self, from: line) { self.onEvent(event) }
                }
            }
            if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection)
            }
        }
    }
}
