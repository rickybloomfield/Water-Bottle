import CoreBluetooth
import Foundation

/// Which sip-record characteristic the connected firmware exposes.
public enum ProtocolPath: String, Sendable {
    /// `BF2D1BA1…` (newer firmware).
    case modern
    /// `016E11B1…` (firmware 80.18 and older).
    case legacy
}

public enum ConnectionState: Sendable, Equatable {
    case disconnected(reason: String?)
    case connecting
    case discoveringServices
    case handshaking
    case ready(ProtocolPath?)

    public var isConnected: Bool {
        switch self {
        case .disconnected, .connecting: false
        case .discoveringServices, .handshaking, .ready: true
        }
    }

    /// Short, user-facing status.
    public var label: String {
        switch self {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .discoveringServices, .handshaking: "Setting up…"
        case .ready: "Connected"
        }
    }

    /// Detailed status for logs and tooling.
    public var technicalLabel: String {
        switch self {
        case .disconnected(let reason): reason.map { "Disconnected (\($0))" } ?? "Disconnected"
        case .connecting: "Connecting"
        case .discoveringServices: "Discovering services"
        case .handshaking: "Handshaking"
        case .ready(let path): path.map { "Ready (\($0.rawValue) path)" } ?? "Ready (no sip channel)"
        }
    }
}

public struct DiscoveredBottle: Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var rssi: Int
    public var lastSeen: Date
    public var isConnectable: Bool
    public var advertisedServices: [String]
    public var manufacturerData: Data?
}

public struct GATTCharacteristicInfo: Sendable, Identifiable, Hashable {
    public let serviceUUID: String
    public let uuid: String
    public let propertiesRawValue: UInt
    public var isNotifying: Bool

    public init(serviceUUID: String, uuid: String, properties: CBCharacteristicProperties, isNotifying: Bool) {
        self.serviceUUID = serviceUUID
        self.uuid = uuid
        self.propertiesRawValue = properties.rawValue
        self.isNotifying = isNotifying
    }

    public var properties: CBCharacteristicProperties { CBCharacteristicProperties(rawValue: propertiesRawValue) }

    public var id: String { serviceUUID + "/" + uuid }
    public var name: String? { HidrateUUID.name(for: uuid) }
    public var serviceName: String? { HidrateUUID.name(for: serviceUUID) }

    public var propertyList: String {
        var parts: [String] = []
        if properties.contains(.read) { parts.append("read") }
        if properties.contains(.write) { parts.append("write") }
        if properties.contains(.writeWithoutResponse) { parts.append("writeNR") }
        if properties.contains(.notify) { parts.append("notify") }
        if properties.contains(.indicate) { parts.append("indicate") }
        return parts.joined(separator: " ")
    }
}

public struct GATTInventory: Sendable, Hashable {
    public var services: [String]
    public var characteristics: [GATTCharacteristicInfo]

    public func characteristics(in service: String) -> [GATTCharacteristicInfo] {
        characteristics.filter { $0.serviceUUID == service }
    }

    public func has(_ characteristic: String) -> Bool {
        let key = HidrateUUID.normalize(characteristic)
        return characteristics.contains { $0.uuid == key }
    }
}

public struct CharacteristicValue: Sendable, Hashable {
    public let uuid: String
    public let data: Data
    public let receivedAt: Date
    public var name: String? { HidrateUUID.name(for: uuid) }
}

public enum LogLevel: Int, Sendable, Comparable {
    case debug, info, warning, error
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct LogEntry: Sendable, Identifiable, Hashable {
    public let id = UUID()
    public let date: Date
    public let level: LogLevel
    public let message: String
}

/// Everything the client can tell you. Consume via `HidrateBottleClient.events()`.
public enum BottleEvent: Sendable {
    case bluetoothState(CBManagerState)
    case scanning(Bool)
    case discovered(DiscoveredBottle)
    case connection(ConnectionState)
    case gatt(GATTInventory)
    case deviceInformation([String: String])
    case battery(Int)
    /// Signal strength of the connected bottle, in dBm, from a `readRSSI()`.
    case rssi(Int)
    /// The bottle's own configuration block (capacity in mL), read from the Reference service.
    case bottleConfig(BottleConfig)
    case weight(WeightSample)
    case cap(CapState)
    case sip(SipRecord)
    /// A read or a notification on a characteristic the SDK does not decode.
    case rawValue(CharacteristicValue)
    case log(LogEntry)
}

/// A settled reading and what the tracker made of it, for the session log.
public struct SettledReading: Sendable, Hashable {
    public var date: Date
    public var raw: Int
    public var levelML: Double
    /// The level the change was measured against, or nil when the tracker had nothing to
    /// compare with — which is how a drink goes missing without a trace.
    public var baselineBeforeML: Double?
    public var change: LevelChange?
    /// False when the reading sits below empty — where a sunk zero puts an empty bottle.
    /// Tracked all the same; noted so the log can explain a level under nothing.
    public var plausible: Bool
    /// The first settled reading after connecting, which is the one that has to account
    /// for anything drunk while the bottle was away.
    public var isFirstOfSession: Bool
    /// What the drink measured before being cut down to what the bottle was believed to
    /// hold, when it was.
    public var cappedFromML: Double?

    public init(date: Date, raw: Int, levelML: Double, baselineBeforeML: Double?,
                change: LevelChange?, plausible: Bool, isFirstOfSession: Bool,
                cappedFromML: Double? = nil) {
        self.date = date
        self.raw = raw
        self.levelML = levelML
        self.baselineBeforeML = baselineBeforeML
        self.change = change
        self.plausible = plausible
        self.isFirstOfSession = isFirstOfSession
        self.cappedFromML = cappedFromML
    }

    /// One line for the session log. Only worth writing when something notable happened
    /// or could have: the rest are two-second heartbeats.
    public var logLine: String? {
        guard isFirstOfSession || baselineBeforeML == nil || !plausible
                || change?.isHandled == true || cappedFromML != nil else { return nil }
        let baseline = baselineBeforeML.map { String(Int($0.rounded())) } ?? "none"
        let outcome = change.map { String(describing: $0) } ?? "no change"
        var line = "settled raw=\(raw) level=\(Int(levelML.rounded()))mL baseline=\(baseline) → \(outcome)"
        if !plausible { line += " [below empty]" }
        if let cappedFromML { line += " [measured \(Int(cappedFromML.rounded()))mL; only what the bottle held]" }
        if isFirstOfSession { line += " [first of session]" }
        return line
    }
}
