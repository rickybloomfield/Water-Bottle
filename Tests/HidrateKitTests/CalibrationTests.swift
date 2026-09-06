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
        LevelTracker(configuration: .init(minDrinkML: 15, refillFractionOfCapacity: 0.5, nearFullFraction: 0.9), capacityML: 621)
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

    /// The afternoon the bottle went dark with 402 mL in it and came back reading 207 mL
    /// under empty: the zero had sunk, and the water was gone. A creep rate applied to
    /// the whole two and a half hours would have corrected the drink out of existence.
    @Test func creepDiscountIsCappedAcrossALongGap() {
        var t = tracker()
        t.creepMLPerSecond = 0.05
        _ = t.ingest(levelML: 402, at: t0)
        let gap: TimeInterval = 2.5 * 3600
        // More than half the bottle in one step is held until it stays down.
        #expect(t.ingest(levelML: -207, at: t0 + gap) == nil)
        guard case .drink(let volume, let from, let to)? = t.ingest(levelML: -210, at: t0 + gap + 61) else {
            Issue.record("expected the drop to be confirmed as a drink")
            return
        }
        // Held from the level less ten minutes' creep, the most the rate is extrapolated.
        #expect(from == 372)
        #expect(to == -210)
        // 609 observed, less 30 mL of creep and the minute of it while it waited.
        #expect(volume > 570 && volume < 580, "got \(volume)")
        #expect(t.baselineML == -210, "tracking carries on from under empty")
    }

    @Test func liftedReadingIsIgnored() {
        var t = tracker()
        _ = t.ingest(levelML: 500, at: t0)
        // 700 mL out of a 621 mL bottle: the bottle moved, not the water.
        #expect(t.ingest(levelML: -200, at: t0 + 5) == .handled(levelML: -200, deltaML: -700))
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

    /// Moving the zero is not calibrating, and mustn't read as if it were: the bottle's
    /// page said "Calibrated just now" after every move.
    @Test func movingTheZeroKeepsTheCalibrationDate() {
        let calibratedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let original = BottleCalibration(emptyRaw: 23089, fullRaw: 23946, capacityML: 621, calibratedAt: calibratedAt)
        let moved = original.rezeroed(toEmptyRaw: 22569, at: calibratedAt.addingTimeInterval(86_400))
        #expect(moved.calibratedAt == calibratedAt)
        #expect(moved.zeroedAt == calibratedAt.addingTimeInterval(86_400))
        #expect(original.zeroedAt == nil)
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

/// The believed level: carried across events, never read off the scale.
@Suite("Believed level")
struct BelievedLevelTests {
    let capacity = 621.0

    /// Reproduces a day: fill to the top, three drinks, and an hour of creep between
    /// them. The believed level follows the water; the scale does not.
    @Test func followsDrinksAndIgnoresDrift() {
        var tracker = LevelTracker(capacityML: capacity)
        var believed = 0.0
        var scale = 0.0

        var now = Date(timeIntervalSince1970: 1_000_000)

        func settle(_ level: Double, after seconds: TimeInterval = 15) {
            scale = level
            now += seconds
            switch tracker.ingest(levelML: level, at: now) {
            case .drink(let volume, _, _)?: believed = max(believed - volume, 0)
            case .refill(let volume, _, _)?:
                let filled = believed + volume
                believed = filled >= capacity * 0.92 ? capacity : min(filled, capacity)
            default: break
            }
        }

        settle(0)                     // baseline: empty bottle
        settle(capacity)              // filled to the top
        #expect(believed == capacity)

        // Twenty minutes of creep at 5 mL/min, in the small steps it actually arrives in.
        for step in 1...20 { settle(capacity - Double(step) * 5) }
        #expect(believed == capacity, "drift must not move the believed level")
        #expect(scale < capacity - 90, "while the scale has wandered a long way")

        settle(scale - 355)           // a 12 oz drink: held back until it stays down
        #expect(believed == capacity, "half a bottleful in one step waits to prove itself")
        settle(scale, after: 90)      // still down a minute and a half later
        #expect(abs(believed - (capacity - 355)) < 1)
    }

    /// Miss an event and the believed level is wrong. Adding most of a bottleful puts it
    /// back, because the water had nowhere else to go.
    @Test func fillingFromEmptyResynchronises() {
        var tracker = LevelTracker(capacityML: capacity)
        var believed = 200.0                    // out of step: the bottle really holds 20
        _ = tracker.ingest(levelML: 20)
        if case .refill(let volume, _, _)? = tracker.ingest(levelML: capacity) {
            believed = volume >= capacity * 0.92 ? capacity : min(believed + volume, capacity)
        }
        #expect(believed == capacity)
    }

    /// A top-up says how much went in, not how much is there, so it cannot resynchronise
    /// a believed level that is already wrong — it can only add to it.
    @Test func aTopUpOnlyAddsWhatWentIn() {
        var tracker = LevelTracker(capacityML: capacity)
        var believed = 200.0
        _ = tracker.ingest(levelML: 400)
        if case .refill(let volume, _, _)? = tracker.ingest(levelML: capacity) {
            believed = volume >= capacity * 0.92 ? capacity : min(believed + volume, capacity)
        }
        #expect(abs(believed - 421) < 1)
    }

    // MARK: - A drink is at most what the bottle held

    @Test func aDrinkIsCutDownToTheContents() {
        let measured = LevelChange.drink(volumeML: 569, fromML: 402, toML: -207)
        #expect(HidrateBottleModel.drink(measured, cappedAt: 402, minDrinkML: 15) == .drink(volumeML: 402, fromML: 402, toML: -207))
        #expect(HidrateBottleModel.drink(measured, cappedAt: 700, minDrinkML: 15) == measured)
        #expect(HidrateBottleModel.drink(measured, cappedAt: nil, minDrinkML: 15) == measured)
    }

    /// The bottle the app believed empty, lifted with some weight left on the sensor for
    /// a minute: 507 mL "drunk" from nothing is nothing.
    @Test func anEmptyBottleHasNothingToGive() {
        let measured = LevelChange.drink(volumeML: 507, fromML: -27, toML: -534)
        #expect(HidrateBottleModel.drink(measured, cappedAt: 0, minDrinkML: 15) == nil)
        #expect(HidrateBottleModel.drink(measured, cappedAt: 9, minDrinkML: 15) == nil)
    }

    // MARK: - Putting a deleted drink back

    private func makeStore() -> (CalibrationStore, UserDefaults, String) {
        let name = "HidrateKitTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        return (CalibrationStore(defaults: defaults), defaults, name)
    }

    private let noon = Date(timeIntervalSince1970: 1_700_000_000)

    /// The bug: deleting a drink the bottle had logged left the carried level down by it.
    @Test func aDeletedDrinkGoesBackIntoTheBottle() {
        let level = HidrateBottleModel.believedLevel(200, capacityML: capacity, restoring: 250, drunkAt: noon, setAt: nil)
        #expect(level == 450)
    }

    @Test func putBackStopsAtAFullBottle() {
        let level = HidrateBottleModel.believedLevel(500, capacityML: capacity, restoring: 250, drunkAt: noon, setAt: nil)
        #expect(level == capacity)
    }

    /// A refill to the top or an emptying after the drink already counted whatever was in
    /// the bottle, so putting the drink back would double it.
    @Test func aDrinkFromBeforeTheLevelWasResetPutsNothingBack() {
        let reset = noon.addingTimeInterval(3_600)
        let level = HidrateBottleModel.believedLevel(capacity, capacityML: capacity, restoring: 250, drunkAt: noon, setAt: reset)
        #expect(level == nil)
    }

    @Test func aDrinkSinceTheLastResetStillGoesBack() {
        let reset = noon.addingTimeInterval(-3_600)
        let level = HidrateBottleModel.believedLevel(300, capacityML: capacity, restoring: 250, drunkAt: noon, setAt: reset)
        #expect(level == 550)
    }

    @Test func nothingCarriedMeansNothingToPutBack() {
        #expect(HidrateBottleModel.believedLevel(nil, capacityML: capacity, restoring: 250, drunkAt: noon, setAt: nil) == nil)
        #expect(HidrateBottleModel.believedLevel(200, capacityML: capacity, restoring: 0, drunkAt: noon, setAt: nil) == nil)
    }

    @Test func theResetTimeRoundTripsWithTheLevel() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(store.loadBelievedLevelSetAt() == nil)
        store.saveBelievedLevelML(300)
        store.saveBelievedLevelSetAt(noon)
        #expect(store.loadBelievedLevelSetAt() == noon)
        store.erase()
        #expect(store.loadBelievedLevelML() == nil)
        #expect(store.loadBelievedLevelSetAt() == nil)
    }

}

/// Picking a full bottle up by the lid used to read as a 24.9 oz drink, logged to Health,
/// followed by a refill that put the level back. Every number here is from the session log
/// of 4 September 2026, converted through the calibration that was in force
/// (empty 22883 raw, 1.418 raw/mL, 621 mL).
@Suite("Picking the bottle up")
struct HandlingTests {
    let capacity = 621.0
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func tracker() -> LevelTracker { LevelTracker(capacityML: 621) }

    /// 17:22 on the day it was reported: resting at 1169 mL (the zero had been moved onto
    /// a lifted bottle hours earlier), 434 mL in the hand, back to 1193 mL on the table.
    @Test func theReportedFalsePositive() {
        var t = tracker()
        _ = t.ingest(levelML: 1169.1, at: t0)
        let lifted = t.ingest(levelML: 434.4, at: t0 + 15)
        #expect(lifted?.isDrink == false, "a 735 mL drink out of a 621 mL bottle")
        #expect(lifted?.isHandled == true)
        #expect(t.baselineML == 1169.1, "the baseline waits for the bottle to come back")
        // And setting it down is a change of nothing, rather than a 759 mL refill.
        let setDown = t.ingest(levelML: 1193.1, at: t0 + 29)
        #expect(setDown == nil, "got \(String(describing: setDown))")
    }

    /// The same lift with a sound calibration: a full bottle reading 600 mL drops to
    /// −517 mL in the hand and comes back. Nothing happened.
    @Test func aLiftAndSetDownIsNoEventAtAll() {
        var t = tracker()
        _ = t.ingest(levelML: 600, at: t0)
        #expect(t.ingest(levelML: -517, at: t0 + 15)?.isHandled == true)
        #expect(t.ingest(levelML: -515, at: t0 + 19)?.isHandled == true)
        #expect(t.ingest(levelML: 599, at: t0 + 140) == nil)
        #expect(abs((t.baselineML ?? 0) - 599) < 0.001)
    }

    /// A gentler lift — 500 mL of displacement, under what the bottle holds, so the rule
    /// above cannot see it. It is caught by coming back: a drop that big is held until it
    /// has stayed down.
    @Test func aLiftTooGentleToBeImpossibleIsCaughtByComingBack() {
        var t = tracker()
        _ = t.ingest(levelML: 520, at: t0)
        #expect(t.ingest(levelML: 20, at: t0 + 15) == nil, "held, not logged")
        #expect(t.ingest(levelML: 21, at: t0 + 30) == nil)
        // Set down 40 seconds later, back where it started: the drop is dropped.
        #expect(t.ingest(levelML: 518, at: t0 + 55)?.isHandled == true)
        #expect(t.baselineML == 520)
        // And nothing is logged afterwards either.
        #expect(t.ingest(levelML: 519, at: t0 + 70) == nil)
    }

    /// The other half of that bargain: a real half-bottle chug stays down, so it is logged
    /// once it has proved itself.
    @Test func aBigChugThatStaysDownIsStillADrink() {
        var t = tracker()
        _ = t.ingest(levelML: 520, at: t0)
        #expect(t.ingest(levelML: 20, at: t0 + 15) == nil)
        #expect(t.ingest(levelML: 19, at: t0 + 30) == nil)
        let confirmed = t.ingest(levelML: 18, at: t0 + 80)
        guard case .drink(let volume, let from, let to)? = confirmed else {
            Issue.record("expected a drink, got \(String(describing: confirmed))")
            return
        }
        #expect(abs(volume - 502) < 0.001)
        #expect(from == 520 && to == 18)
    }

    /// An ordinary sip is not held back: most drinks are nothing like a lift, and waiting
    /// on them would put the blue glow a minute after the drink.
    @Test func anOrdinarySipIsLoggedStraightAway() {
        var t = tracker()
        _ = t.ingest(levelML: 600, at: t0)
        #expect(t.ingest(levelML: 500, at: t0 + 15) == .drink(volumeML: 100, fromML: 600, toML: 500))
    }

    /// A drop measured across a disconnect is not a step between two readings, and drift
    /// over a quarter of an hour away can be larger than the bottle. Only readings that
    /// follow on from one another can say the bottle was handled: this one is a drink
    /// candidate, held until it stays — and the model cuts it to what the bottle held.
    @Test func aGapIsNotAStep() {
        var t = tracker()
        _ = t.ingest(levelML: 700, at: t0)
        #expect(t.ingest(levelML: -100, at: t0 + 3600) == nil, "held")
        let confirmed = t.ingest(levelML: -102, at: t0 + 3661)
        #expect(confirmed?.isDrink == true, "got \(String(describing: confirmed))")
        #expect(confirmed?.volumeML ?? 0 > 780, "more than the bottle: the model caps it")
        #expect(t.baselineML == -102)
    }

    /// Filling a dry bottle to the brim is the largest change water can make, and has to
    /// stay a refill.
    @Test func fillingToTheBrimIsStillARefill() {
        var t = tracker()
        _ = t.ingest(levelML: 5, at: t0)
        #expect(t.ingest(levelML: 621, at: t0 + 15)?.isRefill == true)
    }
}

/// The upward half of the same drift the re-zero handles downward. On 4 September the
/// level climbed from 804 mL to 1209 mL over two and a half hours, in 15 mL steps, each
/// one logged as a refill because the bottle was already past the fill line.
@Suite("Drift is not a refill")
struct UpwardDriftTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func creepPastTheFillLineIsNeverARefill() {
        var t = LevelTracker(capacityML: 621)
        var level = 600.0
        _ = t.ingest(levelML: level, at: t0)
        for step in 1...600 {                      // two and a half hours at 15 s a reading
            level += 1.5                           // ~6 mL a minute, upward
            let change = t.ingest(levelML: level, at: t0 + Double(step) * 15)
            #expect(change == nil, "drift produced \(String(describing: change))")
        }
        // The baseline went with it, so the next drink is still measured correctly.
        #expect(abs((t.baselineML ?? 0) - level) < 0.001)
        let change = t.ingest(levelML: level - 100, at: t0 + 601 * 15)
        #expect(change == .drink(volumeML: 100, fromML: level, toML: level - 100))
    }

    /// A step up is still a top-off, because water arrives between two readings and drift
    /// does not.
    @Test func aStepUpToTheBrimIsARefill() {
        var t = LevelTracker(capacityML: 621)
        _ = t.ingest(levelML: 500, at: t0)
        #expect(t.ingest(levelML: 610, at: t0 + 15)?.isRefill == true)
    }

    /// And a step up that is a different surface reading high is neither a refill nor
    /// something the baseline adopts.
    @Test func aSurfaceReadingHighIsNeitherRefillNorBaseline() {
        var t = LevelTracker(capacityML: 621)
        _ = t.ingest(levelML: 300, at: t0)
        #expect(t.ingest(levelML: 340, at: t0 + 15) == nil)
        #expect(t.baselineML == 300)
    }
}

/// Washing the bottle, from the session log of 5 September 2026: the sensor came off, the
/// bottle was emptied, and the two went back together. Five drinks were logged — 97, 1008,
/// 23, 211 and 18 mL — from a 621 mL bottle nobody drank from. Levels are as the
/// calibration in force read them (its zero had wandered a long way up; the tracker only
/// ever uses steps).
@Suite("Washing the bottle")
struct WashingTests {
    let capacity = 621.0
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func tracker() -> LevelTracker { LevelTracker(capacityML: 621) }

    /// 16:34:58: resting at 1521 mL before the wash, the emptied bottle read 822 and sat
    /// there, creeping, for the best part of a minute. Then a gap, and 513 at 16:42:50.
    /// The drop is held until it stays, then reported as measured — 1008 mL, more than
    /// the bottle holds — for the model to cut down to what the bottle held: nothing, for
    /// a bottle believed empty. Either way the baseline goes to where the bottle now sits.
    @Test func anEmptiedBottleBecomesTheNewBaseline() {
        var t = tracker()
        t.reset(baselineML: 1521)
        var changes: [LevelChange?] = []
        changes.append(t.ingest(levelML: 822, at: t0))
        for step in 1...20 {
            changes.append(t.ingest(levelML: 814 - Double(step) * 1.4, at: t0 + 9 + Double(step) * 2))
        }
        #expect(changes.allSatisfy { $0?.isDrink != true }, "nothing here was drunk")
        #expect(t.baselineML == 1521, "held: the bottle could still be set back down")
        let later = t.ingest(levelML: 513, at: t0 + 472)
        #expect(later == .drink(volumeML: 1008, fromML: 1521, toML: 513), "reported as measured: \(String(describing: later))")
        #expect(HidrateBottleModel.drink(later!, cappedAt: 0, minDrinkML: 15) == nil,
                "and the model, believing the bottle empty, logs nothing")
        #expect(HidrateBottleModel.drink(later!, cappedAt: nil, minDrinkML: 15) == later,
                "with nothing to cap by the measurement stands; the model caps by capacity itself")
        #expect(t.baselineML == 513, "it stayed: the empty bottle is the new baseline")
    }

    /// The same thing seen the other way: a drop held as a possible drink that then goes
    /// further down than the bottle could have given is a move, however long it has waited.
    @Test func aHeldDropBiggerThanTheBottleIsNeverConfirmed() {
        var t = tracker()
        _ = t.ingest(levelML: 600, at: t0)
        #expect(t.ingest(levelML: 250, at: t0 + 15) == nil, "half a bottleful: held")
        let further = t.ingest(levelML: -55, at: t0 + 90)
        #expect(further?.isDrink != true, "got \(String(describing: further))")
        #expect(further?.isHandled == true)
    }

    /// Picking the bottle up still works as before: a lift and a set-down within seconds
    /// leave the baseline where it was, with nothing logged.
    @Test func aLiftThatComesBackIsStillNothing() {
        var t = tracker()
        _ = t.ingest(levelML: 500, at: t0)
        #expect(t.ingest(levelML: -200, at: t0 + 15)?.isHandled == true)
        #expect(t.ingest(levelML: 502, at: t0 + 30) == nil)
        #expect(t.baselineML == 500)
    }

    /// 16:43 to 16:50: the re-seated load cell sank at about 0.65 mL a second. Handling
    /// broke the stream, and the creep that built up meanwhile came back as a step: 23 mL
    /// over 43 seconds, then 211 mL over six and a half minutes. Both logged as drinks.
    /// Told the rate, the tracker takes the creep off and follows it instead.
    @Test func creepAcrossAGapIsNotADrink() {
        var t = tracker()
        t.creepMLPerSecond = 0.65
        var now = t0
        var level = 513.0
        _ = t.ingest(levelML: level, at: now)
        now += 43; level -= 0.65 * 43
        let small = t.ingest(levelML: level, at: now)
        #expect(small == nil, "43 s of creep: \(String(describing: small))")
        now += 390; level -= 0.65 * 390
        let large = t.ingest(levelML: level, at: now)
        #expect(large == nil, "six minutes of creep: \(String(describing: large))")
        #expect(t.baselineML == level, "the baseline followed it, as it would have step by step")
    }

    /// A drink taken while the sensor is creeping is still a drink, less the creep the gap
    /// would have cost anyway.
    @Test func aDrinkDuringCreepIsCountedNetOfCreep() {
        var t = tracker()
        t.creepMLPerSecond = 0.65
        _ = t.ingest(levelML: 500, at: t0)
        let level = 500 - 0.65 * 40 - 150          // 40 s in the hand, a 150 mL drink
        guard case .drink(let volume, _, _)? = t.ingest(levelML: level, at: t0 + 40) else {
            Issue.record("expected a drink")
            return
        }
        #expect(abs(volume - 150) < 0.01, "logged \(volume)")
    }

    /// Between consecutive readings only one interval's creep comes off: fifteen seconds
    /// at a third of a millilitre a second is five millilitres of a 120 mL drink.
    @Test func aDrinkBetweenConsecutiveReadingsLosesOneIntervalOfCreep() {
        var t = tracker()
        t.creepMLPerSecond = 1.0 / 3.0
        _ = t.ingest(levelML: 500, at: t0)
        guard case .drink(let volume, _, _)? = t.ingest(levelML: 380, at: t0 + 15) else {
            Issue.record("expected a drink")
            return
        }
        #expect(abs(volume - 115) < 0.01, "logged \(volume)")
    }

    /// A held drop is confirmed less the creep of the minute it waited.
    @Test func aHeldDropLosesTheCreepOfItsWait() {
        var t = tracker()
        t.creepMLPerSecond = 0.5
        _ = t.ingest(levelML: 600, at: t0)
        #expect(t.ingest(levelML: 250, at: t0 + 10) == nil, "held")
        guard case .drink(let volume, _, _)? = t.ingest(levelML: 220, at: t0 + 70) else {
            Issue.record("expected a drink")
            return
        }
        // 600 → 220 is 380; 5 mL of the step and 30 mL of the wait were the zero sinking.
        #expect(abs(volume - 345) < 0.01, "logged \(volume)")
    }

    /// 17:00:01, the first reading of a relaunched app: 36 mL saved, 18 mL read half a
    /// minute later, and the creep of the relaunch logged as an 18 mL drink. Restored with
    /// the time of its last reading and the creep measured by then, the tracker sees the gap.
    @Test func aRelaunchDuringCreepIsNotADrink() {
        let saved = (baselineML: 300.0, date: t0, creep: 0.65)
        var after = tracker()
        after.reset(baselineML: saved.baselineML, lastReadingAt: saved.date, creepMLPerSecond: saved.creep)
        let first = after.ingest(levelML: saved.baselineML - 0.65 * 30, at: saved.date + 30)
        #expect(first == nil, "the relaunch's creep: \(String(describing: first))")

        var again = tracker()
        again.reset(baselineML: saved.baselineML, lastReadingAt: saved.date, creepMLPerSecond: saved.creep)
        guard case .drink(let volume, _, _)? = again.ingest(levelML: saved.baselineML - 0.65 * 30 - 100, at: saved.date + 30) else {
            Issue.record("expected a drink")
            return
        }
        #expect(abs(volume - 100) < 0.01, "logged \(volume)")
    }
}

/// The rate is measured from the weight reports themselves, not from what settles: a
/// creeping bottle reports every half minute, each report past the stability tolerance
/// from the last, and nothing settles at all.
@Suite("Creep")
struct CreepTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    /// The calibration in force on 5 September: 1.418 raw units per mL.
    func ml(_ raw: Int) -> Double { Double(raw - 22400) / 1.418 }

    /// 17:00:01 to 17:01:14: four reports, 29 and 42 and 2 seconds apart, sinking at half
    /// a raw unit a second the whole time. Nothing settled until the last two, and the
    /// 41 raw units between the first and the last were logged as a 29 mL drink.
    @Test func sparseReportsAtOneRateAreCreep() {
        var creep = CreepEstimator()
        creep.observe(levelML: ml(22453), at: t0)
        creep.observe(levelML: ml(22437), at: t0 + 29)
        creep.observe(levelML: ml(22413), at: t0 + 71)
        #expect(creep.mlPerSecond == 0, "two reports are not yet a rate")
        // One unit in two seconds is 0.35 mL/s: the same slide, and the third report of it.
        creep.observe(levelML: ml(22412), at: t0 + 73)
        #expect(abs(creep.mlPerSecond - 0.35) < 0.03, "measured \(creep.mlPerSecond)")
        creep.observe(levelML: ml(22395), at: t0 + 103)
        creep.observe(levelML: ml(22379), at: t0 + 133)
        creep.observe(levelML: ml(22362), at: t0 + 163)
        #expect(abs(creep.mlPerSecond - 0.39) < 0.05, "measured \(creep.mlPerSecond)")
    }

    /// One slow drop between two sparse reports is a sip for all anyone knows, and
    /// teaches nothing — otherwise the sip would discount the next drink.
    @Test func aSingleSlowDropIsNotARate() {
        var creep = CreepEstimator()
        creep.observe(levelML: 500, at: t0)
        creep.observe(levelML: 470, at: t0 + 60)
        #expect(creep.mlPerSecond == 0)
        creep.observe(levelML: 470, at: t0 + 90)
        #expect(creep.mlPerSecond == 0)
    }

    /// Picking the bottle up is a cliff, and a cliff is not creep.
    @Test func handlingIsIgnored() {
        var creep = CreepEstimator()
        creep.observe(levelML: 500, at: t0)
        creep.observe(levelML: -100, at: t0 + 15)
        creep.observe(levelML: 505, at: t0 + 30)
        creep.observe(levelML: 20, at: t0 + 45)
        #expect(creep.mlPerSecond == 0)
    }

    /// A zero that has stopped sinking is forgotten, report by report. (Jitter of a unit
    /// downward is not creep and not evidence against it, so it fades at half that pace.)
    @Test func flatReportsFadeTheRate() {
        var creep = CreepEstimator(mlPerSecond: 0.5)
        creep.observe(levelML: 500, at: t0)
        for step in 1...6 {
            creep.observe(levelML: 500 + Double(step / 2), at: t0 + Double(step) * 15)
        }
        #expect(creep.mlPerSecond < 0.06, "faded to \(creep.mlPerSecond)")
    }
}
