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
}

/// Turns a sequence of stable, calibrated level readings into drink and refill events.
///
/// A drink is registered when the level falls at least `minDrinkML` below the last
/// settled baseline. Sub-threshold changes are ignored, but the baseline is not moved
/// for them, so three small sips add up to one drink event. A sub-threshold change that
/// persists for `driftAdoptAfter` is treated as sensor drift and adopted silently.
public struct LevelTracker: Sendable {
    public struct Configuration: Sendable, Equatable, Codable {
        public var minDrinkML: Double
        public var minRefillML: Double
        public var noiseML: Double
        public var driftAdoptAfter: TimeInterval

        public init(minDrinkML: Double = 15, minRefillML: Double = 30, noiseML: Double = 4, driftAdoptAfter: TimeInterval = 600) {
            self.minDrinkML = minDrinkML
            self.minRefillML = minRefillML
            self.noiseML = noiseML
            self.driftAdoptAfter = driftAdoptAfter
        }
    }

    public var configuration: Configuration
    public private(set) var baselineML: Double?
    private var candidate: (levelML: Double, since: Date)?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public mutating func ingest(levelML: Double, at date: Date = Date()) -> LevelChange? {
        guard let base = baselineML else {
            baselineML = levelML
            return .baseline(levelML: levelML)
        }
        let drop = base - levelML
        if drop >= configuration.minDrinkML {
            baselineML = levelML
            candidate = nil
            return .drink(volumeML: drop, fromML: base, toML: levelML)
        }
        if -drop >= configuration.minRefillML {
            baselineML = levelML
            candidate = nil
            return .refill(volumeML: -drop, fromML: base, toML: levelML)
        }
        if abs(drop) < configuration.noiseML {
            candidate = nil
            return nil
        }
        if let candidate, abs(candidate.levelML - levelML) < configuration.noiseML {
            if date.timeIntervalSince(candidate.since) >= configuration.driftAdoptAfter {
                baselineML = levelML
                self.candidate = nil
            }
        } else {
            candidate = (levelML, date)
        }
        return nil
    }

    /// Forget the baseline (for example after recalibrating or reconnecting).
    public mutating func reset(baselineML: Double? = nil) {
        self.baselineML = baselineML
        candidate = nil
    }
}
