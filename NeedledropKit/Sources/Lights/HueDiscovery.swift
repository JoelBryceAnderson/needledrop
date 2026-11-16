import Foundation
import Network
import Secrets

/// Finds bridges: Signify's discovery service (needs the internet) and Bonjour
/// (`_hue._tcp` on the local network) at the same time, merged by bridge id.
public enum HueDiscovery {
    public static func discover(timeout: Duration = .seconds(4)) async -> [HueBridge] {
        async let cloud = cloudBridges()
        async let local = bonjourBridges(timeout: timeout)
        var found: [String: HueBridge] = [:]
        for bridge in await cloud { found[bridge.id] = bridge }
        for bridge in await local { found[bridge.id] = bridge }  // the local answer is fresher
        return found.values.sorted { $0.id < $1.id }
    }

    static func cloudBridges() async -> [HueBridge] {
        var request = URLRequest(url: URL(string: "https://discovery.meethue.com")!)
        request.timeoutInterval = 4
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parseCloud(data)
    }

    static func parseCloud(_ data: Data) -> [HueBridge] {
        let entries = (try? JSONDecoder().decode([DiscoveryDTO].self, from: data)) ?? []
        return entries.map { HueBridge(id: $0.id, host: $0.internalipaddress) }
    }

    /// Browses for `_hue._tcp`, then connects to each service briefly to learn its address.
    static func bonjourBridges(timeout: Duration) async -> [HueBridge] {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_hue._tcp", domain: nil), using: .tcp)
        let results = ResultBox()
        browser.browseResultsChangedHandler = { all, _ in results.set(Array(all)) }
        browser.start(queue: .global(qos: .utility))
        try? await Task.sleep(for: timeout)
        browser.cancel()

        var bridges: [HueBridge] = []
        await withTaskGroup(of: HueBridge?.self) { group in
            for result in results.get() {
                group.addTask { await resolve(result) }
            }
            for await bridge in group {
                if let bridge { bridges.append(bridge) }
            }
        }
        return bridges
    }

    private static func resolve(_ result: NWBrowser.Result) async -> HueBridge? {
        var bridgeID: String?
        if case .bonjour(let txt) = result.metadata { bridgeID = txt["bridgeid"] }
        guard let host = await address(of: result.endpoint) else { return nil }
        if let bridgeID { return HueBridge(id: bridgeID, host: host) }
        guard let id = try? await HueClient.bridgeID(host: host) else { return nil }
        return HueBridge(id: id, host: host)
    }

    /// The IP address behind a Bonjour service.
    private static func address(of endpoint: NWEndpoint) async -> String? {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let resolved = ResolveOnce()
        return await withCheckedContinuation { continuation in
            resolved.continuation = continuation
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var host: String?
                    if case .hostPort(let h, _) = connection.currentPath?.remoteEndpoint {
                        switch h {
                        case .ipv4(let a): host = "\(a)"
                        case .ipv6(let a): host = "[\("\(a)".split(separator: "%").first ?? "")]"
                        case .name(let n, _): host = n
                        @unknown default: host = nil
                        }
                    }
                    resolved.finish(host)
                    connection.cancel()
                case .failed, .cancelled:
                    resolved.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                resolved.finish(nil)
                connection.cancel()
            }
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [NWBrowser.Result] = []
        func set(_ r: [NWBrowser.Result]) { lock.withLock { results = r } }
        func get() -> [NWBrowser.Result] { lock.withLock { results } }
    }

    private final class ResolveOnce: @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<String?, Never>?
        func finish(_ value: String?) {
            let c: CheckedContinuation<String?, Never>? = lock.withLock {
                let c = continuation
                continuation = nil
                return c
            }
            c?.resume(returning: value)
        }
    }
}

/// Pairings, one file per bridge holding its app and client keys, readable only by this
/// user (see `SecretStore`).
public enum HueKeyStore {
    static func name(_ bridgeID: String) -> String { "hue-\(bridgeID.lowercased())" }

    public static func load(bridgeID: String) -> HueCredentials? {
        SecretStore.load(name(bridgeID)).flatMap { try? JSONDecoder().decode(HueCredentials.self, from: $0) }
    }

    /// Saves (or, with nil, deletes) a bridge's keys.
    @discardableResult
    public static func save(_ credentials: HueCredentials?, bridgeID: String) -> Bool {
        SecretStore.save(name(bridgeID), credentials.flatMap { try? JSONEncoder().encode($0) })
    }
}
