import Pipeline
import SignalAnalysis
import Testing

@Suite struct FeatureHistoryTests {
    private func history(beatsEvery period: Double? = nil) -> FeatureHistory {
        var h = FeatureHistory(capacity: 600)
        for i in 1...500 {
            let t = Double(i) * 0.01
            let beat = period.map { (t / $0).rounded() == t / $0 } ?? false
            h.append(AudioFeatures(time: t, rms: Float(t), beat: beat))
        }
        return h
    }

    @Test func returnsTheHopThatManySecondsBack() {
        let h = history()
        #expect(abs(h.features(delayedBy: 0).features.time - 5.0) < 1e-9)
        #expect(abs(h.features(delayedBy: 2).features.time - 3.0) < 0.011)
    }

    @Test func clampsToTheOldestKept() {
        #expect(abs(history().features(delayedBy: 60).features.time - 0.01) < 1e-9)
        #expect(FeatureHistory().features(delayedBy: 1).beatAge == nil)
    }

    @Test func beatAgeIsMeasuredAtTheDelayedPoint() {
        let h = history(beatsEvery: 0.5)  // beats at 0.5, 1.0, … 5.0
        let (f, age, _) = h.features(delayedBy: 1.2)  // t = 3.8 → last beat 3.5
        #expect(abs(f.time - 3.8) < 0.011)
        #expect(abs((age ?? -1) - 0.3) < 0.011)
    }
}
