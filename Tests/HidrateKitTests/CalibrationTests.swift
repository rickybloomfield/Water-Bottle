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

@Suite("Level tracker")
struct LevelTrackerTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func tracker() -> LevelTracker {
        LevelTracker(configuration: .init(minDrinkML: 15, refillFractionOfCapacity: 0.5, nearFullFraction: 0.9, restSeconds: 0), capacityML: 621)
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

    /// The night the bottle sat untouched with 330 mL in it and the reading slid down
    /// 186 mL by morning: within a connection the slide arrives a millilitre at a time
    /// and is absorbed, but the bottle sleeps for an hour at a stretch, and each time it
    /// woke the slide had become one step of 20 to 75 mL — four "drinks" from a bottle
    /// nobody touched. Nothing across a gap is measured; the baseline follows.
    @Test func aDropAcrossAGapIsNotADrink() {
        var t = tracker()
        _ = t.ingest(levelML: 328, at: t0)
        #expect(t.ingest(levelML: 254, at: t0 + 63 * 60) == nil)
        #expect(t.baselineML == 254, "the baseline follows to where the bottle now reads")
        // The next drop watched happen is measured from there.
        #expect(t.ingest(levelML: 224, at: t0 + 63 * 60 + 15) == .drink(volumeML: 30, fromML: 254, toML: 224))
    }

    /// A new connection is a gap however recent the last reading was: the first reading
    /// of a session is judged against where the bottle last rested, over the time since.
    /// Half a minute after resting at 402, a bottle at −207 is 609 mL down — held the
    /// minute any big drop is, then logged. The model cuts it to what the bottle held,
    /// 402 at most, and dates it to the middle of the gap.
    @Test func aNewSessionMeasuresFromWhereTheBottleLastRested() {
        var t = tracker()
        _ = t.ingest(levelML: 402, at: t0)
        t.sessionStarted()
        #expect(t.ingest(levelML: -207, at: t0 + 30) == nil, "held")
        #expect(t.baselineML == 402, "the baseline waits for the drop to prove itself")
        guard case .drink(let volume, let from, let to)? = t.ingest(levelML: -207, at: t0 + 95) else {
            Issue.record("expected a drink")
            return
        }
        #expect(from == 402 && to == -207)
        // 609, less the half-millilitre the zero typically manages in half a minute.
        #expect(abs(volume - 608.75) < 0.01, "logged \(volume)")
        #expect(t.lastDrinkAcrossGapSince == t0, "measured across the gap since the bottle rested at 402")
        #expect(t.baselineML == -207)
    }

    /// 07:36 on 7 September: home after an hour away, the phone reconnected and the
    /// session's first reading was of the bottle in a hand, 1293 mL under the 710 it had
    /// rested at. Set back down half a minute later it read 551 — re-seated, and an hour
    /// of drift — with nothing drunk. The bottle in a hand is not a reading; where it
    /// rests is measured against the 710 over the whole hour, and 159 mL is within what
    /// the zero is allowed in that time, so the baseline follows it and nothing is logged.
    @Test func aSessionThatOpensWithTheBottleInHandMeasuresWhereItRests() {
        var t = tracker()
        _ = t.ingest(levelML: 710, at: t0)
        t.sessionStarted()
        let back = t0 + 3600
        #expect(t.ingest(levelML: -583, at: back)?.isHandled == true)
        #expect(t.baselineML == 710, "held: the bottle is in the air")
        #expect(t.ingest(levelML: -580, at: back + 20)?.isHandled == true)
        #expect(t.ingest(levelML: 551, at: back + 35) == nil, "an hour's drift, not a drink")
        #expect(t.baselineML == 551)
        // From here on the app is watching: the next drop is a drink.
        #expect(t.ingest(levelML: 500, at: back + 50) == .drink(volumeML: 51, fromML: 551, toML: 500))
    }

    /// The same lift, but the bottle never comes back down: carried off, or left off its
    /// sensor. A reading off the sensor is never adopted, however long it stays, so the
    /// baseline holds at the last rest, and wherever the bottle next rests is measured
    /// against it over the whole stretch — here a bottleful drunk on the way.
    @Test func aLiftThatStaysHoldsTheBaselineUntilTheBottleRests() {
        var t = tracker()
        _ = t.ingest(levelML: 710, at: t0)
        t.sessionStarted()
        for i in 0..<5 { #expect(t.ingest(levelML: -583, at: t0 + 20 + Double(i) * 15)?.isHandled == true) }
        #expect(t.baselineML == 710, "never adopted")
        // Set down empty ten minutes later: 710 down, less the 5 mL ten minutes allows
        // the zero, is a bottleful — held, then logged.
        #expect(t.ingest(levelML: 0, at: t0 + 600) == nil, "held")
        guard case .drink(let volume, _, _)? = t.ingest(levelML: 0, at: t0 + 665) else {
            Issue.record("expected a drink")
            return
        }
        #expect(abs(volume - 705) < 0.01, "logged \(volume)")
    }

    /// The zero wanders up as readily as down while the bottle sleeps. Adopting only
    /// the downward kind would leave the baseline low and the next real drink unmeasured.
    @Test func aRiseAcrossAGapIsAdoptedToo() {
        var t = tracker()
        _ = t.ingest(levelML: 200, at: t0)
        #expect(t.ingest(levelML: 260, at: t0 + 3600) == nil)
        #expect(t.baselineML == 260)
        #expect(t.ingest(levelML: 230, at: t0 + 3600 + 15) == .drink(volumeML: 30, fromML: 260, toML: 230))
    }

    /// A refill is the one thing worth reporting across a gap: filling from near empty
    /// to the brim is unmistakable however long the bottle was away.
    @Test func aRefillAcrossAGapIsStillARefill() {
        var t = tracker()
        _ = t.ingest(levelML: 40, at: t0)
        #expect(t.ingest(levelML: 615, at: t0 + 3600) == .refill(volumeML: 575, fromML: 40, toML: 615))
        #expect(t.baselineML == 615)
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
        var tracker = LevelTracker(configuration: .init(restSeconds: 0), capacityML: 621)
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
        var tracker = LevelTracker(configuration: .init(restSeconds: 0), capacityML: 621)
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
        var tracker = LevelTracker(configuration: .init(restSeconds: 0), capacityML: capacity)
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
        var tracker = LevelTracker(configuration: .init(restSeconds: 0), capacityML: capacity)
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
        var tracker = LevelTracker(configuration: .init(restSeconds: 0), capacityML: capacity)
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

    func tracker() -> LevelTracker { LevelTracker(configuration: .init(restSeconds: 0), capacityML: 621) }

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

    /// A drop across a gap is measured, less what the zero is allowed for the time. An
    /// hour away and 800 mL down from 700 — emptied, and the zero sunk 100 — is most of
    /// a bottle: held the minute any big drop is, then logged less the 30 mL the zero
    /// typically wanders in an hour. The model then cuts it to what the bottle held.
    @Test func aDropAcrossAGapIsMeasuredLessTheDrift() {
        var t = tracker()
        _ = t.ingest(levelML: 700, at: t0)
        #expect(t.ingest(levelML: -100, at: t0 + 3600) == nil, "held")
        #expect(t.baselineML == 700, "held")
        guard case .drink(let volume, let from, let to)? = t.ingest(levelML: -101, at: t0 + 3600 + 61) else {
            Issue.record("expected a drink")
            return
        }
        #expect(from == 700 && to == -101)
        #expect(abs(volume - (801 - 30)) < 0.01, "logged \(volume)")
        #expect(t.baselineML == -101)
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
        var t = LevelTracker(configuration: .init(restSeconds: 0), capacityML: 621)
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
        var t = LevelTracker(configuration: .init(restSeconds: 0), capacityML: 621)
        _ = t.ingest(levelML: 500, at: t0)
        #expect(t.ingest(levelML: 610, at: t0 + 15)?.isRefill == true)
    }

    /// And a step up that is a different surface reading high is neither a refill nor
    /// something the baseline adopts.
    @Test func aSurfaceReadingHighIsNeitherRefillNorBaseline() {
        var t = LevelTracker(configuration: .init(restSeconds: 0), capacityML: 621)
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

    func tracker() -> LevelTracker { LevelTracker(configuration: .init(restSeconds: 0), capacityML: 621) }

    /// 16:34:58: resting at 1521 mL a quarter of an hour before, the emptied bottle read
    /// 822 — held, since emptying a bottle into a sink reads exactly like drinking it —
    /// and sat there creeping for the best part of a minute; then a gap, and 513 at
    /// 16:42:50, which is 1008 under the baseline: more than the bottle could have lost,
    /// so it is off its sensor, or the zero has moved for good. The held drop is dropped
    /// and the baseline holds. Half an hour of that and the baseline is forgotten, so the
    /// next resting reading starts afresh with nothing logged.
    @Test func anEmptiedBottleReadingFurtherThanItHeldIsOffItsSensor() {
        var t = tracker()
        t.reset(baselineML: 1521, lastReadingAt: t0 - 900)
        #expect(t.ingest(levelML: 822, at: t0) == nil, "held")
        #expect(t.baselineML == 1521, "held: the bottle could still be set back down")
        for step in 1...20 {
            #expect(t.ingest(levelML: 814 - Double(step) * 1.4, at: t0 + 9 + Double(step) * 2) == nil, "still held")
        }
        let later = t.ingest(levelML: 513, at: t0 + 472)
        #expect(later?.isHandled == true, "1008 under 1521 is more than the bottle held: \(String(describing: later))")
        #expect(t.baselineML == 1521, "held, not adopted")
        // Still there half an hour on: the baseline is forgotten, and the reading after
        // that is where measuring starts again.
        #expect(t.ingest(levelML: 500, at: t0 + 472 + 1800)?.isHandled == true)
        #expect(t.baselineML == nil)
        #expect(t.ingest(levelML: 499, at: t0 + 472 + 1815) == .baseline(levelML: 499))
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
    /// log nothing, and the two millilitres the surface reads differently are drift the
    /// baseline follows.
    @Test func aLiftThatComesBackIsStillNothing() {
        var t = tracker()
        _ = t.ingest(levelML: 500, at: t0)
        #expect(t.ingest(levelML: -200, at: t0 + 15)?.isHandled == true)
        #expect(t.ingest(levelML: 502, at: t0 + 30) == nil)
        #expect(t.baselineML == 502)
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

/// The morning of 14 September 2026: the bottle filled and marked Full at 07:55, drunk
/// empty during a workout with the phone out of range from 08:01 to 08:30, and 4.9 oz
/// logged — because nothing across a gap was measured, and the app still believed the
/// bottle full when it came back. Levels are as the calibration read them, with the
/// zero set by Full (1.418 raw/mL).
@Suite("Measuring across a gap")
struct GapTests {
    /// 08:00:57, the last resting reading before the gap.
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func tracker() -> LevelTracker { LevelTracker(configuration: .init(restSeconds: 0), capacityML: 621) }

    /// At rest reading 641 (the zero had crept up 20 since Full). 08:30:56, a new
    /// connection: −771, in a hand. 08:31:04 set down empty at −123, and there it stayed.
    /// That is the whole bottle, drunk while nobody was watching.
    @Test func aBottleDrunkEmptyWhileOutOfRangeIsLoggedWhenItComesBack() {
        var t = tracker()
        t.believedContentsML = 621
        _ = t.ingest(levelML: 641, at: t0)
        t.sessionStarted()
        let back = t0 + 30 * 60
        #expect(t.ingest(levelML: -771, at: back)?.isHandled == true, "in a hand")
        #expect(t.ingest(levelML: -123, at: back + 8) == nil, "at rest, 764 down: held")
        #expect(t.baselineML == 641)
        for i in 1...20 { #expect(t.ingest(levelML: -124, at: back + 8 + Double(i) * 2) == nil) }
        guard case .drink(let volume, let from, let to)? = t.ingest(levelML: -122, at: back + 70) else {
            Issue.record("expected the workout's drink")
            return
        }
        #expect(from == 641 && to == -122)
        // 763 down, less the 15 mL the zero typically manages in half an hour: more than
        // the bottle held, which the model cuts to a bottleful.
        #expect(abs(volume - (763 - 15)) < 0.5, "logged \(volume)")
        #expect(t.lastDrinkAcrossGapSince == t0)
        #expect(HidrateBottleModel.drink(.drink(volumeML: volume, fromML: from, toML: to), cappedAt: 621, minDrinkML: 15)
                == .drink(volumeML: 621, fromML: from, toML: to))
    }

    /// 08:36:54 the same morning: the empty bottle lifted and set down again 144 mL lower
    /// — a different spot on the desk, or the last mouthful. Watched, that is a drink by
    /// the scale; the model, believing the bottle empty, logs nothing.
    @Test func anEmptyBottleSetDownLowerGivesNothing() {
        let step = LevelChange.drink(volumeML: 144, fromML: -121, toML: -265)
        #expect(HidrateBottleModel.drink(step, cappedAt: 0, minDrinkML: 15) == nil)
    }

    /// The night of 6 September, when the bottle slept for an hour at a stretch and the
    /// zero slid 20 to 75 mL between wakes: 74 mL over 64 minutes, 25 over 59, 21 over
    /// 33, 30 over 50 — four "drinks" from a bottle nobody touched, and none of them
    /// clears the allowance for the time.
    @Test func theZeroSlidingWhileTheBottleSleepsIsNotADrink() {
        var t = tracker()
        _ = t.ingest(levelML: 328, at: t0)
        var now = t0
        for (drop, minutes) in [(74.0, 64.0), (25.0, 59.0), (21.0, 33.0), (30.0, 50.0)] {
            let before = t.baselineML!
            now += minutes * 60
            #expect(t.ingest(levelML: before - drop, at: now) == nil, "\(drop) mL over \(minutes) min")
            #expect(t.baselineML == before - drop, "the baseline follows the slide")
        }
    }

    /// 09:26 on 11 September: resting at 824 after a fill, the bottle came back 25
    /// minutes later reading 62, and the person had to mark it empty by hand. That is a
    /// bottleful, drunk in the gap.
    @Test func aBottlefulAcrossHalfAnHourIsADrink() {
        var t = tracker()
        t.believedContentsML = 621
        _ = t.ingest(levelML: 824, at: t0)
        t.sessionStarted()
        #expect(t.ingest(levelML: 62, at: t0 + 25 * 60) == nil, "held")
        guard case .drink(let volume, _, _)? = t.ingest(levelML: 62, at: t0 + 25 * 60 + 60) else {
            Issue.record("expected a drink")
            return
        }
        #expect(abs(volume - (762 - 12.5)) < 0.01, "logged \(volume)")
    }

    /// A bottle carried around for three minutes and set back down with a sip taken on
    /// the way: the readings in the hand are not readings, and the sip is measured from
    /// where the bottle last rested, over the whole stretch — less the drift three
    /// minutes allows the zero.
    @Test func aSipWhileCarriedIsMeasuredWhenTheBottleIsSetDown() {
        var t = tracker()
        _ = t.ingest(levelML: 400, at: t0)
        for i in 1...11 { #expect(t.ingest(levelML: -500, at: t0 + Double(i) * 15)?.isHandled == true) }
        #expect(t.baselineML == 400, "never adopted")
        guard case .drink(let volume, let from, _)? = t.ingest(levelML: 320, at: t0 + 180) else {
            Issue.record("expected a drink")
            return
        }
        #expect(from == 400)
        #expect(abs(volume - 78.5) < 0.01, "logged \(volume)")
        #expect(t.lastDrinkAcrossGapSince == t0)
    }

    /// The same carry with nothing drunk: set down where it was, nothing is logged.
    @Test func aCarryWithNothingDrunkLogsNothing() {
        var t = tracker()
        _ = t.ingest(levelML: 400, at: t0)
        for i in 1...11 { _ = t.ingest(levelML: -500, at: t0 + Double(i) * 15) }
        #expect(t.ingest(levelML: 398, at: t0 + 180) == nil)
        #expect(t.baselineML == 398)
    }

    /// A bottle believed to hold 100 mL, and a reading 700 mL under the baseline: that is
    /// not a drink from a bottle with 100 in it, whatever the scale says — it is the
    /// bottle off its sensor, however plausible the level itself looks.
    @Test func aDropPastWhatTheBottleHeldIsTheBottleOffItsSensor() {
        var t = tracker()
        t.believedContentsML = 100
        _ = t.ingest(levelML: 600, at: t0)
        t.sessionStarted()
        #expect(t.ingest(levelML: -100, at: t0 + 600)?.isHandled == true)
        #expect(t.baselineML == 600)
    }

    /// The first reading the tracker ever sees can be of the bottle in a hand — it woke
    /// and connected because it was picked up. That is no baseline.
    @Test func aFirstReadingInAHandIsNoBaseline() {
        var t = tracker()
        #expect(t.ingest(levelML: -600, at: t0)?.isHandled == true)
        #expect(t.baselineML == nil)
        #expect(t.ingest(levelML: 500, at: t0 + 20) == .baseline(levelML: 500))
    }

    /// 8 September: the zero a litre stale, every resting reading of the day under the
    /// floor. Restored beside a baseline taken the same way, those readings are still
    /// measured against one another — a drink is a difference — and a lift, another
    /// 500 under, is still a lift.
    @Test func aStaleZeroStillMeasuresDifferences() {
        var t = tracker()
        t.reset(baselineML: -1000, lastReadingAt: t0)
        #expect(t.ingest(levelML: -1010, at: t0 + 15) == nil, "drift")
        #expect(t.ingest(levelML: -1300, at: t0 + 30) == .drink(volumeML: 290, fromML: -1010, toML: -1300))
        #expect(t.ingest(levelML: -1800, at: t0 + 45)?.isHandled == true, "a lift")
        #expect(t.baselineML == -1300)
    }

    /// With no baseline and every reading under the floor, half an hour of them is where
    /// the bottle rests, floor or no floor. Set down properly later — 800 mL up in a
    /// step — it is simply back on its sensor, not refilled.
    @Test func halfAnHourUnderTheFloorWithNoBaselineIsWhereTheBottleRests() {
        var t = tracker()
        for i in 0..<120 { #expect(t.ingest(levelML: -700, at: t0 + Double(i) * 15)?.isHandled == true) }
        #expect(t.baselineML == nil)
        #expect(t.ingest(levelML: -700, at: t0 + 1800) == .baseline(levelML: -700))
        #expect(t.ingest(levelML: -705, at: t0 + 1815) == nil, "drift, measured from there")
        #expect(t.ingest(levelML: 100, at: t0 + 1830) == .baseline(levelML: 100), "back on the sensor")
        #expect(t.ingest(levelML: 60, at: t0 + 1845) == .drink(volumeML: 40, fromML: 100, toML: 60))
    }

    /// Restored from disk with the time the baseline was last followed, a relaunch's
    /// first reading is judged over the gap since — and so is the drink in it.
    @Test func aRelaunchMeasuresOverTheGapSinceTheBaseline() {
        var t = tracker()
        t.reset(baselineML: 500, lastReadingAt: t0)
        guard case .drink(let volume, _, _)? = t.ingest(levelML: 300, at: t0 + 20 * 60) else {
            Issue.record("expected a drink")
            return
        }
        #expect(abs(volume - (200 - 10)) < 0.01, "logged \(volume)")
    }

    /// A drop held across a gap survives the link dropping again: the baseline it fell
    /// from stands, and the next resting reading measures it over the whole stretch.
    @Test func aHeldDropSurvivesTheLinkDropping() {
        var t = tracker()
        _ = t.ingest(levelML: 600, at: t0)
        t.sessionStarted()
        #expect(t.ingest(levelML: 50, at: t0 + 600) == nil, "held")
        t.forgetHeldDrink()
        t.sessionStarted()
        #expect(t.ingest(levelML: 48, at: t0 + 900) == nil, "held again, from the same 600")
        #expect(t.baselineML == 600)
        guard case .drink(let volume, let from, _)? = t.ingest(levelML: 48, at: t0 + 965) else {
            Issue.record("expected a drink")
            return
        }
        #expect(from == 600)
        #expect(abs(volume - (552 - 7.5)) < 0.01, "logged once, less a quarter-hour's drift: \(volume)")
    }
}

/// The evening of 15 September, the bottle being played with: pushed down, picked up
/// and set straight back, jostled. Each push read as a refill and each release as a
/// drink — +579 then −579 a minute apart, of the same water — and a lift set back down
/// reading lower was a drink of the difference. Nothing is measured now until the bottle
/// has rested: half a minute of readings that sit still. The suites above turn that off
/// to test the rules one reading at a time; these test the rest.
@Suite("Resting before measuring")
struct RestingTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func tracker() -> LevelTracker { LevelTracker(capacityML: 621) }

    /// Three readings, fifteen seconds apart, are a rest; the first two are not yet.
    @Test func aBaselineTakesHalfAMinute() {
        var t = tracker()
        #expect(t.ingest(levelML: 396, at: t0) == nil)
        #expect(t.ingest(levelML: 397, at: t0 + 15) == nil)
        #expect(t.ingest(levelML: 396, at: t0 + 30) == .baseline(levelML: 396))
    }

    /// 19:39: at rest reading 396, pushed to 975 for six seconds, back to 396 and left.
    /// Neither the push nor the release rests, and the baseline never moved.
    @Test func aPushThatComesStraightBackIsNothing() {
        var t = tracker()
        for i in 0...2 { _ = t.ingest(levelML: 396, at: t0 + Double(i) * 15) }
        #expect(t.baselineML == 396)
        #expect(t.ingest(levelML: 975, at: t0 + 36) == nil)
        #expect(t.ingest(levelML: 975, at: t0 + 38) == nil)
        #expect(t.ingest(levelML: 396, at: t0 + 40) == nil)
        var changes: [LevelChange?] = []
        for i in 1...10 { changes.append(t.ingest(levelML: 396, at: t0 + 40 + Double(i) * 15)) }
        #expect(changes.allSatisfy { $0 == nil }, "\(changes.compactMap { $0 })")
        #expect(t.baselineML == 396)
    }

    /// A refill has to stay: filled to the brim and left, it is a refill half a minute on.
    @Test func aRefillThatStaysIsARefill() {
        var t = tracker()
        for i in 0...2 { _ = t.ingest(levelML: 100, at: t0 + Double(i) * 15) }
        #expect(t.ingest(levelML: 615, at: t0 + 45) == nil, "not yet")
        #expect(t.ingest(levelML: 616, at: t0 + 60) == nil)
        #expect(t.ingest(levelML: 616, at: t0 + 75)?.isRefill == true)
    }

    /// A drink: picked up, drunk from, set down and left. Logged once the bottle has
    /// rested, half a minute after it was set down, and exact.
    @Test func aDrinkIsLoggedOnceTheBottleHasRested() {
        var t = tracker()
        for i in 0...2 { _ = t.ingest(levelML: 500, at: t0 + Double(i) * 15) }
        #expect(t.ingest(levelML: -600, at: t0 + 45)?.isHandled == true)
        #expect(t.ingest(levelML: 400, at: t0 + 60) == nil, "set down; not yet at rest")
        #expect(t.ingest(levelML: 401, at: t0 + 75) == nil)
        #expect(t.ingest(levelML: 401, at: t0 + 90) == .drink(volumeML: 99, fromML: 500, toML: 401))
    }

    /// 18:29: lifted, set down 84 lower, and picked up again twenty seconds later to
    /// read about where it was. It never rested lower, so nothing is logged.
    @Test func aSetDownThatIsPickedStraightUpAgainIsNothing() {
        var t = tracker()
        for i in 0...2 { _ = t.ingest(levelML: 424, at: t0 + Double(i) * 15) }
        #expect(t.ingest(levelML: -472, at: t0 + 45)?.isHandled == true)
        #expect(t.ingest(levelML: 340, at: t0 + 60) == nil)
        #expect(t.ingest(levelML: 415, at: t0 + 75) == nil)
        #expect(t.ingest(levelML: 416, at: t0 + 90) == nil)
        #expect(t.ingest(levelML: 415, at: t0 + 105) == nil, "at rest again, 9 mL under: drift")
        #expect(t.baselineML == 415)
    }

    /// Once at rest, every reading is measured as it comes: a bottle that sits still
    /// does not wait half a minute for each sip.
    @Test func aRestingBottleMeasuresEveryReading() {
        var t = tracker()
        for i in 0...3 { _ = t.ingest(levelML: 500, at: t0 + Double(i) * 15) }
        #expect(t.ingest(levelML: 490, at: t0 + 60) == nil, "10 mL: drift, followed")
        #expect(t.baselineML == 490)
        // A sip taken without lifting the bottle off its sensor, say through a straw.
        #expect(t.ingest(levelML: 470, at: t0 + 75) == nil, "a 20 mL step: not yet rested there")
        #expect(t.ingest(levelML: 470, at: t0 + 90) == nil)
        #expect(t.ingest(levelML: 470, at: t0 + 105) == .drink(volumeML: 20, fromML: 490, toML: 470))
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
