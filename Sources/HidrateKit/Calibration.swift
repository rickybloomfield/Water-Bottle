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

    public var volumeML: Double {
        switch self {
        case .baseline: 0
        case .drink(let v, _, _), .refill(let v, _, _): v
        }
    }

    public var isDrink: Bool { if case .drink = self { true } else { false } }
    public var isRefill: Bool { if case .refill = self { true } else { false } }
    public var isBaseline: Bool { if case .baseline = self { true } else { false } }
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

/// Turns settled, calibrated level readings into drink and refill events.
///
/// The PRO 2 load cell reads slightly differently on different surfaces and drifts with
/// temperature, so absolute readings wander even when the water volume has not changed.
/// The rules here are deliberately asymmetric to match physical reality:
///
/// * **A drink is any decrease** past `minDrinkML`. Water leaving the bottle is the only
///   thing that lowers the true level, so a real drop is trusted.
/// * **An increase is ignored** unless it is unmistakably a refill: either a jump of at
///   least `refillFractionOfCapacity` of the bottle, or the level reaching
///   `nearFullFraction` of capacity (you top off to the brim). Small increases are surface
///   or thermal noise and must never be logged as "water added".
/// * **The baseline never inflates on a small change.** A small increase is dropped and the
///   baseline held; a small decrease is adopted. So placing the bottle on a surface that
///   reads a little high cannot quietly raise the recorded volume and inflate the next
///   drink.
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

        public init(
            minDrinkML: Double = 15,
            refillFractionOfCapacity: Double = 0.5,
            nearFullFraction: Double = 0.9,
            liftedBelowML: Double = -60
        ) {
            self.minDrinkML = minDrinkML
            self.refillFractionOfCapacity = refillFractionOfCapacity
            self.nearFullFraction = nearFullFraction
            self.liftedBelowML = liftedBelowML
        }

        enum CodingKeys: String, CodingKey {
            case minDrinkML, refillFractionOfCapacity, nearFullFraction, liftedBelowML
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Configuration()
            minDrinkML = try c.decodeIfPresent(Double.self, forKey: .minDrinkML) ?? d.minDrinkML
            refillFractionOfCapacity = try c.decodeIfPresent(Double.self, forKey: .refillFractionOfCapacity) ?? d.refillFractionOfCapacity
            nearFullFraction = try c.decodeIfPresent(Double.self, forKey: .nearFullFraction) ?? d.nearFullFraction
            liftedBelowML = try c.decodeIfPresent(Double.self, forKey: .liftedBelowML) ?? d.liftedBelowML
        }
    }

    public var configuration: Configuration
    /// Bottle capacity in mL, needed for the refill thresholds. Set from the calibration.
    public var capacityML: Double
    /// The level the next change is measured against (best estimate of true current volume).
    public private(set) var baselineML: Double?

    public init(configuration: Configuration = Configuration(), capacityML: Double = 621) {
        self.configuration = configuration
        self.capacityML = capacityML
    }

    @discardableResult
    public mutating func ingest(levelML: Double, at date: Date = Date()) -> LevelChange? {
        // A reading well below empty means the bottle is lifted or tilted, not that it was
        // drained. Ignore it entirely so it can't register as a giant drink.
        if levelML < configuration.liftedBelowML { return nil }

        guard let base = baselineML else {
            baselineML = levelML
            return .baseline(levelML: levelML)
        }
        let delta = levelML - base

        // A drink: any trusted decrease.
        if delta <= -configuration.minDrinkML {
            baselineML = levelML
            return .drink(volumeML: -delta, fromML: base, toML: levelML)
        }

        // A refill: a large jump up, or topping off to near-full.
        let bigJump = delta >= configuration.refillFractionOfCapacity * capacityML
        let toppedOff = levelML >= configuration.nearFullFraction * capacityML && delta >= configuration.minDrinkML
        if bigJump || toppedOff {
            baselineML = levelML
            return .refill(volumeML: delta, fromML: base, toML: levelML)
        }

        // Small change: never inflate the baseline. Adopt a small decrease (drift or a
        // sub-threshold sip); drop a small increase (surface/thermal noise).
        if levelML < base { baselineML = levelML }
        return nil
    }

    public mutating func reset(baselineML: Double? = nil) {
        self.baselineML = baselineML
    }
}
