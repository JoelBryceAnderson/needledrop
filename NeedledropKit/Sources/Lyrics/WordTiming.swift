import Foundation

/// When each word of a line is sung, estimated from the line's start and end: time is
/// shared out by syllable count (so "beautiful" takes longer than "a"), then each word's
/// start is pulled onto a nearby beat when one is close.
public enum WordTiming {
    /// Words in the order they're printed (whitespace-separated, punctuation kept).
    public static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Rough syllable count: vowel groups, with a silent final "e", minimum 1.
    public static func syllables(_ word: String) -> Int {
        let letters = word.lowercased().filter(\.isLetter)
        guard !letters.isEmpty else { return 1 }
        var count = 0
        var previousVowel = false
        for c in letters {
            let vowel = "aeiouy".contains(c)
            if vowel, !previousVowel { count += 1 }
            previousVowel = vowel
        }
        // Silent final "e" ("fold" vs "make"), also before an "s" ("there's", "makes") —
        // but not in "-les" or after s/x/z/c/g ("boxes", "pages").
        let chars = Array(letters)
        if count > 1, letters.hasSuffix("e"), !letters.hasSuffix("le") {
            count -= 1
        } else if count > 1, letters.hasSuffix("es"), chars.count >= 3, !letters.hasSuffix("les"),
                  !"sxzcg".contains(chars[chars.count - 3]) {
            count -= 1
        }
        return max(1, count)
    }

    /// Start time of each word. `beats` are track positions of beats (any order); a word
    /// start within `snap` seconds of one moves onto it, keeping words in order.
    public static func starts(for text: String, from start: Double, to end: Double,
                              beats: [Double] = [], snap: Double = 0.12) -> [Double] {
        let words = words(text)
        guard !words.isEmpty, end > start else { return [] }
        // Sing through ~85% of the line; the tail is the last word held.
        let span = (end - start) * 0.85
        let weights = words.map { Double(syllables($0)) }
        let total = weights.reduce(0, +)
        var t = start
        var result: [Double] = []
        for w in weights {
            result.append(t)
            t += span * w / total
        }
        let sortedBeats = beats.sorted()
        for i in result.indices.dropFirst() {
            guard let beat = sortedBeats.min(by: { abs($0 - result[i]) < abs($1 - result[i]) }),
                  abs(beat - result[i]) <= snap else { continue }
            let lower = result[i - 1] + 0.05
            let upper = i + 1 < result.count ? result[i + 1] - 0.05 : end
            if beat > lower, beat < upper { result[i] = beat }
        }
        return result
    }

    /// How many words are showing at `position`: whole words, plus the current word's
    /// fraction over its first `fade` seconds.
    public static func revealed(at position: Double, starts: [Double], fade: Double = 0.18) -> Double {
        var shown = 0.0
        for s in starts where position >= s {
            shown += min(1, (position - s) / fade)
        }
        return shown
    }
}
