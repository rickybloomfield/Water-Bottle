import CoreBluetooth
import Foundation
import Observation

/// A drink or refill detected from the weight stream.
public struct LevelChangeEvent: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let date: Date
    public let change: LevelChange
    public let stableRaw: Int

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
    /// Signal strength of the live link, in dBm. A connected bottle stops advertising, so
    /// this is the only reading that can be compared with the bottles that still are.
    public private(set) var connectedRSSI: Int?
    public private(set) var connectedRSSIAt: Date?
    /// Capacity configured inside the bottle (what its own sip percentages refer to).
    public private(set) var bottleCapacityML: Int?
    public private(set) var capState: CapState?
    public private(set) var capChangedAt: Date?
    public private(set) var latestWeight: WeightSample?
    public private(set) var stableRaw: Int?
    /// Last settled raw reading saved to disk. Held as a raw value, not millilitres, so
    /// that recalibrating reinterprets it rather than throwing it away.
    public private(set) var rememberedRaw: Int?

    /// How much water the bottle is believed to hold, carried forward across events
    /// rather than read off the scale.
    ///
    /// The scale's zero creeps by hundreds of millilitres over an hour, so an absolute
    /// reading is a poor thing to display. Differences across a drink are taken over
    /// seconds, where creep is nothing — so this starts from a known point and moves only
    /// when the tracker reports a drink or a refill. Drift moves it not at all. It goes
    /// out of step if an event is missed, and comes back into step at the next fill to
    /// the top, which snaps it to capacity.
    public private(set) var believedLevelML: Double?
    /// When `believedLevelML` was last set outright — a refill to the top, an emptying, a
    /// fresh start from the scale — rather than moved by a drink or a top-up. A drink
    /// deleted from before this moment puts nothing back: that reset already counted
    /// whatever was in the bottle. Saved with the level.
    public private(set) var believedLevelSetAt: Date?
    /// A refill adding this much of a bottleful is taken as "filled from empty to full".
    public var filledToTheTopFraction = 0.92
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
    /// Called on the main actor when the zero is moved — only ever by Empty or Full on
    /// the bottle's page — with how far it moved, in millilitres under the old zero.
    public var onZeroMoved: (@MainActor (Double) -> Void)?
    /// A settled reading below this is noted in the log as below empty. That is all: every
    /// reading is tracked, and only the person moves the zero.
    public var belowEmptyNoteML: Double = -60
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
            resetBelievedLevel(to: nil, at: Date())
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
            let creepRate = store?.loadCreepMLPerSecond() ?? 0
            creep.reset(mlPerSecond: creepRate)
            tracker.reset(baselineML: baseline, lastReadingAt: store?.loadLastLevel()?.date, creepMLPerSecond: creepRate)
            recovered = true
        }
        if rememberedRaw == nil, let raw = store?.loadLastRaw()?.raw {
            rememberedRaw = raw
            recovered = true
        }
        return recovered
    }

    /// The bottle is empty: the reading in hand becomes the zero, keeping the scale.
    /// Returns how far the zero moved, in millilitres under the old one, or nil without a
    /// settled reading.
    ///
    /// This is what fixes drift, and with `markFull()` the only thing that moves the
    /// zero: the level, the tracker and the saved reading all restart from a bottle known
    /// to be empty, and unlike a fresh calibration it needs no full capture.
    @discardableResult
    public func markEmpty() -> Double? {
        guard let stableRaw else { return nil }
        return anchor(levelML: 0, atRaw: stableRaw)
    }

    /// The bottle is full: the level is its capacity, and the zero moves so that the
    /// reading in hand reads as exactly that. Given the scale, a full bottle says where
    /// empty sits as surely as an empty one does. Returns how far the zero moved.
    @discardableResult
    public func markFull() -> Double? {
        guard let stableRaw, let capacity = storedCalibration?.capacityML, capacity > 0 else { return nil }
        return anchor(levelML: capacity, atRaw: stableRaw)
    }

    /// Declare that `raw` is the bottle holding `level`, and move the zero to make it so.
    private func anchor(levelML level: Double, atRaw raw: Int) -> Double? {
        guard let calibration = storedCalibration, calibration.isValid else { return nil }
        let emptyRaw = Double(raw) - level * calibration.rawUnitsPerML
        let shift = calibration.milliliters(forRaw: emptyRaw)
        let now = Date()
        // Not through the setter: this keeps the scale, so it isn't a new calibration and
        // must not throw away the level the tracker is measuring against.
        storedCalibration = calibration.rezeroed(toEmptyRaw: emptyRaw, at: now)
        store?.saveCalibration(storedCalibration)
        // The level is known outright, so everything restarts from it.
        tracker.reset(baselineML: level)
        store?.saveBaselineML(level)
        store?.saveLastLevel(level, date: now)
        rememberedRaw = raw
        store?.saveLastRaw(raw, date: now)
        resetBelievedLevel(to: level, at: now)
        onZeroMoved?(shift)
        return shift
    }

    /// Point the model at another bottle's saved calibration and level.
    ///
    /// Everything derived from the old bottle goes with it: its scale, the level it was
    /// holding, and what the tracker was measuring against. Nothing about one bottle
    /// should ever be read through another one's calibration, and a drink is the
    /// difference between two readings of the *same* bottle.
    public func activate(store newStore: CalibrationStore?) {
        guard newStore?.keyPrefix != store?.keyPrefix else { return }
        store = newStore
        storedCalibration = newStore?.loadCalibration()
        creep.reset(mlPerSecond: newStore?.loadCreepMLPerSecond() ?? 0)
        tracker.reset(baselineML: newStore?.loadBaselineML(), lastReadingAt: newStore?.loadLastLevel()?.date,
                      creepMLPerSecond: creep.mlPerSecond)
        if let capacity = storedCalibration?.capacityML { tracker.capacityML = capacity }
        believedLevelML = newStore?.loadBelievedLevelML()
        believedLevelSetAt = newStore?.loadBelievedLevelSetAt()
        rememberedRaw = newStore?.loadLastRaw()?.raw
        stableRaw = nil
        latestWeight = nil
        stableStreak = 0
        weightSampleCount = 0
        filter.reset()
        awaitingFirstSettledReading = false
        levelChanges = []
        sips = []
        deviceInformation = [:]
        batteryPercent = nil
        bottleCapacityML = nil
        capState = nil
        capChangedAt = nil
        connectedRSSI = nil
        connectedRSSIAt = nil
    }

    /// Switch to one of the bottles you own: its saved calibration and level, and a
    /// connection to it in place of whatever is connected now.
    public func use(_ saved: SavedBottle, defaults: UserDefaults = .standard) {
        connectedBottleName = saved.name
        activate(store: saved.store(defaults: defaults))
        client.use(identifier: saved.peripheralID, name: saved.name)
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
    /// Watches every weight sample for the zero sinking on its own; the tracker discounts
    /// drops by it. Saved with the baseline so a relaunch starts knowing.
    private var creep = CreepEstimator()
    /// True until the first settled reading of a session, which is the one that has to
    /// account for anything drunk while the bottle was away.
    private var awaitingFirstSettledReading = false
    private var stableSubscribers: [UUID: AsyncStream<Int>.Continuation] = [:]
    private var eventTask: Task<Void, Never>?
    private var store: CalibrationStore?

    public init(client: HidrateBottleClient = HidrateBottleClient(), store: CalibrationStore? = CalibrationStore()) {
        self.client = client
        self.store = store
        storedCalibration = store?.loadCalibration()
        if let baseline = store?.loadBaselineML() {
            creep.reset(mlPerSecond: store?.loadCreepMLPerSecond() ?? 0)
            tracker.reset(baselineML: baseline, lastReadingAt: store?.loadLastLevel()?.date,
                          creepMLPerSecond: creep.mlPerSecond)
        }
        believedLevelML = store?.loadBelievedLevelML()
        believedLevelSetAt = store?.loadBelievedLevelSetAt()
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

    /// How far above capacity the reading sits, when it does. The bottle cannot hold more
    /// than it holds, so this is the same stale zero as `zeroDriftML`, crept the other
    /// way. The app can't correct it on its own — a zero is captured from an empty bottle,
    /// and a full one has nothing to say about where empty is — so it says so instead.
    public var overFullML: Double? {
        guard let level = currentLevelML, let capacity = calibration?.capacityML,
              capacity > 0, level > capacity else { return nil }
        return level - capacity
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

    /// Level to show. The believed level first: it is the one that doesn't wander while
    /// the bottle sits still. The scale is the fallback, before enough has happened to
    /// know what the bottle holds.
    public var displayLevelML: Double? { believedLevelML ?? clampedLevelML ?? rememberedLevelML }

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

    /// How long a bottle stays in `bottles` after it was last heard.
    public var sightingLifetime: TimeInterval = 180

    public func startScanning() { client.startScanning() }
    public func stopScanning() { client.stopScanning() }
    public func setProximityListening(_ enabled: Bool) { client.setProximityListening(enabled) }

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

    /// Forget a level change — and when it was a drink that has turned out not to be one,
    /// which is what deleting its row usually means, believe the water is in the bottle
    /// again.
    ///
    /// `levelChanges` lasts only the process, and the bottle relaunches the app every time
    /// it reconnects, so a drink from earlier in the day is often found by nothing here.
    /// `volumeML` and `date` are the caller's own record of it for that case. Pass them
    /// only for a drink the bottle measured — one logged by hand never touched the
    /// bottle.
    public func removeLevelChange(id: UUID, volumeML: Double? = nil, date: Date? = nil) {
        let event = levelChanges.first { $0.id == id }
        levelChanges.removeAll { $0.id == id }
        let drink: (volumeML: Double, date: Date)?
        if let event {
            drink = event.change.isDrink ? (event.change.volumeML, event.date) : nil
        } else if let volumeML, let date {
            drink = (volumeML, date)
        } else {
            drink = nil
        }
        guard let drink, let capacity = calibration?.capacityML, capacity > 0,
              let restored = Self.believedLevel(believedLevelML, capacityML: capacity, restoring: drink.volumeML,
                                                drunkAt: drink.date, setAt: believedLevelSetAt) else { return }
        believedLevelML = restored
        store?.saveBelievedLevelML(restored)
    }

    /// The believed level once a drink of `volumeML`, taken at `drunkAt`, is known not to
    /// have happened: the water goes back, up to a full bottle. Nil when there is nothing
    /// to put back — no level is being carried, or it was set outright at `setAt` after
    /// the drink, and that reset already counted whatever was in the bottle.
    nonisolated public static func believedLevel(_ believed: Double?, capacityML: Double, restoring volumeML: Double,
                                                 drunkAt: Date, setAt: Date?) -> Double? {
        guard let believed, volumeML > 0 else { return nil }
        if let setAt, drunkAt < setAt { return nil }
        return min(believed + volumeML, capacityML)
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
        case .discovered(let bottle):
            if let index = bottles.firstIndex(where: { $0.id == bottle.id }) {
                bottles[index] = bottle
            } else {
                bottles.append(bottle)
            }
            // The list outlives any one scan — the proximity listen keeps filling it while
            // nobody is looking — so it is trimmed by age rather than emptied on demand.
            let cutoff = Date().addingTimeInterval(-sightingLifetime)
            bottles.removeAll { $0.lastSeen < cutoff && $0.id != bottle.id }
            bottles.sort { $0.rssi > $1.rssi }
        case .connection(let state):
            if state != connectionState { connectionStateChangedAt = Date() }
            let wasReady = { if case .ready = connectionState { return true } else { return false } }()
            connectionState = state
            if case .ready = state, !wasReady {
                awaitingFirstSettledReading = true
                // Whatever the bottle did while it was out of sight is not measured: the
                // first reading of a session is where the bottle now sits, not a step
                // from the last one seen. A session can start over without a disconnect
                // in between — a second connect attempt completing on the bottle's old
                // address, for one — and that is a gap too.
                tracker.sessionStarted()
            }
            if !state.isConnected {
                filter.reset()
                creep.reset()
                tracker.forgetHeldDrink()
                stableStreak = 0
                capState = nil
                gatt = nil
                connectedRSSI = nil
                connectedRSSIAt = nil
            }
        case .gatt(let inventory):
            gatt = inventory
        case .deviceInformation(let info):
            deviceInformation = info
        case .battery(let level):
            batteryPercent = level
        case .rssi(let value):
            connectedRSSI = value
            connectedRSSIAt = Date()
        case .bottleConfig(let config):
            bottleCapacityML = config.capacityML
        case .cap(let state):
            capState = state
            capChangedAt = Date()
        case .weight(let sample):
            latestWeight = sample
            weightSampleCount += 1
            if let calibration, calibration.isValid {
                creep.observe(levelML: calibration.milliliters(forRaw: Double(sample.raw)), at: sample.receivedAt)
                tracker.creepMLPerSecond = creep.mlPerSecond
            }
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

        // Below empty is where a sunk zero puts an empty bottle, and it is tracked like
        // anywhere else: the tracker measures differences, and only the person moves the
        // zero. It is noted, so the log can explain a level that reads under nothing.
        let plausible = levelML >= belowEmptyNoteML
        let baselineBefore = tracker.baselineML

        // A drop held back until it proved itself belongs at the moment it happened, not
        // at the reading a minute later that confirmed it.
        let heldSince = tracker.heldDrinkSince
        var change = tracker.ingest(levelML: levelML, at: date)
        // Only what the bottle held can have left it — a bottleful at the very most. A
        // drop past that is the zero sinking, or a hand taking some of the weight off the
        // sensor, and neither is water; a bottle believed empty has nothing to give.
        var cappedFromML: Double?
        if let measured = change, measured.isDrink {
            let capped = Self.drink(measured, cappedAt: believedLevelML ?? calibration.capacityML,
                                    minDrinkML: tracker.configuration.minDrinkML)
            if capped != measured {
                cappedFromML = measured.volumeML
                change = capped
            }
        }
        let happenedAt = change?.isDrink == true ? (heldSince ?? date) : date
        let wasFirst = awaitingFirstSettledReading
        awaitingFirstSettledReading = false
        onSettledReading?(SettledReading(
            date: date, raw: raw, levelML: levelML, baselineBeforeML: baselineBefore,
            change: change, plausible: plausible, isFirstOfSession: wasFirst,
            cappedFromML: cappedFromML
        ))

        // Saved whatever the reading says, below empty or not: a relaunch has to pick the
        // tracker up exactly where it left off, and an empty bottle whose zero has sunk is
        // the ordinary case, not an exception.
        rememberedRaw = raw
        store?.saveLastRaw(raw, date: date)
        store?.saveBaselineML(tracker.baselineML)
        store?.saveLastLevel(tracker.baselineML ?? levelML, date: date)
        store?.saveCreepMLPerSecond(creep.mlPerSecond)

        applyToBelievedLevel(change, measuredLevelML: levelML, at: date)

        guard let change, !change.isBaseline, !change.isHandled else { return }
        let event = LevelChangeEvent(id: UUID(), date: happenedAt, change: change, stableRaw: raw)
        levelChanges.insert(event, at: 0)
        onLevelChange?(event)
    }

    /// A measured drink cut down to what the bottle is believed to hold — or, when nothing
    /// is believed yet, to a bottleful. Nil when the bottle held too little for any of it
    /// to have been a drink; unchanged when nothing is known to cap it by.
    nonisolated public static func drink(_ change: LevelChange, cappedAt contents: Double?,
                                         minDrinkML: Double) -> LevelChange? {
        guard case .drink(let volume, let from, let to) = change, let contents, volume > contents else { return change }
        guard contents >= minDrinkML else { return nil }
        return .drink(volumeML: contents, fromML: from, toML: to)
    }

    /// Move the believed level by what actually happened, never by what the scale says.
    private func applyToBelievedLevel(_ change: LevelChange?, measuredLevelML: Double, at date: Date) {
        guard let capacity = calibration?.capacityML, capacity > 0 else { return }
        switch change {
        case .drink(let volumeML, _, _):
            believedLevelML = max((believedLevelML ?? measuredLevelML) - volumeML, 0)
        case .refill(let volumeML, _, _):
            // Adding most of a bottleful can only mean it started near empty and is now
            // near full — the water had nowhere else to go. That is the one moment the
            // contents are known from a difference alone, so it is where a believed level
            // that has fallen out of step comes back. A smaller top-up says only how much
            // went in, not how much is there.
            if volumeML >= capacity * filledToTheTopFraction {
                resetBelievedLevel(to: capacity, at: date)
                return
            }
            believedLevelML = min((believedLevelML ?? measuredLevelML) + volumeML, capacity)
        case .handled:
            // The bottle was picked up or set down. Nothing left it and nothing went in.
            return
        case .baseline where believedLevelML == nil:
            // Nothing to carry forward yet; start from the scale, wrong as it may be.
            resetBelievedLevel(to: min(max(measuredLevelML, 0), capacity), at: date)
            return
        case .baseline, .none:
            return
        }
        store?.saveBelievedLevelML(believedLevelML)
    }

    /// Set the believed level outright, and remember when, so a drink deleted later
    /// knows whether it is still counted in it.
    private func resetBelievedLevel(to level: Double?, at date: Date) {
        believedLevelML = level
        believedLevelSetAt = date
        store?.saveBelievedLevelML(level)
        store?.saveBelievedLevelSetAt(date)
    }
}
