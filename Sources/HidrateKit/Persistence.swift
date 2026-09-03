import Foundation

/// Persists the calibration and the last known water level in `UserDefaults`.
public final class CalibrationStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let calibrationKey: String
    private let baselineKey: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "HidrateKit") {
        self.defaults = defaults
        calibrationKey = keyPrefix + ".calibration"
        baselineKey = keyPrefix + ".baselineML"
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
}
