import Foundation
import Testing
@testable import HidrateKit

@Suite("Calibration")
struct CalibrationTests {
    // Measured on a 946 mL bottle: empty 35880, full 37115.
    let calibration = BottleCalibration(emptyRaw: 35880, fullRaw: 37115, capacityML: 946)

    @Test func scaleMatchesFieldMeasurement() {
        #expect(abs(calibration.rawUnitsPerML - 1.305) < 0.001)
        #expect(calibration.isValid)
        #expect(calibration.looksReasonable)
    }

    @Test func endpointsMapToEmptyAndFull() {
        #expect(calibration.milliliters(forRaw: 37115) == 946)
        #expect(calibration.milliliters(forRaw: 35880) == 0)
        #expect(abs(calibration.milliliters(forRaw: 37115 - 1235 / 2) - 473) < 1)
    }

    @Test func clampingAndFraction() {
        #expect(calibration.clampedMilliliters(forRaw: 99000) == 946)
        #expect(calibration.clampedMilliliters(forRaw: 0) == 0)
        #expect(abs(calibration.fillFraction(forRaw: 36497.5) - 0.5) < 0.01)
    }

    @Test func invalidCalibrationIsHarmless() {
        let bad = BottleCalibration(emptyRaw: 100, fullRaw: 90, capacityML: 621)
        #expect(!bad.isValid)
        #expect(bad.milliliters(forRaw: 95) == 0)
    }

    @Test func ouncesConvert() {
        #expect(BottleCalibration.capacityML(ounces: 21) == 621)
        #expect(BottleCalibration.capacityML(ounces: 32) == 946)
    }
}

@Suite("Stable weight filter")
struct StableWeightFilterTests {
    @Test func needsAgreeingSamples() {
        var filter = StableWeightFilter(tolerance: 4, requiredSamples: 3)
        #expect(filter.ingest(100) == nil)
        #expect(filter.ingest(101) == nil)
        #expect(filter.ingest(150) == nil) // handling the bottle
        #expect(filter.ingest(151) == nil)
        #expect(filter.ingest(152) == 152)
        #expect(filter.ingest(153) == 153)
        #expect(filter.stableValue == 153)
        filter.reset()
        #expect(filter.ingest(153) == nil)
    }
}

@Suite("Drift model")
struct DriftModelTests {
    @Test func correctsForDriftButNeverGoesNegative() {
        let drift = DriftModel(mlPerMinute: 15, maxGapSeconds: 3600)
        // Over 4 minutes, 60 mL of the observed drop is drift.
        #expect(abs(drift.correctedDrop(observedDrop: 200, gapSeconds: 240) - 140) < 0.01)
        // Pure drift, no real drink: corrected drop is ~0, not negative.
        #expect(drift.correctedDrop(observedDrop: 60, gapSeconds: 240) <= 0.01)
        #expect(drift.correctedDrop(observedDrop: 10, gapSeconds: 600) <= 0.01)
    }
}

@Suite("Level tracker")
struct LevelTrackerTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var config: LevelTracker.Configuration {
        .init(minDrinkML: 15, minRefillML: 30, noiseML: 6, liftedBelowML: -40, fastCadenceSeconds: 6, settleSamples: 3)
    }

    @Test func slowCadenceDriftIsAdoptedSilently() {
        var tracker = LevelTracker(configuration: config)
        #expect(tracker.ingest(levelML: 600, at: t0) == .baseline(levelML: 600))
        var level = 600.0
        for i in 1...20 {
            level -= 3 // ~12 mL/min of thermal drift at 15 s cadence
            #expect(tracker.ingest(levelML: level, at: t0 + Double(i) * 15) == nil)
        }
        // The last sample is still pending confirmation; the one before it is the baseline.
        #expect(tracker.baselineML == level + 3)
    }

    @Test func slowCadenceJumpIsStillADrink() {
        var tracker = LevelTracker(configuration: config)
        _ = tracker.ingest(levelML: 600, at: t0)
        // A slow sample is confirmed by the next slow sample, so events lag by one reading.
        #expect(tracker.ingest(levelML: 560, at: t0 + 15) == nil)
        #expect(tracker.ingest(levelML: 600, at: t0 + 30) == .drink(volumeML: 40, fromML: 600, toML: 560))
        #expect(tracker.ingest(levelML: 600, at: t0 + 45) == .refill(volumeML: 40, fromML: 560, toML: 600))
    }

    @Test func handlingEpisodeIgnoresLiftAndReportsSettledDrop() {
        var tracker = LevelTracker(configuration: config)
        _ = tracker.ingest(levelML: 600, at: t0)
        _ = tracker.ingest(levelML: 599, at: t0 + 15)
        var t = t0 + 30
        // Picked up: the first burst sample arrives at slow spacing, then fast readings far
        // below empty while lifted.
        for v in [590.0, -200, -201, -199, -200] {
            #expect(tracker.ingest(levelML: v, at: t) == nil)
            if v < 0 { #expect(tracker.isHandling) }
            t += 2
        }
        // Set back down: three agreeing fast samples.
        #expect(tracker.ingest(levelML: 552, at: t) == nil)
        #expect(tracker.ingest(levelML: 551, at: t + 2) == nil)
        let change = tracker.ingest(levelML: 552, at: t + 4)
        guard case .drink(let volume, let from, let to)? = change else {
            Issue.record("expected a drink, got \(String(describing: change))")
            return
        }
        #expect(from == 599)
        #expect(abs(to - 551.67) < 0.01)
        #expect(abs(volume - 47.33) < 0.01)
        // Cadence returns to slow with no further change.
        #expect(tracker.ingest(levelML: 551, at: t + 20) == nil)
        #expect(!tracker.isHandling)
    }

    @Test func unsettledFastSamplesNeverReport() {
        var tracker = LevelTracker(configuration: config)
        _ = tracker.ingest(levelML: 600, at: t0)
        var t = t0 + 15
        for v in [580.0, 560, 540, 520, 500, 480] {
            #expect(tracker.ingest(levelML: v, at: t) == nil)
            t += 2
        }
        #expect(tracker.baselineML == 600)
    }

    @Test func refillDuringHandling() {
        var tracker = LevelTracker(configuration: config)
        _ = tracker.ingest(levelML: 200, at: t0)
        var t = t0 + 15
        for v in [-150.0, -151, 400, 600, 610, 611, 610] {
            let result = tracker.ingest(levelML: v, at: t)
            if v == 610, t > t0 + 25 {
                if case .refill(let volume, _, _)? = result { #expect(abs(volume - 410.33) < 0.01) }
            }
            t += 2
        }
        #expect(tracker.baselineML.map { abs($0 - 610.33) < 0.01 } == true)
    }

    @Test func resetRestoresBaseline() {
        var tracker = LevelTracker()
        _ = tracker.ingest(levelML: 300)
        tracker.reset(baselineML: 500)
        #expect(tracker.baselineML == 500)
        tracker.reset()
        #expect(tracker.baselineML == nil)
    }

    @Test func configurationDecodesOldJSON() throws {
        let json = #"{"minDrinkML":20,"minRefillML":40,"noiseML":4,"driftAdoptAfter":600}"#
        let decoded = try JSONDecoder().decode(LevelTracker.Configuration.self, from: Data(json.utf8))
        #expect(decoded.minDrinkML == 20)
        #expect(decoded.settleSamples == 5)
    }
}
