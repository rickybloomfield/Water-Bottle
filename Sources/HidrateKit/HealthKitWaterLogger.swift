#if canImport(HealthKit)
import Foundation
import HealthKit

/// Describes the bottle to HealthKit so samples carry a device record.
public struct WaterSourceDevice: Sendable, Hashable {
    public var name: String
    public var manufacturer: String
    public var model: String?
    public var hardwareVersion: String?
    public var firmwareVersion: String?
    public var softwareVersion: String?
    public var localIdentifier: String?

    public init(
        name: String = "HidrateSpark",
        manufacturer: String = "Hidrate Inc.",
        model: String? = nil,
        hardwareVersion: String? = nil,
        firmwareVersion: String? = nil,
        softwareVersion: String? = nil,
        localIdentifier: String? = nil
    ) {
        self.name = name
        self.manufacturer = manufacturer
        self.model = model
        self.hardwareVersion = hardwareVersion
        self.firmwareVersion = firmwareVersion
        self.softwareVersion = softwareVersion
        self.localIdentifier = localIdentifier
    }

    /// Build from the bottle's Device Information service values.
    public init(deviceInformation: [String: String], localIdentifier: String? = nil) {
        self.init(
            name: deviceInformation["Model Number"].map { "HidrateSpark \($0)" } ?? "HidrateSpark",
            manufacturer: deviceInformation["Manufacturer Name"] ?? "Hidrate Inc.",
            model: deviceInformation["Model Number"],
            hardwareVersion: deviceInformation["Hardware Revision"],
            firmwareVersion: deviceInformation["Firmware Revision"],
            softwareVersion: deviceInformation["Software Revision"],
            localIdentifier: localIdentifier
        )
    }

    fileprivate var hkDevice: HKDevice {
        HKDevice(
            name: name, manufacturer: manufacturer, model: model,
            hardwareVersion: hardwareVersion, firmwareVersion: firmwareVersion,
            softwareVersion: softwareVersion, localIdentifier: localIdentifier, udiDeviceIdentifier: nil
        )
    }
}

/// One water sample as stored in Health, from any app.
public struct WaterSample: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let date: Date
    public let milliliters: Double
    public let sourceName: String
    public let sourceBundleID: String
    /// True when this app wrote the sample.
    public let isFromThisApp: Bool
}

/// Writes water intake to HealthKit as `dietaryWater` samples.
public final class HealthKitWaterLogger: @unchecked Sendable {
    private var observerQuery: HKObserverQuery?
    public enum LoggerError: Error, LocalizedError {
        case unavailable
        case notAuthorized

        public var errorDescription: String? {
            switch self {
            case .unavailable: "HealthKit is not available on this device."
            case .notAuthorized: "Water intake writing has not been authorized in Health."
            }
        }
    }

    /// Metadata keys attached to every sample so other apps (and you) can tell them apart.
    public enum MetadataKey {
        public static let source = "HidrateKit.source"
        public static let rawBefore = "HidrateKit.rawBefore"
        public static let rawAfter = "HidrateKit.rawAfter"
        public static let eventID = "HidrateKit.eventID"
    }

    public static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let store = HKHealthStore()
    private let waterType = HKQuantityType(.dietaryWater)
    private let unit = HKUnit.literUnit(with: .milli)

    public init() {}

    public var sharingStatus: HKAuthorizationStatus {
        store.authorizationStatus(for: waterType)
    }

    public var canWrite: Bool { sharingStatus == .sharingAuthorized }

    public func requestAuthorization() async throws {
        guard Self.isAvailable else { throw LoggerError.unavailable }
        try await store.requestAuthorization(toShare: [waterType], read: [waterType])
    }

    /// Saves one water sample and returns its HealthKit UUID (keep it to allow undo).
    @discardableResult
    public func logWater(
        milliliters: Double,
        at date: Date,
        device: WaterSourceDevice? = nil,
        metadata: [String: String] = [:]
    ) async throws -> UUID {
        guard Self.isAvailable else { throw LoggerError.unavailable }
        guard canWrite else { throw LoggerError.notAuthorized }
        let quantity = HKQuantity(unit: unit, doubleValue: milliliters)
        var meta: [String: Any] = [HKMetadataKeyWasUserEntered: false]
        for (key, value) in metadata { meta[key] = value }
        let sample = HKQuantitySample(
            type: waterType, quantity: quantity, start: date, end: date,
            device: device?.hkDevice, metadata: meta
        )
        try await store.save(sample)
        return sample.uuid
    }

    /// Deletes a sample this app wrote earlier.
    public func deleteWater(uuid: UUID) async throws {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: waterType, predicate: HKQuery.predicateForObject(with: uuid))],
            sortDescriptors: []
        )
        let samples = try await descriptor.result(for: store)
        guard !samples.isEmpty else { return }
        try await store.delete(samples)
    }

    /// Total water logged (by any app) between two dates.
    public func totalML(from start: Date, to end: Date) async throws -> Double {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: waterType, predicate: predicate),
            options: .cumulativeSum
        )
        let statistics = try await descriptor.result(for: store)
        return statistics?.sumQuantity()?.doubleValue(for: unit) ?? 0
    }

    /// Every water sample between two dates, newest first, with its source.
    public func samples(from start: Date, to end: Date) async throws -> [WaterSample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: waterType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
        )
        let results = try await descriptor.result(for: store)
        let me = Bundle.main.bundleIdentifier ?? ""
        return results.map { sample in
            WaterSample(
                id: sample.uuid,
                date: sample.startDate,
                milliliters: sample.quantity.doubleValue(for: unit),
                sourceName: sample.sourceRevision.source.name,
                sourceBundleID: sample.sourceRevision.source.bundleIdentifier,
                isFromThisApp: sample.sourceRevision.source.bundleIdentifier == me
            )
        }
    }

    public func todaySamples(calendar: Calendar = .current) async throws -> [WaterSample] {
        let start = calendar.startOfDay(for: Date())
        return try await samples(from: start, to: Date())
    }

    /// Calls `onChange` whenever water samples change in Health (any app), so the UI can
    /// refresh without polling. Only one observer runs at a time.
    /// Watch for water samples from any app. `onChange` is handed a completion it must
    /// call once it has finished; with background delivery enabled the system keeps
    /// redelivering until it does.
    public func startObservingWater(_ onChange: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        stopObservingWater()
        let query = HKObserverQuery(sampleType: waterType, predicate: nil) { _, completion, _ in
            onChange { completion() }
        }
        observerQuery = query
        store.execute(query)
    }

    public func stopObservingWater() {
        if let observerQuery { store.stop(observerQuery) }
        observerQuery = nil
    }

    /// Ask the system to wake the app when water is logged elsewhere, so a widget or a
    /// watch face doesn't sit on a stale total until the app is next opened. Needs the
    /// `com.apple.developer.healthkit.background-delivery` entitlement.
    public func enableBackgroundDelivery(frequency: HKUpdateFrequency = .immediate) async throws {
        try await store.enableBackgroundDelivery(for: waterType, frequency: frequency)
    }

    public func disableBackgroundDelivery() async throws {
        try await store.disableBackgroundDelivery(for: waterType)
    }

    public func todayTotalML(calendar: Calendar = .current) async throws -> Double {
        let start = calendar.startOfDay(for: Date())
        return try await totalML(from: start, to: Date())
    }

    /// Water logged per calendar day (by any app) for the last `days` days, keyed by the
    /// start of each day. Days with nothing logged are omitted.
    /// Water logged per calendar day for the last `days` days, by any app.
    ///
    /// Summed from the samples themselves rather than with a statistics collection
    /// query. Measured on a real account, a collection query returned exactly the day's
    /// samples minus the ones this app had written — two days checked, each short by
    /// precisely our own contribution, while a sample query over the same window
    /// returned all of them. Bucketing here also means a list of days and a single day
    /// are answered by one query under one rule, so the two cannot drift apart again.
    public func dailyTotalsML(days: Int, calendar: Calendar = .current) async throws -> [Date: Double] {
        let startOfToday = calendar.startOfDay(for: Date())
        let endOfToday = startOfToday.addingTimeInterval(86_400)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday) else { return [:] }
        var totals: [Date: Double] = [:]
        for sample in try await samples(from: start, to: endOfToday) {
            totals[calendar.startOfDay(for: sample.date), default: 0] += sample.milliliters
        }
        return totals
    }
}
#endif
