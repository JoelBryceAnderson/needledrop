import Pipeline
import Testing

@Suite struct StallDetectorTests {
    /// Restart decisions for (now, audioTime) pairs, one per second.
    private func run(_ d: inout StallDetector, _ times: Range<Int>, audio: (Int) -> Double, running: Bool = true) -> [Int] {
        times.filter { d.update(now: Double($0), audioTime: audio($0), running: running) }
    }

    @Test func restartsWhenAudioStopsArriving() {
        var d = StallDetector(timeout: 5, backoff: 20)
        #expect(run(&d, 0..<10, audio: { Double($0) }).isEmpty)
        // Audio time stuck at 9 from here: restart once at 5 s, then back off 20 s.
        #expect(run(&d, 10..<40, audio: { _ in 9 }) == [14, 34])
    }

    @Test func ignoresSourcesThatArentRunning() {
        var d = StallDetector()
        #expect(run(&d, 0..<60, audio: { _ in 0 }, running: false).isEmpty)
    }
}
