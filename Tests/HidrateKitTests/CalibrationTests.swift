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

    @Test func rawInvertsMilliliters() {
        for ml in [0.0, 250.0, 946.0] {
            #expect(abs(calibration.milliliters(forRaw: calibration.raw(forMilliliters: ml)) - ml) < 0.001)
        }
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
        let drift = DriftModel(mlPerMinute: 15, maxCorrectionML: .infinity, maxGapSeconds: 3600)
        // Over 4 minutes, 60 mL of the observed drop is drift.
        #expect(abs(drift.correctedDrop(observedDrop: 200, gapSeconds: 240) - 140) < 0.01)
        // Pure drift, no real drink: corrected drop is ~0, not negative.
        #expect(drift.correctedDrop(observedDrop: 60, gapSeconds: 240) <= 0.01)
        #expect(drift.correctedDrop(observedDrop: 10, gapSeconds: 600) <= 0.01)
    }

    /// The bottle disconnects every quarter of an hour, so the correction over a gap that
    /// long has to leave a real drink standing.
    @Test func aRealDrinkSurvivesTheUsualDisconnect() {
        let drift = DriftModel()
        // 12 oz taken while the bottle was away for fifteen minutes.
        #expect(drift.correctedDrop(observedDrop: 355, gapSeconds: 900) > 300)
        // And the correction stops growing rather than swallowing the drink whole.
        #expect(drift.correctedDrop(observedDrop: 355, gapSeconds: 3600) > 300)
        // Still nothing left of a drop that is only drift.
        #expect(drift.correctedDrop(observedDrop: 20, gapSeconds: 900) <= 0.01)
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

@Suite("Remembered level")
struct RememberedLevelTests {
    /// A fresh, isolated defaults domain so these don't touch the real one.
    private func makeStore() -> (CalibrationStore, UserDefaults, String) {
        let name = "HidrateKitTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        return (CalibrationStore(defaults: defaults), defaults, name)
    }

    @Test func lastRawRoundTrips() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(store.loadLastRaw() == nil)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        store.saveLastRaw(36_500, date: when)
        #expect(store.loadLastRaw()?.raw == 36_500)
        #expect(store.loadLastRaw()?.date == when)
    }

    /// The regression: recalibrating cleared the saved level, so the Today tab drew an
    /// empty bottle until the next connection. The raw reading has to outlive it.
    @Test func clearingTheLastLevelLeavesTheRawReading() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        store.saveLastLevel(300, date: Date())
        store.saveLastRaw(36_500, date: Date())
        store.clearLastLevel()

        #expect(store.loadLastLevel() == nil)
        #expect(store.loadLastRaw()?.raw == 36_500)
    }

    /// And the point of keeping the raw: a new calibration reads the same reading
    /// differently rather than losing it.
    @Test func aNewCalibrationReinterpretsTheSameReading() {
        let raw = 36_500.0
        let before = BottleCalibration(emptyRaw: 35_880, fullRaw: 37_115, capacityML: 946)
        // The zero drifted up by 200 raw units, so recapturing empty moves both ends.
        let after = BottleCalibration(emptyRaw: 36_080, fullRaw: 37_315, capacityML: 946)

        #expect(abs(before.milliliters(forRaw: raw) - 475.4) < 0.5)
        #expect(abs(after.milliliters(forRaw: raw) - 322.0) < 0.5)
    }
}

@Suite("Re-zeroing")
struct RezeroTests {
    let calibration = BottleCalibration(emptyRaw: 23089, fullRaw: 23946, capacityML: 621)

    @Test func keepsTheScaleAndMovesTheZero() {
        // The zero has drifted 520 raw units down: an empty bottle reads far below empty.
        let drifted = 22569.0
        #expect(calibration.milliliters(forRaw: drifted) < -350)

        let rezeroed = calibration.rezeroed(toEmptyRaw: drifted)
        #expect(abs(rezeroed.rawUnitsPerML - calibration.rawUnitsPerML) < 0.0001)
        #expect(rezeroed.capacityML == calibration.capacityML)
        // The reading that set the zero now reads empty, and a full bottle still reads full.
        #expect(abs(rezeroed.milliliters(forRaw: drifted)) < 0.001)
        #expect(abs(rezeroed.milliliters(forRaw: drifted + calibration.rawSpan) - 621) < 0.001)
    }

    /// A drink measured before the re-zero must measure the same after it: only the
    /// origin moved, so differences are untouched.
    @Test func differencesSurviveTheMove() {
        let rezeroed = calibration.rezeroed(toEmptyRaw: 22569)
        let before = calibration.milliliters(forRaw: 23500) - calibration.milliliters(forRaw: 23300)
        let after = rezeroed.milliliters(forRaw: 23500) - rezeroed.milliliters(forRaw: 23300)
        #expect(abs(before - after) < 0.001)
    }
}

@Suite("Drinking from a near-empty bottle")
struct NearEmptyTests {
    /// The ordering that matters: a drop past the drink threshold is a drink even when it
    /// lands below empty. Re-zeroing on it instead would swallow the drink whole.
    @Test func aDropBelowEmptyIsStillADrink() {
        var tracker = LevelTracker(capacityML: 621)
        _ = tracker.ingest(levelML: 80)
        let change = tracker.ingest(levelML: -40)
        guard case .drink(let volume, _, _)? = change else {
            Issue.record("expected a drink, got \(String(describing: change))")
            return
        }
        #expect(abs(volume - 120) < 0.001)
    }

    /// Drift, by contrast, arrives in steps too small to be a drink and the tracker makes
    /// nothing of them — which is the signal that the zero, not the water, has moved.
    @Test func slowDriftBelowEmptyProducesNoChange() {
        var tracker = LevelTracker(capacityML: 621)
        _ = tracker.ingest(levelML: 10)
        for level in stride(from: 5.0, through: -40.0, by: -5.0) {
            #expect(tracker.ingest(levelML: level) == nil)
        }
    }
}
