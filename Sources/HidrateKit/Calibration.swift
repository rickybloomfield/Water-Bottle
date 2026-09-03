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
    public var mlPerMinute: Double
    /// Don't attempt drift-corrected recovery across gaps longer than this.
    public var maxGapSeconds: TimeInterval

    public init(mlPerMinute: Double = 15, maxGapSeconds: TimeInterval = 3600) {
        self.mlPerMinute = mlPerMinute
        self.maxGapSeconds = maxGapSeconds
    }

    /// Correct an observed drop for drift over a gap. The correction never turns a real
    /// drop negative (it is clamped to the observed drop).
    public func correctedDrop(observedDrop: Double, gapSeconds: TimeInterval) -> Double {
        let drift = mlPerMinute * gapSeconds / 60
        return observedDrop - min(drift, max(observedDrop, 0))
    }
}

/// Turns calibrated level samples into drink and refill events.
///
/// Designed around how the PRO 2 sensor behaves:
///
/// * At rest it notifies every ~15 s and drifts slowly (thermal). Slow-cadence samples are
///   adopted as the resting level unless they jump by more than a drink/refill threshold.
/// * When handled it switches to ~2 s notifications. Only readings that settle (N fast
///   samples within `noiseML`) are compared against the resting level.
/// * The sensor weighs the water resting on the base, so a tilted bottle reads *lower*
///   (like a partly empty one) rather than far below empty. That is why a settled reading
///   during handling needs several agreeing fast samples (`settleSamples`, ~15 s): nobody
///   holds a bottle tilted perfectly still that long. Anything below `liftedBelowML`
///   is discarded outright.
///
/// Feed it every sample, not just stable ones, with its timestamp.
public struct LevelTracker: Sendable {
    public struct Configuration: Sendable, Equatable, Codable {
        public var minDrinkML: Double
        public var minRefillML: Double
        /// Settle tolerance: spread allowed across `settleSamples` fast samples.
        public var noiseML: Double
        /// Readings below this level mean the bottle is lifted or tilted; ignore them.
        public var liftedBelowML: Double
        /// Samples arriving faster than this are "handling" samples.
        public var fastCadenceSeconds: TimeInterval
        public var settleSamples: Int

        public init(
            minDrinkML: Double = 15, minRefillML: Double = 30, noiseML: Double = 6,
            liftedBelowML: Double = -40, fastCadenceSeconds: TimeInterval = 6, settleSamples: Int = 5
        ) {
            self.minDrinkML = minDrinkML
            self.minRefillML = minRefillML
            self.noiseML = noiseML
            self.liftedBelowML = liftedBelowML
            self.fastCadenceSeconds = fastCadenceSeconds
            self.settleSamples = settleSamples
        }

        enum CodingKeys: String, CodingKey {
            case minDrinkML, minRefillML, noiseML, liftedBelowML, fastCadenceSeconds, settleSamples
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Configuration()
            minDrinkML = try c.decodeIfPresent(Double.self, forKey: .minDrinkML) ?? d.minDrinkML
            minRefillML = try c.decodeIfPresent(Double.self, forKey: .minRefillML) ?? d.minRefillML
            noiseML = try c.decodeIfPresent(Double.self, forKey: .noiseML) ?? d.noiseML
            liftedBelowML = try c.decodeIfPresent(Double.self, forKey: .liftedBelowML) ?? d.liftedBelowML
            fastCadenceSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .fastCadenceSeconds) ?? d.fastCadenceSeconds
            settleSamples = try c.decodeIfPresent(Int.self, forKey: .settleSamples) ?? d.settleSamples
        }
    }

    public var configuration: Configuration
    /// The level the next change is measured against.
    public private(set) var baselineML: Double?
    public private(set) var isHandling = false
    public var isBottleHandled: Bool { isHandling }
    private var lastSampleAt: Date?
    private var recent: [Double] = []
    /// A sample that arrived at slow cadence. It is only a rest reading if the *next*
    /// sample is also slow; if the next one arrives fast, it was the start of handling.
    private var pending: Double?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public mutating func ingest(levelML: Double, at date: Date = Date()) -> LevelChange? {
        let interval = lastSampleAt.map { date.timeIntervalSince($0) } ?? .infinity
        lastSampleAt = date
        let fast = interval < configuration.fastCadenceSeconds

        guard baselineML != nil else {
            baselineML = levelML
            return .baseline(levelML: levelML)
        }

        if levelML < configuration.liftedBelowML {
            // Lifted or tilted. A rest sample that preceded the lift is confirmed as rest.
            let result = fast ? nil : commitPending()
            pending = nil
            recent = []
            isHandling = true
            return result
        }

        if !fast {
            // Slow cadence: confirm the previous slow sample as a rest reading and hold this one.
            let result = commitPending()
            pending = levelML
            recent = []
            isHandling = false
            return result
        }

        // Fast cadence: the bottle is being handled.
        isHandling = true
        if let held = pending {
            recent.append(held)
            pending = nil
        }
        recent.append(levelML)
        if recent.count > configuration.settleSamples { recent.removeFirst(recent.count - configuration.settleSamples) }
        guard recent.count == configuration.settleSamples,
              let lo = recent.min(), let hi = recent.max(), hi - lo <= configuration.noiseML else { return nil }
        let settled = recent.reduce(0, +) / Double(recent.count)
        recent = []
        return compare(settled)
    }

    private mutating func commitPending() -> LevelChange? {
        guard let held = pending else { return nil }
        pending = nil
        return compare(held)
    }

    private mutating func compare(_ level: Double) -> LevelChange? {
        guard let base = baselineML else {
            baselineML = level
            return .baseline(levelML: level)
        }
        let drop = base - level
        baselineML = level
        if drop >= configuration.minDrinkML {
            return .drink(volumeML: drop, fromML: base, toML: level)
        }
        if -drop >= configuration.minRefillML {
            return .refill(volumeML: -drop, fromML: base, toML: level)
        }
        return nil
    }

    /// Forget the baseline (for example after recalibrating).
    public mutating func reset(baselineML: Double? = nil) {
        self.baselineML = baselineML
        recent = []
        pending = nil
        lastSampleAt = nil
        isHandling = false
    }
}
