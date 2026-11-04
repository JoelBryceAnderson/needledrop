import SessionState
import Testing

@Suite struct CalibrationTests {
    @Test func gainAdvice() {
        #expect(Calibration.gainAdvice(peakDB: -0.2, clipped: false) == .clipping)
        #expect(Calibration.gainAdvice(peakDB: -10, clipped: true) == .clipping)
        #expect(Calibration.gainAdvice(peakDB: -2, clipped: false) == .tooHot(lowerByDB: 7))
        #expect(Calibration.gainAdvice(peakDB: -9, clipped: false) == .good)
        #expect(Calibration.gainAdvice(peakDB: -30, clipped: false) == .tooQuiet(raiseByDB: 21))
        #expect(Calibration.gainAdvice(peakDB: -90, clipped: false) == .noSignal)
    }

    @Test func thresholdsSitBetweenTheMeasuredLevels() {
        let fit = Calibration.fit(.init(grooveNoiseDB: -58, musicDB: -24, needleUpDB: -82))
        let c = fit.config
        #expect(fit.warnings.isEmpty)
        #expect(c.stopThresholdDB > -58 && c.stopThresholdDB <= -52)
        #expect(c.startThresholdDB > c.stopThresholdDB + 3 && c.startThresholdDB <= -30)
        #expect(c.needleLiftFloorDB == -70)
    }

    @Test func warnsWhenLevelsAreTooClose() {
        let fit = Calibration.fit(.init(grooveNoiseDB: -50, musicDB: -42, needleUpDB: -52))
        #expect(fit.warnings.count == 2)
        #expect(fit.config.startThresholdDB >= fit.config.stopThresholdDB + 4)
        #expect(fit.config.needleLiftFloorDB < -70)  // lift detection effectively off
    }

    @Test func robustLevels() {
        let samples: [Float] = [-60, -61, -59, -10, -60, -62, -60, .nan]  // one click
        #expect(Calibration.level(samples, percentile: 0.5) == -60)
        #expect(Calibration.level([], percentile: 0.5) == nil)
    }
}
