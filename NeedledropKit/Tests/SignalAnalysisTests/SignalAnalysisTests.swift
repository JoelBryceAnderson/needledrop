import Foundation
import ReplayHarness
import SignalAnalysis
import Testing

private let sampleRate = 48_000.0

private func sine(_ frequency: Double, amplitude: Float, seconds: Double) -> [Float] {
    (0..<Int(seconds * sampleRate)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
}

private func whiteNoise(rms: Float, seconds: Double) -> [Float] {
    var g = SystemRandomNumberGenerator()
    return (0..<Int(seconds * sampleRate)).map { _ in Float.random(in: -1...1, using: &g) * rms * 1.7320508 }
}

/// Runs `samples` through a fresh extractor and returns every hop's features.
private func extract(_ samples: [Float]) -> [AudioFeatures] {
    let extractor = FeatureExtractor(parameters: .standard(sampleRate: sampleRate))
    let hop = extractor.parameters.hopSize
    return samples.withUnsafeBufferPointer { p in
        stride(from: 0, to: samples.count - hop + 1, by: hop).map { extractor.process(left: p.baseAddress! + $0, right: nil) }
    }
}

@Suite struct SpectrumTests {
    @Test func parametersScaleWithSampleRate() {
        #expect(AnalysisParameters.standard(sampleRate: 44_100).fftSize == 2048)
        #expect(AnalysisParameters.standard(sampleRate: 48_000).fftSize == 2048)
        #expect(AnalysisParameters.standard(sampleRate: 96_000).fftSize == 4096)
        #expect(AnalysisParameters.standard(sampleRate: 192_000).fftSize == 8192)
    }

    @Test func powerSumsToMeanSquare() {
        let analyzer = SpectrumAnalyzer(fftSize: 2048, sampleRate: sampleRate)
        let tone = sine(1000, amplitude: 0.5, seconds: 0.1)
        tone.withUnsafeBufferPointer { analyzer.analyze($0.baseAddress!) }
        let total = analyzer.sum(0..<analyzer.binCount)
        #expect(abs(total - 0.125) / 0.125 < 0.02, "total mean square \(total)")  // 0.5² / 2
        #expect(analyzer.sum(analyzer.bins(from: 900, to: 1100)) / total > 0.99)
    }

    @Test func bandEnergiesLandInTheRightBand() {
        let cases: [(Double, KeyPath<BandEnergies, Float>)] = [(40, \.sub), (120, \.bass), (1000, \.mids), (8000, \.highs)]
        for (frequency, band) in cases {
            let f = extract(sine(frequency, amplitude: 0.5, seconds: 0.3)).last!
            let rms = f.bands[keyPath: band]
            #expect(abs(decibels(rms) - decibels(Float(0.5 / 2.0.squareRoot()))) < 1, "\(frequency) Hz → \(decibels(rms)) dB")
            #expect(f.bands.asArray.max() == rms)
        }
    }

    @Test func flatnessSeparatesMusicFromGrooveNoise() {
        let noise = extract(whiteNoise(rms: 0.01, seconds: 1)).dropFirst(4)
        let chord = extract(zip(sine(220, amplitude: 0.1, seconds: 1), sine(330, amplitude: 0.1, seconds: 1)).map(+)).dropFirst(4)
        #expect(noise.allSatisfy { $0.flatness > 0.4 })
        #expect(chord.allSatisfy { $0.flatness < 0.05 })
    }

    @Test func clippingIsCounted() {
        var samples = sine(100, amplitude: 0.5, seconds: 0.1)
        for i in stride(from: 0, to: samples.count, by: 100) { samples[i] = 1 }
        let clipped = extract(samples).reduce(0) { $0 + $1.clippedSamples }
        let processed = samples.count / 512 * 512
        let expected = Array(stride(from: 0, to: processed, by: 100)).count
        #expect(clipped == expected)
    }
}

@Suite struct RhythmTests {
    @Test func onsetsLandOnClicks() {
        var samples = whiteNoise(rms: 0.001, seconds: 6)
        let clickTimes = stride(from: 0.5, to: 5.6, by: 0.5).map { $0 }
        for t in clickTimes {
            let start = Int(t * sampleRate)
            for j in 0..<480 { samples[start + j] += 0.5 * Float(exp(-Double(j) / 80)) * Float(sin(Double(j) * 0.3)) }
        }
        let onsets = extract(samples).filter(\.onset).map(\.time)
        #expect(onsets.count == clickTimes.count, "onsets at \(onsets)")
        for (detected, actual) in zip(onsets, clickTimes) {
            #expect(abs(detected - actual) < 0.04, "onset \(detected) vs click \(actual)")
        }
    }

    @Test(arguments: [84.0, 96, 120, 140, 165])
    func tempoLocksWithinTwoBPM(bpm: Double) {
        let side = SyntheticSide(sampleRate: sampleRate, segments: [.track(seconds: 16, bpm: bpm, rootHz: 220)])
        let (left, _, _) = side.render()
        let features = extract(left)
        let late = features.filter { $0.time > 8 && $0.time < 14 }.compactMap(\.tempo)
        #expect(!late.isEmpty)
        let median = late.sorted()[late.count / 2]
        #expect(abs(median - bpm) < 2, "estimated \(median) for \(bpm)")
    }

    @Test func beatsFollowTheTempo() {
        let side = SyntheticSide(sampleRate: sampleRate, segments: [.track(seconds: 16, bpm: 120, rootHz: 220)])
        let beats = extract(side.render().left).filter { $0.beat && $0.time > 8 && $0.time < 14 }.map(\.time)
        let intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }
        #expect(beats.count >= 10)
        #expect(intervals.allSatisfy { abs($0 - 0.5) < 0.03 }, "beat intervals \(intervals)")
        // Locked to the kicks, which start at 0.05 s past each half second.
        let phaseErrors = beats.map { t in abs((t - 0.05).truncatingRemainder(dividingBy: 0.5) - 0.25) }
        #expect(phaseErrors.allSatisfy { $0 > 0.17 }, "beats should sit near kicks: \(beats)")
    }

    @Test func tempoClearsAfterMusicStops() {
        let side = SyntheticSide(sampleRate: sampleRate, segments: [
            .track(seconds: 10, bpm: 120, rootHz: 220), .digitalSilence(seconds: 6),
        ])
        let last = extract(side.render().left).last!
        #expect(last.tempo == nil)
    }
}
