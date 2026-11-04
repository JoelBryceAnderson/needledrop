import Archive
import Testing

/// Fixtures: envelopes at 10 Hz from 0 s, loud music at -18 dB with dips where given.
private func envelope(duration: Double, quiet: [ClosedRange<Double>] = [], dips: [Double] = []) -> [Float] {
    (0..<Int(duration * 10)).map { i in
        let t = Double(i) / 10 + 0.05
        if quiet.contains(where: { $0.contains(t) }) { return -60 }
        if dips.contains(where: { abs($0 - t) < 0.4 }) { return -40 }
        return -18 + Float((i * 7) % 5)  // a little texture
    }
}

private func observation(_ id: String, start: Double, duration: Double?, seen: ClosedRange<Double>) -> TrackObservation {
    TrackObservation(identity: id, clockStart: start, duration: duration, firstSeen: seen.lowerBound, lastSeen: seen.upperBound)
}

@Suite struct TrackSplitterTests {
    @Test func cutsAtGapsAndLabelsTracks() {
        let segments = TrackSplitter.split(.init(
            sideStart: 4, sideEnd: 70, recordingStart: 0, recordingEnd: 82,
            gaps: [28...31, 51...53.5],
            observations: [
                observation("A", start: 4, duration: 24, seen: 9...28),
                observation("B", start: 31, duration: 20, seen: 36...51),
                observation("C", start: 53.5, duration: 16, seen: 58...70),
            ],
            envelope: envelope(duration: 82, quiet: [0...4, 28...31, 51...53.5, 70...82])
        ))
        #expect(segments.map(\.observation) == [0, 1, 2])
        #expect(segments.map(\.start) == [3.5, 29.5, 52.25])
        #expect(segments.map(\.end) == [29.5, 52.25, 71.5])
        #expect(segments.allSatisfy { !$0.uncertain })
    }

    @Test func aQuietPassageInsideASongIsNotABoundary() {
        // A 4-minute song with a 2-second near-silence at 1:30.
        let segments = TrackSplitter.split(.init(
            sideStart: 0, sideEnd: 240, recordingStart: 0, recordingEnd: 250,
            gaps: [90...92],
            observations: [observation("A", start: 0, duration: 240, seen: 5...85)],
            envelope: envelope(duration: 250, quiet: [90...92])
        ))
        #expect(segments.count == 1)
        #expect(segments[0].observation == 0 && segments[0].end == 241.5)
    }

    @Test func aSlowIntroAfterAGapBelongsToTheNextSong() {
        // Track B starts at 100 with a near-silent intro until 112 (detected as a gap end).
        let segments = TrackSplitter.split(.init(
            sideStart: 0, sideEnd: 200, recordingStart: 0, recordingEnd: 205,
            gaps: [98...100, 104...112],
            observations: [
                observation("A", start: 0, duration: 98, seen: 5...97),
                observation("B", start: 100, duration: 100, seen: 120...199),
            ],
            envelope: envelope(duration: 205, quiet: [98...100, 104...112])
        ))
        #expect(segments.map(\.observation) == [0, 1])
        #expect(segments[1].start == 99)
    }

    @Test func seguesSplitAtTheDip() {
        let segments = TrackSplitter.split(.init(
            sideStart: 0, sideEnd: 120, recordingStart: 0, recordingEnd: 125,
            gaps: [],
            observations: [
                observation("A", start: 0, duration: 61, seen: 5...58),
                observation("B", start: 59.5, duration: 60, seen: 64...119),  // clock says 59.5
            ],
            envelope: envelope(duration: 125, dips: [61.2])
        ))
        #expect(segments.count == 2)
        #expect(abs(segments[0].end - 61.2) < 0.3)
        #expect(!segments[0].uncertain && !segments[1].uncertain)
    }

    @Test func seguesWithNoDipAreMarkedUncertain() {
        let segments = TrackSplitter.split(.init(
            sideStart: 0, sideEnd: 120, recordingStart: 0, recordingEnd: 125,
            gaps: [],
            observations: [
                observation("A", start: 0, duration: nil, seen: 5...58),
                observation("B", start: 60, duration: nil, seen: 64...119),
            ],
            envelope: envelope(duration: 125)
        ))
        #expect(segments[0].end == 60)
        #expect(segments[0].uncertainEnd && segments[1].uncertainStart)
    }

    @Test func unidentifiedSegmentsStayUnknown() {
        let segments = TrackSplitter.split(.init(
            sideStart: 0, sideEnd: 100, recordingStart: 0, recordingEnd: 105,
            gaps: [48...51],
            observations: [observation("A", start: 0, duration: 48, seen: 5...47)],
            envelope: envelope(duration: 105, quiet: [48...51])
        ))
        #expect(segments.map(\.observation) == [0, nil])
    }

    @Test func clipsToTheRecording() {
        let segments = TrackSplitter.split(.init(
            sideStart: 0.2, sideEnd: 30, recordingStart: 0, recordingEnd: 30.5,
            gaps: [], observations: [], envelope: envelope(duration: 31)
        ))
        #expect(segments == [TrackSegment(start: 0, end: 30.5)])
    }
}
