import Foundation
import Network
import Synchronization

/// Where light states go: streamed to an entertainment area, or sent over REST.
public protocol LightOutput: AnyObject, Sendable {
    /// Fast enough for beat pulses.
    var pulses: Bool { get }
    /// The latest state; outputs send as often as they're allowed and drop the rest.
    func send(_ state: LightState, now: Double)
    func close() async
}

/// Something that accepts REST light commands (the bridge client, or a fake).
public protocol LightCommandSink: Sendable {
    func set(_ target: LightTarget, state: LightState, gamut: Gamut, transition: Double) async throws
}

extension HueClient: LightCommandSink {}

/// REST (CLIP v2) at the bridge's limits: about 10 light commands a second in all, and
/// one a second for a room or zone. Several lights (an area that can't stream) share the
/// budget in turn. Each command fades over the time until the next, so it reads as smooth.
public final class RESTLightOutput: LightOutput {
    public static let lightRate = 10.0
    public static let groupRate = 1.0

    public let pulses: Bool
    private let sink: any LightCommandSink
    private let targets: [(target: LightTarget, gamut: Gamut)]
    private let rate: Double
    private let state: Mutex<State>
    private let onError: @Sendable (Error) -> Void

    private struct State {
        var limiter: RateLimiter
        var inFlight = false
        var next = 0
        var lastSent: [LightState?]
        var closed = false
    }

    public init(sink: any LightCommandSink, targets: [(target: LightTarget, gamut: Gamut)],
                onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.sink = sink
        self.targets = targets
        let group = targets.contains { if case .group = $0.target { true } else { false } }
        rate = group ? Self.groupRate : Self.lightRate
        // Pulses need each light updated several times a beat.
        pulses = !group && Self.lightRate / Double(max(1, targets.count)) >= 5
        state = Mutex(State(limiter: RateLimiter(rate: rate), lastSent: Array(repeating: nil, count: targets.count)))
        self.onError = onError
    }

    public func send(_ light: LightState, now: Double) {
        guard !targets.isEmpty else { return }
        let job: (index: Int, transition: Double)? = state.withLock { s in
            guard !s.closed, !s.inFlight else { return nil }
            let index = s.next % targets.count
            // Nothing visible changed for this light: don't spend a command on it.
            if let last = s.lastSent[index], Self.close(last, light) { return nil }
            guard s.limiter.tryAcquire(now: now) else { return nil }
            s.inFlight = true
            s.next = index + 1
            s.lastSent[index] = light
            return (index, Double(targets.count) / rate)
        }
        guard let job else { return }
        let target = targets[job.index]
        Task {
            do {
                try await self.sink.set(target.target, state: light, gamut: target.gamut, transition: job.transition)
            } catch {
                self.state.withLock { $0.lastSent[job.index] = nil }
                self.onError(error)
            }
            self.state.withLock { $0.inFlight = false }
        }
    }

    public func close() async {
        state.withLock { $0.closed = true }
    }

    /// Below what anyone would see: 0.5 % brightness and a hair of chromaticity.
    static func close(_ a: LightState, _ b: LightState) -> Bool {
        let xa = HueColor.xy(a.color), xb = HueColor.xy(b.color)
        return abs(a.brightness - b.brightness) < 0.005 && abs(xa.x - xb.x) < 0.002 && abs(xa.y - xb.y) < 0.002
    }
}

// MARK: - Entertainment streaming

/// The HueStream v2 datagram: header, area id, then x/y/brightness for each channel.
public enum HueStreamMessage {
    public static func encode(areaID: String, sequence: UInt8, channels: [(id: Int, state: LightState)]) -> Data {
        var data = Data("HueStream".utf8)
        data.append(contentsOf: [0x02, 0x00, sequence, 0x00, 0x00, 0x01 /* xy + brightness */, 0x00])
        var id = Data(areaID.utf8.prefix(36))
        if id.count < 36 { id.append(Data(repeating: 0x30, count: 36 - id.count)) }
        data.append(id)
        for channel in channels.prefix(20) {
            let xy = HueColor.xy(channel.state.color)
            data.append(UInt8(clamping: channel.id))
            for value in [xy.x, xy.y, channel.state.brightness] {
                let v = UInt16(max(0, min(1, value)) * 65535)
                data.append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)])
            }
        }
        return data
    }
}

/// Streams to an entertainment area over DTLS 1.2 (UDP 2100, PSK = the client key,
/// identity = the app key), resending the latest state at 50 Hz. The bridge drops the
/// stream after 10 s of silence, so it keeps sending even when nothing changes.
public final class EntertainmentOutput: LightOutput, @unchecked Sendable {  // NWConnection and the timer live on `queue`
    public let pulses = true
    private let client: HueClient
    private let areaID: String
    private let channels: [Int]
    private let queue = DispatchQueue(label: "needledrop.lights.stream", qos: .userInteractive)
    private let latest = Mutex<LightState?>(nil)
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var sequence: UInt8 = 0
    private let onError: @Sendable (Error) -> Void

    private init(client: HueClient, areaID: String, channels: [Int], onError: @escaping @Sendable (Error) -> Void) {
        self.client = client
        self.areaID = areaID
        self.channels = channels.isEmpty ? [0] : channels
        self.onError = onError
    }

    /// Asks the bridge to start the area, then completes the DTLS handshake. Throws if
    /// either fails (another app is streaming, no client key, the area is gone…).
    public static func start(client: HueClient, areaID: String, channels: [Int],
                             onError: @escaping @Sendable (Error) -> Void = { _ in }) async throws -> EntertainmentOutput {
        guard let credentials = client.credentials else { throw HueError.unauthorized }
        guard let psk = credentials.psk else { throw HueError.noClientKey }
        try await client.setStreaming(true, area: areaID)
        let output = EntertainmentOutput(client: client, areaID: areaID, channels: channels, onError: onError)
        do {
            try await output.connect(psk: psk, identity: Data(credentials.appKey.utf8))
        } catch {
            try? await client.setStreaming(false, area: areaID)
            throw error
        }
        return output
    }

    private func connect(psk: Data, identity: Data) async throws {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .DTLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .DTLSv12)
        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, pskData as __DispatchData, identityData as __DispatchData)
        // TLS_PSK_WITH_AES_128_GCM_SHA256, the only suite the bridge offers.
        if let suite = tls_ciphersuite_t(rawValue: 0x00A8) {
            sec_protocol_options_append_tls_ciphersuite(options, suite)
        }
        let parameters = NWParameters(dtls: tls, udp: NWProtocolUDP.Options())
        let connection = NWConnection(host: NWEndpoint.Host(client.bridge.host), port: 2100, using: parameters)
        self.connection = connection

        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            once.continuation = continuation
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    once.finish(nil)
                case .failed(let error):
                    once.finish(HueError.streaming(error.localizedDescription))
                    self?.onError(HueError.streaming(error.localizedDescription))
                case .waiting(let error):
                    once.finish(HueError.streaming(error.localizedDescription))
                case .cancelled:
                    once.finish(HueError.streaming("cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { once.finish(HueError.streaming("the bridge didn't answer the handshake")) }
        }
        queue.sync { startTimer() }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard let connection, let state = latest.withLock({ $0 }) else { return }
        sequence &+= 1
        let message = HueStreamMessage.encode(areaID: areaID, sequence: sequence,
                                              channels: channels.map { ($0, state) })
        connection.send(content: message, completion: .idempotent)
    }

    public func send(_ state: LightState, now: Double) {
        latest.withLock { $0 = state }
    }

    public func close() async {
        queue.sync {
            timer?.cancel()
            timer = nil
            connection?.cancel()
            connection = nil
        }
        try? await client.setStreaming(false, area: areaID)
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<Void, Error>?
        func finish(_ error: Error?) {
            let c: CheckedContinuation<Void, Error>? = lock.withLock {
                let c = continuation
                continuation = nil
                return c
            }
            if let error { c?.resume(throwing: error) } else { c?.resume() }
        }
    }
}
