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
///   baseline than the bottle holds, moments after the last, is the bottle being handled —
///   but one that stays there for `confirmSeconds` was emptied, or the sensor was taken
///   off and put back, and the baseline goes to it with nothing logged. Across a gap the
///   same drop is held like any large one and reported as measured; the model cuts it to
///   what the bottle held, which for a bottle believed empty — a washed one, usually — is
///   nothing. The old baseline was once confirmed against a freshly washed bottle as a
///   1008 mL drink out of a 621 mL bottle; now the most that can be is what was in it.
/// * **Creep is discounted over the interval.** The rate at which the zero has been
///   sinking (`creepMLPerSecond`, measured by a `CreepEstimator` on every weight sample)
///   says what it would have sunk since the last reading, and that comes off a drop
///   before the drop is judged a drink. Between readings seconds apart that is a
///   millilitre or two; while a drop is held it is the whole of what the zero sank in the
///   wait. A load cell just re-seated after washing sank at 35 mL a minute, and logged
///   the minutes as drinks.
/// * **Nothing is measured across a gap.** A drink is a drop the tracker watched happen,
///   between readings within `handlingWindowSeconds` of each other in one connection.
///   After a silence, or a reconnect, the reading the bottle comes back at is adopted as
///   the new baseline, up or down, and only a refill is reported. If it comes back in a
///   hand — further below than the bottle could have given — the baseline waits until it
///   rests, and where it rests is adopted; the baseline from before the gap is never
///   measured against. A slow slide that arrives as one step after an hour asleep is not
///   a drink — a bottle nobody touched logged four of them in a night — and a real drink
///   taken while the bottle was away is not measured either; it is reconciled when the
///   bottle is marked empty.
/// * **Below empty is still a reading.** A sunk zero puts an empty bottle under nothing,
///   and the water in it is measured from there like anywhere else. Nothing here decides
///   where empty is; that is the person's to say, on the bottle's page.
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
        /// A change of more than this fraction of the bottle is the bottle being picked up
        /// or set down: nothing that happens to the water can move more than it holds.
        /// A little over 1 so that filling a dry bottle to the brim still reads as a refill.
        public var handlingFractionOfCapacity: Double
        /// How recent the previous reading has to be for the two to follow on from one
        /// another — for a step between them to be a lift, and for a drop between them to
        /// be a drink. Further apart than this, or in a new connection, the bottle was out
        /// of sight and nothing that happened meanwhile is measured.
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
            handlingFractionOfCapacity: Double = 1.05,
            handlingWindowSeconds: TimeInterval = 120,
            confirmDrinkFractionOfCapacity: Double = 0.5,
            confirmSeconds: TimeInterval = 60,
            driftStepML: Double = 20
        ) {
            self.minDrinkML = minDrinkML
            self.refillFractionOfCapacity = refillFractionOfCapacity
            self.nearFullFraction = nearFullFraction
            self.handlingFractionOfCapacity = handlingFractionOfCapacity
            self.handlingWindowSeconds = handlingWindowSeconds
            self.confirmDrinkFractionOfCapacity = confirmDrinkFractionOfCapacity
            self.confirmSeconds = confirmSeconds
            self.driftStepML = driftStepML
        }

        enum CodingKeys: String, CodingKey {
            case minDrinkML, refillFractionOfCapacity, nearFullFraction
            case handlingFractionOfCapacity, handlingWindowSeconds
            case confirmDrinkFractionOfCapacity, confirmSeconds, driftStepML
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
        }
    }

    public var configuration: Configuration
    /// Bottle capacity in mL, needed for the refill thresholds. Set from the calibration.
    public var capacityML: Double
    /// The level the next change is measured against (best estimate of true current volume).
    public private(set) var baselineML: Double?
    private var lastReading: (levelML: Double, date: Date)?
    /// A drop being held until it proves itself.
    private var heldDrink: (fromML: Double, at: Date)?
    /// True after a gap opened with the bottle in a hand or off its sensor. The baseline
    /// from before the gap is kept but is not measured against: where the bottle rests
    /// next is adopted, and nothing between is logged.
    private var awaitingRest = false
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
        let followsOnFrom = !awaitingRest && (sinceLast.map { $0 <= configuration.handlingWindowSeconds } ?? false)
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

        guard var base = baselineML else {
            baselineML = levelML
            return .baseline(levelML: levelML)
        }

        let fillLine = configuration.nearFullFraction * capacityML
        func refill(from base: Double) -> LevelChange? {
            let delta = levelML - base
            let bigJump = delta >= configuration.refillFractionOfCapacity * capacityML
            let toppedOff = base < fillLine && levelML >= fillLine && delta >= configuration.minDrinkML
            return bigJump || toppedOff ? .refill(volumeML: delta, fromML: base, toML: levelML) : nil
        }

        // Across a gap nothing is measured. Whatever the bottle did while out of sight,
        // the reading it comes back at is where the next drink is measured from, up or
        // down — a drink is only ever a drop the app watched happen, so a slow slide that
        // arrives as one step after an hour asleep is not one (four such "drinks" were
        // logged one night, from a bottle nobody touched), and neither is a real drink
        // taken while the bottle was away, which Empty reconciles. The exception is a
        // refill: a rise of most of a bottleful, or to the brim, is unmistakable.
        if !followsOnFrom {
            heldDrink = nil
            if levelML < base, base - levelML > moreThanTheBottle {
                // Further below than the bottle could have given: it is in a hand, or off
                // its sensor — the bottle wakes and connects because it was picked up, as
                // often as not, so a session's first reading is frequently this. Not a
                // place to put the baseline. Not a place to measure from, either: where
                // the bottle rests next is adopted, and the difference from before the
                // gap is not a drink — a bottle set back down after an hour away read
                // 160 mL lighter with nothing drunk. A lift that stays becomes the
                // baseline in a minute, as any move does.
                awaitingRest = true
                return moved(to: levelML, from: base, at: date)
            }
            awaitingRest = false
            heldMove = nil
            baselineML = levelML
            return refill(from: base)
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
        if let refill = refill(from: base) {
            baselineML = levelML
            return refill
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
            awaitingRest = false
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
        awaitingRest = false
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

    /// A new connection. Whatever the bottle did while it was out of sight is not
    /// measured: the next reading is where the bottle now sits, not a step from the last
    /// one seen, however recent that was.
    public mutating func sessionStarted() {
        lastReading = nil
        heldDrink = nil
        heldMove = nil
        awaitingRest = false
    }
}
