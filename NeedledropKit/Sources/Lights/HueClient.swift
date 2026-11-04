import Foundation
import Security

/// Sends one HTTP request. The real one talks to the bridge; tests use a fake.
public protocol HueTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

/// Talks to one bridge: pairing, listing what it controls, setting lights, and
/// starting/stopping entertainment streaming (CLIP v2).
public struct HueClient: Sendable {
    public let bridge: HueBridge
    public var credentials: HueCredentials?
    private let transport: any HueTransport

    public init(bridge: HueBridge, credentials: HueCredentials? = nil, transport: (any HueTransport)? = nil) {
        self.bridge = bridge
        self.credentials = credentials
        self.transport = transport ?? BridgeTransport(bridgeID: bridge.id)
    }

    private var base: URL { URL(string: "https://\(bridge.host)")! }

    // MARK: - Pairing

    /// Asks the bridge for a key. Throws `.linkButtonNotPressed` until the user presses it.
    public func pair(deviceName: String = "needledrop#mac") async throws -> HueCredentials {
        var request = URLRequest(url: base.appendingPathComponent("api"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["devicetype": deviceName, "generateclientkey": true])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, status) = try await transport.send(request)
        guard status == 200 else { throw HueError.http(status, String(decoding: data, as: UTF8.self)) }
        guard let reply = try? JSONDecoder().decode([PairingResponse].self, from: data).first else {
            throw HueError.malformedResponse
        }
        if let success = reply.success { return HueCredentials(appKey: success.username, clientKey: success.clientkey) }
        if reply.error?.type == 101 { throw HueError.linkButtonNotPressed }
        throw HueError.bridge(reply.error?.description ?? "Pairing failed")
    }

    /// The bridge's id, from its unauthenticated config (for bridges entered by address).
    public static func bridgeID(host: String, transport: (any HueTransport)? = nil) async throws -> String {
        var request = URLRequest(url: URL(string: "https://\(host)/api/0/config")!)
        request.timeoutInterval = 5
        let (data, status) = try await (transport ?? BridgeTransport(bridgeID: nil)).send(request)
        guard status == 200, let config = try? JSONDecoder().decode(BridgeConfigDTO.self, from: data) else {
            throw HueError.malformedResponse
        }
        return config.bridgeid.lowercased()
    }

    // MARK: - Resources

    /// Lights, rooms and zones, and entertainment areas, areas first (they pulse best).
    public func resources() async throws -> [HueResource] {
        async let lights: [LightDTO] = list("light")
        async let rooms: [GroupDTO] = list("room")
        async let zones: [GroupDTO] = list("zone")
        async let areas: [EntertainmentConfigurationDTO] = list("entertainment_configuration")
        var result: [HueResource] = []
        for area in try await areas.sorted(by: { $0.metadata.name < $1.metadata.name }) {
            result.append(HueResource(target: .entertainment(id: area.id, name: area.metadata.name),
                                      channels: (area.channels ?? []).map(\.channel_id),
                                      lights: (area.light_services ?? []).filter { $0.rtype == "light" }.map(\.rid)))
        }
        for group in try await (rooms + zones).sorted(by: { $0.metadata.name < $1.metadata.name }) {
            guard let id = group.groupedLightID else { continue }
            result.append(HueResource(target: .group(groupedLightID: id, name: group.metadata.name)))
        }
        for light in try await lights.sorted(by: { $0.metadata.name < $1.metadata.name }) where light.color != nil {
            result.append(HueResource(target: .light(id: light.id, name: light.metadata.name), gamut: light.gamut))
        }
        return result
    }

    func list<Item: Decodable>(_ type: String) async throws -> [Item] {
        let (data, status) = try await transport.send(authorized("clip/v2/resource/\(type)", method: "GET"))
        try check(status, data)
        guard let envelope = try? JSONDecoder().decode(ResourceEnvelope<Item>.self, from: data) else {
            throw HueError.malformedResponse
        }
        if let error = envelope.errors.first { throw HueError.bridge(error.description) }
        return envelope.data
    }

    // MARK: - Control

    /// Sets a light or group's colour and brightness, fading over `transition` seconds.
    public func set(_ target: LightTarget, state: LightState, gamut: Gamut = .c, transition: Double) async throws {
        let path: String
        switch target {
        case .light(let id, _): path = "clip/v2/resource/light/\(id)"
        case .group(let id, _): path = "clip/v2/resource/grouped_light/\(id)"
        case .entertainment: return
        }
        let body = Self.body(for: state, gamut: gamut, transition: transition, group: { if case .group = target { true } else { false } }())
        var request = try authorized(path, method: "PUT")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status) = try await transport.send(request)
        try check(status, data)
    }

    /// The CLIP v2 body for a state. Groups take no colour gamut and no duration below 0.1 s.
    static func body(for state: LightState, gamut: Gamut, transition: Double, group: Bool) -> [String: Any] {
        let xy = HueColor.xy(state.color, gamut: gamut)
        let on = state.brightness > 0.004
        var body: [String: Any] = ["on": ["on": on]]
        if on {
            // Brightness is a percentage; below ~1 % many lights switch off.
            body["dimming"] = ["brightness": max(1, min(100, (state.brightness * 100 * 100).rounded() / 100))]
            body["color"] = ["xy": ["x": (xy.x * 10000).rounded() / 10000, "y": (xy.y * 10000).rounded() / 10000]]
        }
        body["dynamics"] = ["duration": Int(max(0, transition) * 1000)]
        return body
    }

    /// Starts (or stops) streaming to an entertainment area. Only one app streams at a time.
    public func setStreaming(_ on: Bool, area id: String) async throws {
        var request = try authorized("clip/v2/resource/entertainment_configuration/\(id)", method: "PUT")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": on ? "start" : "stop"])
        let (data, status) = try await transport.send(request)
        try check(status, data)
    }

    private func authorized(_ path: String, method: String) throws -> URLRequest {
        guard let key = credentials?.appKey else { throw HueError.unauthorized }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 5
        request.setValue(key, forHTTPHeaderField: "hue-application-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func check(_ status: Int, _ data: Data) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw HueError.unauthorized
        default:
            if let envelope = try? JSONDecoder().decode(ResourceEnvelope<EmptyDTO>.self, from: data),
               let error = envelope.errors.first {
                throw HueError.bridge(error.description)
            }
            throw HueError.http(status, String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    private struct EmptyDTO: Decodable {}
}

/// HTTPS to the bridge. Its certificate is self-signed (by Signify) and issued to the
/// bridge id, so trust is checked against that name instead of the system roots.
final class BridgeTransport: NSObject, HueTransport, URLSessionDelegate {
    private let bridgeID: String?
    private let session: URLSessionBox

    init(bridgeID: String?) {
        self.bridgeID = bridgeID?.lowercased()
        let box = URLSessionBox()
        session = box
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        box.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard let session = session.session else { throw HueError.malformedResponse }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        if let bridgeID {
            // Pinned to the bridge we paired with: its certificate's common name is its id.
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
                return (.cancelAuthenticationChallenge, nil)
            }
            var name: CFString?
            SecCertificateCopyCommonName(leaf, &name)
            guard (name as String?)?.lowercased() == bridgeID else { return (.cancelAuthenticationChallenge, nil) }
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// URLSession retains its delegate; the box breaks the init-order knot without a cycle leak
/// mattering (one transport per paired bridge, kept for the app's life).
private final class URLSessionBox: @unchecked Sendable {
    var session: URLSession?
}

extension BridgeTransport: @unchecked Sendable {}
