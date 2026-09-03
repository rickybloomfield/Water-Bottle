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
    func tracker() -> LevelTracker {
        LevelTracker(configuration: .init(minDrinkML: 15, refillFractionOfCapacity: 0.5, nearFullFraction: 0.9, liftedBelowML: -60), capacityML: 621)
    }

    @Test func firstReadingIsBaseline() {
        var t = tracker()
        #expect(t.ingest(levelML: 600, at: t0) == .baseline(levelML: 600))
        #expect(t.baselineML == 600)
    }

    @Test func decreaseIsADrink() {
        var t = tracker()
        _ = t.ingest(levelML: 600, at: t0)
        #expect(t.ingest(levelML: 550, at: t0 + 10) == .drink(volumeML: 50, fromML: 600, toML: 550))
        #expect(t.baselineML == 550)
    }

    @Test func smallIncreaseIsIgnoredAndDoesNotInflateBaseline() {
        var t = tracker()
        _ = t.ingest(levelML: 500, at: t0)
        // Placed on a surface that reads 40 mL high — must NOT be a refill and must NOT
        // raise the baseline.
        #expect(t.ingest(levelML: 540, at: t0 + 10) == nil)
        #expect(t.baselineML == 500)
        // A later real drink is still measured from the true 500, not an inflated 540.
        #expect(t.ingest(levelML: 470, at: t0 + 20) == .drink(volumeML: 30, fromML: 500, toML: 470))
    }

    @Test func smallDecreaseIsAdoptedNotLogged() {
        var t = tracker()
        _ = t.ingest(levelML: 500, at: t0)
        #expect(t.ingest(levelML: 492, at: t0 + 10) == nil) // 8 mL, below minimum
        #expect(t.baselineML == 492) // adopted downward
    }

    @Test func bigJumpIsARefill() {
        var t = tracker()
        _ = t.ingest(levelML: 100, at: t0)
        // +400 mL (> 50% of 621) is a refill.
        let change = t.ingest(levelML: 500, at: t0 + 10)
        #expect(change == .refill(volumeML: 400, fromML: 100, toML: 500))
    }

    @Test func toppingOffToFullIsARefillEvenIfIncreaseIsModest() {
        var t = tracker()
        _ = t.ingest(levelML: 380, at: t0) // ~61%
        // +240 mL is < 50% of the bottle, but it reaches 620 (~100%), so it's a top-off.
        let change = t.ingest(levelML: 620, at: t0 + 10)
        guard case .refill(let v, _, _)? = change else { Issue.record("expected refill"); return }
        #expect(abs(v - 240) < 0.01)
        #expect(t.baselineML == 620)
    }

    @Test func modestIncreaseNotReachingFullIsNotARefill() {
        var t = tracker()
        _ = t.ingest(levelML: 300, at: t0)
        // +150 mL, ends at 450 (~72%): neither a big jump nor near full → ignored.
        #expect(t.ingest(levelML: 450, at: t0 + 10) == nil)
        #expect(t.baselineML == 300)
    }

    @Test func liftedReadingIsIgnored() {
        var t = tracker()
        _ = t.ingest(levelML: 500, at: t0)
        #expect(t.ingest(levelML: -200, at: t0 + 5) == nil) // inverted/lifted
        #expect(t.baselineML == 500) // unchanged
        #expect(t.ingest(levelML: 460, at: t0 + 10) == .drink(volumeML: 40, fromML: 500, toML: 460))
    }

    @Test func driftDownIsAbsorbedWithoutEvents() {
        var t = tracker()
        _ = t.ingest(levelML: 600, at: t0)
        var level = 600.0
        for i in 1...30 {
            level -= 4 // ~4 mL per settled reading, below the drink threshold
            #expect(t.ingest(levelML: level, at: t0 + Double(i) * 15) == nil)
        }
        #expect(t.baselineML == level)
    }

    @Test func configurationDecodesOldJSON() throws {
        let json = #"{"minDrinkML":20,"minRefillML":40,"noiseML":4,"driftAdoptAfter":600}"#
        let decoded = try JSONDecoder().decode(LevelTracker.Configuration.self, from: Data(json.utf8))
        #expect(decoded.minDrinkML == 20)
        #expect(decoded.refillFractionOfCapacity == 0.5) // default applied for missing key
        #expect(decoded.nearFullFraction == 0.9)
    }

    @Test func resetRestoresBaseline() {
        var t = tracker()
        _ = t.ingest(levelML: 300, at: t0)
        t.reset(baselineML: 500)
        #expect(t.baselineML == 500)
        t.reset()
        #expect(t.baselineML == nil)
    }
}
