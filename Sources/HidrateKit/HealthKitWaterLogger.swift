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

/// Writes water intake to HealthKit as `dietaryWater` samples.
public final class HealthKitWaterLogger: @unchecked Sendable {
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

    public func todayTotalML(calendar: Calendar = .current) async throws -> Double {
        let start = calendar.startOfDay(for: Date())
        return try await totalML(from: start, to: Date())
    }
}
#endif
