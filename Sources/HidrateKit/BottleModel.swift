import CoreBluetooth
import Foundation
import Observation

/// A drink or refill detected from the weight stream.
public struct LevelChangeEvent: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let date: Date
    public let change: LevelChange
    public let stableRaw: Int
    /// True when the volume was reconstructed across a disconnect (drift-corrected estimate).
    public var approximate: Bool = false

    public var volumeML: Double { change.volumeML }
    public var isDrink: Bool { change.isDrink }
}

/// Main-actor, observable view of one bottle: connection state, live readings,
/// calibration, and detected drinks. Drive UI from this; use `client` for raw commands.
@MainActor
@Observable
public final class HidrateBottleModel {
    public let client: HidrateBottleClient

    public private(set) var bluetoothState: CBManagerState = .unknown
    public private(set) var connectionState: ConnectionState = .disconnected(reason: nil)
    public private(set) var isScanning = false
    public private(set) var bottles: [DiscoveredBottle] = []
    public private(set) var connectedBottleName: String?
    public private(set) var gatt: GATTInventory?
    public private(set) var deviceInformation: [String: String] = [:]
    public private(set) var batteryPercent: Int?
    /// Capacity configured inside the bottle (what its own sip percentages refer to).
    public private(set) var bottleCapacityML: Int?
    public private(set) var capState: CapState?
    public private(set) var capChangedAt: Date?
    public private(set) var latestWeight: WeightSample?
    public private(set) var stableRaw: Int?
    /// Last settled raw reading saved to disk. Held as a raw value, not millilitres, so
    /// that recalibrating reinterprets it rather than throwing it away.
    public private(set) var rememberedRaw: Int?
    public private(set) var stableStreak = 0
    public private(set) var weightSampleCount = 0
    public private(set) var sips: [SipRecord] = []
    public private(set) var rawValues: [CharacteristicValue] = []
    public private(set) var logs: [LogEntry] = []
    public private(set) var levelChanges: [LevelChangeEvent] = []

    /// Called on the main actor for every detected drink or refill.
    public var onLevelChange: (@MainActor (LevelChangeEvent) -> Void)?
    /// Called on the main actor for every settled reading, whether or not it produced a
    /// change. A drink that goes unlogged leaves no other trace, so this is what makes
    /// the difference between "the tracker saw it and rejected it" and "it never arrived".
    public var onSettledReading: (@MainActor (SettledReading) -> Void)?
    /// Called on the main actor for every sip record the bottle reports.
    public var onSip: (@MainActor (SipRecord) -> Void)?
    /// Called on the main actor for every raw event, before the model processes it.
    /// Useful for persisting a session log.
    public var onEvent: (@MainActor (BottleEvent) -> Void)?
    /// When the current connection attempt or session began.
    public private(set) var connectionStateChangedAt = Date()

    public var maxLogEntries = 500
    public var maxRawValues = 200

    private var storedCalibration: BottleCalibration?

    public var calibration: BottleCalibration? {
        get { storedCalibration }
        set {
            storedCalibration = newValue
            store?.saveCalibration(newValue)
            tracker.reset()
            store?.saveBaselineML(nil)
            // A new calibration invalidates any level saved under the old one, so a
            // reconnect can't reconstruct a phantom drink across the change. The last raw
            // reading survives: it means the same thing under any calibration, and it is
            // what keeps the bottle from being drawn empty until the next connection.
            store?.clearLastLevel()
            pendingRecoveryCheck = false
        }
    }

    /// Re-read anything that wasn't there at launch, and say whether that found something.
    ///
    /// An app woken while the phone is still locked — which for this one is routine, since
    /// CoreBluetooth relaunches it when the bottle reconnects — can come up before its
    /// stored preferences are readable. It then runs with no calibration, and `trackLevel`
    /// drops every reading it takes on the floor: the water level looks right on screen
    /// but nothing is ever logged. Call this whenever protected data becomes available.
    @discardableResult
    public func reloadPersistedStateIfNeeded() -> Bool {
        var recovered = false
        if storedCalibration == nil, let calibration = store?.loadCalibration() {
            // Assigned to the backing store, not through the setter: this is restoring
            // what was already saved, not calibrating afresh.
            storedCalibration = calibration
            recovered = true
        }
        if tracker.baselineML == nil, let baseline = store?.loadBaselineML() {
            tracker.reset(baselineML: baseline)
            recovered = true
        }
        if rememberedRaw == nil, let raw = store?.loadLastRaw()?.raw {
            rememberedRaw = raw
            recovered = true
        }
        return recovered
    }

    /// What the model managed to restore, for the session log.
    public var restoredStateDescription: String {
        let baseline = tracker.baselineML.map { "\(Int($0.rounded()))mL" } ?? "none"
        let raw = rememberedRaw.map(String.init) ?? "none"
        return "calibration=\(storedCalibration == nil ? "none" : "yes") baseline=\(baseline) lastRaw=\(raw)"
    }

    public var trackerConfiguration: LevelTracker.Configuration {
        get { tracker.configuration }
        set { tracker.configuration = newValue }
    }

    /// Drift model used to recover drinks/refills that happened while disconnected.
    public var driftModel = DriftModel()
    /// Recover level changes measured across a disconnect. On by default because the PRO 2
    /// disconnects every ~15 minutes, so many drinks happen while briefly away.
    public var recoverAcrossDisconnects = true

    public var stabilityTolerance: Int {
        get { filter.tolerance }
        set { filter.tolerance = newValue }
    }

    public var stabilitySamples: Int {
        get { filter.requiredSamples }
        set { filter.requiredSamples = newValue }
    }

    // PRO 2 firmware notifies weight every ~15 s and drifts a few units per sample, so two
    // agreeing samples within ±8 is the practical definition of "settled".
    private var filter = StableWeightFilter(tolerance: 8, requiredSamples: 2)
    private var tracker = LevelTracker()
    private var pendingRecoveryCheck = false
    /// True until the first settled reading of a session, which is the one that has to
    /// account for anything drunk while the bottle was away.
    private var awaitingFirstSettledReading = false
    private var stableSubscribers: [UUID: AsyncStream<Int>.Continuation] = [:]
    private var eventTask: Task<Void, Never>?
    private let store: CalibrationStore?

    public init(client: HidrateBottleClient = HidrateBottleClient(), store: CalibrationStore? = CalibrationStore()) {
        self.client = client
        self.store = store
        storedCalibration = store?.loadCalibration()
        if let baseline = store?.loadBaselineML() {
            tracker.reset(baselineML: baseline)
        }
        if let raw = store?.loadLastRaw()?.raw {
            rememberedRaw = raw
        } else if let level = store?.loadLastLevel()?.levelML, let calibration = storedCalibration, calibration.isValid {
            // Upgrading from a version that only saved millilitres: turn what it saved
            // back into a raw reading so the bottle isn't drawn empty on the first launch.
            rememberedRaw = Int(calibration.raw(forMilliliters: level).rounded())
        }
        // Subscribe synchronously so nothing emitted before the task first runs is lost.
        let events = client.events()
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                self.handle(event)
            }
        }
    }

    // MARK: - Derived values

    public var isConnected: Bool { connectionState.isConnected }

    /// Calibrated water level from the last stable reading, unclamped.
    public var currentLevelML: Double? {
        guard let calibration, calibration.isValid, let stableRaw else { return nil }
        return calibration.milliliters(forRaw: Double(stableRaw))
    }

    /// The same reading held inside 0…capacity, for anywhere a number is shown to
    /// someone. The bottle's zero drifts, so the raw conversion goes negative with water
    /// still in the bottle; "-7.5 oz" is never a useful thing to read.
    public var clampedLevelML: Double? {
        guard let calibration, calibration.isValid, let stableRaw else { return nil }
        return calibration.clampedMilliliters(forRaw: Double(stableRaw))
    }

    /// How far below the calibrated empty point the reading sits, when it does. Past a
    /// few percent of capacity this means the empty capture is stale, not noise.
    public var zeroDriftML: Double? {
        guard let level = currentLevelML, level < 0 else { return nil }
        return -level
    }

    public var fillFraction: Double? {
        guard let calibration, calibration.isValid, let stableRaw else { return nil }
        return calibration.fillFraction(forRaw: Double(stableRaw))
    }

    /// The last saved reading, read through the calibration in force now.
    public var rememberedLevelML: Double? {
        guard let calibration, calibration.isValid, let rememberedRaw else { return nil }
        return calibration.milliliters(forRaw: Double(rememberedRaw))
    }

    /// Level to show: the live reading when we have one, otherwise the last one we saved.
    public var displayLevelML: Double? { currentLevelML ?? rememberedLevelML }

    public var displayFillFraction: Double? {
        guard let calibration, calibration.isValid, let level = displayLevelML, calibration.capacityML > 0 else { return nil }
        return min(max(level / calibration.capacityML, 0), 1)
    }

    /// The level the tracker is comparing against (last settled reading).
    public var baselineLevelML: Double? { tracker.baselineML }

    public func drinks(on day: Date, calendar: Calendar = .current) -> [LevelChangeEvent] {
        levelChanges.filter { $0.isDrink && calendar.isDate($0.date, inSameDayAs: day) }
    }

    public var todayDrinkTotalML: Double {
        drinks(on: Date()).reduce(0) { $0 + $1.volumeML }
    }

    // MARK: - Commands

    public func startScanning() { client.startScanning() }
    public func stopScanning() { client.stopScanning() }

    public func connect(_ bottle: DiscoveredBottle) {
        connectedBottleName = bottle.name
        client.connect(to: bottle.id, name: bottle.name)
    }

    @discardableResult
    public func reconnectLastBottle() -> Bool {
        if connectedBottleName == nil { connectedBottleName = client.lastBottleName }
        // If a connection or attempt is already in flight (e.g. iOS state restoration),
        // don't stack another connect on top of it.
        if connectionState.isConnected { return true }
        if case .connecting = connectionState { return true }
        return client.reconnectLastBottle()
    }

    public func disconnect() { client.disconnect() }
    public func drainSips() { client.drainSips() }
    public func pulseLED(_ pattern: LEDPattern = .drinkSuccess) { client.setLED(pattern) }

    public func clearLogs() { logs = [] }
    public func clearRawValues() { rawValues = [] }

    /// Forget the tracker baseline so the next stable reading starts fresh.
    public func resetLevelBaseline() {
        tracker.reset()
        store?.saveBaselineML(nil)
    }

    public func removeLevelChange(_ event: LevelChangeEvent) {
        removeLevelChange(id: event.id)
    }

    public func removeLevelChange(id: UUID) {
        levelChanges.removeAll { $0.id == id }
    }

    // MARK: - Calibration capture

    public enum CaptureError: Error, LocalizedError {
        case timeout
        case notConnected

        public var errorDescription: String? {
            switch self {
            case .timeout: "The bottle did not produce a stable reading in time. Set it on a flat surface and keep still."
            case .notConnected: "The bottle is not connected."
            }
        }
    }

    /// Stable raw readings as they are recognised.
    public func stableReadings() -> AsyncStream<Int> {
        makeStableStream().stream
    }

    private func makeStableStream() -> (stream: AsyncStream<Int>, id: UUID) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(16))
        stableSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.stableSubscribers[id] = nil }
        }
        return (stream, id)
    }

    /// Waits for `samples` consecutive stable readings and returns their mean.
    /// Used by the empty/full calibration steps.
    public func captureStableRaw(samples: Int = 3, timeout: Duration = .seconds(120)) async throws -> Double {
        guard isConnected else { throw CaptureError.notConnected }
        filter.reset()
        stableStreak = 0
        let (stream, id) = makeStableStream()
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.stableSubscribers[id]?.finish()
        }
        defer {
            timeoutTask.cancel()
            stableSubscribers[id]?.finish()
        }
        var values: [Int] = []
        for await value in stream {
            values.append(value)
            if values.count >= samples { break }
        }
        guard values.count >= samples else { throw CaptureError.timeout }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    // MARK: - Event handling

    private func handle(_ event: BottleEvent) {
        onEvent?(event)
        switch event {
        case .bluetoothState(let state):
            bluetoothState = state
        case .scanning(let scanning):
            isScanning = scanning
            if scanning { bottles = [] }
        case .discovered(let bottle):
            if let index = bottles.firstIndex(where: { $0.id == bottle.id }) {
                bottles[index] = bottle
            } else {
                bottles.append(bottle)
            }
            bottles.sort { $0.rssi > $1.rssi }
        case .connection(let state):
            if state != connectionState { connectionStateChangedAt = Date() }
            let wasReady = { if case .ready = connectionState { return true } else { return false } }()
            connectionState = state
            if case .ready = state, !wasReady {
                // New live session: the next settled resting reading should be checked
                // against the level saved before we disconnected.
                pendingRecoveryCheck = recoverAcrossDisconnects
                awaitingFirstSettledReading = true
            }
            if !state.isConnected {
                filter.reset()
                stableStreak = 0
                capState = nil
                gatt = nil
            }
        case .gatt(let inventory):
            gatt = inventory
        case .deviceInformation(let info):
            deviceInformation = info
        case .battery(let level):
            batteryPercent = level
        case .bottleConfig(let config):
            bottleCapacityML = config.capacityML
        case .cap(let state):
            capState = state
            capChangedAt = Date()
        case .weight(let sample):
            latestWeight = sample
            weightSampleCount += 1
            if let stable = filter.ingest(sample.raw) {
                stableRaw = stable
                for continuation in stableSubscribers.values { continuation.yield(stable) }
                trackLevel(raw: stable, at: sample.receivedAt)
            }
            stableStreak = filter.currentStreak
        case .sip(let record):
            sips.insert(record, at: 0)
            if sips.count > 500 { sips.removeLast(sips.count - 500) }
            onSip?(record)
        case .rawValue(let value):
            rawValues.insert(value, at: 0)
            if rawValues.count > maxRawValues { rawValues.removeLast(rawValues.count - maxRawValues) }
        case .log(let entry):
            logs.append(entry)
            if logs.count > maxLogEntries { logs.removeFirst(logs.count - maxLogEntries) }
        }
    }

    private func trackLevel(raw: Int, at date: Date) {
        guard let calibration, calibration.isValid else { return }
        tracker.capacityML = calibration.capacityML
        let levelML = calibration.milliliters(forRaw: Double(raw))

        // A below-empty reading means the bottle is lifted/tilted; don't anchor to it.
        let plausible = levelML >= tracker.configuration.liftedBelowML
        let baselineBefore = tracker.baselineML
        var recovered = false
        if pendingRecoveryCheck, plausible {
            pendingRecoveryCheck = false
            // With a baseline in hand the tracker below does the work; recovery is for the
            // case where there isn't one, and compares against the level saved to disk.
            recovered = recoverAcrossGap(currentLevelML: baselineBefore ?? levelML, at: date)
        }

        let change = tracker.ingest(levelML: levelML, at: date)
        let wasFirst = awaitingFirstSettledReading
        awaitingFirstSettledReading = false
        onSettledReading?(SettledReading(
            date: date, raw: raw, levelML: levelML, baselineBeforeML: baselineBefore,
            change: change, recovered: recovered, plausible: plausible, isFirstOfSession: wasFirst
        ))

        // Saved whatever the reading says. A bottle whose zero has drifted reads below
        // empty on every sample, and gating this on plausibility left nothing to draw at
        // launch at all — an empty bottle rather than an approximate one.
        rememberedRaw = raw
        store?.saveLastRaw(raw, date: date)

        if plausible {
            store?.saveBaselineML(tracker.baselineML)
            store?.saveLastLevel(tracker.baselineML ?? levelML, date: date)
        }

        guard let change, !change.isBaseline else { return }
        let event = LevelChangeEvent(id: UUID(), date: date, change: change, stableRaw: raw)
        levelChanges.insert(event, at: 0)
        onLevelChange?(event)
    }

    /// Returns true when it logged a recovered drink.
    @discardableResult
    private func recoverAcrossGap(currentLevelML: Double, at date: Date) -> Bool {
        guard let previous = store?.loadLastLevel(), let capacity = calibration?.capacityML else { return false }
        let gap = date.timeIntervalSince(previous.date)
        guard gap > 30, gap <= driftModel.maxGapSeconds else { return false }
        // Both anchors must be plausible fill levels. Readings below empty or above
        // capacity mean the calibration was stale or the bottle was mid-handling; a
        // "drink" reconstructed from those is noise, not water. (This is what wrote a
        // phantom 137 mL from two negative levels after a recalibration.)
        let slack = 0.15 * capacity
        guard (-slack...(capacity + slack)).contains(previous.levelML),
              (-slack...(capacity + slack)).contains(currentLevelML) else { return false }
        // Only reconstruct DRINKS across a gap. An apparent increase while we were away is
        // far more likely surface/thermal offset than a real refill, so never log a
        // recovered refill.
        let observedDrop = previous.levelML - currentLevelML
        guard observedDrop > 0 else { return false }
        let corrected = driftModel.correctedDrop(observedDrop: observedDrop, gapSeconds: gap)
        guard corrected >= tracker.configuration.minDrinkML else { return false }
        let midpoint = previous.date.addingTimeInterval(gap / 2)
        let change = LevelChange.drink(volumeML: corrected, fromML: previous.levelML, toML: currentLevelML)
        let event = LevelChangeEvent(id: UUID(), date: midpoint, change: change, stableRaw: 0, approximate: true)
        levelChanges.insert(event, at: 0)
        onLevelChange?(event)
        return true
    }
}
