import Foundation

/// Small secrets (API keys, tokens, pairings) in files only this user can read, in
/// Needledrop's Application Support folder.
///
/// Not the keychain: macOS ties a keychain item to the exact build that saved it, and builds
/// that aren't signed with a developer identity change with every update — so each update
/// would ask for the login password before the app could read its own keys, freezing it
/// while the prompt waited.
public enum SecretStore {
    /// `~/Library/Application Support/Needledrop/Secrets` (0700; files 0600).
    public static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Needledrop/Secrets", isDirectory: true)
    }()

    public static func load(_ name: String) -> Data? {
        try? Data(contentsOf: file(name))
    }

    public static func loadString(_ name: String, environment variable: String? = nil) -> String? {
        if let data = load(name), let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        return variable.flatMap { ProcessInfo.processInfo.environment[$0] }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Saves `data`, or deletes the secret when it's nil or empty.
    @discardableResult
    public static func save(_ name: String, _ data: Data?) -> Bool {
        let url = file(name)
        guard let data, !data.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try data.write(to: url, options: [.atomic])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public static func saveString(_ name: String, _ value: String) -> Bool {
        save(name, Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    static func file(_ name: String) -> URL {
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }
        return directory.appendingPathComponent(String(safe))
    }
}
