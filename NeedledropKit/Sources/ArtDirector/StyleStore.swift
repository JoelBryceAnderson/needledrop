import CryptoKit
import Foundation
import Secrets

/// Every direction Claude has given each album, which one is current, and whether it's
/// pinned (a pinned look survives re-rolls). On disk, one JSON file per album.
public actor StyleStore {
    public struct Record: Codable, Sendable, Equatable {
        public var spec: StyleSpec
        public var model: String
        public var created: Date
    }

    private struct Entry: Codable {
        var history: [Record] = []
        var current = 0
        var pinned = false
    }

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func current(for key: String) -> StyleSpec? {
        let entry = read(key)
        return entry.history.indices.contains(entry.current) ? entry.history[entry.current].spec : nil
    }

    public func history(for key: String) -> [StyleSpec] { read(key).history.map(\.spec) }

    public func isPinned(_ key: String) -> Bool { read(key).pinned }

    public func setPinned(_ pinned: Bool, for key: String) {
        var entry = read(key)
        guard !entry.history.isEmpty else { return }
        entry.pinned = pinned
        write(entry, key)
    }

    public func add(_ spec: StyleSpec, for key: String, model: String) {
        var entry = read(key)
        entry.history.append(Record(spec: spec, model: model, created: Date()))
        entry.current = entry.history.count - 1
        write(entry, key)
    }

    private func file(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash).json")
    }

    private func read(_ key: String) -> Entry {
        (try? Data(contentsOf: file(key))).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) } ?? Entry()
    }

    private func write(_ entry: Entry, _ key: String) {
        try? JSONEncoder().encode(entry).write(to: file(key), options: .atomic)
    }
}

/// The Anthropic API key, in a file only this user can read (see `SecretStore`).
public enum APIKeyStore {
    static let name = "anthropic-api-key"

    /// The saved key, else `ANTHROPIC_API_KEY` from the environment (handy in development).
    public static func load() -> String? {
        SecretStore.loadString(name, environment: "ANTHROPIC_API_KEY")
    }

    /// Saves (or, with an empty string, deletes) the key.
    @discardableResult
    public static func save(_ key: String) -> Bool {
        SecretStore.saveString(name, key)
    }
}
