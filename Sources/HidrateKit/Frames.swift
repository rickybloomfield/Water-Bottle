import Foundation

/// One sip record as delivered on the data characteristic after a drain (`0x57`) write.
///
/// Layout (20 bytes, derived from real PRO traffic, see `docs/PROTOCOL.md`):
///
/// ```
/// [0]      records still pending after this one (0 = "queue empty" marker)
/// [1]      sip volume as a percentage of the bottle's configured capacity
/// [2..3]   running total for the day, little-endian u16, a sum of the percent field
/// [4]      flags, values 1 / 4 / 8 observed, meaning unknown
/// [5..7]   zero
/// [8..11]  constant 75 87 2a 8b on the logged bottle (an id or a sentinel)
/// [12..13] raw weight before the sip, little-endian u16
/// [14..15] raw weight after the sip, little-endian u16
/// [16..19] zero
/// ```
///
/// There is no timestamp in the frame. Records are pushed the moment we drain, so
/// `receivedAt` is the best available time for buffered records too.
public struct SipRecord: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let receivedAt: Date
    public let raw: Data
    public let pendingCount: Int
    public let percentOfCapacity: Int
    public let cumulativePercent: Int
    public let flags: Int
    public let rawWeightBefore: Int?
    public let rawWeightAfter: Int?

    public init?(data: Data, receivedAt: Date = Date()) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        id = UUID()
        self.receivedAt = receivedAt
        raw = data
        pendingCount = Int(bytes[0])
        percentOfCapacity = Int(bytes[1])
        cumulativePercent = Int(bytes[2]) | (Int(bytes[3]) << 8)
        flags = bytes.count > 4 ? Int(bytes[4]) : 0
        if bytes.count >= 16 {
            rawWeightBefore = Int(bytes[12]) | (Int(bytes[13]) << 8)
            rawWeightAfter = Int(bytes[14]) | (Int(bytes[15]) << 8)
        } else {
            rawWeightBefore = nil
            rawWeightAfter = nil
        }
    }

    /// `true` for the all-zero "nothing pending" frame the bottle sends when drained.
    public var isQueueEmptyMarker: Bool { pendingCount == 0 }

    /// `true` when the bytes after the count carry a record (some firmwares first
    /// send a bare "N pending" frame and deliver the record on the next drain).
    public var hasPayload: Bool { raw.dropFirst().contains { $0 != 0 } }

    /// Raw weight consumed by this sip, when the frame carries the weight pair.
    public var rawWeightDelta: Int? {
        guard let before = rawWeightBefore, let after = rawWeightAfter else { return nil }
        return before - after
    }

    /// Volume as the bottle computes it: a percentage of the capacity configured in the bottle.
    public func volumeML(capacityML: Double) -> Double {
        capacityML * Double(percentOfCapacity) / 100
    }

    /// Volume derived from the frame's own weight pair using a calibration (more
    /// trustworthy than the percent field, which depends on the bottle-side size).
    public func weightDerivedVolumeML(calibration: BottleCalibration) -> Double? {
        guard let delta = rawWeightDelta, calibration.isValid else { return nil }
        return Double(delta) / calibration.rawUnitsPerML
    }

    /// Basic corruption guards borrowed from field experience: a single sip never
    /// empties the bottle, and the percent field must roughly agree with the weight pair.
    public func isPlausible(rawUnitsPerML: Double?, capacityML: Double, headroom: Double = 3.0) -> Bool {
        guard percentOfCapacity > 0, percentOfCapacity < 100 else { return false }
        guard let rawUnitsPerML, rawUnitsPerML > 0, let delta = rawWeightDelta, delta > 0 else { return true }
        let supportedML = Double(delta) / rawUnitsPerML
        return volumeML(capacityML: capacityML) <= headroom * supportedML
    }

    public var hexString: String { raw.hexString }
}

/// One reading from the weight characteristic: a 16-bit big-endian value that rises
/// with the amount of water in the bottle. Readings taken while the bottle is lifted or
/// tilted are meaningless, which is why consumers should run them through
/// `StableWeightFilter` before trusting them.
public struct WeightSample: Sendable, Hashable {
    public let raw: Int
    public let receivedAt: Date
    public let payload: Data

    public init?(data: Data, receivedAt: Date = Date()) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        raw = (Int(bytes[0]) << 8) | Int(bytes[1])
        self.receivedAt = receivedAt
        payload = data
    }

    public init(raw: Int, receivedAt: Date = Date()) {
        self.raw = raw & 0xFFFF
        self.receivedAt = receivedAt
        payload = Data([UInt8(self.raw >> 8), UInt8(self.raw & 0xFF)])
    }

    /// Earlier community decoders treated the high byte as an orientation flag
    /// (0x8A upright, 0x84 tilted, 0x88 settling). Exposed for experimentation.
    public var highByte: Int { raw >> 8 }
    public var lowByte: Int { raw & 0xFF }
}

/// Cap open/closed state, notified on the debug characteristic as `81 02 00 00` (open)
/// and `80 02 00 00` (closed). Bit 0 of byte 0 is the flag.
public enum CapState: String, Sendable, Hashable {
    case open
    case closed

    public init?(data: Data) {
        guard let first = data.first, data.count <= 4 else { return nil }
        // Only accept the observed frame shape; anything else on this characteristic
        // is surfaced as an unknown notification instead of being misread as a cap event.
        guard first & 0xFE == 0x80 else { return nil }
        self = (first & 0x01) == 1 ? .open : .closed
    }
}

/// LED patterns accepted on the LED control characteristic. Only the first two are
/// confirmed to do anything on current firmware.
public enum LEDPattern: UInt8, Sendable, CaseIterable, Identifiable {
    case shortPulseWhite = 0x02
    case shortStrobeRed = 0x16
    case tripleTriplePulse = 0x34

    public var id: UInt8 { rawValue }

    public var title: String {
        switch self {
        case .shortPulseWhite: "Short white pulse"
        case .shortStrobeRed: "Short red strobe"
        case .tripleTriplePulse: "Three triple pulses"
        }
    }
}

public extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
