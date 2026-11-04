import Lyrics
import Testing

@Suite struct WordTimingTests {
    @Test func countsSyllablesRoughly() {
        #expect(WordTiming.syllables("a") == 1)
        #expect(WordTiming.syllables("paper") == 2)
        #expect(WordTiming.syllables("beautiful") == 3)
        #expect(WordTiming.syllables("fold") == 1)
        #expect(WordTiming.syllables("there's") == 1)
        #expect(WordTiming.syllables("little") == 2)
        #expect(WordTiming.syllables("...") == 1)
    }

    @Test func longerWordsGetMoreTime() {
        let starts = WordTiming.starts(for: "a beautiful morning", from: 10, to: 14)
        #expect(starts.count == 3 && starts[0] == 10)
        let gaps = zip(starts.dropFirst(), starts).map { $0 - $1 }
        #expect(gaps[0] < gaps[1])  // "a" (1) shorter than "beautiful" (3)
        #expect(starts.last! < 14 * 0.99)
    }

    @Test func wordsSnapToNearbyBeatsButStayInOrder() {
        let plain = WordTiming.starts(for: "one two three four", from: 0, to: 4)
        let beats = plain.map { $0 + 0.08 }  // a beat just after each word
        let snapped = WordTiming.starts(for: "one two three four", from: 0, to: 4, beats: beats)
        #expect(snapped[0] == 0)
        for i in 1..<4 { #expect(abs(snapped[i] - beats[i]) < 1e-9) }
        let far = WordTiming.starts(for: "one two three four", from: 0, to: 4, beats: plain.map { $0 + 0.5 })
        #expect(far == plain)
    }

    @Test func revealCountsWordsAndFadesTheCurrentOne() {
        let starts = [0.0, 1.0, 2.0]
        #expect(WordTiming.revealed(at: -1, starts: starts) == 0)
        #expect(abs(WordTiming.revealed(at: 1.09, starts: starts) - 1.5) < 1e-9)
        #expect(WordTiming.revealed(at: 5, starts: starts) == 3)
    }
}

@Suite struct SyllableEdgeCases {
    @Test func esEndings() {
        #expect(WordTiming.syllables("makes") == 1)
        #expect(WordTiming.syllables("boxes") == 2)
        #expect(WordTiming.syllables("pages") == 2)
        #expect(WordTiming.syllables("tables") == 2)
    }
}
