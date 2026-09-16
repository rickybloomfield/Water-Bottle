import Foundation

/// Two-point (empty / full) calibration mapping the bottle's raw weight value to milliliters.
///
/// The raw value is linear in water volume on every bottle measured so far, at roughly
/// 1.3 raw units per mL, so a 621 mL (21 oz) bottle spans about 800 raw units.
public struct BottleCalibration: Codable, Sendable, Equatable {
    public var emptyRaw: Double
    public var fullRaw: Double
    public var capacityML: Double
    public var calibratedAt: Date
    /// When the zero was last moved on its own — Empty or Full on the bottle's page —
    /// leaving the scale, and `calibratedAt`, as they were.
    public var zeroedAt: Date?

    public init(emptyRaw: Double, fullRaw: Double, capacityML: Double, calibratedAt: Date = Date(),
                zeroedAt: Date? = nil) {
        self.emptyRaw = emptyRaw
        self.fullRaw = fullRaw
        self.capacityML = capacityML
        self.calibratedAt = calibratedAt
        self.zeroedAt = zeroedAt
    }

    /// The same scale with a new zero.
    ///
    /// The load cell's zero wanders — hundreds of raw units in an hour is normal — while
    /// how many raw units a millilitre is worth does not. So drift is fixed by moving the
    /// zero alone, not by measuring empty and full again — and moving it is not a
    /// calibration, so it doesn't date as one.
    public func rezeroed(toEmptyRaw raw: Double, at date: Date = Date()) -> BottleCalibration {
        BottleCalibration(emptyRaw: raw, fullRaw: raw + rawSpan, capacityML: capacityML,
                          calibratedAt: calibratedAt, zeroedAt: date)
    }

    public static let millilitersPerUSFluidOunce = 29.5735

    public static func capacityML(ounces: Double) -> Double {
        (ounces * millilitersPerUSFluidOunce).rounded()
    }

    public var rawSpan: Double { fullRaw - emptyRaw }
    public var rawUnitsPerML: Double { rawSpan / capacityML }
    public var isValid: Bool { rawSpan > 0 && capacityML > 0 }

    /// Unclamped conversion; slightly negative or above-capacity values are normal noise.
    public func milliliters(forRaw raw: Double) -> Double {
        guard isValid else { return 0 }
        return (raw - emptyRaw) / rawUnitsPerML
    }

    /// The inverse of `milliliters(forRaw:)`.
    public func raw(forMilliliters ml: Double) -> Double {
        guard isValid else { return emptyRaw }
        return emptyRaw + ml * rawUnitsPerML
    }

    public func clampedMilliliters(forRaw raw: Double) -> Double {
        min(max(milliliters(forRaw: raw), 0), capacityML)
    }

    public func fillFraction(forRaw raw: Double) -> Double {
        guard capacityML > 0 else { return 0 }
        return clampedMilliliters(forRaw: raw) / capacityML
    }

    /// A rough sanity check on a fresh calibration. The community-measured scale is
    /// ~1.3 raw/mL; anything wildly off usually means one capture was taken while the
    /// bottle was lifted, or the puck was not seated.
    public var looksReasonable: Bool {
        isValid && (0.5...3.0).contains(rawUnitsPerML)
    }
}

/// Accepts raw weight samples and reports a value only once the last `requiredSamples`
/// readings agree within `tolerance`. Samples taken while the bottle is being handled
/// never form a streak, so they are dropped here.
public struct StableWeightFilter: Sendable {
    public var tolerance: Int
    public var requiredSamples: Int
    public private(set) var stableValue: Int?
    private var last: Int?
    private var streak = 0

    public init(tolerance: Int = 4, requiredSamples: Int = 3) {
        self.tolerance = tolerance
        self.requiredSamples = requiredSamples
    }

    /// Returns the raw value when it is part of a stable streak, nil otherwise.
    public mutating func ingest(_ raw: Int) -> Int? {
        if let last, abs(raw - last) <= tolerance {
            streak += 1
        } else {
            streak = 1
        }
        last = raw
        guard streak >= requiredSamples else { return nil }
        stableValue = raw
        return raw
    }

    public var currentStreak: Int { streak }

    public mutating func reset() {
        last = nil
        streak = 0
        stableValue = nil
    }
}

/// A change in the amount of water in the bottle, as inferred from stable weight readings.
public enum LevelChange: Sendable, Hashable {
    /// First stable reading since (re)start; nothing to log.
    case baseline(levelML: Double)
    /// Water left the bottle.
    case drink(volumeML: Double, fromML: Double, toML: Double)
    /// Water was added.
    case refill(volumeML: Double, fromML: Double, toML: Double)
    /// The bottle moved, not the water: the reading either jumped further than the bottle
    /// could possibly hold, or dropped and came straight back. Nothing to log, and the
    /// baseline is held for when the bottle is set down again.
    case handled(levelML: Double, deltaML: Double)

    public var volumeML: Double {
        switch self {
        case .baseline, .handled: 0
        case .drink(let v, _, _), .refill(let v, _, _): v
        }
    }

    public var isDrink: Bool { if case .drink = self { true } else { false } }
    public var isRefill: Bool { if case .refill = self { true } else { false } }
    public var isBaseline: Bool { if case .baseline = self { true } else { false } }
    /// True when this reading was the bottle being picked up or set down.
    public var isHandled: Bool { if case .handled = self { true } else { false } }
}

/// The load cell's own rate of sinking, in mL per second, watched on every weight sample
/// rather than only the settled ones.
///
/// A bottle whose sensor has just been re-seated after washing sinks at half a millilitre
/// a second, and while it does it reports every half minute, each report further from the
/// last than the stability tolerance — so nothing settles, and the whole slide arrives at
/// the tracker as one step. The rate has to be measured here, from the reports themselves.
///
/// Creep is sustained: one report after another, each a little lower at much the same
/// rate. A drink is one-off. So a rate is only believed once three reports in a row have
/// agreed on it (within a factor of two), and a single slow drop between two sparse
/// reports — a sip, as far as anyone can tell — teaches nothing. Faster than the ceiling
/// is handling, not creep, and a rise past noise is handling too; a flat report says the
/// zero is not sinking, and the rate fades.
public struct CreepEstimator: Sendable {
    public var ceilingMLPerSecond: Double
    public var noiseML: Double
    public var maxIntervalSeconds: TimeInterval
    public private(set) var mlPerSecond: Double
    private var last: (levelML: Double, date: Date)?
    private var candidate: (rate: Double, agreeing: Int)?

    public init(mlPerSecond: Double = 0, ceilingMLPerSecond: Double = 2, noiseML: Double = 6,
                maxIntervalSeconds: TimeInterval = 600) {
        self.mlPerSecond = mlPerSecond
        self.ceilingMLPerSecond = ceilingMLPerSecond
        self.noiseML = noiseML
        self.maxIntervalSeconds = maxIntervalSeconds
    }

    public mutating func observe(levelML: Double, at date: Date) {
        defer { last = (levelML: levelML, date: date) }
        guard let last else { return }
        let dt = date.timeIntervalSince(last.date)
        guard dt > 0, dt <= maxIntervalSeconds else { return }
        let delta = levelML - last.levelML
        if delta < 0 {
            let rate = -delta / dt
            guard rate <= ceilingMLPerSecond else { return }
            if let c = candidate, rate >= c.rate / 2, rate <= c.rate * 2 {
                candidate = (rate: rate, agreeing: c.agreeing + 1)
            } else {
                candidate = (rate: rate, agreeing: 1)
            }
            guard let c = candidate, c.agreeing >= 3 else { return }
            mlPerSecond = mlPerSecond == 0 ? rate : mlPerSecond * 0.7 + rate * 0.3
        } else if delta <= noiseML {
            candidate = nil
            mlPerSecond *= 0.7
        }
    }

    /// Forget the last sample (a gap is not an interval) but keep what was measured.
    public mutating func reset(mlPerSecond: Double? = nil) {
        last = nil
        candidate = nil
        if let mlPerSecond { self.mlPerSecond = mlPerSecond }
    }
}

/// Turns settled, calibrated level readings into drink and refill events.
///
/// The PRO 2 load cell reads slightly differently on different surfaces and drifts with
/// temperature and with what it has just been through, so absolute readings wander even
/// when the water volume has not changed. The rules here are deliberately asymmetric to
/// match physical reality:
///
/// * **A reading off the sensor is not a reading.** The bottle in a hand, on its side, or
///   with the puck out of it reads about the bottle's own weight under empty — some
///   500 mL on the 21 oz — whatever it holds, and a lifted bottle set back down is a
///   change of nothing. Three tests catch it, and any one is enough: the reading sits
///   further under empty than a sunk zero could put a resting bottle
///   (`offSensorBelowEmptyML`) and well under the baseline too — a zero stale by a
///   litre once put every resting reading of a day under the floor, and those are
///   still measured against one another; it sits further under the baseline than the
///   bottle's contents and a margin for the zero sinking could account for
///   (`offSensorMarginML`, against `believedContentsML`); or, between readings seconds
///   apart, it moved more than the bottle holds (`handlingFractionOfCapacity`), which
///   water cannot do in seconds. Such a reading is `handled`: the baseline stays where
///   the bottle last rested, and nothing is measured until it rests again. Half an hour
///   of such readings (`offSensorForgetAfterSeconds`), though, is not a hand: the zero
///   has moved for good — the puck re-seated after a wash, most likely — and the
///   baseline is forgotten, so that the next resting reading starts afresh with
///   nothing logged; with no baseline at all, where the bottle has sat for that half
///   hour is taken as where it rests, under the floor or not — provisionally, since it
///   may be sitting off its sensor: nothing is measured from there until a rise past
///   the margin says it has been set back down.
/// * **Nothing is measured until the bottle has rested**: `restReadings` readings each
///   within `restToleranceML` of the last, spanning `restSeconds`. After handling the
///   bottle reports every three or four seconds, so that is under ten seconds after it
///   is set down. A rise is adopted as a refill only once it has held for
///   `refillRestSeconds`: a bottle pushed down reads a refill's worth higher for as long
///   as the hand is on it, and the evening of 15 September a bottle played with read
///   +579 then −579 a minute apart, a refill and a drink of the same water. A push never
///   moves the baseline now, so its release is a change of nothing; a real refill stays,
///   and nothing about a refill is urgent. A lift set straight back down reads a drink's
///   worth lower for a moment, and does not rest there either.
/// * **A drink is a drop between two resting readings**, less what the zero could have
///   done in between. Between readings seconds apart that is one interval of creep
///   (`creepMLPerSecond`). Across a gap — the bottle out of range for a workout, asleep
///   for an hour, carried around in a hand, the app relaunched — the zero may have
///   wandered, so a drop only counts once it clears an allowance that grows with the gap
///   (`gapDriftBaseML` plus `gapDriftMaxMLPerMinute`, or the creep last measured if that
///   is faster), and what is logged is the drop less what the zero typically manages
///   (`gapDriftTypicalMLPerMinute`). Half an hour away costs a 95 mL allowance, so a
///   bottle drunk empty during a workout is logged the moment it comes back, while the
///   20 to 75 mL the zero slides during an hour's sleep is not — four such "drinks" were
///   once logged from a bottle nobody touched in a night. Over a night the allowance
///   grows past anything the bottle holds, and nothing is measured at all.
/// * **A drop of half the bottle or more waits a minute** (`confirmDrinkFractionOfCapacity`,
///   `confirmSeconds`) before it counts, because a lift that leaves some weight on the
///   sensor has the same shape. A bottle that was only carried comes back long before
///   that; water that was drunk never does.
/// * **An increase is ignored** unless it is unmistakably a refill: a jump of at least
///   `refillFractionOfCapacity` of the bottle, or a rise from below `nearFullFraction`
///   of capacity to above it (you top off to the brim). A bottle already at the fill
///   line cannot be topped off, which is how the zero creeping upward stops reading as
///   an endless series of small refills.
/// * **The baseline follows drift but not steps.** A creeping change of a millilitre or
///   two per reading is the zero wandering, so the baseline goes with it in both
///   directions and the next drink is still measured correctly. A step up of
///   `driftStepML` or more between readings seconds apart that isn't a refill is a
///   different surface reading high, and is never adopted. Across a gap any rise short
///   of a refill is adopted: the zero wanders up as readily as down while the bottle
///   sleeps.
/// * **Below empty is still a reading.** A sunk zero puts an empty bottle under nothing,
///   and the water in it is measured from there like anywhere else. Nothing here decides
///   where empty is; that is the person's to say, on the bottle's page.
///
/// Pouring the bottle out reads exactly like drinking it — the scale cannot tell — so a
/// wash logs a drink of what left the scale. The model cuts that to what it believed
/// the bottle held and marks it as measured across a gap; the row is there to delete.
///
/// Feed it settled readings (e.g. the output of `StableWeightFilter`).
public struct LevelTracker: Sendable {
    public struct Configuration: Sendable, Equatable, Codable {
        /// A decrease of at least this many mL between settled readings is a drink.
        public var minDrinkML: Double
        /// An increase of at least this fraction of capacity is a refill.
        public var refillFractionOfCapacity: Double
        /// Reaching at least this fraction of capacity (with a non-trivial increase) is a
        /// refill too — this is the "I always fill to the top" signal.
        public var nearFullFraction: Double
        /// A change of more than this fraction of the bottle between readings seconds
        /// apart is the bottle being picked up or set down: nothing that happens to the
        /// water can move more than it holds in the time. A little over 1 so that filling
        /// a dry bottle to the brim still reads as a refill.
        public var handlingFractionOfCapacity: Double
        /// How recently the baseline has to have been set for a reading to follow on from
        /// it — for a step between them to be a lift, and for the only drift between them
        /// to be one interval of creep. Further apart than this, or in a new connection,
        /// the bottle was out of sight, and the drop has to clear the gap allowance.
        public var handlingWindowSeconds: TimeInterval
        /// A drop of at least this fraction of the bottle is held back until it proves
        /// itself — see `confirmSeconds`.
        public var confirmDrinkFractionOfCapacity: Double
        /// How long a held drop has to stay down before it counts as a drink.
        public var confirmSeconds: TimeInterval
        /// An increase of less than this between two consecutive readings is the zero
        /// creeping, and the baseline follows it; more than this arrived all at once and
        /// is a surface reading high, which the baseline never adopts.
        public var driftStepML: Double
        /// A resting reading can sit under empty by up to this much and still be a
        /// resting reading: the zero sinks by hundreds of millilitres in the hour after a
        /// big emptying. Further under than this is the bottle off its sensor, which
        /// reads about its own weight — some 500 mL on the 21 oz — under empty.
        public var offSensorBelowEmptyML: Double
        /// A drop of more than the bottle's contents plus this is the bottle off its
        /// sensor too, the contents being what the model believes it holds. The margin
        /// is for the zero sinking between the last resting reading and this one.
        public var offSensorMarginML: Double
        /// What the zero is allowed to have done across any gap at all, before time is
        /// counted: a re-seat, a different surface, the noise of a single reading.
        public var gapDriftBaseML: Double
        /// The most the zero is allowed to have wandered per minute of a gap. A drop has
        /// to clear the whole allowance to count as a drink.
        public var gapDriftMaxMLPerMinute: Double
        /// What the zero typically wanders per minute of a gap, which comes off a drink
        /// measured across one.
        public var gapDriftTypicalMLPerMinute: Double
        /// Readings off the sensor for this long are not a hand: the zero has moved for
        /// good, and the baseline is forgotten so the next resting reading starts afresh.
        public var offSensorForgetAfterSeconds: TimeInterval
        /// How long the readings have to sit still — each within `restToleranceML` of the
        /// last — before the bottle counts as at rest and the level is measured. A lift
        /// that comes straight back never rests, and is nothing. Zero measures every
        /// settled reading as it comes.
        public var restSeconds: TimeInterval
        /// And how many of them, at least: the bottle reports every few seconds after
        /// handling and a single reading is no rest.
        public var restReadings: Int
        /// How long a rise has to hold before it is adopted as a refill. A push reads a
        /// refill's worth higher for as long as the hand is on it; a refill stays.
        public var refillRestSeconds: TimeInterval
        /// How far one reading may sit from the last while the bottle still counts as
        /// resting: creep of a millilitre or two a reading passes, a step does not.
        public var restToleranceML: Double

        public init(
            minDrinkML: Double = 15,
            refillFractionOfCapacity: Double = 0.5,
            nearFullFraction: Double = 0.9,
            handlingFractionOfCapacity: Double = 1.05,
            handlingWindowSeconds: TimeInterval = 120,
            confirmDrinkFractionOfCapacity: Double = 0.5,
            confirmSeconds: TimeInterval = 60,
            driftStepML: Double = 20,
            offSensorBelowEmptyML: Double = 450,
            offSensorMarginML: Double = 350,
            gapDriftBaseML: Double = 20,
            gapDriftMaxMLPerMinute: Double = 2.5,
            gapDriftTypicalMLPerMinute: Double = 0.5,
            offSensorForgetAfterSeconds: TimeInterval = 1800,
            restSeconds: TimeInterval = 8,
            restReadings: Int = 3,
            refillRestSeconds: TimeInterval = 30,
            restToleranceML: Double = 15
        ) {
            self.minDrinkML = minDrinkML
            self.refillFractionOfCapacity = refillFractionOfCapacity
            self.nearFullFraction = nearFullFraction
            self.handlingFractionOfCapacity = handlingFractionOfCapacity
            self.handlingWindowSeconds = handlingWindowSeconds
            self.confirmDrinkFractionOfCapacity = confirmDrinkFractionOfCapacity
            self.confirmSeconds = confirmSeconds
            self.driftStepML = driftStepML
            self.offSensorBelowEmptyML = offSensorBelowEmptyML
            self.offSensorMarginML = offSensorMarginML
            self.gapDriftBaseML = gapDriftBaseML
            self.gapDriftMaxMLPerMinute = gapDriftMaxMLPerMinute
            self.gapDriftTypicalMLPerMinute = gapDriftTypicalMLPerMinute
            self.offSensorForgetAfterSeconds = offSensorForgetAfterSeconds
            self.restSeconds = restSeconds
            self.restReadings = restReadings
            self.refillRestSeconds = refillRestSeconds
            self.restToleranceML = restToleranceML
        }

        enum CodingKeys: String, CodingKey {
            case minDrinkML, refillFractionOfCapacity, nearFullFraction
            case handlingFractionOfCapacity, handlingWindowSeconds
            case confirmDrinkFractionOfCapacity, confirmSeconds, driftStepML
            case offSensorBelowEmptyML, offSensorMarginML
            case gapDriftBaseML, gapDriftMaxMLPerMinute, gapDriftTypicalMLPerMinute
            case offSensorForgetAfterSeconds, restSeconds, restReadings, refillRestSeconds, restToleranceML
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Configuration()
            minDrinkML = try c.decodeIfPresent(Double.self, forKey: .minDrinkML) ?? d.minDrinkML
            refillFractionOfCapacity = try c.decodeIfPresent(Double.self, forKey: .refillFractionOfCapacity) ?? d.refillFractionOfCapacity
            nearFullFraction = try c.decodeIfPresent(Double.self, forKey: .nearFullFraction) ?? d.nearFullFraction
            handlingFractionOfCapacity = try c.decodeIfPresent(Double.self, forKey: .handlingFractionOfCapacity) ?? d.handlingFractionOfCapacity
            handlingWindowSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .handlingWindowSeconds) ?? d.handlingWindowSeconds
            confirmDrinkFractionOfCapacity = try c.decodeIfPresent(Double.self, forKey: .confirmDrinkFractionOfCapacity) ?? d.confirmDrinkFractionOfCapacity
            confirmSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .confirmSeconds) ?? d.confirmSeconds
            driftStepML = try c.decodeIfPresent(Double.self, forKey: .driftStepML) ?? d.driftStepML
            offSensorBelowEmptyML = try c.decodeIfPresent(Double.self, forKey: .offSensorBelowEmptyML) ?? d.offSensorBelowEmptyML
            offSensorMarginML = try c.decodeIfPresent(Double.self, forKey: .offSensorMarginML) ?? d.offSensorMarginML
            gapDriftBaseML = try c.decodeIfPresent(Double.self, forKey: .gapDriftBaseML) ?? d.gapDriftBaseML
            gapDriftMaxMLPerMinute = try c.decodeIfPresent(Double.self, forKey: .gapDriftMaxMLPerMinute) ?? d.gapDriftMaxMLPerMinute
            gapDriftTypicalMLPerMinute = try c.decodeIfPresent(Double.self, forKey: .gapDriftTypicalMLPerMinute) ?? d.gapDriftTypicalMLPerMinute
            offSensorForgetAfterSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .offSensorForgetAfterSeconds) ?? d.offSensorForgetAfterSeconds
            restSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .restSeconds) ?? d.restSeconds
            restReadings = try c.decodeIfPresent(Int.self, forKey: .restReadings) ?? d.restReadings
            refillRestSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .refillRestSeconds) ?? d.refillRestSeconds
            restToleranceML = try c.decodeIfPresent(Double.self, forKey: .restToleranceML) ?? d.restToleranceML
        }
    }

    public var configuration: Configuration
    /// Bottle capacity in mL, needed for the refill thresholds. Set from the calibration.
    public var capacityML: Double
    /// The level the next change is measured against: where the bottle last rested, as
    /// the scale read it. Never a reading taken off the sensor.
    public private(set) var baselineML: Double?
    /// When the baseline was last set or followed. A drink is measured against it over
    /// the time since, which is what tells a step watched happen from one that arrived
    /// across a gap.
    public private(set) var baselineAt: Date?
    /// A drop being held until it proves itself: where it fell from, when it was first
    /// seen, the drift already taken off it, and — when it arrived across a gap — when
    /// the reading it fell from was taken.
    private var heldDrink: (fromML: Double, at: Date, driftML: Double, acrossGapSince: Date?)?
    /// True from a new connection until its first resting reading: however recent the
    /// baseline, the bottle was out of sight, and the reading is judged as across a gap.
    private var gapPending = false
    /// Since when every reading has been off the sensor, while they are. Kept across
    /// connections: it is about the readings, not the link, and the bottle drops the
    /// link every quarter of an hour.
    private var offSensorSince: Date?
    /// True while the baseline is where the bottle sat under the floor for half an hour
    /// with no baseline to compare against — as likely off its sensor as resting on a
    /// stale zero. Nothing is measured from it; a rise past the margin is the bottle set
    /// back down, and measuring starts there.
    private var baselineIsProvisional = false
    /// The run of readings that have sat still: since when, and the last of them. The
    /// level is measured only once the run is `restSeconds` long.
    private var rest: (since: Date, lastLevel: Double, count: Int)?
    /// How fast the resting reading is sinking on its own, in mL per second. Set by
    /// whoever sees the weight samples (a `CreepEstimator`): settled readings are too few
    /// to learn it from, since a creeping bottle reports every half minute and each report
    /// is further from the last than the stability tolerance, so nothing settles. Zero
    /// when it isn't sinking.
    public var creepMLPerSecond: Double = 0 {
        didSet { creepMLPerSecond = max(creepMLPerSecond, 0) }
    }
    /// What the bottle is believed to hold, in mL, from whoever carries that forward (the
    /// model). A drop past it and a margin is the bottle off its sensor, not a drink.
    /// Nil means nothing is known, and the bottle's capacity stands in.
    public var believedContentsML: Double?
    /// For the drink `ingest` last returned: when the resting reading it was measured
    /// against was taken, if that was on the far side of a gap. Nil for a drink watched
    /// between readings seconds apart, and whenever no drink was returned.
    public private(set) var lastDrinkAcrossGapSince: Date?

    /// When the drop currently being held back was first seen, if there is one. A drink
    /// confirmed later belongs at this moment, not at the reading that confirmed it.
    public var heldDrinkSince: Date? { heldDrink?.at }

    public init(configuration: Configuration = Configuration(), capacityML: Double = 621) {
        self.configuration = configuration
        self.capacityML = capacityML
    }

    @discardableResult
    public mutating func ingest(levelML: Double, at date: Date = Date()) -> LevelChange? {
        lastDrinkAcrossGapSince = nil
        let contents = min(believedContentsML ?? capacityML, capacityML)
        let elapsed = baselineAt.map { max(date.timeIntervalSince($0), 0) }
        // Seconds after the baseline, in the same connection: the only drift between the
        // two is one interval of creep, and a step bigger than the bottle is a lift.
        let watched = !gapPending && (elapsed.map { $0 <= configuration.handlingWindowSeconds } ?? false)

        // Off the sensor: in a hand, on its side, or the puck out of it. Not a reading.
        // Under the floor counts only when the reading is well under the baseline as
        // well: a zero stale by a litre puts every resting reading under the floor, and
        // those still measure against one another.
        let farBelowEmpty = levelML < -configuration.offSensorBelowEmptyML
            && (baselineML.map { $0 - levelML > configuration.offSensorMarginML } ?? true)
        let moreThanItHeld = baselineML.map { $0 - levelML > contents + configuration.offSensorMarginML } ?? false
        // (Not from a provisional baseline: a rise from one is the bottle set back down.)
        let impossibleStep = watched && !baselineIsProvisional
            && (baselineML.map { abs(levelML - $0) > configuration.handlingFractionOfCapacity * capacityML } ?? false)
        if farBelowEmpty || moreThanItHeld || impossibleStep {
            // A drop that was waiting to prove itself is not lost: the baseline it fell
            // from is still where the bottle last rested, and the next resting reading is
            // measured against that over the whole stretch.
            heldDrink = nil
            rest = nil
            let since = offSensorSince ?? date
            offSensorSince = since
            if date.timeIntervalSince(since) >= configuration.offSensorForgetAfterSeconds {
                // Half an hour off the sensor is not a hand. Whatever the zero has done,
                // the baseline is no longer worth measuring against: forget it, and the
                // next resting reading starts afresh. With none to forget, this is where
                // the bottle rests, under the floor or not.
                offSensorSince = nil
                if baselineML == nil {
                    // Provisionally: nothing is measured from a reading that may have
                    // been taken off the sensor, until the bottle is set back down.
                    adopt(levelML, at: date)
                    baselineIsProvisional = true
                    return .baseline(levelML: levelML)
                }
                baselineML = nil
                baselineAt = nil
            }
            return .handled(levelML: levelML, deltaML: baselineML.map { levelML - $0 } ?? 0)
        }

        // At rest? Only a level the bottle has held still at for a while is measured: a
        // push reads high for as long as the hand is on it, a bottle set down and
        // picked straight up again reads low for a moment, and neither is water.
        if configuration.restSeconds > 0 {
            if let run = rest, abs(levelML - run.lastLevel) <= configuration.restToleranceML {
                rest = (since: run.since, lastLevel: levelML, count: run.count + 1)
                guard date.timeIntervalSince(run.since) >= configuration.restSeconds,
                      run.count + 1 >= configuration.restReadings else { return nil }
            } else {
                rest = (since: date, lastLevel: levelML, count: 1)
                return nil
            }
        }
        offSensorSince = nil
        gapPending = false

        guard let base = baselineML else {
            adopt(levelML, at: date)
            return .baseline(levelML: levelML)
        }

        if baselineIsProvisional {
            // The baseline is where the bottle sat off its sensor for half an hour. A
            // rise past the margin is the bottle set back down, and where it rests now
            // is where measuring starts again; anything less is followed, unmeasured.
            adopt(levelML, at: date)
            guard levelML - base > configuration.offSensorMarginML else { return nil }
            baselineIsProvisional = false
            return .baseline(levelML: levelML)
        }

        // What the zero could have done since the baseline was set, and what it probably
        // did. Watched, that is one interval of creep. Across a gap it is an allowance
        // that grows with the gap — or the creep last measured, if that is faster.
        let seconds = elapsed ?? 0
        let creepOver = creepMLPerSecond * seconds
        let worstDrift = watched ? creepOver
            : configuration.gapDriftBaseML + max(configuration.gapDriftMaxMLPerMinute / 60, creepMLPerSecond) * seconds
        let likelyDrift = watched ? creepOver
            : max(configuration.gapDriftTypicalMLPerMinute / 60, creepMLPerSecond) * seconds
        let acrossGapSince = watched ? nil : baselineAt

        // A drop big enough to have been a lift is held until it proves itself.
        if let held = heldDrink {
            if levelML >= held.fromML - configuration.minDrinkML {
                // Back where it started: the bottle was moved, not drunk from. It rests
                // again at the level it had before it was picked up.
                heldDrink = nil
                adopt(held.fromML, at: date)
                return .handled(levelML: levelML, deltaML: levelML - held.fromML)
            }
            if date.timeIntervalSince(held.at) >= configuration.confirmSeconds {
                heldDrink = nil
                adopt(levelML, at: date)
                // Less the drift already taken off it, and what the zero sank while it
                // waited.
                let drop = held.fromML - levelML
                let volume = drop - min(held.driftML + creepMLPerSecond * date.timeIntervalSince(held.at), drop)
                guard volume >= configuration.minDrinkML else { return nil }
                lastDrinkAcrossGapSince = held.acrossGapSince
                return .drink(volumeML: volume, fromML: held.fromML, toML: levelML)
            }
            return nil // still down, still unproven
        }

        let delta = levelML - base

        // A drink: a drop past what the zero could have done on its own.
        if delta < 0 {
            let drop = -delta
            if drop - worstDrift < configuration.minDrinkML {
                // Within what the zero could have done in the time. Not a drink; the
                // baseline follows it as it would have step by step.
                adopt(levelML, at: date)
                return nil
            }
            let driftTaken = min(likelyDrift, drop)
            let volume = drop - driftTaken
            if volume >= configuration.confirmDrinkFractionOfCapacity * capacityML {
                // Half a bottleful in one step is also what picking the bottle up looks
                // like when the grip leaves some of the weight on the sensor. Hold it.
                heldDrink = (fromML: base, at: date, driftML: driftTaken, acrossGapSince: acrossGapSince)
                return nil
            }
            adopt(levelML, at: date)
            lastDrinkAcrossGapSince = acrossGapSince
            return .drink(volumeML: volume, fromML: base, toML: levelML)
        }

        // A refill: a large jump up, or topping off from below the fill line to the brim.
        // A bottle already at the fill line cannot be topped off, which is what keeps the
        // zero creeping upward from reading as an endless series of small refills.
        let fillLine = configuration.nearFullFraction * capacityML
        let bigJump = delta >= configuration.refillFractionOfCapacity * capacityML
        let toppedOff = base < fillLine && levelML >= fillLine && delta >= configuration.minDrinkML
        if bigJump || toppedOff {
            // Only once it has stayed up: a hand pressing on the bottle reads exactly
            // like this until it lets go. Until then the baseline holds, so letting go
            // is a change of nothing.
            if let run = rest, date.timeIntervalSince(run.since) < configuration.refillRestSeconds { return nil }
            adopt(levelML, at: date)
            return .refill(volumeML: delta, fromML: base, toML: levelML)
        }

        // Small change: adopt drift so that the next drink is still measured from where
        // the bottle really sits. Watched, an increase that arrives all at once is a
        // different surface reading high rather than the zero creeping, and is never
        // adopted — otherwise it would quietly inflate the next drink. Across a gap the
        // zero wanders up as readily as down, and the reading is adopted either way.
        if !watched || delta < configuration.driftStepML {
            adopt(levelML, at: date)
        }
        return nil
    }

    private mutating func adopt(_ levelML: Double, at date: Date) {
        baselineML = levelML
        baselineAt = date
    }

    /// Start over from a baseline. Restoring from disk also brings the time it was last
    /// followed and the creep measured by then: a new process's first reading is then
    /// judged over the gap since, with the drift that gap allows taken off. Without
    /// that, the half-minute a relaunch takes came back as an 18 mL "drink".
    public mutating func reset(baselineML: Double? = nil, lastReadingAt: Date? = nil, creepMLPerSecond: Double = 0) {
        self.baselineML = baselineML
        baselineAt = baselineML == nil ? nil : lastReadingAt
        heldDrink = nil
        gapPending = false
        offSensorSince = nil
        baselineIsProvisional = false
        rest = nil
        lastDrinkAcrossGapSince = nil
        self.creepMLPerSecond = creepMLPerSecond
    }

    /// Forget a drop that was waiting to prove itself, keeping the level it started from.
    ///
    /// Called when the connection drops. The baseline it fell from still stands, so the
    /// drop is measured again — over the whole gap, with the gap's allowance — when the
    /// bottle is next seen at rest, and counted once.
    public mutating func forgetHeldDrink() {
        heldDrink = nil
    }

    /// A new connection. However recent the baseline, the bottle was out of sight, and
    /// its first resting reading is judged as across a gap: a drop has to clear the gap
    /// allowance, and a step bigger than the bottle is not, on its own, a lift.
    public mutating func sessionStarted() {
        gapPending = true
        heldDrink = nil
        rest = nil
    }
}
