import Foundation

// What Needledrop and its HomeKit helper say to each other.
//
// HomeKit's `HMHomeManager` is Mac Catalyst only, so a small Catalyst app inside
// Needledrop.app (NeedledropHome) holds the HomeKit permission and does the writes.
// Needledrop listens on a Unix socket, launches the helper with the socket's path, and
// the two exchange newline-delimited JSON. This file is Foundation-only so both build it.

public enum HomeLink {
    /// Bumped when either side's messages change shape.
    public static let version = 1
    /// The helper's launch argument that precedes the socket path.
    public static let socketArgument = "--needledrop-socket"

    /// One message as a line of JSON.
    public static func encode<Message: Encodable>(_ message: Message) throws -> Data {
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        return data
    }

    public static func decode<Message: Decodable>(_ type: Message.Type, from line: Data) throws -> Message {
        try JSONDecoder().decode(type, from: line)
    }
}

/// Splits a byte stream into lines. Partial lines wait for the rest.
public struct LineFramer: Sendable {
    private var buffer = Data()
    /// A line longer than this is dropped (the other side is confused, not chatty).
    public static let maxLine = 1 << 20

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        if buffer.count > Self.maxLine { buffer = Data() }
        return lines
    }
}

/// A colour light in Apple Home (a lightbulb service with hue and saturation).
public struct HomeLight: Sendable, Hashable, Codable, Identifiable {
    /// The service's `uniqueIdentifier`.
    public var id: String
    public var name: String
    public var room: String?
    public var home: String

    public init(id: String, name: String, room: String?, home: String) {
        self.id = id
        self.name = name
        self.room = room
        self.home = home
    }
}

/// A room with at least one colour light.
public struct HomeRoom: Sendable, Hashable, Codable, Identifiable {
    /// The room's `uniqueIdentifier`.
    public var id: String
    public var name: String
    public var home: String
    /// Its colour lights' ids.
    public var lights: [String]

    public init(id: String, name: String, home: String, lights: [String]) {
        self.id = id
        self.name = name
        self.home = home
        self.lights = lights
    }
}

/// Whether the helper may use HomeKit.
public enum HomeAuthorization: String, Sendable, Codable {
    case notDetermined, authorized, restricted, denied
}

/// A light state in HomeKit's own units.
public struct HomeColor: Sendable, Hashable, Codable {
    /// Degrees, 0..<360.
    public var hue: Double
    /// Percent, 0…100.
    public var saturation: Double
    /// Percent, 1…100 when on.
    public var brightness: Int
    public var on: Bool

    public init(hue: Double, saturation: Double, brightness: Int, on: Bool) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
        self.on = on
    }
}

/// Needledrop → helper.
public enum HomeRequest: Sendable, Equatable, Codable {
    /// Send the catalog (it's also sent unasked whenever Home changes).
    case list
    /// Set these lights. The helper drops a command that arrives while it's still writing
    /// the last one, except the newest, which it writes next.
    case set(lights: [String], color: HomeColor)
}

/// Helper → Needledrop.
public enum HomeEvent: Sendable, Equatable, Codable {
    case hello(version: Int)
    case catalog(authorization: HomeAuthorization, lights: [HomeLight], rooms: [HomeRoom])
    /// A write or HomeKit problem, in words for Settings.
    case problem(String)
}
