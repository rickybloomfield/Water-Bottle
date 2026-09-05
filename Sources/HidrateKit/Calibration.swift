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

    public init(emptyRaw: Double, fullRaw: Double, capacityML: Double, calibratedAt: Date = Date()) {
        self.emptyRaw = emptyRaw
        self.fullRaw = fullRaw
        self.capacityML = capacityML
        self.calibratedAt = calibratedAt
    }

    /// The same scale with a new zero.
    ///
    /// The load cell's zero wanders — hundreds of raw units in an hour is normal — while
    /// how many raw units a millilitre is worth does not. So drift is fixed by
    /// re-capturing empty alone, not by measuring empty and full again.
    public func rezeroed(toEmptyRaw raw: Double) -> BottleCalibration {
        BottleCalibration(emptyRaw: raw, fullRaw: raw + rawSpan, capacityML: capacityML)
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

/// Drift compensation for the PRO 2 load cell, whose resting reading falls slowly after
/// handling. Used when recovering a level change measured across a disconnect gap.
public struct DriftModel: Sendable, Equatable, Codable {
    /// How fast the resting reading falls on its own, in mL per minute (downward = positive).
    ///
    /// Measured from session logs, a PRO 2 settling after being handled moves about one
    /// raw unit every ten to fifteen seconds — roughly 3 mL a minute — and between
    /// handlings it drifts as readily up as down. The original 15 subtracted 225 mL over
    /// the bottle's usual quarter-hour disconnect, which is more than a third of the
    /// bottle: any drink taken while it was away was corrected out of existence.
    public var mlPerMinute: Double
    /// Ceiling on the correction however long the gap. Drift is a slow wander around a
    /// value, not a march in one direction, so it does not keep accumulating.
    public var maxCorrectionML: Double
    /// Don't attempt drift-corrected recovery across gaps longer than this.
    public var maxGapSeconds: TimeInterval

    public init(mlPerMinute: Double = 3, maxCorrectionML: Double = 40, maxGapSeconds: TimeInterval = 3600) {
        self.mlPerMinute = mlPerMinute
        self.maxCorrectionML = maxCorrectionML
        self.maxGapSeconds = maxGapSeconds
    }

    enum CodingKeys: String, CodingKey {
        case mlPerMinute, maxCorrectionML, maxGapSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DriftModel()
        mlPerMinute = try c.decodeIfPresent(Double.self, forKey: .mlPerMinute) ?? d.mlPerMinute
        maxCorrectionML = try c.decodeIfPresent(Double.self, forKey: .maxCorrectionML) ?? d.maxCorrectionML
        maxGapSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .maxGapSeconds) ?? d.maxGapSeconds
    }

    /// Correct an observed drop for drift over a gap. The correction never turns a real
    /// drop negative (it is clamped to the observed drop).
    public func correctedDrop(observedDrop: Double, gapSeconds: TimeInterval) -> Double {
        let drift = min(mlPerMinute * gapSeconds / 60, maxCorrectionML)
        return observedDrop - min(drift, max(observedDrop, 0))
    }
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
/// temperature, so absolute readings wander even when the water volume has not changed.
/// The rules here are deliberately asymmetric to match physical reality:
///
/// * **The bottle itself moving is not a level change.** No amount of drinking or filling
///   can move more water than the bottle holds, so a reading that jumps further than that
///   between two samples taken moments apart is the bottle being picked up or set down.
///   The baseline is held, so setting it back down is a change of nothing.
/// * **A drink is any decrease** past `minDrinkML`. Water leaving the bottle is the only
///   thing that lowers the true level, so a real drop is trusted — but a drop of more than
///   `confirmDrinkFractionOfCapacity` of the bottle has the same shape as a lift that was
///   too gentle to exceed the rule above, so it is held until it has stayed down for
///   `confirmSeconds`. A bottle that was only carried comes back long before that.
/// * **An increase is ignored** unless it is unmistakably a refill: either a jump of at
///   least `refillFractionOfCapacity` of the bottle, or a rise from below
///   `nearFullFraction` of capacity to above it (you top off to the brim). A bottle
///   already at the fill line cannot be topped off, which is how the zero creeping upward
///   stops reading as an endless series of small refills.
/// * **The baseline follows drift but not steps.** A creeping change of a millilitre or
///   two per reading is the load cell's zero wandering, so the baseline goes with it in
///   both directions and the next drink is still measured correctly. A step up that isn't
///   a refill is a different surface reading high, and is never adopted.
/// * **A move that stays is a new baseline, never a drink.** A reading further from the
///   baseline than the bottle holds is the bottle being handled — but one that stays there
///   for `confirmSeconds` was emptied, or the sensor was taken off and put back, and the
///   baseline goes to it with nothing logged. Left waiting, the old baseline was confirmed
///   against a freshly washed bottle as a 1008 mL drink out of a 621 mL bottle.
/// * **Creep is discounted over the interval.** The rate at which the zero has been
///   sinking (`creepMLPerSecond`, measured by a `CreepEstimator` on every weight sample)
///   says what it would have sunk since the last reading, and that comes off a drop
///   before the drop is judged a drink. Between readings seconds apart that is a
///   millilitre or two; across an interruption — the bottle in the hand, the sensor being
///   re-seated, the app relaunched — it is the whole of what came back as one step. A load
///   cell just re-seated after washing sank at 35 mL a minute, and logged the minutes as
///   drinks.
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
        /// Ignore any settled reading that maps below this level (bottle lifted or tilted).
        public var liftedBelowML: Double
        /// A change of more than this fraction of the bottle is the bottle being picked up
        /// or set down: nothing that happens to the water can move more than it holds.
        /// A little over 1 so that filling a dry bottle to the brim still reads as a refill.
        public var handlingFractionOfCapacity: Double
        /// How recent the previous reading has to be for the step between the two to mean
        /// anything. Over a disconnect the zero can wander by more than the bottle holds
        /// without the bottle being touched at all.
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

        public init(
            minDrinkML: Double = 15,
            refillFractionOfCapacity: Double = 0.5,
            nearFullFraction: Double = 0.9,
            liftedBelowML: Double = -60,
            handlingFractionOfCapacity: Double = 1.05,
            handlingWindowSeconds: TimeInterval = 120,
            confirmDrinkFractionOfCapacity: Double = 0.5,
            confirmSeconds: TimeInterval = 60,
            driftStepML: Double = 20
        ) {
            self.minDrinkML = minDrinkML
            self.refillFractionOfCapacity = refillFractionOfCapacity
            self.nearFullFraction = nearFullFraction
            self.liftedBelowML = liftedBelowML
            self.handlingFractionOfCapacity = handlingFractionOfCapacity
            self.handlingWindowSeconds = handlingWindowSeconds
            self.confirmDrinkFractionOfCapacity = confirmDrinkFractionOfCapacity
            self.confirmSeconds = confirmSeconds
            self.driftStepML = driftStepML
        }

        enum CodingKeys: String, CodingKey {
            case minDrinkML, refillFractionOfCapacity, nearFullFraction, liftedBelowML
            case handlingFractionOfCapacity, handlingWindowSeconds
            case confirmDrinkFractionOfCapacity, confirmSeconds, driftStepML
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Configuration()
            minDrinkML = try c.decodeIfPresent(Double.self, forKey: .minDrinkML) ?? d.minDrinkML
            refillFractionOfCapacity = try c.decodeIfPresent(Double.self, forKey: .refillFractionOfCapacity) ?? d.refillFractionOfCapacity
            nearFullFraction = try c.decodeIfPresent(Double.self, forKey: .nearFullFraction) ?? d.nearFullFraction
            liftedBelowML = try c.decodeIfPresent(Double.self, forKey: .liftedBelowML) ?? d.liftedBelowML
            handlingFractionOfCapacity = try c.decodeIfPresent(Double.self, forKey: .handlingFractionOfCapacity) ?? d.handlingFractionOfCapacity
            handlingWindowSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .handlingWindowSeconds) ?? d.handlingWindowSeconds
            confirmDrinkFractionOfCapacity = try c.decodeIfPresent(Double.self, forKey: .confirmDrinkFractionOfCapacity) ?? d.confirmDrinkFractionOfCapacity
            confirmSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .confirmSeconds) ?? d.confirmSeconds
            driftStepML = try c.decodeIfPresent(Double.self, forKey: .driftStepML) ?? d.driftStepML
        }
    }

    public var configuration: Configuration
    /// Bottle capacity in mL, needed for the refill thresholds. Set from the calibration.
    public var capacityML: Double
    /// The level the next change is measured against (best estimate of true current volume).
    public private(set) var baselineML: Double?
    private var lastReading: (levelML: Double, date: Date)?
    private var heldDrink: (fromML: Double, at: Date)?
    /// Since when the reading has sat further from the baseline than the bottle holds.
    /// A bottle picked up comes back within seconds; past `confirmSeconds` it was emptied
    /// or the sensor re-seated, and the baseline moves to wherever it is by then.
    private var heldMove: Date?
    /// How fast the resting reading is sinking on its own, in mL per second. Set by
    /// whoever sees the weight samples (a `CreepEstimator`): settled readings are too few
    /// to learn it from, since a creeping bottle reports every half minute and each report
    /// is further from the last than the stability tolerance, so nothing settles. Zero
    /// when it isn't sinking.
    public var creepMLPerSecond: Double = 0 {
        didSet { creepMLPerSecond = max(creepMLPerSecond, 0) }
    }

    /// When the drop currently being held back was first seen, if there is one. A drink
    /// confirmed later belongs at this moment, not at the reading that confirmed it.
    public var heldDrinkSince: Date? { heldDrink?.at }

    public init(configuration: Configuration = Configuration(), capacityML: Double = 621) {
        self.configuration = configuration
        self.capacityML = capacityML
    }

    @discardableResult
    public mutating func ingest(levelML: Double, at date: Date = Date()) -> LevelChange? {
        let previous = lastReading
        lastReading = (levelML: levelML, date: date)
        let sinceLast = previous.map { date.timeIntervalSince($0.date) }
        let followsOnFrom = sinceLast.map { $0 <= configuration.handlingWindowSeconds } ?? false
        let moreThanTheBottle = configuration.handlingFractionOfCapacity * capacityML

        // Further than the bottle could hold, moments after the last reading: the bottle
        // was picked up or set down. Water cannot do this, so the baseline stays where it
        // is and setting the bottle back down is a change of nothing — unless it stays.
        // Back within range, a move is over; a gap in the readings alone does not end
        // one, or an emptied bottle that went quiet would start its wait over.
        let farFromBase = baselineML.map { abs(levelML - $0) > moreThanTheBottle } ?? false
        if !farFromBase { heldMove = nil }
        if let base = baselineML, farFromBase, followsOnFrom {
            return moved(to: levelML, from: base, at: date)
        }

        // A reading well below empty means the bottle is lifted or tilted, not that it was
        // drained. Ignore it entirely so it can't register as a giant drink.
        if levelML < configuration.liftedBelowML { return nil }

        guard var base = baselineML else {
            baselineML = levelML
            return .baseline(levelML: levelML)
        }

        // What the zero would have sunk on its own since the last reading.
        let creepSinceLast = creepMLPerSecond * (sinceLast ?? 0)

        // A drop big enough to have been a lift is held until it proves itself.
        if let held = heldDrink {
            if levelML >= held.fromML - configuration.minDrinkML {
                // Back where it started: the bottle was moved, not drunk from. The next
                // reading measures against the level it had before it was picked up.
                heldDrink = nil
                baselineML = held.fromML
                return .handled(levelML: levelML, deltaML: levelML - held.fromML)
            }
            if held.fromML - levelML > moreThanTheBottle {
                // Further down than the bottle could have given: it was emptied, or the
                // sensor is back on it differently. Not water, however long it stays.
                heldDrink = nil
                return moved(to: levelML, from: held.fromML, at: date)
            }
            if date.timeIntervalSince(held.at) >= configuration.confirmSeconds {
                heldDrink = nil
                baselineML = levelML
                // Less what the zero sank on its own while it waited.
                let drop = held.fromML - levelML
                let volume = drop - min(creepMLPerSecond * date.timeIntervalSince(held.at), drop)
                guard volume >= configuration.minDrinkML else { return nil }
                return .drink(volumeML: volume, fromML: held.fromML, toML: levelML)
            }
            return nil // still down, still unproven
        }

        let delta = levelML - base

        // A drink: any trusted decrease.
        if delta <= -configuration.minDrinkML {
            if -delta > moreThanTheBottle {
                // After a gap the handling rule above has nothing to go on, but the water
                // still cannot have done this. Emptied, or re-seated: a move.
                return moved(to: levelML, from: base, at: date)
            }
            let drop = -delta - min(creepSinceLast, -delta)
            if drop < configuration.minDrinkML {
                // What the zero would have sunk on its own in the time. Not a drink; the
                // baseline follows it as it would have step by step.
                baselineML = levelML
                return nil
            }
            if drop >= configuration.confirmDrinkFractionOfCapacity * capacityML {
                // Half a bottleful in one step is also what picking the bottle up looks
                // like when the grip leaves some of the weight on the sensor. Hold it.
                heldDrink = (fromML: levelML + drop, at: date)
                return nil
            }
            baselineML = levelML
            return .drink(volumeML: drop, fromML: levelML + drop, toML: levelML)
        }

        // A refill: a large jump up, or topping off from below the fill line to the brim.
        // A bottle already at the fill line cannot be topped off, which is what keeps the
        // zero creeping upward from reading as an endless series of small refills.
        let fillLine = configuration.nearFullFraction * capacityML
        let bigJump = delta >= configuration.refillFractionOfCapacity * capacityML
        let toppedOff = base < fillLine && levelML >= fillLine && delta >= configuration.minDrinkML
        if bigJump || toppedOff {
            baselineML = levelML
            return .refill(volumeML: delta, fromML: base, toML: levelML)
        }

        // Small change: adopt drift, in either direction, so that the next drink is still
        // measured from where the bottle really sits. An increase that arrives all at once
        // is a different surface reading high rather than the zero creeping, and is never
        // adopted — otherwise it would quietly inflate the volume of the next drink.
        let crept = (previous.map { levelML - $0.levelML } ?? delta) < configuration.driftStepML
        if levelML < base || crept { base = levelML }
        baselineML = base
        return nil
    }

    /// The bottle is further from its baseline than it could hold. Picked up, it comes
    /// back within seconds and the baseline is right where it was. Still there after
    /// `confirmSeconds`, it was emptied or the sensor was re-seated, and the baseline
    /// moves to it. Either way nothing is logged: water did not do this.
    private mutating func moved(to levelML: Double, from base: Double, at date: Date) -> LevelChange {
        let since = heldMove ?? date
        heldMove = since
        if date.timeIntervalSince(since) >= configuration.confirmSeconds {
            heldMove = nil
            baselineML = levelML
        }
        return .handled(levelML: levelML, deltaML: levelML - base)
    }

    /// Start over from a baseline. Restoring from disk also brings the time of the last
    /// reading and the creep measured by then: a new process's first reading is then
    /// judged over the gap since the last one, with the creep that gap cost taken off.
    /// Without that, the half-minute a relaunch takes came back as an 18 mL "drink".
    public mutating func reset(baselineML: Double? = nil, lastReadingAt: Date? = nil, creepMLPerSecond: Double = 0) {
        self.baselineML = baselineML
        if let baselineML, let lastReadingAt {
            lastReading = (levelML: baselineML, date: lastReadingAt)
        } else {
            lastReading = nil
        }
        heldDrink = nil
        heldMove = nil
        self.creepMLPerSecond = creepMLPerSecond
    }

    /// Forget a drop that was waiting to prove itself, keeping the level it started from.
    ///
    /// Called when the connection drops: the bottle is about to be away for a quarter of
    /// an hour, and the saved level it was measured against is what cross-disconnect
    /// recovery compares the next reading with. Left in place, the drink would be
    /// recovered there and confirmed here, and counted twice.
    public mutating func forgetHeldDrink() {
        heldDrink = nil
        heldMove = nil
    }
}

/// Decides when a run of readings below empty means the zero has moved rather than the
/// water — and, just as importantly, when it doesn't.
///
/// A bottle cannot hold less than nothing, so settled readings that stay below empty mean
/// the load cell's zero has crept and every one of those readings is being thrown away as
/// "lifted". Moving the zero back is the fix. But a bottle held in a hand also reads below
/// empty, holds still, and does it for as long as you carry it — and re-zeroing onto one
/// is far worse than not re-zeroing at all, because it moves the zero by the weight of the
/// whole bottle and every reading afterwards is wrong by that much.
///
/// The two are told apart by how the reading got there. Drift creeps: a millilitre or two
/// per reading, so the run begins with a step no bigger than any other. Picking the bottle
/// up is a cliff — hundreds of millilitres between two readings fifteen seconds apart, and
/// no drink can do the same, since a bottle already reading near empty has nothing like
/// that left to give.
public struct ZeroDriftWatcher: Sendable {
    /// A settled reading this far below empty means the zero has drifted. Nil to never
    /// move the zero on its own.
    public var belowML: Double?
    /// How many readings in a row, over how long, before believing it.
    public var samples: Int
    public var minimumSeconds: TimeInterval
    /// A drop of at least this much into the run means the bottle was picked up.
    public var maxStepML: Double
    /// How recent the previous reading has to be for the step to mean anything.
    public var stepWindowSeconds: TimeInterval

    private var streak = 0
    private var since: Date?
    private var beganWithAStep = false

    public init(belowML: Double? = -25, samples: Int = 3, minimumSeconds: TimeInterval = 45,
                maxStepML: Double = 100, stepWindowSeconds: TimeInterval = 120) {
        self.belowML = belowML
        self.samples = samples
        self.minimumSeconds = minimumSeconds
        self.maxStepML = maxStepML
        self.stepWindowSeconds = stepWindowSeconds
    }

    /// Feed every settled reading the tracker made nothing of. True means move the zero
    /// to this reading.
    public mutating func shouldRezero(levelML: Double, at date: Date,
                                      after previous: (levelML: Double, date: Date)?) -> Bool {
        guard let belowML else { return false }
        guard levelML < belowML else {
            reset()
            return false
        }
        if streak == 0, let previous, date.timeIntervalSince(previous.date) <= stepWindowSeconds,
           previous.levelML - levelML >= maxStepML {
            beganWithAStep = true
        }
        streak += 1
        let since = since ?? date
        self.since = since
        guard !beganWithAStep, streak >= samples,
              date.timeIntervalSince(since) >= minimumSeconds else { return false }
        reset()
        return true
    }

    public mutating func reset() {
        streak = 0
        since = nil
        beganWithAStep = false
    }
}
