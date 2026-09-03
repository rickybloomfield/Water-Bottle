import CoreBluetooth
import Foundation
import Observation

/// A drink or refill detected from the weight stream.
public struct LevelChangeEvent: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let date: Date
    public let change: LevelChange
    public let stableRaw: Int

    public var volumeML: Double {
        switch change {
        case .baseline: 0
        case .drink(let v, _, _), .refill(let v, _, _): v
        }
    }

    public var isDrink: Bool {
        if case .drink = change { return true }
        return false
    }
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
    public private(set) var stableStreak = 0
    public private(set) var weightSampleCount = 0
    public private(set) var sips: [SipRecord] = []
    public private(set) var rawValues: [CharacteristicValue] = []
    public private(set) var logs: [LogEntry] = []
    public private(set) var levelChanges: [LevelChangeEvent] = []

    /// Called on the main actor for every detected drink or refill.
    public var onLevelChange: (@MainActor (LevelChangeEvent) -> Void)?
    /// Called on the main actor for every sip record the bottle reports.
    public var onSip: (@MainActor (SipRecord) -> Void)?
    /// Called on the main actor for every raw event, before the model processes it.
    /// Useful for persisting a session log.
    public var onEvent: (@MainActor (BottleEvent) -> Void)?
    /// When the current connection attempt or session began.
    public private(set) var connectionStateChangedAt = Date()

    public var maxLogEntries = 500
    public var maxRawValues = 200

    public var calibration: BottleCalibration? {
        didSet {
            store?.saveCalibration(calibration)
            tracker.reset()
            store?.saveBaselineML(nil)
        }
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
    private var stableSubscribers: [UUID: AsyncStream<Int>.Continuation] = [:]
    private var eventTask: Task<Void, Never>?
    private let store: CalibrationStore?

    public init(client: HidrateBottleClient = HidrateBottleClient(), store: CalibrationStore? = CalibrationStore()) {
        self.client = client
        self.store = store
        calibration = store?.loadCalibration()
        if let baseline = store?.loadBaselineML() {
            tracker.reset(baselineML: baseline)
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

    public var fillFraction: Double? {
        guard let calibration, calibration.isValid, let stableRaw else { return nil }
        return calibration.fillFraction(forRaw: Double(stableRaw))
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
        return client.reconnectLastBottle()
    }

    public func disconnect() { client.disconnect() }
    public func drainSips() { client.drainSips() }
    public func pulseLED(_ pattern: LEDPattern = .shortPulseWhite) { client.setLED(pattern) }

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
            connectionState = state
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
                trackLevel(stableRaw: stable, at: sample.receivedAt)
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

    private func trackLevel(stableRaw: Int, at date: Date) {
        guard let calibration, calibration.isValid else { return }
        let levelML = calibration.milliliters(forRaw: Double(stableRaw))
        guard let change = tracker.ingest(levelML: levelML, at: date) else { return }
        store?.saveBaselineML(tracker.baselineML)
        let event = LevelChangeEvent(id: UUID(), date: date, change: change, stableRaw: stableRaw)
        if case .baseline = change {
            return
        }
        levelChanges.insert(event, at: 0)
        onLevelChange?(event)
    }
}
