import Foundation

/// A track's timed lyrics as the visuals plan with them: each line's start, how long it's
/// printed, and its words. The app builds this from the synced lyrics.
public struct LyricTimeline: Sendable, Equatable, Codable {
    public struct Line: Sendable, Equatable, Codable {
        /// The line's index in the track's lyrics (what `LyricFrame.id` carries).
        public var index: Int
        public var start: Double
        /// When it comes down (a moment after it's sung).
        public var shownUntil: Double
        /// When it would come down if held until the next line.
        public var heldUntil: Double
        public var text: String

        public init(index: Int, start: Double, shownUntil: Double, heldUntil: Double? = nil, text: String) {
            self.index = index
            self.start = start
            self.shownUntil = shownUntil
            self.heldUntil = heldUntil ?? shownUntil
            self.text = text
        }
    }

    /// Lines with words, in order.
    public var lines: [Line]
    public var duration: Double?

    public init(lines: [Line], duration: Double? = nil) {
        self.lines = lines.sorted { $0.start < $1.start }
        self.duration = duration
    }

    public func line(_ index: Int) -> Line? { lines.first { $0.index == index } }

    /// Position of line `index` in `lines`.
    func position(of index: Int) -> Int? { lines.firstIndex { $0.index == index } }

    /// The quiet before line `index`: from the previous line coming down (or the start of
    /// the track) to this one starting. This is when the picture can move.
    public func gap(before index: Int) -> Double? {
        guard let i = position(of: index) else { return nil }
        let previousEnd = i > 0 ? lines[i - 1].shownUntil : 0
        return max(0, lines[i].start - previousEnd)
    }

    // MARK: - Structure

    /// A stretch of lines between long gaps, with a guess at what it is.
    public struct Section: Sendable, Equatable, Codable {
        public enum Kind: String, Sendable, Codable { case verse, chorus }
        /// Line indices (as in `Line.index`), first and last.
        public var firstLine: Int
        public var lastLine: Int
        public var kind: Kind
        /// Seconds of quiet before the section's first line.
        public var gapBefore: Double
    }

    public struct Structure: Sendable, Equatable {
        public var sections: [Section]
        /// Line index → a group number shared by lines with the same words (repeats only).
        public var repeats: [Int: Int]
    }

    /// Sections split at long gaps (4 s or more); a section mostly made of lines heard
    /// elsewhere in the song is probably the chorus.
    public func structure(sectionGap: Double = 4) -> Structure {
        func normalise(_ s: String) -> String {
            s.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " }
                .map(String.init).joined().split(separator: " ").joined(separator: " ")
        }
        var groups: [String: [Int]] = [:]
        for line in lines { groups[normalise(line.text), default: []].append(line.index) }
        var repeats: [Int: Int] = [:]
        var next = 0
        for line in lines {
            let key = normalise(line.text)
            guard let members = groups[key], members.count > 1, !key.isEmpty else { continue }
            if let existing = members.lazy.compactMap({ repeats[$0] }).first {
                repeats[line.index] = existing
            } else {
                repeats[line.index] = next
                next += 1
            }
        }

        var sections: [Section] = []
        var current: [Line] = []
        var gapBefore = lines.first.map { $0.start } ?? 0
        func close() {
            guard let first = current.first, let last = current.last else { return }
            let repeated = current.filter { repeats[$0.index] != nil }.count
            let kind: Section.Kind = Double(repeated) >= Double(current.count) * 0.5 ? .chorus : .verse
            sections.append(Section(firstLine: first.index, lastLine: last.index, kind: kind, gapBefore: gapBefore))
            current = []
        }
        for (i, line) in lines.enumerated() {
            if i > 0 {
                let gap = line.start - lines[i - 1].shownUntil
                if gap >= sectionGap {
                    close()
                    gapBefore = gap
                }
            }
            current.append(line)
        }
        close()
        return Structure(sections: sections, repeats: repeats)
    }
}
