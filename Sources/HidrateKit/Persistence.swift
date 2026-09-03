import Foundation

/// Persists the calibration and the last known water level in `UserDefaults`.
public final class CalibrationStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let calibrationKey: String
    private let baselineKey: String
    private let lastLevelKey: String
    private let lastLevelDateKey: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "HidrateKit") {
        self.defaults = defaults
        calibrationKey = keyPrefix + ".calibration"
        baselineKey = keyPrefix + ".baselineML"
        lastLevelKey = keyPrefix + ".lastLevelML"
        lastLevelDateKey = keyPrefix + ".lastLevelDate"
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
}
