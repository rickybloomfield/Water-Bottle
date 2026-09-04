import Foundation
import HidrateKit
import UIKit
import Observation
import UserNotifications

/// One logged drink, with its HealthKit link when written.
struct IntakeEntry: Identifiable, Codable, Hashable {
    enum Source: String, Codable {
        case weight
        case sipFrame
        case manual
        case widget
        case watch

        var title: String {
            switch self {
            case .weight: "Weight"
            case .sipFrame: "Bottle sip"
            case .manual: "Manual"
            case .widget: "Widget"
            case .watch: "Apple Watch"
            }
        }

        /// True for anything the user tapped rather than the bottle measuring.
        var isHandLogged: Bool { self == .manual || self == .widget || self == .watch }

        var symbolName: String {
            switch self {
            case .weight, .sipFrame: "waterbottle.fill"
            case .manual: "hand.tap.fill"
            case .widget: "square.grid.2x2.fill"
            case .watch: "applewatch"
            }
        }

        /// How the drink describes itself in the Today list.
        var rowLabel: String {
            switch self {
            case .weight, .sipFrame: "Bottle"
            case .manual: "Logged by hand"
            case .widget: "Widget"
            case .watch: "Apple Watch"
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
    /// The system can launch this app into the background — Bluetooth restoration, a
    /// drink sent from the watch, water logged in Health by another app, a scheduled
    /// refresh — and each of those needs the same live state, built once at launch.
    static let shared = AppState()

    let model: HidrateBottleModel
    let health = HealthKitWaterLogger()
    let sessionLog = SessionLog()
    /// Dev only: launch with `-demoFill 0.6` to show the bottle at a fixed level without a
    /// connected bottle (used to check the fluid rendering in the Simulator).
    let demoFillOverride: Double? = {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-demoFill"), i + 1 < args.count { return Double(args[i + 1]) }
        return nil
    }()

    private(set) var entries: [IntakeEntry] = [] {
        didSet {
            entriesRevision &+= 1
            saveEntries()
            publishSnapshot()
        }
    }
    /// Bumped on every change to `entries`. Screens that hold a snapshot of a day watch
    /// this rather than the count, which doesn't move when a drink is only corrected.
    private(set) var entriesRevision = 0
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

    var unit: VolumeUnit {
        didSet {
            defaults.set(unit.rawValue, forKey: Keys.unit)
            publishSnapshot()
            Task { await rescheduleReminders() }
        }
    }
    var dailyGoalML: Double {
        didSet {
            defaults.set(dailyGoalML, forKey: Keys.goal)
            publishSnapshot()
            Task { await rescheduleReminders() }
        }
    }
    var reminders: ReminderSettings {
        didSet {
            if let data = try? JSONEncoder().encode(reminders) { defaults.set(data, forKey: Keys.reminders) }
            // The window is what the pace marker on every ring is drawn from.
            publishSnapshot()
            Task { await rescheduleReminders() }
        }
    }
    private(set) var notificationsAuthorized = false
    /// Shown by the Today tab when the goal is first reached each day.
    var showCelebration = false
    private var lastCelebratedDay: String? {
        get { defaults.string(forKey: Keys.celebratedDay) }
        set { defaults.set(newValue, forKey: Keys.celebratedDay) }
    }

    var flashLEDOnDrink: Bool { didSet { defaults.set(flashLEDOnDrink, forKey: Keys.flashLED) } }
    var flashLEDOnGoal: Bool { didSet { defaults.set(flashLEDOnGoal, forKey: Keys.flashGoalLED) } }
    /// Put the bottle's light out as soon as the connection handshake finishes, so the
    /// handshake's own writes don't leave it flashing every time the bottle reconnects.
    var quietLightOnConnect: Bool {
        didSet {
            defaults.set(quietLightOnConnect, forKey: Keys.quietOnConnect)
            var options = model.client.options
            options.silenceLEDAfterHandshake = quietLightOnConnect
            model.client.options = options
        }
    }
    var drinkLEDByte: Int { didSet { defaults.set(drinkLEDByte, forKey: Keys.ledByte) } }
    var ledStopEnabled: Bool { didSet { defaults.set(ledStopEnabled, forKey: Keys.ledStop) } }
    var ledStopByte: Int { didSet { defaults.set(ledStopByte, forKey: Keys.ledStopByte) } }
    var ledStopDelay: Double { didSet { defaults.set(ledStopDelay, forKey: Keys.ledStopDelay) } }

    var handshakeMode: BottleClientOptions.HandshakeMode {
        didSet {
            defaults.set(handshakeMode.rawValue, forKey: Keys.handshake)
            var options = model.client.options
            options.handshake = handshakeMode
            model.client.options = options
        }
    }

    /// Ids of widget and watch drinks already folded into `entries`, echoed back in the
    /// snapshot so the watch knows to stop counting them itself.
    var adoptedDrinkIDs: [UUID] = [] { didSet { defaults.set(adoptedDrinkIDs.map(\.uuidString), forKey: Keys.adopted) } }

    /// The most recent time the zero moved, so the Bottle tab can say it happened.
    struct ZeroMove: Equatable {
        var shiftML: Double
        var automatic: Bool
        var date: Date
    }
    private(set) var lastZeroMove: ZeroMove?

    private(set) var healthTodayML: Double?
    private(set) var healthAuthorized = false
    /// Today's water samples written by *other* apps (ours are already in `entries`).
    private(set) var externalTodaySamples: [WaterSample] = []
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
        static let flashLED = "app.flashLEDOnDrink"
        static let flashGoalLED = "app.flashLEDOnGoal"
        static let quietOnConnect = "app.quietLightOnConnect"
        static let unit = "app.unit"
        static let goal = "app.dailyGoalML"
        static let reminders = "app.reminders"
        static let celebratedDay = "app.lastCelebratedDay"
        static let ledByte = "app.drinkLEDByte"
        static let ledStop = "app.ledStopEnabled"
        static let ledStopByte = "app.ledStopByte"
        static let ledStopDelay = "app.ledStopDelay"
        static let tracker = "app.trackerConfiguration"
        static let adopted = "app.adoptedDrinkIDs"
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
        unit = defaults.string(forKey: Keys.unit).flatMap(VolumeUnit.init(rawValue:)) ?? .ounces
        dailyGoalML = defaults.object(forKey: Keys.goal) as? Double ?? (64 * VolumeUnit.mlPerOunce)
        reminders = (defaults.data(forKey: Keys.reminders)).flatMap { try? JSONDecoder().decode(ReminderSettings.self, from: $0) } ?? ReminderSettings()
        flashLEDOnDrink = defaults.object(forKey: Keys.flashLED) as? Bool ?? true
        flashLEDOnGoal = defaults.object(forKey: Keys.flashGoalLED) as? Bool ?? true
        let quiet = defaults.object(forKey: Keys.quietOnConnect) as? Bool ?? true
        options.silenceLEDAfterHandshake = quiet
        quietLightOnConnect = quiet
        drinkLEDByte = defaults.object(forKey: Keys.ledByte) as? Int ?? Int(LEDPattern.drinkSuccess.rawValue)
        ledStopEnabled = defaults.object(forKey: Keys.ledStop) as? Bool ?? true
        ledStopByte = defaults.object(forKey: Keys.ledStopByte) as? Int ?? 0x00 // best guess for "off"
        ledStopDelay = defaults.object(forKey: Keys.ledStopDelay) as? Double ?? 2.0
        model = HidrateBottleModel(client: HidrateBottleClient(options: options))

        autoLogToHealth = defaults.object(forKey: Keys.autoLog) as? Bool ?? true
        intakeSource = defaults.string(forKey: Keys.source).flatMap(IntakeSource.init(rawValue:)) ?? .weight
        minimumLogML = defaults.object(forKey: Keys.minimumLog) as? Double ?? 15
        capacityML = defaults.object(forKey: Keys.capacity) as? Double ?? BottleCalibration.capacityML(ounces: 21)

        // One-time: adopt the confirmed blue-glow drink colour (0xB0) for anyone who was
        // left on an exploratory byte before the LED map was known.
        if !defaults.bool(forKey: "app.migratedDrinkLED") {
            defaults.set(true, forKey: "app.migratedDrinkLED")
            drinkLEDByte = Int(LEDPattern.drinkSuccess.rawValue)
        }
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        entriesURL = support.appendingPathComponent("intake-entries.json")
        adoptedDrinkIDs = (defaults.stringArray(forKey: Keys.adopted) ?? []).compactMap(UUID.init(uuidString:))
        loadEntries()

        if let data = defaults.data(forKey: Keys.tracker),
           let configuration = try? JSONDecoder().decode(LevelTracker.Configuration.self, from: data) {
            model.trackerConfiguration = configuration
        }

        PhoneWatchLink.shared.activate { [weak self] drink in
            self?.adopt(drink)
        } currentSnapshot: { [weak self] in
            guard let self else { return HydrationSnapshot() }
            await self.catchUp()
            return self.snapshot
        }
        model.onLevelChange = { [weak self] event in self?.handle(event) }
        model.onSettledReading = { [weak self] reading in
            if let line = reading.logLine { self?.sessionLog.write(line) }
        }
        model.onZeroMoved = { [weak self] shiftML, automatic in
            guard let self else { return }
            sessionLog.write(String(format: "zero moved %@ by %.0f mL", automatic ? "automatically" : "by hand", shiftML))
            lastZeroMove = ZeroMove(shiftML: shiftML, automatic: automatic, date: Date())
            publishSnapshot()
        }
        model.onSip = { [weak self] record in self?.handle(record) }
        model.onEvent = { [weak self] event in self?.sessionLog.record(event) }

        healthAuthorized = HealthKitWaterLogger.isAvailable && health.canWrite
        sessionLog.write("restored \(model.restoredStateDescription)")
        // The phone can be locked when CoreBluetooth relaunches this app, and a locked
        // phone's preferences read back empty. Pick them up the moment they can be read.
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Hop rather than assert: an isolation check that fails is a crash, and this
            // is not worth crashing over. (The watch app crashed on exactly that.)
            Task { @MainActor in self?.reloadPersistedBottleState() }
        }
        model.reconnectLastBottle()
        startHealthObserver()
        adoptPendingDrinks()
        // Always write once at launch, so a fresh install has a real snapshot to read
        // rather than whatever the defaults happen to be.
        publishSnapshot(force: true)
        Task { await refreshHealthTotal() }
    }

    /// Re-read the calibration and level saved on disk if the launch came up without
    /// them. Without this the session runs uncalibrated and logs nothing it measures.
    func reloadPersistedBottleState() {
        guard model.reloadPersistedStateIfNeeded() else { return }
        sessionLog.write("recovered state unreadable at launch: \(model.restoredStateDescription)")
        publishSnapshot()
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

    /// Everything you drank today: this app's drinks plus water logged in Health by other apps.
    var todayTotalML: Double {
        todayEntries.reduce(0) { $0 + $1.volumeML } + externalTodaySamples.reduce(0) { $0 + $1.milliliters }
    }

    enum TodayItem: Identifiable {
        case entry(IntakeEntry)
        case health(WaterSample)

        var id: String {
            switch self {
            case .entry(let e): "e-\(e.id.uuidString)"
            case .health(let s): "h-\(s.id.uuidString)"
            }
        }
        var date: Date {
            switch self { case .entry(let e): e.date; case .health(let s): s.date }
        }
        var volumeML: Double {
            switch self { case .entry(let e): e.volumeML; case .health(let s): s.milliliters }
        }
    }

    /// Today's drinks from every source, newest first.
    var todayItems: [TodayItem] {
        (todayEntries.map(TodayItem.entry) + externalTodaySamples.map(TodayItem.health))
            .sorted { $0.date > $1.date }
    }

    /// Water per day for the last `days` days.
    ///
    /// Counted the same way a single day is on screen, which is the point: Apple Health
    /// for everything that reached it, plus this app's own drinks that did not. Reading
    /// Health alone left a day's row disagreeing with the day itself for any drink the
    /// app holds but Health never got — and no amount of reloading would settle it,
    /// because the two were adding up different things.
    func dailyTotals(days: Int, calendar: Calendar = .current) async -> [Date: Double] {
        // The window Health is asked for, so a caller paging back sees the app's own
        // entries bounded the same way.
        let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: Date()))
        func inWindow(_ entry: IntakeEntry) -> Bool { cutoff.map { entry.date >= $0 } ?? true }

        var totals: [Date: Double] = [:]
        var health: [Date: Double]?
        if HealthKitWaterLogger.isAvailable, healthAuthorized {
            health = try? await self.health.dailyTotalsML(days: days)
        }
        if let health, !health.isEmpty {
            for (day, ml) in health { totals[calendar.startOfDay(for: day), default: 0] += ml }
        }
        for entry in entries where inWindow(entry) {
            // Health already counted the ones it has.
            guard health == nil || entry.healthKitUUID == nil else { continue }
            totals[calendar.startOfDay(for: entry.date), default: 0] += entry.volumeML
        }
        return totals
    }

    func entries(on day: Date, calendar: Calendar = .current) -> [IntakeEntry] {
        entries.filter { calendar.isDate($0.date, inSameDayAs: day) }
    }

    /// Everything drunk on a given day, the app's own and other apps' Health samples,
    /// newest first. Today's is held in memory; any other day is read from Health.
    func items(on day: Date, calendar: Calendar = .current) async -> [TodayItem] {
        if calendar.isDateInToday(day) { return todayItems }
        let mine = entries(on: day)
        var external: [WaterSample] = []
        if HealthKitWaterLogger.isAvailable, healthAuthorized {
            let start = calendar.startOfDay(for: day)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? day
            let written = Set(mine.compactMap(\.healthKitUUID))
            external = ((try? await health.samples(from: start, to: end)) ?? [])
                .filter { !$0.isFromThisApp && !written.contains($0.id) }
        }
        return (mine.map(TodayItem.entry) + external.map(TodayItem.health))
            .sorted { $0.date > $1.date }
    }

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

    func addManual(volumeML: Double, at date: Date = Date(), id: UUID = UUID(), source: IntakeEntry.Source = .manual) {
        add(IntakeEntry(id: id, date: date, volumeML: volumeML, source: source))
    }

    private func add(_ entry: IntakeEntry) {
        sessionLog.write("intake \(Int(entry.volumeML))mL source=\(entry.source.rawValue) autoLog=\(autoLogToHealth && entry.volumeML >= minimumLogML)")
        if flashLEDOnDrink, !entry.source.isHandLogged, model.isConnected {
            flashDrinkLED()
        }
        entries.insert(entry, at: 0)
        if entries.count > 2000 { entries.removeLast(entries.count - 2000) }
        if autoLogToHealth, entry.volumeML >= minimumLogML {
            Task { await logToHealth(entry) }
        }
        checkGoalReached()
    }

    // MARK: - Goal

    var goalProgress: Double { dailyGoalML > 0 ? min(todayTotalML / dailyGoalML, 1) : 0 }
    /// How far round a second lap of the ring, once the goal is beaten.
    var goalOverflow: Double { dailyGoalML > 0 ? min(max(todayTotalML / dailyGoalML - 1, 0), 1) : 0 }
    var remainingML: Double { max(dailyGoalML - todayTotalML, 0) }
    var goalReachedToday: Bool { todayTotalML >= dailyGoalML && dailyGoalML > 0 }

    // MARK: - Pace

    /// Where you'd have to be by now to finish the goal by the end of the day's drinking
    /// window (the reminder From/Until times).
    var paceTargetML: Double { dailyGoalML * reminders.paceFraction() }
    var isOnTrack: Bool { todayTotalML >= paceTargetML }

    /// Where the pace tick sits on the ring, or nil when there's nothing worth marking:
    /// before the window opens, after it closes, or once the goal is in.
    var paceMarker: Double? {
        guard !goalReachedToday else { return nil }
        let fraction = reminders.paceFraction()
        return fraction > 0 && fraction < 1 ? fraction : nil
    }

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    /// Celebrate the first time the goal is crossed each day: in-app confetti, a success
    /// haptic, and the bottle's own goal light.
    private func checkGoalReached() {
        guard goalReachedToday else { return }
        let today = Self.dayKeyFormatter.string(from: Date())
        guard lastCelebratedDay != today else { return }
        lastCelebratedDay = today
        showCelebration = true
        sessionLog.write("goal reached: \(Int(todayTotalML))mL of \(Int(dailyGoalML))mL")
        if flashLEDOnGoal, model.isConnected { model.client.setLED(.goalAchieved) }
    }

    // MARK: - Reminders

    func setRemindersEnabled(_ enabled: Bool) async {
        if enabled {
            notificationsAuthorized = await ReminderScheduler.requestAuthorization()
            reminders.enabled = notificationsAuthorized
        } else {
            reminders.enabled = false
        }
    }

    func rescheduleReminders() async {
        await ReminderScheduler.apply(reminders, goalML: dailyGoalML, totalML: todayTotalML)
    }

    func refreshNotificationStatus() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsAuthorized = status == .authorized || status == .provisional
    }

    // MARK: - Formatting

    func volume(_ ml: Double) -> String { unit.format(ml) }
    func volumeNumber(_ ml: Double) -> String { unit.number(ml) }

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

    /// Correct a logged drink's amount or time.
    ///
    /// A Health sample can't be changed once written, so one that reached Health is
    /// removed and rewritten. The entry keeps its id either way, which is what stops a
    /// widget or watch drink being adopted a second time.
    func update(_ entry: IntakeEntry, volumeML: Double, at date: Date) async {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        if let uuid = entries[index].healthKitUUID {
            do {
                try await health.deleteWater(uuid: uuid)
            } catch {
                lastError = "HealthKit: \(error.localizedDescription)"
                return
            }
            entries[index].healthKitUUID = nil
        }
        entries[index].volumeML = volumeML.rounded()
        entries[index].date = date
        entries[index].healthError = nil
        sessionLog.write("edited \(Int(entries[index].volumeML))mL at \(Format.time.string(from: date))")
        if autoLogToHealth, entries[index].volumeML >= minimumLogML {
            await logToHealth(entries[index])
        }
        await refreshHealthTotal()
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

    /// Flash the bottle LED for a drink: show the colour byte, then send the "off" byte
    /// after a short delay so it does not keep looping.
    func flashDrinkLED() {
        model.client.setLED(rawByte: UInt8(drinkLEDByte & 0xFF))
        guard ledStopEnabled else { return }
        let stop = UInt8(ledStopByte & 0xFF)
        let delay = ledStopDelay
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.model.client.setLED(rawByte: stop)
        }
    }

    // MARK: - HealthKit

    func requestHealthAccess() async {
        do {
            try await health.requestAuthorization()
            healthAuthorized = health.canWrite
            if !healthAuthorized { lastError = "Health access was not granted for water intake." }
            startHealthObserver()
            await refreshHealthTotal()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshHealthTotal() async {
        guard HealthKitWaterLogger.isAvailable else { return }
        healthAuthorized = health.canWrite
        healthTodayML = try? await health.todayTotalML()
        if let samples = try? await health.todaySamples() {
            let mine = Set(entries.compactMap(\.healthKitUUID))
            externalTodaySamples = samples.filter { !$0.isFromThisApp && !mine.contains($0.id) }
        }
        checkGoalReached()
        publishSnapshot()
    }

    /// Watch Health so water logged in other apps appears without a manual refresh, and
    /// ask to be woken for it so the widget and the watch don't wait for the next launch.
    private func startHealthObserver() {
        guard HealthKitWaterLogger.isAvailable else { return }
        health.startObservingWater { [weak self] finished in
            Task { @MainActor in
                await self?.refreshHealthTotal()
                finished()
            }
        }
        guard health.canWrite else { return }
        Task { [health] in try? await health.enableBackgroundDelivery() }
    }

    /// One pass of catching up, for a background refresh: take over anything logged on the
    /// widget or the watch, re-read Health, prod a stalled bottle connection, and push the
    /// result back out.
    func backgroundRefresh() async {
        sessionLog.write("background refresh")
        reloadPersistedBottleState()
        model.client.nudgeReconnect()
        await catchUp()
        // Reminders are laid down two days at a time and only for the slots you're behind
        // for, so they have to be re-laid even on a day when nothing else changed.
        await rescheduleReminders()
    }

    // MARK: - Calibration

    func saveCalibration(emptyRaw: Double, fullRaw: Double) {
        let calibration = BottleCalibration(emptyRaw: emptyRaw, fullRaw: fullRaw, capacityML: capacityML)
        sessionLog.write(String(format: "calibration saved empty=%.1f full=%.1f capacity=%.0f scale=%.3f raw/mL", emptyRaw, fullRaw, capacityML, calibration.rawUnitsPerML))
        model.calibration = calibration
        if model.isConnected { model.client.setLED(.calibrationSuccess) }  // green glow
    }

    /// Take the reading in hand as a new empty point, keeping the scale. What drift
    /// actually needs — and far less work than measuring empty and full again.
    @discardableResult
    func rezeroToCurrentReading() -> Double? {
        guard let shift = model.rezeroToCurrentReading() else {
            lastError = "No steady reading yet. Set the bottle on a flat surface and wait a few seconds."
            return nil
        }
        return shift
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
