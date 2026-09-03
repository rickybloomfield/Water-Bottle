import CoreBluetooth
import Foundation
import os

/// Tunables for `HidrateBottleClient`.
public struct BottleClientOptions: Sendable, Equatable {
    public enum HandshakeMode: String, Sendable, CaseIterable, Identifiable {
        /// Detect the bottle and pick the right init automatically (recommended).
        case auto
        /// Full PRO 2 init captured from the official app (firmware 100.x).
        case pro2
        /// Older Spark/PRO 13-step replay.
        case capturedReplay
        /// Decoded older-firmware sequence with the real time of day.
        case computed
        /// Skip the handshake.
        case none

        public var id: String { rawValue }
    }

    public var handshake: HandshakeMode = .auto
    /// Write `0x57` automatically after subscribing and after every pending-record frame.
    public var autoDrainSips = true
    /// Subscribe to every notify/indicate characteristic, decoded or not (exploration mode).
    /// Off by default: some firmware drops the link when unusual characteristics are enabled.
    public var subscribeToAllNotifying = false
    /// Read the battery level this often while connected so the link never sits idle.
    /// Set to nil to disable. Reads are slow on PRO 2 firmware, so keep this sparse.
    public var keepAliveInterval: TimeInterval? = 60
    /// Poll the weight characteristic by reading it this often. Off by default: PRO 2
    /// firmware 100.64 answers a read with a single `00` byte and queues reads for tens of
    /// seconds, so only the ~15 s notifications carry real values.
    public var weightPollInterval: TimeInterval? = nil
    /// After connecting, read every readable characteristic once and surface the values
    /// as `rawValue` events. Cheap, and the fastest way to map unfamiliar firmware.
    public var readUnknownCharacteristicsOnConnect = true
    public var readDeviceInformation = true
    /// Re-issue the connect request whenever the link drops. CoreBluetooth then connects
    /// again as soon as the bottle is back in range, including from the background on iOS.
    public var autoReconnect = true
    /// Only report peripherals that look like bottles while scanning.
    public var onlyBottles = true
    public var namePrefix = HidrateUUID.advertisedNamePrefix
    /// Stop acking a sip record that the firmware keeps re-sending after this many repeats.
    public var maxIdenticalSipFrames = 5
    /// iOS state-restoration identifier. Requires the `bluetooth-central` background mode.
    public var restoreIdentifier: String? = nil
    /// While a connect request is pending, also scan for the bottle's advertised service and
    /// switch to it if it reappears under a new identifier. The bottle changes its Bluetooth
    /// address (and therefore its CoreBluetooth identifier) from time to time; a connect
    /// request aimed at the old identity never completes. Strongly recommended.
    public var rescanWhileConnecting = true

    public init() {}
}

/// Owns the CoreBluetooth central, speaks the bottle's protocol and publishes
/// everything it learns as `BottleEvent`s.
///
/// All CoreBluetooth work happens on a private serial queue. The public API is safe to
/// call from anywhere; state is read back through `events()`.
public final class HidrateBottleClient: NSObject, @unchecked Sendable {
    public var options: BottleClientOptions {
        get { queue.sync { _options } }
        set { queue.async { self._options = newValue } }
    }

    private var _options: BottleClientOptions
    private let queue = DispatchQueue(label: "HidrateKit.ble", qos: .userInitiated)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristics: [String: CBCharacteristic] = [:]
    private var services: [String] = []
    private var pendingCharacteristicDiscoveries = 0
    private var sessionActive = false  // true from didConnect until disconnect; blocks duplicate discovery
    private var wantsConnection = false
    private var scanRequested = false
    private var targetIdentifier: UUID?
    private var dataCharacteristicUUID: String?
    private var protocolPath: ProtocolPath?
    private var initialDrainDone = false
    private var lastSipFrameHex: String?
    private var sipFrameRepeat = 0
    private var handshakeWorkItems: [DispatchWorkItem] = []
    private var deviceInformation: [String: String] = [:]
    private var keepAliveTimer: DispatchSourceTimer?
    private var weightPollTimer: DispatchSourceTimer?
    private var connectAttemptStarted: Date?
    private var reconnectScanTimer: DispatchSourceTimer?
    private var reconnectScanActive = false
    private var reconnectScanSightings = 0
    private var manualRetryInProgress = false
    private var targetName: String?
    private var state: ConnectionState = .disconnected(reason: nil) {
        didSet { emit(.connection(state)) }
    }

    private let subscribersLock = NSLock()
    private var subscribers: [UUID: AsyncStream<BottleEvent>.Continuation] = [:]
    private let logger = Logger(subsystem: "HidrateKit", category: "BottleClient")

    private static let lastBottleKey = "HidrateKit.lastBottleIdentifier"
    private static let lastBottleNameKey = "HidrateKit.lastBottleName"

    public init(options: BottleClientOptions = BottleClientOptions()) {
        _options = options
        super.init()
        var managerOptions: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: true]
        #if os(iOS)
        if let id = options.restoreIdentifier {
            managerOptions[CBCentralManagerOptionRestoreIdentifierKey] = id
        }
        #endif
        central = CBCentralManager(delegate: self, queue: queue, options: managerOptions)
    }

    // MARK: - Events

    /// A fresh stream of events. Each call gets its own stream, primed with the current
    /// Bluetooth and connection state.
    public func events() -> AsyncStream<BottleEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<BottleEvent>.makeStream(bufferingPolicy: .bufferingNewest(1024))
        subscribersLock.withLock { subscribers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.subscribersLock.withLock { _ = self.subscribers.removeValue(forKey: id) }
        }
        queue.async { [weak self] in
            guard let self else { return }
            continuation.yield(.bluetoothState(self.central.state))
            continuation.yield(.connection(self.state))
        }
        return stream
    }

    private func emit(_ event: BottleEvent) {
        let continuations = subscribersLock.withLock { Array(subscribers.values) }
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    private func log(_ level: LogLevel, _ message: String) {
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        emit(.log(LogEntry(date: Date(), level: level, message: message)))
    }

    // MARK: - Scanning

    public func startScanning() {
        queue.async {
            guard self.central.state == .poweredOn else {
                self.scanRequested = true
                self.log(.warning, "Scan requested while Bluetooth is \(Self.describe(self.central.state)); will start when powered on")
                return
            }
            self.central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
            self.emit(.scanning(true))
            self.log(.info, "Scanning for peripherals named \(self._options.namePrefix)…")
        }
    }

    public func stopScanning() {
        queue.async {
            self.scanRequested = false
            if self.central.state == .poweredOn { self.central.stopScan() }
            self.emit(.scanning(false))
        }
    }

    // MARK: - Connecting

    /// The identifier of the last bottle `connect(to:)` was called with, if any.
    public var lastBottleIdentifier: UUID? {
        UserDefaults.standard.string(forKey: Self.lastBottleKey).flatMap(UUID.init(uuidString:))
    }

    /// The advertised name of the last bottle, used to find it again after an address change.
    public var lastBottleName: String? {
        UserDefaults.standard.string(forKey: Self.lastBottleNameKey)
    }

    public func connect(to identifier: UUID, name: String? = nil) {
        queue.async {
            self.targetIdentifier = identifier
            self.wantsConnection = true
            UserDefaults.standard.set(identifier.uuidString, forKey: Self.lastBottleKey)
            if let name, !name.isEmpty {
                self.targetName = name
                UserDefaults.standard.set(name, forKey: Self.lastBottleNameKey)
            } else {
                self.targetName = self.targetName ?? self.lastBottleName
            }
            if let pending = self.peripheral, pending.identifier == identifier, pending.state == .connecting {
                // A connect request is already queued with CoreBluetooth. Cancel it and
                // issue a fresh one so a manual retry has a visible effect.
                let waited = self.connectAttemptStarted.map { Int(Date().timeIntervalSince($0)) } ?? 0
                self.log(.info, "Cancelling pending connect (waited \(waited)s) and retrying")
                self.manualRetryInProgress = true
                self.central.cancelPeripheralConnection(pending)
                self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.attemptConnection() }
                return
            }
            self.attemptConnection()
        }
    }

    /// Reconnect to the bottle used last time. Returns false when there is none.
    @discardableResult
    public func reconnectLastBottle() -> Bool {
        guard let id = lastBottleIdentifier else { return false }
        connect(to: id, name: lastBottleName)
        return true
    }

    /// Kick a stalled reconnect. Safe to call often (e.g. when the app returns to the
    /// foreground). If a connect has been pending too long, it is cancelled and re-issued,
    /// and the by-name reconnect scan is (re)started.
    public func nudgeReconnect() {
        queue.async {
            guard self.wantsConnection, self.central.state == .poweredOn else { return }
            if self.sessionActive { return }
            let pendingFor = self.connectAttemptStarted.map { Date().timeIntervalSince($0) } ?? .infinity
            if let pending = self.peripheral, pending.state == .connecting {
                if pendingFor > 20 {
                    self.log(.info, "Reconnect pending \(Int(pendingFor))s; re-issuing")
                    self.manualRetryInProgress = true
                    self.central.cancelPeripheralConnection(pending)
                    self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.attemptConnection() }
                } else {
                    self.startReconnectScan()
                }
            } else {
                self.attemptConnection()
            }
        }
    }

    public func forgetLastBottle() {
        UserDefaults.standard.removeObject(forKey: Self.lastBottleKey)
        UserDefaults.standard.removeObject(forKey: Self.lastBottleNameKey)
        queue.async { self.targetName = nil }
    }

    public func disconnect() {
        queue.async {
            self.wantsConnection = false
            self.cancelHandshake()
            if let peripheral = self.peripheral {
                self.central.cancelPeripheralConnection(peripheral)
            } else {
                self.state = .disconnected(reason: nil)
            }
        }
    }

    private func attemptConnection() {
        guard central.state == .poweredOn, let id = targetIdentifier else { return }
        // Already connected to this peripheral? Don't reconnect; just make sure a session is running.
        if let existing = peripheral, existing.identifier == id, existing.state == .connected {
            beginSession(with: existing)
            return
        }
        guard let found = central.retrievePeripherals(withIdentifiers: [id]).first else {
            log(.error, "Peripheral \(id) is not known to this device yet; scan first")
            state = .disconnected(reason: "unknown peripheral")
            return
        }
        central.stopScan()
        emit(.scanning(false))
        peripheral = found
        found.delegate = self
        if targetName == nil, let name = found.name, !name.isEmpty {
            targetName = name
            UserDefaults.standard.set(name, forKey: Self.lastBottleNameKey)
        }
        state = .connecting
        connectAttemptStarted = Date()
        manualRetryInProgress = false
        log(.info, "Connecting to \(found.name ?? id.uuidString) [\(id.uuidString.prefix(8))] (peripheral state \(found.state.rawValue))…")
        central.connect(found, options: connectOptions)
        startReconnectScan()
    }

    // While a connect is pending, scan for the bottle's advertised service so we notice
    // when it comes back under a new identifier (address change) and connect to that.
    private func startReconnectScan() {
        cancelReconnectScan()
        guard _options.rescanWhileConnecting, central.state == .poweredOn else { return }
        reconnectScanActive = true
        reconnectScanSightings = 0
        central.scanForPeripherals(
            withServices: [CBUUID(string: HidrateUUID.referenceService)],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        let check = DispatchSource.makeTimerSource(queue: queue)
        check.schedule(deadline: .now() + 20, repeating: 30)
        check.setEventHandler { [weak self] in
            guard let self, self.reconnectScanActive else { return }
            let waited = self.connectAttemptStarted.map { Int(Date().timeIntervalSince($0)) } ?? 0
            if self.reconnectScanSightings == 0 {
                self.log(.warning, "Bottle not seen advertising for \(waited)s (asleep, charging, or held by another central)")
            } else {
                self.log(.warning, "Bottle is advertising but the connect has not completed after \(waited)s")
            }
        }
        check.resume()
        reconnectScanTimer = check
    }

    private func cancelReconnectScan() {
        reconnectScanTimer?.cancel()
        reconnectScanTimer = nil
        if reconnectScanActive {
            reconnectScanActive = false
            if central.state == .poweredOn { central.stopScan() }
        }
    }

    /// Called from the scan callback while a connect is pending.
    private func handleReconnectSighting(_ found: CBPeripheral, name: String, rssi: Int) {
        let matchesIdentifier = found.identifier == targetIdentifier
        let matchesName = targetName.map { !$0.isEmpty && $0 == name } ?? false
        guard matchesIdentifier || matchesName else { return }
        reconnectScanSightings += 1
        if matchesIdentifier {
            if reconnectScanSightings == 1 {
                log(.info, "Target bottle \(name) is advertising (rssi \(rssi)); waiting for iOS to connect")
            }
            return
        }
        // Same name, different identifier: the bottle's Bluetooth address changed.
        let old = targetIdentifier?.uuidString.prefix(8) ?? "-"
        log(.warning, "Bottle \(name) reappeared with a new identifier \(found.identifier.uuidString.prefix(8)) (was \(old)); its Bluetooth address changed. Switching.")
        if let stale = peripheral, stale.identifier != found.identifier, stale.state == .connecting {
            manualRetryInProgress = true
            central.cancelPeripheralConnection(stale)
        }
        targetIdentifier = found.identifier
        UserDefaults.standard.set(found.identifier.uuidString, forKey: Self.lastBottleKey)
        cancelReconnectScan()
        peripheral = found
        found.delegate = self
        connectAttemptStarted = Date()
        state = .connecting
        central.connect(found, options: connectOptions)
    }

    private var connectOptions: [String: Any] {
        var options: [String: Any] = [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true]
        #if os(iOS)
        if #available(iOS 17.0, *) {
            // Let CoreBluetooth re-establish the link itself after a supervision timeout.
            options[CBConnectPeripheralOptionEnableAutoReconnect] = true
        }
        #endif
        return options
    }

    private func startKeepAlive() {
        stopKeepAlive()
        guard let interval = _options.keepAliveInterval, interval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, let peripheral = self.peripheral, peripheral.state == .connected,
                  let battery = self.characteristic(HidrateUUID.batteryLevel) else { return }
            peripheral.readValue(for: battery)
        }
        timer.resume()
        keepAliveTimer = timer
    }

    private func stopKeepAlive() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        weightPollTimer?.cancel()
        weightPollTimer = nil
    }

    private func startWeightPolling() {
        guard let interval = _options.weightPollInterval, interval > 0,
              let weight = characteristic(HidrateUUID.weight), weight.properties.contains(.read) else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, let peripheral = self.peripheral, peripheral.state == .connected else { return }
            peripheral.readValue(for: weight)
        }
        timer.resume()
        weightPollTimer = timer
        log(.info, "Polling weight every \(Int(interval))s")
    }

    private func readUnknownCharacteristics() {
        guard let peripheral else { return }
        let decoded: Set<String> = Set(
            ([HidrateUUID.batteryLevel, HidrateUUID.weight] + HidrateUUID.deviceInformationCharacteristics)
                .map(HidrateUUID.normalize)
        )
        let readable = characteristics.values
            .filter { $0.properties.contains(.read) && !decoded.contains($0.uuid.uuidString) }
            .sorted { $0.uuid.uuidString < $1.uuid.uuidString }
        guard !readable.isEmpty else { return }
        log(.info, "Reading \(readable.count) other readable characteristics")
        for c in readable { peripheral.readValue(for: c) }
    }

    private static func describe(_ error: Error?) -> String {
        guard let error else { return "no error reported" }
        let ns = error as NSError
        return "\(error.localizedDescription) [\(ns.domain) \(ns.code)]"
    }

    private func handleDisconnect(_ peripheral: CBPeripheral, error: Error?, isReconnecting: Bool) {
        sessionActive = false
        if manualRetryInProgress {
            // Our own cancel of a pending connect; attemptConnection() is already scheduled.
            manualRetryInProgress = false
            log(.debug, "Pending connect cancelled")
            return
        }
        let reason = Self.describe(error)
        log(error == nil ? .info : .warning, "Disconnected: \(reason)\(isReconnecting ? " (system auto-reconnect pending)" : "")")
        resetSessionState()
        state = .disconnected(reason: error?.localizedDescription)
        guard wantsConnection, _options.autoReconnect else {
            self.peripheral = nil
            return
        }
        connectAttemptStarted = Date()
        state = .connecting
        if isReconnecting {
            log(.info, "CoreBluetooth is reconnecting automatically; waiting…")
        } else {
            log(.info, "Re-issuing connect; it completes when the bottle advertises again")
            central.connect(peripheral, options: connectOptions)
        }
        startReconnectScan()
    }

    // MARK: - Commands

    /// Ask the bottle for the next buffered sip record.
    public func drainSips() {
        queue.async {
            guard let uuid = self.dataCharacteristicUUID else {
                self.log(.warning, "No sip characteristic available; cannot drain")
                return
            }
            self.write(uuid, Data([self.sipRequestByte]))
        }
    }

    public func setLED(_ pattern: LEDPattern) {
        setLED(rawByte: pattern.rawValue)
    }

    public func setLED(rawByte: UInt8) {
        queue.async { self.write(HidrateUUID.ledControl, Data([rawByte])) }
    }

    public func readBattery() {
        read(characteristic: HidrateUUID.batteryLevel)
    }

    /// Send a handshake sequence manually (for experiments).
    public func sendHandshake(_ steps: [HandshakeStep]) {
        queue.async { self.runHandshake(steps) {} }
    }

    public func write(characteristic uuid: String, data: Data, withResponse: Bool? = nil) {
        queue.async { self.write(uuid, data, withResponse: withResponse) }
    }

    public func read(characteristic uuid: String) {
        queue.async {
            guard let peripheral = self.peripheral, let c = self.characteristic(uuid) else {
                self.log(.warning, "Read: characteristic \(uuid) not available")
                return
            }
            peripheral.readValue(for: c)
        }
    }

    public func setNotify(characteristic uuid: String, enabled: Bool) {
        queue.async {
            guard let peripheral = self.peripheral, let c = self.characteristic(uuid) else {
                self.log(.warning, "Notify: characteristic \(uuid) not available")
                return
            }
            peripheral.setNotifyValue(enabled, for: c)
        }
    }

    // MARK: - Internals (queue only)

    private func characteristic(_ uuid: String) -> CBCharacteristic? {
        characteristics[HidrateUUID.normalize(uuid)]
    }

    private func uuid(for target: HandshakeTarget) -> String {
        switch target {
        case .debug: HidrateUUID.debug
        case .setPoint: HidrateUUID.setPoint
        case .config: HidrateUUID.referenceConfig
        case .led: HidrateUUID.ledControl
        case .cmdA1: HidrateUUID.commandA1
        case .cmdA2: HidrateUUID.commandA2
        }
    }

    /// True when this is a PRO 2 (has the command-channel characteristic).
    private var isPRO2: Bool { characteristic(HidrateUUID.commandA2) != nil }
    /// Sip request/ack bytes differ by generation: PRO 2 uses 0x55/0x33, older uses 0x57.
    private var sipRequestByte: UInt8 { isPRO2 ? 0x55 : 0x57 }
    private var sipAckByte: UInt8? { isPRO2 ? 0x33 : nil }

    private func write(_ uuid: String, _ data: Data, withResponse: Bool? = nil) {
        guard let peripheral, let c = characteristic(uuid) else {
            log(.warning, "Write: characteristic \(uuid) not available")
            return
        }
        let type: CBCharacteristicWriteType
        if let withResponse {
            type = withResponse ? .withResponse : .withoutResponse
        } else {
            type = c.properties.contains(.write) ? .withResponse : .withoutResponse
        }
        log(.debug, "→ \(HidrateUUID.name(for: uuid) ?? uuid): \(data.hexString)")
        peripheral.writeValue(data, for: c, type: type)
    }

    private func resetSessionState() {
        cancelHandshake()
        stopKeepAlive()
        cancelReconnectScan()
        characteristics = [:]
        services = []
        pendingCharacteristicDiscoveries = 0
        dataCharacteristicUUID = nil
        protocolPath = nil
        initialDrainDone = false
        lastSipFrameHex = nil
        sipFrameRepeat = 0
        deviceInformation = [:]
    }

    private func cancelHandshake() {
        handshakeWorkItems.forEach { $0.cancel() }
        handshakeWorkItems = []
    }

    private func finishDiscovery() {
        let inventory = GATTInventory(
            services: services,
            characteristics: characteristics.values.map {
                GATTCharacteristicInfo(
                    serviceUUID: $0.service?.uuid.uuidString ?? "",
                    uuid: $0.uuid.uuidString,
                    properties: $0.properties,
                    isNotifying: $0.isNotifying
                )
            }.sorted { ($0.serviceUUID, $0.uuid) < ($1.serviceUUID, $1.uuid) }
        )
        emit(.gatt(inventory))
        log(.info, "Discovered \(services.count) services, \(characteristics.count) characteristics")
        if inventory.has(HidrateUUID.nordicDFUService) || inventory.has(HidrateUUID.nordicButtonlessDFU) {
            log(.info, "Nordic Secure DFU service present (firmware updates are signed Nordic DFU packages)")
        }
        afterDiscovery()
    }

    private func afterDiscovery() {
        guard let peripheral else { return }

        if let battery = characteristic(HidrateUUID.batteryLevel) {
            peripheral.readValue(for: battery)
            if battery.properties.contains(.notify) { peripheral.setNotifyValue(true, for: battery) }
        }

        if _options.readDeviceInformation {
            for uuid in HidrateUUID.deviceInformationCharacteristics {
                if let c = characteristic(uuid) { peripheral.readValue(for: c) }
            }
        }

        var mode = _options.handshake
        if mode == .auto { mode = isPRO2 ? .pro2 : .capturedReplay }
        let steps: [HandshakeStep]?
        switch mode {
        case .pro2: steps = HidrateHandshake.pro2()
        case .capturedReplay: steps = HidrateHandshake.capturedReplay
        case .computed: steps = HidrateHandshake.computed()
        case .auto, .none: steps = nil
        }

        if let steps, characteristic(HidrateUUID.setPoint) != nil {
            state = .handshaking
            log(.info, "Sending \(steps.count)-step \(mode.rawValue) init")
            runHandshake(steps) { [weak self] in self?.subscribeToStreams() }
            return
        }
        subscribeToStreams()
    }

    private func runHandshake(_ steps: [HandshakeStep], completion: @escaping @Sendable () -> Void) {
        cancelHandshake()
        let delayNanos = UInt64(HidrateHandshake.interStepDelay.components.attoseconds / 1_000_000_000)
            + UInt64(HidrateHandshake.interStepDelay.components.seconds) * 1_000_000_000
        for (index, step) in steps.enumerated() {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.write(self.uuid(for: step.target), step.payload)
            }
            handshakeWorkItems.append(item)
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(delayNanos) * index), execute: item)
        }
        let done = DispatchWorkItem { [weak self] in
            self?.handshakeWorkItems = []
            completion()
        }
        handshakeWorkItems.append(done)
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(delayNanos) * steps.count + 100_000_000), execute: done)
    }

    private func subscribeToStreams() {
        guard let peripheral else { return }

        if characteristic(HidrateUUID.userData) != nil {
            dataCharacteristicUUID = HidrateUUID.userData
            protocolPath = .modern
        } else if characteristic(HidrateUUID.dataPoint) != nil {
            dataCharacteristicUUID = HidrateUUID.dataPoint
            protocolPath = .legacy
        } else {
            log(.warning, "No sip-record characteristic found on this firmware")
        }

        var wanted: [String] = []
        if let dataCharacteristicUUID { wanted.append(dataCharacteristicUUID) }
        wanted.append(contentsOf: [HidrateUUID.debug, HidrateUUID.weight, HidrateUUID.setPoint, HidrateUUID.sensorSecondary])
        if _options.subscribeToAllNotifying {
            wanted.append(contentsOf: characteristics.keys.sorted())
        }

        var seen = Set<String>()
        for uuid in wanted.map(HidrateUUID.normalize) where !seen.contains(uuid) {
            seen.insert(uuid)
            guard let c = characteristics[uuid], !c.isNotifying,
                  c.properties.contains(.notify) || c.properties.contains(.indicate),
                  uuid != HidrateUUID.normalize(HidrateUUID.batteryLevel) else { continue }
            peripheral.setNotifyValue(true, for: c)
        }

        state = .ready(protocolPath)
        log(.info, "Ready. Sip path: \(protocolPath?.rawValue ?? "none")")
        startKeepAlive()
        startWeightPolling()
        if _options.readUnknownCharacteristicsOnConnect {
            queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.readUnknownCharacteristics() }
        }
    }

    private func handleSipFrame(_ data: Data) {
        guard let record = SipRecord(data: data) else {
            emit(.rawValue(CharacteristicValue(uuid: dataCharacteristicUUID ?? "", data: data, receivedAt: Date())))
            return
        }
        if record.isQueueEmptyMarker {
            lastSipFrameHex = nil
            sipFrameRepeat = 0
            log(.debug, "Sip queue empty")
            return
        }

        let hex = data.hexString
        if hex == lastSipFrameHex { sipFrameRepeat += 1 } else { sipFrameRepeat = 0 }
        lastSipFrameHex = hex

        if _options.autoDrainSips, let uuid = dataCharacteristicUUID {
            if sipFrameRepeat >= _options.maxIdenticalSipFrames {
                log(.warning, "Sip frame repeated \(sipFrameRepeat + 1)×; pausing auto-drain: \(hex)")
            } else {
                // PRO 2: acknowledge a real record with 0x33, then request the next with 0x55.
                if record.hasPayload, let ack = sipAckByte { write(uuid, Data([ack])) }
                write(uuid, Data([sipRequestByte]))
            }
        }

        if record.hasPayload {
            log(.info, "Sip: \(record.percentOfCapacity)% (day total \(record.cumulativePercent)%, \(record.pendingCount) pending) raw=\(hex)")
            emit(.sip(record))
        } else {
            log(.debug, "Sip announcement: \(record.pendingCount) record(s) pending")
        }
    }

    static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: "unknown"
        case .resetting: "resetting"
        case .unsupported: "unsupported"
        case .unauthorized: "unauthorized"
        case .poweredOff: "powered off"
        case .poweredOn: "powered on"
        @unknown default: "state \(state.rawValue)"
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension HidrateBottleClient: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emit(.bluetoothState(central.state))
        log(.info, "Bluetooth is \(Self.describe(central.state))")
        switch central.state {
        case .poweredOn:
            if scanRequested {
                scanRequested = false
                startScanning()
            }
            if let restored = peripheral, restored.state == .connected {
                log(.info, "Restored connection to \(restored.name ?? "bottle")")
                beginSession(with: restored)
            } else if wantsConnection {
                attemptConnection()
            }
        case .poweredOff, .unauthorized, .unsupported:
            if peripheral != nil || state.isConnected {
                sessionActive = false
                resetSessionState()
                peripheral = nil
                state = .disconnected(reason: "Bluetooth \(Self.describe(central.state))")
            }
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let first = restored.first else { return }
        log(.info, "Restored peripheral \(first.name ?? first.identifier.uuidString) (state \(first.state.rawValue))")
        peripheral = first
        first.delegate = self
        targetIdentifier = first.identifier
        targetName = targetName ?? first.name ?? lastBottleName
        if let name = targetName { UserDefaults.standard.set(name, forKey: Self.lastBottleNameKey) }
        wantsConnection = true
        // Do not talk to the peripheral yet: this callback arrives before the central
        // reports poweredOn, and requests made before that are dropped silently.
        // centralManagerDidUpdateState begins the session once powered on.
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = localName ?? peripheral.name ?? ""
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        let knownServices: Set<String> = [
            HidrateUUID.userService, HidrateUUID.referenceService, HidrateUUID.sensorService,
        ]
        let looksLikeBottle = name.lowercased().hasPrefix(_options.namePrefix.lowercased())
            || advertised.contains { knownServices.contains($0) }
        if reconnectScanActive {
            handleReconnectSighting(peripheral, name: name, rssi: RSSI.intValue)
        }
        if _options.onlyBottles, !looksLikeBottle { return }

        emit(.discovered(DiscoveredBottle(
            id: peripheral.identifier,
            name: name.isEmpty ? "(unnamed)" : name,
            rssi: RSSI.intValue,
            lastSeen: Date(),
            isConnectable: (advertisementData[CBAdvertisementDataIsConnectable] as? Bool) ?? true,
            advertisedServices: advertised,
            manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        )))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let waited = connectAttemptStarted.map { String(format: " after %.1fs", Date().timeIntervalSince($0)) } ?? ""
        log(.info, "Connected to \(peripheral.name ?? peripheral.identifier.uuidString)\(waited)")
        beginSession(with: peripheral)
    }

    /// Start service discovery for a freshly connected (or restored) peripheral exactly once.
    /// Restoration, the app's own reconnect call and the powered-on handler can all fire for
    /// the same connection; this collapses them into a single discovery + handshake.
    private func beginSession(with peripheral: CBPeripheral) {
        if sessionActive {
            log(.debug, "Session already active; ignoring duplicate connect")
            return
        }
        self.peripheral = peripheral
        peripheral.delegate = self
        sessionActive = true
        resetSessionState()
        state = .discoveringServices
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log(.error, "Connect failed: \(Self.describe(error))")
        state = .disconnected(reason: error?.localizedDescription ?? "connect failed")
        if wantsConnection, _options.autoReconnect {
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.attemptConnection() }
        }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handleDisconnect(peripheral, error: error, isReconnecting: false)
    }

    #if os(iOS)
    @available(iOS 17.0, *)
    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        handleDisconnect(peripheral, error: error, isReconnecting: isReconnecting)
    }
    #endif
}

// MARK: - CBPeripheralDelegate

extension HidrateBottleClient: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log(.error, "Service discovery failed: \(error.localizedDescription)")
            return
        }
        guard case .discoveringServices = state else {
            log(.debug, "Ignoring service-discovery callback outside discovery state")
            return
        }
        let found = peripheral.services ?? []
        services = found.map { $0.uuid.uuidString }
        pendingCharacteristicDiscoveries = found.count
        if found.isEmpty {
            finishDiscovery()
            return
        }
        for service in found {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log(.warning, "Characteristic discovery failed for \(service.uuid.uuidString): \(error.localizedDescription)")
        }
        for c in service.characteristics ?? [] {
            characteristics[c.uuid.uuidString] = c
        }
        pendingCharacteristicDiscoveries -= 1
        if pendingCharacteristicDiscoveries <= 0 {
            finishDiscovery()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid.uuidString
        if let error {
            log(.warning, "Notify failed for \(HidrateUUID.name(for: uuid) ?? uuid): \(error.localizedDescription)")
            return
        }
        log(.debug, "Notifications \(characteristic.isNotifying ? "on" : "off") for \(HidrateUUID.name(for: uuid) ?? uuid)")
        if characteristic.isNotifying, uuid == dataCharacteristicUUID, _options.autoDrainSips, !initialDrainDone {
            initialDrainDone = true
            write(uuid, Data([sipRequestByte]))
            if characteristic.properties.contains(.read) {
                queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, let peripheral = self.peripheral, let c = self.characteristic(uuid) else { return }
                    peripheral.readValue(for: c)
                }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid.uuidString
        if let error {
            log(.warning, "Value error for \(HidrateUUID.name(for: uuid) ?? uuid): \(error.localizedDescription)")
            return
        }
        let data = characteristic.value ?? Data()
        let now = Date()

        switch uuid {
        case HidrateUUID.batteryLevel:
            if let level = data.first { emit(.battery(Int(level))) }
        case HidrateUUID.weight:
            if let sample = WeightSample(data: data, receivedAt: now) {
                emit(.weight(sample))
            } else {
                emit(.rawValue(CharacteristicValue(uuid: uuid, data: data, receivedAt: now)))
            }
        case HidrateUUID.referenceConfig:
            if let capacity = BottleConfig(data: data) {
                log(.info, "Bottle-side capacity: \(capacity.capacityML) mL (raw \(data.hexString))")
                emit(.bottleConfig(capacity))
            } else {
                emit(.rawValue(CharacteristicValue(uuid: uuid, data: data, receivedAt: now)))
            }
        case HidrateUUID.debug:
            if let cap = CapState(data: data) {
                log(.info, "Cap \(cap.rawValue)")
                emit(.cap(cap))
            } else {
                emit(.rawValue(CharacteristicValue(uuid: uuid, data: data, receivedAt: now)))
            }
        case let u where u == dataCharacteristicUUID:
            handleSipFrame(data)
        case let u where HidrateUUID.deviceInformationCharacteristics.contains(u):
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
            deviceInformation[HidrateUUID.name(for: u) ?? u] = text
            emit(.deviceInformation(deviceInformation))
        default:
            emit(.rawValue(CharacteristicValue(uuid: uuid, data: data, receivedAt: now)))
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            let uuid = characteristic.uuid.uuidString
            log(.warning, "Write failed for \(HidrateUUID.name(for: uuid) ?? uuid): \(error.localizedDescription)")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        log(.warning, "Bottle changed its GATT table; rediscovering")
        resetSessionState()
        state = .discoveringServices
        peripheral.discoverServices(nil)
    }
}
