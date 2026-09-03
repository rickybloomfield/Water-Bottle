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
    @Test func detectsDrinksRefillsAndIgnoresNoise() {
        var tracker = LevelTracker(configuration: .init(minDrinkML: 15, minRefillML: 30, noiseML: 4, driftAdoptAfter: 600))
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(tracker.ingest(levelML: 600, at: t0) == .baseline(levelML: 600))
        #expect(tracker.ingest(levelML: 598, at: t0 + 2) == nil)
        #expect(tracker.ingest(levelML: 580, at: t0 + 4) == .drink(volumeML: 20, fromML: 600, toML: 580))
        #expect(tracker.ingest(levelML: 540, at: t0 + 6) == .drink(volumeML: 40, fromML: 580, toML: 540))
        #expect(tracker.ingest(levelML: 600, at: t0 + 8) == .refill(volumeML: 60, fromML: 540, toML: 600))
        #expect(tracker.baselineML == 600)
    }

    @Test func smallSipsAccumulate() {
        var tracker = LevelTracker(configuration: .init(minDrinkML: 15, minRefillML: 30, noiseML: 4, driftAdoptAfter: 600))
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = tracker.ingest(levelML: 600, at: t0)
        #expect(tracker.ingest(levelML: 592, at: t0 + 10) == nil)
        #expect(tracker.ingest(levelML: 586, at: t0 + 20) == nil)
        #expect(tracker.ingest(levelML: 570, at: t0 + 30) == .drink(volumeML: 30, fromML: 600, toML: 570))
    }

    @Test func persistentSubThresholdChangeIsAdoptedAsDrift() {
        var tracker = LevelTracker(configuration: .init(minDrinkML: 15, minRefillML: 30, noiseML: 4, driftAdoptAfter: 600))
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = tracker.ingest(levelML: 600, at: t0)
        #expect(tracker.ingest(levelML: 594, at: t0 + 10) == nil)
        #expect(tracker.ingest(levelML: 594, at: t0 + 300) == nil)
        #expect(tracker.baselineML == 600)
        #expect(tracker.ingest(levelML: 594, at: t0 + 700) == nil)
        #expect(tracker.baselineML == 594)
        // 14 mL below the new baseline is still under the threshold.
        #expect(tracker.ingest(levelML: 580, at: t0 + 710) == nil)
        #expect(tracker.ingest(levelML: 578, at: t0 + 720) == .drink(volumeML: 16, fromML: 594, toML: 578))
    }

    @Test func resetRestoresBaseline() {
        var tracker = LevelTracker()
        _ = tracker.ingest(levelML: 300)
        tracker.reset(baselineML: 500)
        #expect(tracker.baselineML == 500)
        tracker.reset()
        #expect(tracker.baselineML == nil)
    }
}
