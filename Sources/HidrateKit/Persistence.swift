import Foundation

/// Persists the calibration and the last known water level in `UserDefaults`.
public final class CalibrationStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let calibrationKey: String
    private let baselineKey: String
    private let lastLevelKey: String
    private let lastLevelDateKey: String
    private let lastRawKey: String
    private let lastRawDateKey: String
    private let believedLevelKey: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "HidrateKit") {
        self.defaults = defaults
        calibrationKey = keyPrefix + ".calibration"
        baselineKey = keyPrefix + ".baselineML"
        lastLevelKey = keyPrefix + ".lastLevelML"
        lastLevelDateKey = keyPrefix + ".lastLevelDate"
        lastRawKey = keyPrefix + ".lastRaw"
        lastRawDateKey = keyPrefix + ".lastRawDate"
        believedLevelKey = keyPrefix + ".believedLevelML"
    }

    public func loadCalibration() -> BottleCalibration? {
        guard let data = defaults.data(forKey: calibrationKey) else { return nil }
        return try? JSONDecoder().decode(BottleCalibration.self, from: data)
    }

    public func saveCalibration(_ calibration: BottleCalibration?) {
        guard let calibration, let data = try? JSONEncoder().encode(calibration) else {
            defaults.removeObject(forKey: calibrationKey)
            return
        }
        defaults.set(data, forKey: calibrationKey)
    }

    public func loadBaselineML() -> Double? {
        defaults.object(forKey: baselineKey) as? Double
    }

    public func saveBaselineML(_ value: Double?) {
        if let value { defaults.set(value, forKey: baselineKey) } else { defaults.removeObject(forKey: baselineKey) }
    }

    /// The last settled resting level and when it was seen, used to recover level changes
    /// that happened while the bottle was disconnected.
    public func loadLastLevel() -> (levelML: Double, date: Date)? {
        guard defaults.object(forKey: lastLevelKey) != nil,
              let date = defaults.object(forKey: lastLevelDateKey) as? Date else { return nil }
        return (defaults.double(forKey: lastLevelKey), date)
    }

    public func saveLastLevel(_ levelML: Double, date: Date) {
        defaults.set(levelML, forKey: lastLevelKey)
        defaults.set(date, forKey: lastLevelDateKey)
    }

    public func clearLastLevel() {
        defaults.removeObject(forKey: lastLevelKey)
        defaults.removeObject(forKey: lastLevelDateKey)
    }

    /// The last settled *raw* reading, kept separately from `lastLevel` and only ever used
    /// to draw a level before the bottle reconnects. Storing the raw rather than the
    /// millilitres means a recalibration reinterprets it instead of invalidating it, so
    /// the bottle isn't drawn empty for the rest of the day after you recalibrate.
    public func loadLastRaw() -> (raw: Int, date: Date)? {
        guard defaults.object(forKey: lastRawKey) != nil,
              let date = defaults.object(forKey: lastRawDateKey) as? Date else { return nil }
        return (defaults.integer(forKey: lastRawKey), date)
    }

    public func saveLastRaw(_ raw: Int, date: Date) {
        defaults.set(raw, forKey: lastRawKey)
        defaults.set(date, forKey: lastRawDateKey)
    }

    /// The level carried forward across drinks and refills, rather than read off the
    /// scale. See `HidrateBottleModel.believedLevelML`.
    public func loadBelievedLevelML() -> Double? {
        defaults.object(forKey: believedLevelKey) as? Double
    }

    public func saveBelievedLevelML(_ value: Double?) {
        if let value { defaults.set(value, forKey: believedLevelKey) } else { defaults.removeObject(forKey: believedLevelKey) }
    }
}
