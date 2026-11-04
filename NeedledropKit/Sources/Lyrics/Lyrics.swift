import Foundation

public struct LyricLine: Sendable, Equatable, Codable {
    /// Track position (seconds) where the line starts.
    public var time: Double
    /// Empty for an instrumental break.
    public var text: String

    public init(time: Double, text: String) {
        self.time = time
        self.text = text
    }
}

/// The line to show at a moment, with its timing.
public struct LyricCue: Sendable, Equatable {
    public var index: Int
    public var text: String
    public var start: Double
    public var end: Double
    public var next: String?
}

public struct Lyrics: Sendable, Equatable, Codable {
    /// Time-synced lines, sorted. Empty if only plain lyrics exist.
    public var lines: [LyricLine]
    public var plain: String?
    public var instrumental: Bool

    public init(lines: [LyricLine] = [], plain: String? = nil, instrumental: Bool = false) {
        self.lines = lines.sorted { $0.time < $1.time }
        self.plain = plain
        self.instrumental = instrumental
    }

    public var isSynced: Bool { !lines.isEmpty }

    /// A line stays up until the next one starts, but no more than this long — so a
    /// line before a long solo doesn't hang around through it.
    public static let maximumLineDuration = 8.0

    /// The line sounding at track `position`, or nil before the first line, during an
    /// instrumental break, or after the last line has had its time.
    public func cue(at position: Double) -> LyricCue? {
        guard let index = lines.lastIndex(where: { $0.time <= position }) else { return nil }
        let line = lines[index]
        let nextLine = index + 1 < lines.count ? lines[index + 1] : nil
        let end = min(nextLine?.time ?? .infinity, line.time + Self.maximumLineDuration)
        guard !line.text.isEmpty, position < end else { return nil }
        let upcoming = lines[(index + 1)...].first { !$0.text.isEmpty }?.text
        return LyricCue(index: index, text: line.text, start: line.time, end: end, next: upcoming)
    }
}

/// Parses LRC: `[mm:ss.xx]text`, several stamps per line, `[offset:±ms]`, enhanced-LRC
/// word stamps (`<mm:ss.xx>`, stripped for now), and metadata tags (ignored).
public enum LRCParser {
    public static func parse(_ source: String) -> [LyricLine] {
        var offset = 0.0
        var lines: [LyricLine] = []
        for raw in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = Substring(raw).trimmingCharacters(in: .whitespaces)[...]
            var stamps: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let t = timestamp(tag) {
                    stamps.append(t)
                } else if tag.lowercased().hasPrefix("offset:"), let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    // Positive offset makes lyrics appear sooner.
                    offset = ms / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            guard !stamps.isEmpty else { continue }
            let text = stripWordStamps(String(rest)).trimmingCharacters(in: .whitespaces)
            lines += stamps.map { LyricLine(time: $0, text: text) }
        }
        return lines
            .map { LyricLine(time: max(0, $0.time - offset), text: $0.text) }
            .sorted { $0.time < $1.time }
    }

    /// `mm:ss`, `mm:ss.x`, `mm:ss.xx`, `mm:ss.xxx` (also `:` before the fraction).
    static func timestamp(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let minutes = Int(parts[0]), minutes >= 0 else { return nil }
        let secondsText = parts[1].replacingOccurrences(of: ":", with: ".")
        guard let seconds = Double(secondsText), seconds >= 0, seconds < 60,
              secondsText.first?.isNumber == true else { return nil }
        return Double(minutes) * 60 + seconds
    }

    private static func stripWordStamps(_ s: String) -> String {
        s.replacingOccurrences(of: #"<\d+:\d+(?:[.:]\d+)?>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }
}
