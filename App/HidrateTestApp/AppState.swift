import Foundation
import HidrateKit
import Observation

/// One logged drink, with its HealthKit link when written.
struct IntakeEntry: Identifiable, Codable, Hashable {
    enum Source: String, Codable {
        case weight
        case sipFrame
        case manual

        var title: String {
            switch self {
            case .weight: "Weight"
            case .sipFrame: "Bottle sip"
            case .manual: "Manual"
            }
        }
    }

    let id: UUID
    var date: Date
    var volumeML: Double
    var source: Source
    var healthKitUUID: UUID?
    var rawBefore: Int?
    var rawAfter: Int?
    var healthError: String?
    var approximate: Bool = false
}

enum IntakeSource: String, CaseIterable, Identifiable {
    case weight
    case bottleSips

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weight: "Calibrated weight"
        case .bottleSips: "Bottle sip records"
        }
    }
}

@MainActor
@Observable
final class AppState {
    let model: HidrateBottleModel
    let health = HealthKitWaterLogger()
    let sessionLog = SessionLog()

    private(set) var entries: [IntakeEntry] = [] { didSet { saveEntries() } }
    var autoLogToHealth: Bool { didSet { defaults.set(autoLogToHealth, forKey: Keys.autoLog) } }
    var intakeSource: IntakeSource { didSet { defaults.set(intakeSource.rawValue, forKey: Keys.source) } }
    var minimumLogML: Double { didSet { defaults.set(minimumLogML, forKey: Keys.minimumLog) } }
    var capacityML: Double { didSet { defaults.set(capacityML, forKey: Keys.capacity) } }
    var exploreAllCharacteristics: Bool {
        didSet {
            defaults.set(exploreAllCharacteristics, forKey: Keys.exploreAll)
            var options = model.client.options
            options.subscribeToAllNotifying = exploreAllCharacteristics
            model.client.options = options
        }
    }

    var readUnknownOnConnect: Bool {
        didSet {
            defaults.set(readUnknownOnConnect, forKey: Keys.readUnknown)
            var options = model.client.options
            options.readUnknownCharacteristicsOnConnect = readUnknownOnConnect
            model.client.options = options
        }
    }

    var handshakeMode: BottleClientOptions.HandshakeMode {
        didSet {
            defaults.set(handshakeMode.rawValue, forKey: Keys.handshake)
            var options = model.client.options
            options.handshake = handshakeMode
            model.client.options = options
        }
    }

    private(set) var healthTodayML: Double?
    private(set) var healthAuthorized = false
    var lastError: String?

    private let defaults = UserDefaults.standard
    private let entriesURL: URL

    private enum Keys {
        static let autoLog = "app.autoLogToHealth"
        static let source = "app.intakeSource"
        static let minimumLog = "app.minimumLogML"
        static let capacity = "app.capacityML"
        static let handshake = "app.handshakeMode"
        static let exploreAll = "app.exploreAllCharacteristics"
        static let readUnknown = "app.readUnknownOnConnect"
        static let tracker = "app.trackerConfiguration"
    }

    init() {
        var options = BottleClientOptions()
        options.restoreIdentifier = "com.rickybloomfield.HidrateTestApp.central"
        let storedHandshake = UserDefaults.standard.string(forKey: Keys.handshake)
            .flatMap(BottleClientOptions.HandshakeMode.init(rawValue:)) ?? .auto
        options.handshake = storedHandshake
        handshakeMode = storedHandshake
        let exploreAll = UserDefaults.standard.bool(forKey: Keys.exploreAll)
        options.subscribeToAllNotifying = exploreAll
        exploreAllCharacteristics = exploreAll
        let readUnknown = UserDefaults.standard.object(forKey: Keys.readUnknown) as? Bool ?? true
        options.readUnknownCharacteristicsOnConnect = readUnknown
        readUnknownOnConnect = readUnknown
        model = HidrateBottleModel(client: HidrateBottleClient(options: options))

        autoLogToHealth = defaults.object(forKey: Keys.autoLog) as? Bool ?? true
        intakeSource = defaults.string(forKey: Keys.source).flatMap(IntakeSource.init(rawValue:)) ?? .bottleSips
        minimumLogML = defaults.object(forKey: Keys.minimumLog) as? Double ?? 15
        capacityML = defaults.object(forKey: Keys.capacity) as? Double ?? BottleCalibration.capacityML(ounces: 21)

        // One-time migration: the HCI sniff proved the PRO 2 reports intake via sip records,
        // which are drift-immune, so switch anyone still on weight-tracking over to sips.
        if !defaults.bool(forKey: "app.migratedToSipSource") {
            defaults.set(true, forKey: "app.migratedToSipSource")
            if intakeSource == .weight { intakeSource = .bottleSips }
        }
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        entriesURL = support.appendingPathComponent("intake-entries.json")
        loadEntries()

        if let data = defaults.data(forKey: Keys.tracker),
           let configuration = try? JSONDecoder().decode(LevelTracker.Configuration.self, from: data) {
            model.trackerConfiguration = configuration
        }

        model.onLevelChange = { [weak self] event in self?.handle(event) }
        model.onSip = { [weak self] record in self?.handle(record) }
        model.onEvent = { [weak self] event in self?.sessionLog.record(event) }

        healthAuthorized = HealthKitWaterLogger.isAvailable && health.canWrite
        model.reconnectLastBottle()
        Task { await refreshHealthTotal() }
    }

    // MARK: - Tracker configuration

    var trackerConfiguration: LevelTracker.Configuration {
        get { model.trackerConfiguration }
        set {
            model.trackerConfiguration = newValue
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Keys.tracker) }
        }
    }

    // MARK: - Intake

    var todayEntries: [IntakeEntry] {
        entries.filter { Calendar.current.isDateInToday($0.date) }
    }

    var todayTotalML: Double { todayEntries.reduce(0) { $0 + $1.volumeML } }

    private func handle(_ event: LevelChangeEvent) {
        sessionLog.write("levelChange \(event.change)\(event.approximate ? " [recovered]" : "") raw=\(event.stableRaw)")
        guard intakeSource == .weight, case .drink(let volume, let from, let to) = event.change else { return }
        let entry = IntakeEntry(
            id: event.id, date: event.date, volumeML: volume.rounded(), source: .weight,
            rawBefore: Int(from.rounded()), rawAfter: Int(to.rounded()), approximate: event.approximate
        )
        add(entry)
    }

    private func handle(_ record: SipRecord) {
        guard intakeSource == .bottleSips, record.hasPayload, record.percentOfCapacity > 0 else { return }
        let calibration = model.calibration
        guard record.isPlausible(rawUnitsPerML: calibration?.rawUnitsPerML, capacityML: capacityML) else {
            lastError = "Ignored an implausible sip record (\(record.percentOfCapacity)%)."
            return
        }
        let entry = IntakeEntry(
            id: record.id, date: record.receivedAt, volumeML: record.volumeML(capacityML: capacityML).rounded(),
            source: .sipFrame, rawBefore: record.rawWeightBefore, rawAfter: record.rawWeightAfter
        )
        add(entry)
    }

    func addManual(volumeML: Double, at date: Date = Date()) {
        add(IntakeEntry(id: UUID(), date: date, volumeML: volumeML, source: .manual))
    }

    private func add(_ entry: IntakeEntry) {
        sessionLog.write("intake \(Int(entry.volumeML))mL source=\(entry.source.rawValue) autoLog=\(autoLogToHealth && entry.volumeML >= minimumLogML)")
        entries.insert(entry, at: 0)
        if entries.count > 2000 { entries.removeLast(entries.count - 2000) }
        if autoLogToHealth, entry.volumeML >= minimumLogML {
            Task { await logToHealth(entry) }
        }
    }

    func logToHealth(_ entry: IntakeEntry) async {
        sessionLog.write("healthkit write \(Int(entry.volumeML))mL for \(entry.id)")
        guard let index = entries.firstIndex(where: { $0.id == entry.id }), entries[index].healthKitUUID == nil else { return }
        do {
            var metadata: [String: String] = [
                HealthKitWaterLogger.MetadataKey.source: entry.source.rawValue,
                HealthKitWaterLogger.MetadataKey.eventID: entry.id.uuidString,
            ]
            if let before = entry.rawBefore { metadata[HealthKitWaterLogger.MetadataKey.rawBefore] = String(before) }
            if let after = entry.rawAfter { metadata[HealthKitWaterLogger.MetadataKey.rawAfter] = String(after) }
            let device = WaterSourceDevice(deviceInformation: model.deviceInformation, localIdentifier: model.connectedBottleName)
            let uuid = try await health.logWater(milliliters: entry.volumeML, at: entry.date, device: device, metadata: metadata)
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index].healthKitUUID = uuid
                entries[index].healthError = nil
            }
            await refreshHealthTotal()
        } catch {
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index].healthError = error.localizedDescription
            }
            lastError = "HealthKit: \(error.localizedDescription)"
        }
    }

    func delete(_ entry: IntakeEntry) async {
        if let uuid = entry.healthKitUUID {
            do {
                try await health.deleteWater(uuid: uuid)
            } catch {
                lastError = "HealthKit delete failed: \(error.localizedDescription)"
                return
            }
        }
        entries.removeAll { $0.id == entry.id }
        model.removeLevelChange(id: entry.id)
        await refreshHealthTotal()
    }

    // MARK: - HealthKit

    func requestHealthAccess() async {
        do {
            try await health.requestAuthorization()
            healthAuthorized = health.canWrite
            if !healthAuthorized { lastError = "Health access was not granted for water intake." }
            await refreshHealthTotal()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshHealthTotal() async {
        guard HealthKitWaterLogger.isAvailable else { return }
        healthAuthorized = health.canWrite
        healthTodayML = try? await health.todayTotalML()
    }

    // MARK: - Calibration

    func saveCalibration(emptyRaw: Double, fullRaw: Double) {
        let calibration = BottleCalibration(emptyRaw: emptyRaw, fullRaw: fullRaw, capacityML: capacityML)
        sessionLog.write(String(format: "calibration saved empty=%.1f full=%.1f capacity=%.0f scale=%.3f raw/mL", emptyRaw, fullRaw, capacityML, calibration.rawUnitsPerML))
        model.calibration = calibration
    }

    func clearCalibration() {
        model.calibration = nil
    }

    // MARK: - Persistence

    private func loadEntries() {
        guard let data = try? Data(contentsOf: entriesURL),
              let decoded = try? JSONDecoder().decode([IntakeEntry].self, from: data) else { return }
        entries = decoded
    }

    private func saveEntries() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: entriesURL, options: .atomic)
    }
}

// MARK: - Formatting helpers

enum Format {
    static func ml(_ value: Double) -> String {
        "\(Int(value.rounded())) mL"
    }

    static func mlAndOz(_ value: Double) -> String {
        let oz = value / BottleCalibration.millilitersPerUSFluidOunce
        return "\(Int(value.rounded())) mL · \(String(format: "%.1f", oz)) oz"
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
