import Foundation

/// A bridge on the local network.
public struct HueBridge: Sendable, Hashable, Codable, Identifiable {
    /// The bridge id (16 hex digits), lowercased. Its certificate is issued to this name.
    public var id: String
    /// IP address or host name.
    public var host: String

    public init(id: String, host: String) {
        self.id = id.lowercased()
        self.host = host
    }
}

/// What pairing returns: the app key for REST calls and the client key for streaming.
public struct HueCredentials: Sendable, Equatable, Codable {
    /// `hue-application-key`; also the PSK identity for streaming.
    public var appKey: String
    /// 32 hex digits: the PSK for entertainment streaming.
    public var clientKey: String?

    public init(appKey: String, clientKey: String?) {
        self.appKey = appKey
        self.clientKey = clientKey
    }

    /// The PSK bytes, or nil if the client key is missing or malformed.
    public var psk: Data? {
        guard let key = clientKey, key.count % 2 == 0, !key.isEmpty else { return nil }
        var bytes = Data(capacity: key.count / 2)
        var index = key.startIndex
        while index < key.endIndex {
            let next = key.index(index, offsetBy: 2)
            guard let byte = UInt8(key[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

/// What the lights follow: one light, a room or zone, or an entertainment area.
public enum LightTarget: Sendable, Hashable, Codable {
    /// A light resource (REST, about 10 updates a second).
    case light(id: String, name: String)
    /// A room or zone's grouped_light (REST, about 1 update a second: colour only).
    case group(groupedLightID: String, name: String)
    /// An entertainment configuration (DTLS streaming: fast pulses).
    case entertainment(id: String, name: String)

    public var name: String {
        switch self {
        case .light(_, let name), .group(_, let name), .entertainment(_, let name): name
        }
    }
}

/// A light, group or area the bridge offers, for the picker.
public struct HueResource: Sendable, Hashable, Identifiable {
    public var target: LightTarget
    /// Lights only: the colours it can make.
    public var gamut: Gamut?
    /// Areas only: how many channels (segments) it streams.
    public var channels: [Int]
    /// Areas only: their lights, for driving them over REST when streaming isn't possible.
    public var lights: [String]

    public var id: LightTarget { target }

    public init(target: LightTarget, gamut: Gamut? = nil, channels: [Int] = [], lights: [String] = []) {
        self.target = target
        self.gamut = gamut
        self.channels = channels
        self.lights = lights
    }
}

public enum HueError: Error, Equatable, CustomStringConvertible {
    /// Pairing: the round button on the bridge hasn't been pressed in the last 30 s.
    case linkButtonNotPressed
    case unauthorized
    case http(Int, String)
    case bridge(String)
    case malformedResponse
    case noClientKey
    case streaming(String)

    public var description: String {
        switch self {
        case .linkButtonNotPressed: "Press the round link button on the bridge, then try again within 30 seconds."
        case .unauthorized: "The bridge no longer accepts Needledrop's key. Pair again."
        case .http(let code, let body): "The bridge answered \(code)\(body.isEmpty ? "" : ": \(body)")"
        case .bridge(let message): message
        case .malformedResponse: "The bridge sent something Needledrop couldn't read."
        case .noClientKey: "This pairing has no streaming key. Pair again to enable fast pulses."
        case .streaming(let message): "Streaming: \(message)"
        }
    }
}

// MARK: - CLIP v2 wire formats (only the fields Needledrop uses)

struct ResourceEnvelope<Item: Decodable>: Decodable {
    var errors: [ResourceError]
    var data: [Item]

    struct ResourceError: Decodable { var description: String }
}

struct LightDTO: Decodable {
    struct Metadata: Decodable { var name: String }
    struct Color: Decodable {
        struct GamutDTO: Decodable {
            struct Point: Decodable { var x: Double; var y: Double }
            var red: Point
            var green: Point
            var blue: Point
        }
        var gamut: GamutDTO?
        var gamut_type: String?
    }
    var id: String
    var metadata: Metadata
    var color: Color?

    var gamut: Gamut? {
        guard let color else { return nil }
        if let g = color.gamut {
            return Gamut(red: XY(g.red.x, g.red.y), green: XY(g.green.x, g.green.y), blue: XY(g.blue.x, g.blue.y))
        }
        return Gamut.named(color.gamut_type)
    }
}

/// Rooms and zones.
struct GroupDTO: Decodable {
    struct Metadata: Decodable { var name: String }
    struct Service: Decodable { var rid: String; var rtype: String }
    var id: String
    var metadata: Metadata
    var services: [Service]

    var groupedLightID: String? { services.first { $0.rtype == "grouped_light" }?.rid }
}

struct EntertainmentConfigurationDTO: Decodable {
    struct Metadata: Decodable { var name: String }
    struct Channel: Decodable { var channel_id: Int }
    struct Service: Decodable { var rid: String; var rtype: String }
    var id: String
    var metadata: Metadata
    var channels: [Channel]?
    var light_services: [Service]?
    var status: String?
}

struct DiscoveryDTO: Decodable {
    var id: String
    var internalipaddress: String
}

struct PairingResponse: Decodable {
    struct Success: Decodable { var username: String; var clientkey: String? }
    struct Failure: Decodable { var type: Int; var description: String }
    var success: Success?
    var error: Failure?
}

struct BridgeConfigDTO: Decodable {
    var bridgeid: String
    var name: String?
}
