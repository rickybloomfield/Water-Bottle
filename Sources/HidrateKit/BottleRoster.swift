import Foundation

/// One bottle the app knows about.
///
/// The identity is the advertised name (`h2oDB618BB`), because that is the only thing
/// about a PRO 2 that survives the quarter-hourly Bluetooth address change. The
/// CoreBluetooth identifier is kept alongside it as the current address, and replaced
/// whenever the bottle turns up under a new one.
public struct SavedBottle: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var nickname: String
    public var peripheralID: UUID?
    public var serialNumber: String?
    public var modelNumber: String?
    public var firmwareRevision: String?
    public var hardwareRevision: String?
    /// Capacity the bottle reports for itself, in millilitres.
    public var capacityML: Int?
    /// How much water was poured in between the empty and full captures, which is what
    /// the calibration is scaled against. Per bottle, since bottles differ.
    public var calibrationCapacityML: Double?
    public var batteryPercent: Int?
    public var addedAt: Date
    public var lastConnectedAt: Date?
    /// Prefix for this bottle's own calibration and level, stored so the bottle carried
    /// over from before there was a list keeps reading its existing keys.
    public var storeKeyPrefix: String

    public init(
        name: String,
        nickname: String = "",
        peripheralID: UUID? = nil,
        addedAt: Date = Date(),
        storeKeyPrefix: String? = nil
    ) {
        self.name = name
        self.nickname = nickname
        self.peripheralID = peripheralID
        self.addedAt = addedAt
        self.storeKeyPrefix = storeKeyPrefix ?? Self.defaultKeyPrefix(for: name)
    }

    public var id: String { name }
    public var displayName: String { nickname.isEmpty ? name : nickname }

    /// Keys for a bottle added to the list, kept away from the single-bottle keys the
    /// first one still uses.
    public static func defaultKeyPrefix(for name: String) -> String {
        "HidrateKit.bottle." + name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    public func store(defaults: UserDefaults = .standard) -> CalibrationStore {
        CalibrationStore(defaults: defaults, keyPrefix: storeKeyPrefix)
    }

    /// Fold in what a connection just taught us about the bottle.
    public mutating func absorb(deviceInformation: [String: String], capacityML: Int?, batteryPercent: Int?) {
        serialNumber = deviceInformation["Serial Number"] ?? serialNumber
        modelNumber = deviceInformation["Model Number"] ?? modelNumber
        firmwareRevision = deviceInformation["Firmware Revision"] ?? firmwareRevision
        hardwareRevision = deviceInformation["Hardware Revision"] ?? hardwareRevision
        self.capacityML = capacityML ?? self.capacityML
        self.batteryPercent = batteryPercent ?? self.batteryPercent
    }
}

/// The bottles you own and which of them is in use.
public struct BottleRoster: Codable, Sendable, Equatable {
    public var bottles: [SavedBottle] = []
    /// The bottle currently being connected to, by `SavedBottle.id`.
    public var activeID: String?

    public init(bottles: [SavedBottle] = [], activeID: String? = nil) {
        self.bottles = bottles
        self.activeID = activeID
    }

    public var active: SavedBottle? {
        activeID.flatMap { id in bottles.first { $0.id == id } }
    }

    public subscript(id: String) -> SavedBottle? {
        get { bottles.first { $0.id == id } }
        set {
            guard let newValue else {
                bottles.removeAll { $0.id == id }
                return
            }
            if let index = bottles.firstIndex(where: { $0.id == id }) {
                bottles[index] = newValue
            } else {
                bottles.append(newValue)
            }
        }
    }

    @discardableResult
    public mutating func add(_ bottle: SavedBottle) -> SavedBottle {
        if let existing = self[bottle.id] { return existing }
        bottles.append(bottle)
        return bottle
    }

    /// Remove a bottle and everything saved under its name.
    public mutating func remove(id: String, defaults: UserDefaults = .standard) {
        self[id]?.store(defaults: defaults).erase()
        bottles.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
    }
}

/// Where the roster lives between launches.
public enum BottleRosterStore {
    static let key = "HidrateKit.roster"

    public static func load(defaults: UserDefaults = .standard) -> BottleRoster? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(BottleRoster.self, from: data)
    }

    public static func save(_ roster: BottleRoster, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(roster) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Decides which of the bottles you own should be the connected one.
///
/// Radio strength stands in for distance, and it is a noisy stand-in: two bottles on the
/// same desk swap places several times a minute. Every swap costs a disconnect, a
/// handshake and a hole in the weight stream, so a challenger has to win by a margin,
/// hold that margin for a while, and wait until the bottle in possession has had a turn.
/// Two bottles the same distance away therefore never trade — the margin is never met —
/// and one you actually pick up takes over within half a minute.
public struct ProximitySelector: Sendable {
    public struct Configuration: Codable, Sendable, Equatable {
        /// How much louder a challenger has to be heard before it counts as closer.
        public var marginDB: Double
        /// How long it has to keep that lead.
        public var sustainedFor: TimeInterval
        /// The shortest turn a bottle gets once it takes over.
        public var minimumTurn: TimeInterval
        /// A bottle not heard from in this long is out of range.
        public var sightingLifetime: TimeInterval
        /// Weight given to each new reading, 0…1. Low is smooth and slow.
        public var smoothing: Double

        public init(
            marginDB: Double = 8,
            sustainedFor: TimeInterval = 30,
            minimumTurn: TimeInterval = 120,
            sightingLifetime: TimeInterval = 180,
            smoothing: Double = 0.35
        ) {
            self.marginDB = marginDB
            self.sustainedFor = sustainedFor
            self.minimumTurn = minimumTurn
            self.sightingLifetime = sightingLifetime
            self.smoothing = smoothing
        }
    }

    public var configuration: Configuration

    private var strengths: [String: Double] = [:]
    private var lastHeard: [String: Date] = [:]
    private var challenger: (id: String, since: Date)?
    private var active: String?
    private var activeSince: Date?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Note that a bottle was heard, however it was heard: advertising while we scan, or
    /// the link's own signal strength while it is connected.
    public mutating func heard(_ id: String, rssi: Int, at date: Date = Date()) {
        let value = Double(rssi)
        if let previous = strengths[id], let when = lastHeard[id],
           date.timeIntervalSince(when) <= configuration.sightingLifetime {
            strengths[id] = previous + configuration.smoothing * (value - previous)
        } else {
            // Nothing recent to smooth against; the reading in hand is the best estimate.
            strengths[id] = value
        }
        lastHeard[id] = date
    }

    /// Smoothed strength in dBm, or nil when the bottle hasn't been heard lately.
    public func strength(of id: String, now: Date = Date()) -> Double? {
        guard let when = lastHeard[id], now.timeIntervalSince(when) <= configuration.sightingLifetime else { return nil }
        return strengths[id]
    }

    public func lastHeard(_ id: String) -> Date? { lastHeard[id] }

    /// Hand it to this bottle and start its turn, for a choice made by hand.
    public mutating func pin(_ id: String?, at date: Date = Date()) {
        active = id
        activeSince = id == nil ? nil : date
        challenger = nil
    }

    /// Forget a bottle that is no longer owned.
    public mutating func forget(_ id: String) {
        strengths[id] = nil
        lastHeard[id] = nil
        if challenger?.id == id { challenger = nil }
        if active == id { pin(nil) }
    }

    /// Which of `known` should be connected now. Nil when none of them can be heard and
    /// there is no incumbent to keep.
    public mutating func choose(from known: [String], now: Date = Date()) -> String? {
        let owned = Set(known)
        if let active, !owned.contains(active) { pin(nil, at: now) }

        let audible = known
            .compactMap { id in strength(of: id, now: now).map { (id: id, strength: $0) } }
            .sorted { $0.strength > $1.strength }

        guard let best = audible.first else {
            // Nothing to hear. A bottle in a bag is still the one in use, so keep it.
            return active
        }
        guard let incumbent = active else {
            pin(best.id, at: now)
            return best.id
        }
        guard let held = audible.first(where: { $0.id == incumbent }) else {
            // The one in use has gone quiet and another hasn't. Take the one that's here.
            pin(best.id, at: now)
            return best.id
        }
        guard best.id != incumbent else {
            challenger = nil
            return incumbent
        }
        guard best.strength - held.strength >= configuration.marginDB else {
            // Within earshot of each other: not a real difference, so nothing moves.
            challenger = nil
            return incumbent
        }
        if challenger?.id != best.id { challenger = (best.id, now) }
        guard let since = challenger?.since, now.timeIntervalSince(since) >= configuration.sustainedFor,
              now.timeIntervalSince(activeSince ?? .distantPast) >= configuration.minimumTurn else {
            return incumbent
        }
        pin(best.id, at: now)
        return best.id
    }
}
